#!/bin/bash
# Test harness for PHASE CRON.
#
# patch_cron_locks rewrites real PHP source, so it is exercised against a
# throwaway copy of the actual cronbot/ directory rather than a mock.
# The functions are extracted from install.sh instead of sourcing it,
# because sourcing would trip the root check and run main().

SRC="$(dirname "$0")/install.sh"
CRONSRC="$(dirname "$0")/cronbot"
SANDBOX="/tmp/mirza_crontest.$$"

pass=0; fail=0
ok()   { echo "  ok   - $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL - $1"; fail=$((fail+1)); }
note() { echo "         note: $1"; }
sec()  { echo ""; echo "== $1 =="; }

# ── Extract the functions under test ───────────────────────────────────────
FNS="$SANDBOX/fns.sh"
mkdir -p "$SANDBOX"
sed -n '/^# Quoted delimiter: this is PHP source/,/^export -f patch_cron_locks$/p' "$SRC" > "$FNS"
sed -n '/^write_cron_file()/,/^export -f write_cron_file$/p' "$SRC" >> "$FNS"
sed -n '/^CRON_JOBS_SPEC="/,/^export CRON_JOBS_SPEC$/p' "$SRC" >> "$FNS"

if ! grep -q 'patch_cron_locks()' "$FNS"; then
    echo "FATAL: could not extract patch_cron_locks from $SRC"; exit 1
fi
if ! grep -q 'write_cron_file()' "$FNS"; then
    echo "FATAL: could not extract write_cron_file from $SRC"; exit 1
fi

BOT_DIR="$SANDBOX/bot"
PHP_BIN="$(command -v php || echo php)"
CRON_FILE="$SANDBOX/cron.d_mirzabot"
FAKE_CRONTAB="$SANDBOX/root.crontab"
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/crontab" <<'SH'
#!/bin/sh
if [ "$1" = "-l" ]; then
    [ -f "$FAKE_CRONTAB" ] && cat "$FAKE_CRONTAB"
    exit 0
fi
cat "$1" > "$FAKE_CRONTAB"
SH
chmod +x "$SANDBOX/bin/crontab"
PATH="$SANDBOX/bin:$PATH"
export BOT_DIR PHP_BIN CRON_FILE FAKE_CRONTAB PATH
mkdir -p "$BOT_DIR"
cp -r "$CRONSRC" "$BOT_DIR/cronbot"
# shellcheck disable=SC1090
source "$FNS"

HAVE_PHP=0
"$PHP_BIN" --version >/dev/null 2>&1 && HAVE_PHP=1

sec "extraction"
ok "extracted patch_cron_locks + write_cron_lock_helper + write_cron_file"
spec_n=$(printf '%s\n' "$CRON_JOBS_SPEC" | grep -c '|')
[ "$spec_n" -eq 17 ] && ok "CRON_JOBS_SPEC has 17 entries" || bad "CRON_JOBS_SPEC has $spec_n entries, expected 17"

# ── Child-shell boundary ───────────────────────────────────────────────────
# run_step executes every command with `bash -c`. A function that is not
# export -f'd, or a bash ARRAY (which cannot be exported at all), silently
# vanishes there. Sourcing the functions hides this entire class of bug, so
# it is exercised the way run_step really invokes them.
sec "child-shell boundary (how run_step actually calls these)"
for fn in write_cron_lock_helper patch_cron_locks write_cron_file; do
    grep -q "^export -f $fn\$" "$SRC" && ok "$fn is export -f'd" || bad "$fn NOT exported - would be 'command not found' in run_step"
done
grep -qE '^\s*export CRON_JOBS_SPEC' "$SRC" && ok "CRON_JOBS_SPEC is exported" || bad "CRON_JOBS_SPEC not exported"
grep -q 'CRON_JOBS=(' "$SRC" && bad "a bash array is still used - arrays cannot cross bash -c" || ok "no bash array used for the job spec"
grep -qE '^\s*export PHP_BIN CRON_FILE' "$SRC" && ok "PHP_BIN and CRON_FILE are exported" || bad "PHP_BIN/CRON_FILE not exported - child would fall back to a bare 'php'"

# ── Baseline ───────────────────────────────────────────────────────────────
sec "baseline"
before_count=$(ls "$BOT_DIR/cronbot"/*.php | wc -l)
ok "sandbox seeded with $before_count php files"

# ── First patch run ────────────────────────────────────────────────────────
sec "first patch run"
out1=$(write_cron_lock_helper && patch_cron_locks 2>&1)
rc1=$?
[ "$rc1" -eq 0 ] && ok "patch_cron_locks exit 0" || { bad "patch_cron_locks exit $rc1"; echo "$out1"; }
[ -f "$BOT_DIR/cronbot/_lock.php" ] && ok "_lock.php created" || bad "_lock.php missing"
echo "         $out1"

# Every real cron script must now call the lock.
missing=""
for f in "$BOT_DIR/cronbot"/*.php; do
    b=$(basename "$f")
    [ "$b" = "_lock.php" ] && continue
    head -1 "$f" | grep -q '<?php' || continue
    grep -q 'mirza_cron_lock' "$f" || missing="$missing $b"
done
[ -z "$missing" ] && ok "every <?php cron script calls mirza_cron_lock" || bad "not patched:$missing"

# index.php is NOT php (plain 'script runed!' marker) and must be untouched.
if [ -f "$BOT_DIR/cronbot/index.php" ]; then
    if grep -q 'mirza_cron_lock' "$BOT_DIR/cronbot/index.php"; then
        bad "cronbot/index.php was patched but is not a PHP file"
    else
        ok "cronbot/index.php correctly skipped (not a <?php file)"
    fi
fi

# The lock must be inserted after the opening tag, not before it.
badpos=""
for f in "$BOT_DIR/cronbot"/*.php; do
    b=$(basename "$f"); [ "$b" = "_lock.php" ] && continue
    grep -q 'mirza_cron_lock' "$f" || continue
    [ "$(head -1 "$f" | tr -d '\r')" = "<?php" ] || badpos="$badpos $b"
done
[ -z "$badpos" ] && ok "opening <?php still on line 1 everywhere" || bad "line 1 clobbered in:$badpos"

# ── Syntax ─────────────────────────────────────────────────────────────────
sec "php syntax after patching"
if [ "$HAVE_PHP" -eq 1 ]; then
    syntaxbad=""
    for f in "$BOT_DIR/cronbot"/*.php; do
        head -1 "$f" | grep -q '<?php' || continue
        "$PHP_BIN" -l "$f" >/dev/null 2>&1 || syntaxbad="$syntaxbad $(basename "$f")"
    done
    [ -z "$syntaxbad" ] && ok "php -l clean on all patched files" || bad "php -l failed:$syntaxbad"
else
    note "php not on PATH here - syntax check skipped (runs for real on the server)"
fi

# ── Idempotency ────────────────────────────────────────────────────────────
sec "idempotency (simulates repair / re-run)"
sum_before=$(cat "$BOT_DIR/cronbot"/*.php | md5sum | cut -d' ' -f1)
out2=$(patch_cron_locks 2>&1)
sum_after=$(cat "$BOT_DIR/cronbot"/*.php | md5sum | cut -d' ' -f1)
[ "$sum_before" = "$sum_after" ] && ok "second run changed nothing" || bad "second run modified files"
echo "$out2" | grep -q 'Locked 0 ' && ok "second run reports 0 newly locked" || note "second run said: $out2"

dupes=""
for f in "$BOT_DIR/cronbot"/*.php; do
    n=$(grep -c 'mirza_cron_lock' "$f")
    [ "$n" -gt 2 ] && dupes="$dupes $(basename "$f"):$n"
done
[ -z "$dupes" ] && ok "no duplicated lock guards" || bad "duplicate guards in:$dupes"

# ── Update path: fresh files overwrite patched ones ────────────────────────
sec "update path (fresh download replaces patched files)"
cp -f "$CRONSRC/croncard.php" "$BOT_DIR/cronbot/croncard.php"
grep -q 'mirza_cron_lock' "$BOT_DIR/cronbot/croncard.php" && bad "sandbox reset failed" || ok "croncard.php reset to unpatched"
patch_cron_locks >/dev/null 2>&1
grep -q 'mirza_cron_lock' "$BOT_DIR/cronbot/croncard.php" && ok "re-patched after simulated update" || bad "not re-patched after update"

# ── cron.d file ────────────────────────────────────────────────────────────
# Invoked through `bash -c` exactly as run_step does, so a missing export
# fails here instead of on the operator's server.
sec "cron.d file (invoked via bash -c, like run_step)"
export -f write_cron_lock_helper patch_cron_locks write_cron_file
export CRON_JOBS_SPEC BOT_DIR PHP_BIN CRON_FILE
printf '%s\n' '*/1 * * * * curl https://old.example.com/cronbot/croncard.php' '# keep-me' > "$FAKE_CRONTAB"
child_out=$(bash -c 'write_cron_file' 2>&1)
child_rc=$?
[ "$child_rc" -eq 0 ] && ok "write_cron_file ran in a child shell" || bad "child shell failed ($child_rc): $child_out"
[ -f "$CRON_FILE" ] && ok "cron file written" || bad "cron file missing"
lines=$(grep -cE '^\*|^0' "$CRON_FILE")
[ "$lines" -eq 17 ] && ok "17 job lines emitted" || bad "$lines job lines, expected 17"
grep -q 'www-data' "$CRON_FILE" && ok "user field present (required by cron.d)" || bad "no user field"
grep -q 'MAILTO' "$CRON_FILE" && ok "MAILTO set (no mail spam)" || bad "MAILTO missing"
grep -q 'old.example.com/cronbot/croncard.php' "$FAKE_CRONTAB" 2>/dev/null \
    && bad "legacy root cronbot curl entry kept" \
    || ok "legacy root cronbot curl entry pruned"
grep -q 'keep-me' "$FAKE_CRONTAB" 2>/dev/null \
    && ok "non-Mirza root crontab entry preserved" \
    || bad "non-Mirza root crontab entry removed"

# A job for a script that does not exist must be skipped, not emitted.
rm -f "$BOT_DIR/cronbot/lottery.php" 2>/dev/null
mv "$BOT_DIR/cronbot/gift.php" "$SANDBOX/gift.away"
write_cron_file
grep -q 'gift.php' "$CRON_FILE" && bad "emitted a job for a missing script" || ok "missing script skipped"
mv "$SANDBOX/gift.away" "$BOT_DIR/cronbot/gift.php"

# Each emitted line must be a well-formed cron.d entry:
# 5 schedule fields, then a user, then the command.
malformed=0
while read -r line; do
    case "$line" in \#*|""|SHELL=*|PATH=*|MAILTO=*) continue ;; esac
    f=$(echo "$line" | awk '{print $6}')
    [ "$f" = "www-data" ] || malformed=$((malformed+1))
done < "$CRON_FILE"
[ "$malformed" -eq 0 ] && ok "every job line has 5 schedule fields + user" || bad "$malformed malformed cron line(s)"
grep -q "$BOT_DIR/cronbot" "$CRON_FILE" || grep -q "cd $BOT_DIR" "$CRON_FILE" && ok "commands reference BOT_DIR" || bad "BOT_DIR missing from commands"

echo ""
echo "── $pass passed, $fail failed ──"
rm -rf "$SANDBOX"
[ "$fail" -eq 0 ]
