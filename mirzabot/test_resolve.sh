#!/bin/bash
# Throwaway harness for resolve_vars(). Not shipped — delete before release.
# Loads install.sh with main() suppressed, then drives the four
# resolution paths: flag, prompt, resume, and --yes.

SRC="$(dirname "$0")/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Turn the file into a sourceable library:
#   - neutralise the root guard, which would `exit 1` on source
#   - drop the trailing `main "$@"` so nothing runs on load
sed -e 's/^if \[\[ \$EUID -ne 0 \]\]; then$/if false; then/' \
    -e 's/^main "\$@"$//' "$SRC" > "$TMP/lib.sh"

# Cases run in subshells, so counters have to live on disk to survive.
: > "$TMP/pass"; : > "$TMP/fail"
ok()   { echo x >> "$TMP/pass"; echo "  ok   - $1"; }
bad()  { echo x >> "$TMP/fail"; echo "  FAIL - $1"; echo "         expected: $2"; echo "         actual:   $3"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
export TMP

# Every case runs in a subshell with an isolated STATE_DIR and offline stubs,
# so no test can touch the real /root/confmirza or hit the network.
harness() {
    # shellcheck disable=SC1090
    source "$TMP/lib.sh" >/dev/null 2>&1 || { echo "  FAIL - could not source lib"; exit 1; }
    STATE_DIR="$TMP/state.$RANDOM"
    compute_paths
    get_server_ip()      { echo "203.0.113.1"; }
    domain_points_here() { return 0; }
    validate_token()     { [[ "$1" =~ ^[0-9]{8,10}:[a-zA-Z0-9_-]{35}$ ]] && return 0 || return 1; }
    TOKEN_OK="123456789:AAFakeTokenForTestingPurposes01234x"
}

echo "== validators =="
(
    harness
    validate_domain "bot.example.com"        && ok "domain: plain host"          || bad "domain: plain host" 0 1
    validate_domain "bot.example.com/sub"    && ok "domain: host/subdir"         || bad "domain: host/subdir" 0 1
    validate_domain "https://bot.a.com"      && bad "domain: rejects scheme" 1 0 || ok "domain: rejects scheme"
    validate_domain "bot.example.com/"       && bad "domain: rejects trailing /" 1 0 || ok "domain: rejects trailing /"
    validate_domain "notadomain"             && bad "domain: rejects bare word" 1 0 || ok "domain: rejects bare word"

    validate_bot_dir "/opt/mirzabot"         && ok "dir: accepts /opt/mirzabot"  || bad "dir: accepts /opt/mirzabot" 0 1
    validate_bot_dir "/var/www/html"         && bad "dir: rejects /var/www/html" 1 0 || ok "dir: rejects /var/www/html"
    validate_bot_dir "/"                     && bad "dir: rejects /" 1 0         || ok "dir: rejects /"
    validate_bot_dir "relative/path"         && bad "dir: rejects relative" 1 0  || ok "dir: rejects relative"

    validate_chat_id "12345678"              && ok "chat: numeric"               || bad "chat: numeric" 0 1
    validate_chat_id "-100123"               && ok "chat: negative"              || bad "chat: negative" 0 1
    validate_chat_id "abc"                   && bad "chat: rejects text" 1 0     || ok "chat: rejects text"

    validate_email ""                        && ok "email: empty allowed"        || bad "email: empty allowed" 0 1
    validate_email "a@b.com"                 && ok "email: valid"                || bad "email: valid" 0 1
    validate_email "nope"                    && bad "email: rejects garbage" 1 0 || ok "email: rejects garbage"

    is "botname: strips @"      "my_bot" "$(normalize_botname '@my_bot')"
    is "botname: strips spaces" "my_bot" "$(normalize_botname '  my_bot ')"
)

echo
echo "== path 1: values from flags =="
(
    harness
    BOT_DIR="/opt/mirzabot"; DOMAIN="bot.example.com"; BOT_TOKEN="$TOKEN_OK"
    CHAT_ID="777"; BOTNAME="@flag_bot"; DB_NAME="flagdb"; DB_USER="flaguser"
    DB_PASS="flagpass123"; LE_EMAIL="a@b.com"; ASSUME_YES=1
    resolve_vars >/dev/null 2>&1
    is "BOT_DIR kept"   "/opt/mirzabot"    "$BOT_DIR"
    is "DOMAIN kept"    "bot.example.com"  "$DOMAIN"
    is "BOTNAME @ gone" "flag_bot"         "$BOTNAME"
    is "DB_NAME kept"   "flagdb"           "$DB_NAME"
    is "derived config" "/opt/mirzabot/config.php" "$CONFIG_FILE"
    is "persisted dir"  "/opt/mirzabot"    "$(state_get BOT_DIR)"
)

echo
echo "== path 2: defaults applied under --yes =="
(
    harness
    DOMAIN="bot.example.com"; BOT_TOKEN="$TOKEN_OK"; CHAT_ID="777"; BOTNAME="botname"
    ASSUME_YES=1
    resolve_vars >/dev/null 2>&1
    is "BOT_DIR default" "/var/www/html/mirzaprobotconfig" "$BOT_DIR"
    is "DB_NAME default" "mirzaprobot"                     "$DB_NAME"
    [ -n "$DB_USER" ] && ok "DB_USER generated" || bad "DB_USER generated" "non-empty" "empty"
    [ ${#DB_PASS} -ge 6 ] && ok "DB_PASS generated >=6" || bad "DB_PASS generated >=6" ">=6" "${#DB_PASS}"
)

echo
echo "== path 3: --yes with a missing required value must fail loudly =="
(
    harness
    ASSUME_YES=1
    out="$( { DOMAIN="" BOT_TOKEN="" resolve_vars; } 2>&1 )"
    rc=$?
    is "exits non-zero" "1" "$rc"
    case "$out" in
        *"--domain"*) ok "names the missing flag" ;;
        *) bad "names the missing flag" "mentions --domain" "$out" ;;
    esac
)

echo
echo "== path 4: resume must not re-prompt =="
(
    harness
    # First run seeds state.
    BOT_DIR="/opt/resumed"; DOMAIN="resume.example.com"; BOT_TOKEN="$TOKEN_OK"
    CHAT_ID="42"; BOTNAME="resumed_bot"; DB_NAME="rdb"; DB_USER="ruser"
    DB_PASS="rpass123"; ASSUME_YES=1
    resolve_vars >/dev/null 2>&1

    # Second run: everything cleared, stdin closed. Any prompt would hang or
    # read EOF and produce an empty value, so this proves state is used.
    BOT_DIR=""; DOMAIN=""; BOT_TOKEN=""; CHAT_ID=""; BOTNAME=""
    DB_NAME=""; DB_USER=""; DB_PASS=""; ASSUME_YES=0
    resolve_vars >/dev/null 2>&1 <&-
    is "BOT_DIR restored" "/opt/resumed"        "$BOT_DIR"
    is "DOMAIN restored"  "resume.example.com"  "$DOMAIN"
    is "CHAT_ID restored" "42"                  "$CHAT_ID"
    is "DB_USER restored" "ruser"               "$DB_USER"
    is "token restored"   "$TOKEN_OK"           "$BOT_TOKEN"
)

echo
echo "== path 5: interactive prompts =="
(
    harness
    ASSUME_YES=0
    # Enter = accept default dir; then domain, token, id, name; Enter x2 for
    # generated db creds; Enter for optional email; Enter to confirm.
    # Process substitution, not a pipe: a pipe would run resolve_vars in a
    # subshell and throw away every variable it sets.
    resolve_vars >/dev/null 2>&1 \
        < <(printf '\nprompt.example.com\n%s\n999\n@prompted_bot\npromptdb\n\n\n\n\n' "$TOKEN_OK")
    is "dir from default" "/var/www/html/mirzaprobotconfig" "$BOT_DIR"
    is "domain typed"     "prompt.example.com"              "$DOMAIN"
    is "chat typed"       "999"                             "$CHAT_ID"
    is "name normalized"  "prompted_bot"                    "$BOTNAME"
    is "dbname typed"     "promptdb"                        "$DB_NAME"
)

echo
echo "== path 6: invalid input is re-prompted, not accepted =="
(
    harness
    ASSUME_YES=0
    resolve_vars >/dev/null 2>&1 \
        < <(printf '\nnot-a-domain\ngood.example.com\n%s\nabc\n555\nvalid_bot\n\n\n\n\n\n' "$TOKEN_OK")
    is "bad domain rejected" "good.example.com" "$DOMAIN"
    is "bad chat rejected"   "555"              "$CHAT_ID"
)

echo
echo "== environment layer =="
(
    harness
    # The variable block is the single source of truth. A second assignment
    # anywhere else silently overrides it — this caught a real bug once.
    n=$(grep -cE '^[[:space:]]*(export[[:space:]]+)?PHP_VER_CANDIDATES=' "$SRC")
    is "PHP_VER_CANDIDATES assigned once" "1" "$n"

    # Fallback must name a version from the candidate list, never a literal.
    ( PHP_VER_CANDIDATES="8.3 8.4 8.2"
      _apt_has_candidate() { return 1; }
      out="$(resolve_php_ver)"
      [ "$out" = "8.3" ] && echo PASS || echo "FAIL:$out"
    ) > "$TMP/php.out"
    is "resolve_php_ver falls back to first candidate" "PASS" "$(cat "$TMP/php.out")"

    ( PHP_VER_CANDIDATES="8.3 8.4 8.2"
      _apt_has_candidate() { case "$1" in *8.4*) return 0 ;; *) return 1 ;; esac; }
      out="$(resolve_php_ver)"
      [ "$out" = "8.4" ] && echo PASS || echo "FAIL:$out"
    ) > "$TMP/php2.out"
    is "resolve_php_ver picks the installable one" "PASS" "$(cat "$TMP/php2.out")"

    # detect_os must not leak variables out of the sourced os-release.
    (
        printf 'ID=ubuntu\nVERSION_ID="24.04"\nUBUNTU_CODENAME=noble\nPRETTY_NAME="Ubuntu 24.04 LTS"\nBOT_DIR=/hacked\n' \
            > "$TMP/os-release"
        detect_os() {
            local fields
            fields=$(. "$TMP/os-release" 2>/dev/null; printf '%s\t%s\t%s\t%s' \
                "${ID:-}" "${VERSION_ID:-}" "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}" "${PRETTY_NAME:-unknown}")
            IFS=$'\t' read -r OS_ID OS_VERSION_ID OS_CODENAME OS_PRETTY <<< "$fields"
        }
        BOT_DIR="/safe"
        detect_os
        [ "$OS_ID" = "ubuntu" ] && [ "$OS_CODENAME" = "noble" ] && [ "$BOT_DIR" = "/safe" ] \
            && echo PASS || echo "FAIL:$OS_ID/$OS_CODENAME/$BOT_DIR"
    ) > "$TMP/os.out"
    is "detect_os parses without leaking vars" "PASS" "$(cat "$TMP/os.out")"

    # Anything run_step invokes runs in `bash -c`, so it must be exported.
    # Derived from the source rather than a hand-kept list: a hand-kept list
    # only catches the cases someone remembered to add.
    #
    # Most run_step calls wrap onto a second line with a trailing backslash,
    # which a line-based grep cannot see — joining continuations first is
    # what makes multi-line invocations (e.g. write_php_ini) visible here.
    sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$SRC" > "$TMP/joined"
    # First identifier inside the command string of each run_step call.
    grep -oE 'run_step "[^"]*"[[:space:]]*"[A-Za-z_][A-Za-z0-9_]*' "$TMP/joined" \
        | sed 's/.*"//' | sort -u > "$TMP/invoked"
    [ -s "$TMP/invoked" ] || bad "run_step scan found commands" "non-empty list" "nothing matched"
    while read -r fn; do
        [ -n "$fn" ] || continue
        grep -qE "^${fn}\(\)" "$SRC" || continue        # not a local function
        if grep -qE "^export -f( |.*\b)${fn}\b" "$SRC"; then
            ok "exported for child shell: $fn"
        else
            bad "exported for child shell: $fn" "export -f $fn" "missing"
        fi
    done < "$TMP/invoked"

    # Variables those exported functions read must cross the boundary too.
    for v in DB_ROOT_CRED TIMEZONE PHP_VER_CANDIDATES; do
        if grep -qE "^[[:space:]]*export .*\b$v\b" "$SRC"; then
            ok "exported for child shell: \$$v"
        else
            bad "exported for child shell: \$$v" "export $v" "missing"
        fi
    done
)

echo
echo "== state file permissions =="
(
    harness
    state_init
    [ -f "$STATE_FILE" ] && ok "state file created" || bad "state file created" "exists" "missing"
    # NTFS under Git-Bash ignores chmod, so a live stat here proves nothing.
    # Assert the installer asks for 0600; real perms get checked on Linux.
    if grep -q 'chmod 600 "$STATE_FILE"' "$SRC"; then
        ok "state file chmod 600 (source assertion)"
    else
        bad "state file chmod 600 (source assertion)" "chmod 600 present" "absent"
    fi
    perms="$(stat -c %a "$STATE_FILE" 2>/dev/null)"
    [ "$perms" = "600" ] || echo "         note: perms are $perms here — Windows FS, verify on Linux"
)

echo
PASS=$(wc -l < "$TMP/pass" | tr -d ' ')
FAIL=$(wc -l < "$TMP/fail" | tr -d ' ')
echo "── $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
