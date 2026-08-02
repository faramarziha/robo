#!/bin/bash
# Static checks for install.sh.
#
# shellcheck is not available on the dev machine, so this covers the specific
# failure classes that actually matter for THIS script: an unquoted path in an
# rm, a variable used before resolve_vars fills it, a function called inside
# run_step's child shell without being exported, and secrets on a command line.
# Those are the ways this installer can damage a server, as opposed to style.

SRC="$(dirname "$0")/install.sh"
pass=0; fail=0

# Many calls in the script wrap onto a continuation line, so a per-line grep
# sees half a statement and draws the wrong conclusion. FLAT is the same source
# with `\`-newlines joined, for checks that need a whole statement.
FLAT="$(mktemp)"
trap 'rm -f "$FLAT"' EXIT
sed -e :a -e '/\\$/N; s/\\\n\s*//; ta' "$SRC" > "$FLAT"

ok()  { echo "  ok   - $1"; pass=$((pass+1)); }
bad() { echo "  FAIL - $1"; fail=$((fail+1)); }
sec() { echo ""; echo "== $1 =="; }

sec "syntax"
bash -n "$SRC" 2>/dev/null && ok "bash -n clean" || { bad "bash -n failed"; bash -n "$SRC"; }

# ── Destructive commands must quote their target ───────────────────────────
# An unquoted $BOT_DIR containing a space turns `rm -rf /opt/my bot` into two
# arguments and deletes /opt/my. Every rm/mv/cp target must be quoted.
sec "destructive commands quote their arguments"
unq=$(grep -nE '^[^#]*\b(rm|mv|cp) (-[a-zA-Z]+ )*\$[A-Za-z_]' "$SRC")
[ -z "$unq" ] && ok "no unquoted rm/mv/cp target" || { bad "unquoted target:"; echo "$unq"; }

# rm -rf on a bare variable is the single most dangerous line in an installer.
# Each one must be a path this script built, not raw operator input.
sec "rm -rf targets"
while IFS= read -r line; do
    case "$line" in
        # $BOT_DIR is validated by validate_bot_dir before every use; $tmp and
        # $old are paths this script built with a $$ suffix.
        *'"$BOT_DIR"'*|*'"$tmp"'*|*'"$old"'*|*'"$OLD"'*|*'"$NEW"'*|*'"$dest"'*|*'$SANDBOX'*)
            ok "safe: ${line#*:}" ;;
        # repair_mysql purging a broken MySQL. Literal paths, no variable, and
        # it only runs during DEPS, which precheck_fresh_server has already
        # proven has no pre-existing database on it.
        *'/var/lib/mysql /var/log/mysql /etc/mysql'*)
            ok "safe (repair_mysql, DEPS-only): ${line#*:}" ;;
        # carry_runtime_data clearing a destination before copying an agent in.
        # $new is built by this script and $base comes from basename, which
        # cannot return empty for an existing path.
        *'"$new/vpnbot/$base"'*)
            ok "safe (destination clear): ${line#*:}" ;;
        *) bad "review: $line" ;;
    esac
done < <(grep -nE '^[^#]*rm -rf ' "$SRC")

# ── Exported functions ─────────────────────────────────────────────────────
# run_step executes its command with `bash -c`, a child process. A function
# called there that was never `export -f`'d dies with "command not found",
# and because run_step only surfaces the exit code the operator sees a bare
# failed step with no explanation.
sec "functions used inside run_step are exported"
# Checked unconditionally rather than by pattern-matching the call site: a
# run_step invocation is often split across two lines, so "is it called in a
# child shell" is exactly the thing a grep gets wrong. These all are.
for fn in apt_recover setup_php_repo resolve_php_ver repair_mysql write_php_ini \
          write_pma_restrict write_cron_lock_helper patch_cron_locks write_cron_file \
          setup_mysql_root install_php_deps ensure_composer carry_runtime_data; do
    grep -qE "^$fn\(\)" "$SRC" || { bad "$fn is not defined"; continue; }
    grep -qE "^export -f .*\b$fn\b" "$SRC" \
        && ok "$fn exported" \
        || bad "$fn runs in a child shell but is never exported"
done

# Variables those exported functions read must cross the boundary too.
sec "variables used by exported functions are exported"
for v in TIMEZONE CRON_JOBS_SPEC PRESERVE_PATHS PHP_VER_CANDIDATES; do
    grep -qE "^export .*\b$v\b" "$SRC" && ok "$v exported" \
        || bad "$v is read by an exported function but never exported"
done

# ── Unattended mode ────────────────────────────────────────────────────────
# README promises: --yes never invents a domain, token or admin ID; it stops
# and names the missing flag. A value that silently defaults to empty here
# produces an install that looks successful but cannot receive an update.
sec "--yes refuses to guess required values"
# _resolve <VAR> <KEY> <prompt> <flag> <validator> <required> <default>
# required=1 with an empty default is what makes it hard-fail.
for v in DOMAIN CHAT_ID; do
    if grep -E "_resolve $v " "$FLAT" | grep -qE ' 1 ""\s*$'; then
        ok "$v is required with no default"
    else
        bad "$v could resolve to empty under --yes"
    fi
done
# These two are hand-rolled loops rather than _resolve, so they need their own
# guard - without it --yes spins forever on a `read` against a closed stdin.
for v in "Bot token" "Bot username"; do
    grep -qF "_missing_required \"$v\"" "$SRC" \
        && ok "$v guarded under --yes" \
        || bad "$v would block on read under --yes"
done
# Anything with a generated default is fine to leave unattended; assert they
# actually have one, so a future edit does not turn them into a hard stop.
for v in DB_NAME BOT_DIR; do
    grep -E "_resolve $v " "$FLAT" | grep -qE ' 1 "\$[A-Za-z_]+"\s*$' \
        && ok "$v has a default" \
        || bad "$v is required but has no default - --yes will fail"
done

# ── Secrets ────────────────────────────────────────────────────────────────
# Anything on a command line is visible in `ps` to every local user.
sec "no secrets on a command line"
grep -nE "mysql(dump)? [^|]*-p[\"'\$]" "$SRC" | grep -v MYSQL_PWD | grep -q . \
    && bad "mysql password passed with -p" || ok "mysql uses MYSQL_PWD"
grep -nE 'debconf-set-selections <<' "$SRC" | grep -q . \
    && bad "debconf preseed via heredoc puts passwords in the process tree" \
    || ok "debconf preseed piped, not inlined"

# ── Variable block discipline ──────────────────────────────────────────────
# The whole point of the rewrite: each path is declared once. The old script
# repeated BOT_DIR_DEFAULT eleven times and they drifted apart.
sec "no re-literalised paths"
for lit in '/var/www/html/mirzaprobotconfig' '/root/confmirza' '/usr/local/bin/mirza' '/etc/cron.d/mirzabot'; do
    # One definition, plus any number of uses through the variable. Comments
    # and help text are allowed to name the path.
    n=$(grep -vE '^\s*#' "$SRC" | grep -cF "$lit")
    if [ "$n" -le 2 ]; then
        ok "$lit literal appears $n time(s)"
    else
        bad "$lit hard-coded $n times - use the variable"
    fi
done

# ── Resume safety ──────────────────────────────────────────────────────────
# Every phase must be guarded, or a resumed install redoes completed work.
sec "phases are resume-guarded"
for ph in DEPS TUNE FILES DBROOT DB PMA SSL VHOST CONFIG TABLES CRON WEBHOOK; do
    grep -qE "phase_done $ph" "$SRC" && grep -qE "mark_phase $ph" "$SRC" \
        && ok "$ph guarded and marked" \
        || bad "$ph missing phase_done or mark_phase"
done

echo ""
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
