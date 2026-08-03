#!/bin/bash
# Test harness for the lifecycle commands.
#
# The critical contract is the render_config -> config_get round-trip: every
# lifecycle command (update, backup, uninstall, change-*) reads its settings
# back out of config.php through config_get. If that parse silently returns
# empty, `mirza backup` dumps nothing and `mirza uninstall` drops nothing --
# both failing quietly. So the round-trip is tested with awkward but legal
# values rather than a tidy happy path.

SRC="$(dirname "$0")/install.sh"
SANDBOX="/tmp/mirza_lifetest.$$"
mkdir -p "$SANDBOX"

pass=0; fail=0
ok()   { echo "  ok   - $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL - $1"; fail=$((fail+1)); }
sec()  { echo ""; echo "== $1 =="; }

# ── Extract the functions under test ───────────────────────────────────────
FNS="$SANDBOX/fns.sh"
sed -n '/^render_config()/,/^}$/p'   "$SRC" >  "$FNS"
sed -n '/^config_get()/,/^}$/p'      "$SRC" >> "$FNS"
sed -n '/^validate_domain()/,/^}$/p' "$SRC" >> "$FNS"
sed -n '/^validate_bot_dir()/,/^}$/p' "$SRC" >> "$FNS"
for f in render_config config_get validate_domain validate_bot_dir; do
    grep -q "^$f()" "$FNS" || { echo "FATAL: could not extract $f"; exit 1; }
done
# shellcheck disable=SC1090
source "$FNS"

sec "extraction"
ok "extracted render_config + config_get + validators"

# ── Round-trip ─────────────────────────────────────────────────────────────
# Values chosen to break a naive parser: a token with ':' and '-', a domain
# with a /subdir, a negative chat id (supergroups), a password with '_'.
CONFIG_FILE="$SANDBOX/config.php"
DB_NAME="mirzaprobot"
DB_USER="aB3xY9zQ"
DB_PASS="p_ss12_wrd_9XyZ"
BOT_TOKEN="7123456789:AAH-abcdefghijklmnopqrstuvwxyz012345"
CHAT_ID="-1001234567890"
DOMAIN="bot.example.com/sub"
BOTNAME="my_vpn_bot"
SECRET_TOKEN="Xk9mQ2vB"
render_config


sec "render_config output"
[ -f "$CONFIG_FILE" ] && ok "config.php written" || bad "config.php missing"
head -1 "$CONFIG_FILE" | grep -q '<?php' && ok "starts with <?php" || bad "missing opening tag"
grep -q 'die("error: database connection failed")' "$CONFIG_FILE" \
    && ok "database connection failure is fatal" \
    || bad "config.php would continue after a failed PDO connection"

if command -v php >/dev/null 2>&1; then
    php -l "$CONFIG_FILE" >/dev/null 2>&1 && ok "php -l accepts the generated file" || {
        bad "generated config.php is not valid PHP"; php -l "$CONFIG_FILE"; }
else
    echo "         note: php not on PATH - syntax check skipped"
fi

# The PHP sources read these exact names; a rename silently breaks the bot.
for v in dbhost dbname usernamedb passworddb APIKEY adminnumber domainhosts usernamebot webhook_secret; do
    grep -q "^\$$v = " "$CONFIG_FILE" && ok "\$$v present" || bad "\$$v MISSING - the bot reads this name"

done

sec "config_get round-trip"
check() {
    local got; got="$(config_get "$1")"
    [ "$got" = "$2" ] && ok "$1 round-trips ($got)" || bad "$1 got '$got', expected '$2'"
}
check dbname      "$DB_NAME"
check usernamedb  "$DB_USER"
check passworddb  "$DB_PASS"
check APIKEY      "$BOT_TOKEN"
check adminnumber "$CHAT_ID"
check domainhosts "$DOMAIN"
check usernamebot "$BOTNAME"
# 'mirza repair' re-runs setWebhook, and it must register the same secret the
# running bot enforces. If this read comes back empty, repair silently hands
# Telegram a new secret and every subsequent update is rejected with a 403.
check webhook_secret "$SECRET_TOKEN"


# $dbname must not be satisfied by $dbhost, and $usernamedb must not be
# satisfied by $usernamebot: both pairs share a prefix.
[ "$(config_get dbhost)" = "localhost" ] && ok "dbhost not confused with dbname" || bad "prefix collision on dbhost/dbname"
[ "$(config_get usernamebot)" != "$DB_USER" ] && ok "usernamebot not confused with usernamedb" || bad "prefix collision on usernamedb/usernamebot"

sec "missing file"
CONFIG_FILE="$SANDBOX/nope.php"
[ -z "$(config_get dbname)" ] && ok "returns empty for a missing file" || bad "returned data for a missing file"
config_get dbname >/dev/null 2>&1; [ $? -ne 0 ] && ok "non-zero exit for a missing file" || bad "exit 0 for a missing file"

# ── Uninstall guard ────────────────────────────────────────────────────────
# cmd_uninstall runs `rm -rf "$BOT_DIR"`, so validate_bot_dir is the last
# thing standing between a typo and a wiped server.
sec "uninstall directory guard"
for d in / /root /etc /var /var/www /var/www/html /usr /bin /boot /home "" "relative/path" "/var/www/html/"; do
    if validate_bot_dir "$d"; then
        bad "would allow rm -rf on '$d'"
    else
        ok "refuses '$d'"
    fi
done
for d in /var/www/html/mirzaprobotconfig /opt/mirzabot; do
    validate_bot_dir "$d" && ok "allows '$d'" || bad "wrongly refuses '$d'"
done

# ── Domain validation ──────────────────────────────────────────────────────
sec "domain validation (change-domain input)"
for d in bot.example.com sub.bot.example.com bot.example.com/sub a-b.example.co.uk; do
    validate_domain "$d" && ok "accepts '$d'" || bad "wrongly rejects '$d'"
done
for d in "https://bot.example.com" "bot.example.com/" "notadomain" "" " " "-bad.example.com"; do
    validate_domain "$d" && bad "wrongly accepts '$d'" || ok "rejects '$d'"
done

# ── No stubs left ──────────────────────────────────────────────────────────
sec "no unimplemented commands"
if grep -qE '^\s*(update_bot|cmd_diagnose|cmd_repair|cmd_change_domain|cmd_change_token|renew_ssl|backup_to_telegram|migrate_bot|cmd_uninstall)\(\)\s*\{\s*_todo' "$SRC"; then
    bad "a command is still a _todo stub"
else
    ok "every dispatched command is implemented"
fi
grep -q '_todo()' "$SRC" && bad "the _todo helper is now dead code - remove it" || ok "no dead _todo helper"

# ── Runtime data carried across an update ──────────────────────────────────
# update mv's the whole tree aside and unpacks a fresh archive over it, so
# anything not explicitly copied back is destroyed. Agent sub-bots are the
# dangerous case: each vpnbot/<id><name>/ holds its own config.php with that
# reseller's token and is NOT in the release archive, so losing it is
# unrecoverable. Exercised end-to-end against a real directory tree, because
# asserting "the function is exported" says nothing about whether it works.
sec "carry_runtime_data (update must not destroy agent bots)"

CRD="$SANDBOX/crd.sh"
sed -n '/^carry_runtime_data()/,/^}$/p' "$SRC" >  "$CRD"
sed -n '/^PRESERVE_PATHS="/,/^storage"$/p' "$SRC" >> "$CRD"
grep -q '^carry_runtime_data()' "$CRD" && ok "extracted carry_runtime_data" \
    || bad "could not extract carry_runtime_data"
# shellcheck disable=SC1090
source "$CRD"

OLD="$SANDBOX/old"; NEW="$SANDBOX/new"
rm -rf "$OLD" "$NEW"
# Old tree: what a live server looks like before the update.
mkdir -p "$OLD/vpnbot/Default" "$OLD/vpnbot/123mybot/data" "$OLD/vpnbot/456other" "$OLD/api"
echo "<?php \$APIKEY='live-token';" > "$OLD/config.php"
echo "OLD-TEMPLATE"                 > "$OLD/vpnbot/Default/index.php"
echo "<?php \$APIKEY='agent-1';"    > "$OLD/vpnbot/123mybot/config.php"
echo '{"state":"live"}'             > "$OLD/vpnbot/123mybot/data/state.json"
echo "<?php \$APIKEY='agent-2';"    > "$OLD/vpnbot/456other/config.php"
echo "api-secret-hash"              > "$OLD/api/hash.txt"
echo "JPEGDATA"                     > "$OLD/custom.jpg"
# New tree: freshly unpacked archive. Ships the template, no operator data.
mkdir -p "$NEW/vpnbot/Default" "$NEW/api"
echo "NEW-TEMPLATE" > "$NEW/vpnbot/Default/index.php"
echo "<?php // stock" > "$NEW/index.php"

crd_out=$(bash -c "source '$CRD'; carry_runtime_data '$OLD' '$NEW'" 2>&1)
crd_rc=$?
[ "$crd_rc" -eq 0 ] && ok "ran in a child shell (as run_step invokes it)" \
    || bad "child shell failed ($crd_rc): $crd_out"

[ -f "$NEW/vpnbot/123mybot/config.php" ] && ok "agent bot directory preserved" \
    || bad "AGENT BOT LOST - its token is not in the archive and cannot be recovered"
grep -q 'agent-1' "$NEW/vpnbot/123mybot/config.php" 2>/dev/null \
    && ok "agent keeps its own token" || bad "agent config.php content lost"
[ -f "$NEW/vpnbot/123mybot/data/state.json" ] && ok "agent live data/ preserved" \
    || bad "agent data/ lost"
[ -f "$NEW/vpnbot/456other/config.php" ] && ok "second agent preserved" \
    || bad "only one agent carried over"

# The template must come from the NEW archive, or the update silently keeps
# shipping the old sub-bot code to every reseller.
grep -q 'NEW-TEMPLATE' "$NEW/vpnbot/Default/index.php" 2>/dev/null \
    && ok "vpnbot/Default kept at the new version" \
    || bad "vpnbot/Default was overwritten with the old template"

grep -q 'live-token' "$NEW/config.php" 2>/dev/null && ok "config.php carried over" \
    || bad "config.php lost - the bot would not start"
grep -q 'api-secret-hash' "$NEW/api/hash.txt" 2>/dev/null && ok "api/hash.txt carried over" \
    || bad "api/hash.txt lost - the API token would silently change"
[ -f "$NEW/custom.jpg" ] && ok "custom.jpg carried over" || bad "custom.jpg lost"

# Re-running must be safe: update can be retried after a partial failure.
bash -c "source '$CRD'; carry_runtime_data '$OLD' '$NEW'" >/dev/null 2>&1 \
    && ok "second run is idempotent" || bad "second run failed"

# A server with no agents at all must not error.
rm -rf "$SANDBOX/o2" "$SANDBOX/n2"; mkdir -p "$SANDBOX/o2" "$SANDBOX/n2"
echo "<?php" > "$SANDBOX/o2/config.php"
bash -c "source '$CRD'; carry_runtime_data '$SANDBOX/o2' '$SANDBOX/n2'" >/dev/null 2>&1 \
    && ok "no-agents install handled" || bad "failed when there was nothing to carry"

# update_bot must actually CALL it, and before it deletes the old tree.
grep -q 'carry_runtime_data' "$SRC" && ok "update_bot calls carry_runtime_data" \
    || bad "carry_runtime_data defined but never called"
crd_line=$(grep -n 'carry_runtime_data .\$old' "$SRC" | head -1 | cut -d: -f1)
rm_line=$(grep -n '^    rm -rf "\$old"' "$SRC" | head -1 | cut -d: -f1)
if [ -n "$crd_line" ] && [ -n "$rm_line" ] && [ "$crd_line" -lt "$rm_line" ]; then
    ok "runs before the old tree is deleted"
else
    bad "carry_runtime_data does not run before rm -rf \$old"
fi

# ── Self-installation ──────────────────────────────────────────────────────
# The summary tells the operator to run `mirza`, so the command has to exist.
sec "install_self"
grep -qE '^install_self\(\)' "$SRC" && ok "install_self defined" || bad "install_self missing"
grep -qE '\|\| install_self' "$SRC" && ok "invoked from main()" || bad "install_self never called"
# Re-exec'ing into a freshly downloaded script mid-run is what made the old
# installer replace itself during an unrelated `diagnose`.
grep -qE 'exec bash "\$MASTER_(SCRIPT|PATH)"' "$SRC" \
    && bad "still re-execs itself - a diagnose run could swap the script underneath itself" \
    || ok "never re-execs itself"
# Matches a real definition or call only. A bare grep would also hit the
# comment above install_self, which names the function to explain why it was
# dropped.
grep -vE '^\s*#' "$SRC" | grep -qE 'self_update_script\s*(\(\)|"|\$|$)' \
    && bad "self_update_script carried over from the old installer" \
    || ok "no silent GitHub self-update"
# uninstall promises to remove them, so it must.
grep -q 'rm -f "\$MASTER_SCRIPT" "\$BIN_LINK"' "$SRC" \
    && ok "uninstall removes the script and its symlink" \
    || bad "uninstall leaves /usr/local/bin/mirza pointing at a deleted install"

# ── Version reporting ──────────────────────────────────────────────────────
sec "get_installed_version"
grep -qE '^get_installed_version\(\)' "$SRC" && ok "get_installed_version defined" \
    || bad "get_installed_version missing"
# The old installer read $BOT_DIR_DEFAULT here, so a --dir install always
# reported "not installed".
sed -n '/^get_installed_version()/,/^}$/p' "$SRC" | grep -q 'BOT_DIR_DEFAULT' \
    && bad "reads BOT_DIR_DEFAULT - would misreport on a --dir install" \
    || ok "reads \$BOT_DIR, so --dir installs report correctly"
VERFILE_DIR="$SANDBOX/verdir"; mkdir -p "$VERFILE_DIR"
printf ' 9.9.9 \n' > "$VERFILE_DIR/version"
ver_out=$(BOT_DIR="$VERFILE_DIR" bash -c "$(sed -n '/^get_installed_version()/,/^}$/p' "$SRC"); get_installed_version")
[ "$ver_out" = "9.9.9" ] && ok "reads and trims the version file" || bad "got '$ver_out', expected '9.9.9'"
ver_missing=$(BOT_DIR="$SANDBOX/nope" bash -c "$(sed -n '/^get_installed_version()/,/^}$/p' "$SRC"); get_installed_version")
[ "$ver_missing" = "unknown" ] && ok "reports 'unknown' when absent" || bad "got '$ver_missing'"

# ── Vhost exposure ─────────────────────────────────────────────────────────
# The bot's document root is served directly, so anything sitting in the tree
# is downloadable unless the vhost says otherwise. These are the files that
# must never be reachable.
sec "vhost denies secrets and unauthenticated endpoints"
# api/hash.txt is a bearer token that api/utils.php:59 accepts as full admin
# auth. It is a .txt, so without a rule Apache just serves it.
grep -q '<Files "hash.txt">' "$SRC" \
    && ok "api/hash.txt denied (it is an admin API token)" \
    || bad "GET /api/hash.txt would return working admin credentials"
grep -q "<Directory \${BOT_DIR}/cronbot>" "$SRC" \
    && ok "cronbot/ denied" || bad "cronbot/ reachable over HTTP"
grep -q '<Files "table.php">' "$SRC" \
    && ok "table.php denied" || bad "table.php reachable over HTTP"
# mysqldump output and editor leftovers land in the tree during support work.
# grep -F: these patterns are full of backslashes, and escaping them twice for
# a regex is how the assertion ends up testing something other than the file.
grep -qF 'FilesMatch "\.(sql' "$SRC" \
    && ok "database dumps / logs / backups denied" || bad "a stray .sql dump would be downloadable"
grep -qF 'FilesMatch "^\."' "$SRC" \
    && ok "dotfiles denied" || bad "dotfiles (.env, .git) would be served"
# Both vhosts must carry the rules; denying only on :80 protects nothing.
http_deny=$(sed -n '/<VirtualHost \*:80>/,/<\/VirtualHost>/p' "$SRC" | grep -c 'deny_block')
tls_deny=$(sed -n '/<VirtualHost \*:443>/,/<\/VirtualHost>/p' "$SRC" | grep -c 'deny_block')
[ "$http_deny" -ge 1 ] && [ "$tls_deny" -ge 1 ] \
    && ok "deny rules applied to both :80 and :443" \
    || bad "deny rules missing from one vhost (:80=$http_deny :443=$tls_deny)"
# api/.htaccess is RewriteEngine + SetEnvIf; without these two modules the
# extensionless routes 404 and Authorization headers are dropped.
grep -qE 'a2enmod .*rewrite' "$SRC" && ok "mod_rewrite enabled (api/.htaccess needs it)" \
    || bad "api/.htaccess uses RewriteEngine but mod_rewrite is never enabled"
grep -qE 'a2enmod .*setenvif' "$SRC" && ok "mod_setenvif enabled (api/.htaccess SetEnvIf)" \
    || bad "api/.htaccess uses SetEnvIf but mod_setenvif is never enabled"
# AllowOverride All is what makes the shipped .htaccess files take effect.
grep -q 'AllowOverride All' "$SRC" && ok "AllowOverride All (shipped .htaccess honoured)" \
    || bad "AllowOverride not All - api/.htaccess would be ignored"

# ── Webhook authentication ─────────────────────────────────────────────────
# setWebhook registers a secret_token, and Telegram then stamps every genuine
# delivery with it. Nothing on the PHP side used to compare it, so the endpoint
# accepted hand-written POSTs from anyone who knew the domain -- and since
# botapi.php trusts $update['message']['from']['id'], a forged update could
# impersonate any user id, an admin's included. Both halves are pinned here:
# the installer must persist the secret, and index.php must enforce it.
sec "webhook secret enforcement"
INDEX="$(dirname "$0")/index.php"
if [ ! -f "$INDEX" ]; then
    bad "index.php not found beside install.sh - cannot verify enforcement"
else
    grep -q 'HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN' "$INDEX" \
        && ok "index.php reads the secret-token header" \
        || bad "index.php ignores the header - the webhook accepts forged updates"
    grep -q 'hash_equals($webhook_secret' "$INDEX" \
        && ok "compared with hash_equals (constant time)" \
        || bad "secret not compared with hash_equals"
    # A plain != returns early on the first wrong byte, which leaks the secret
    # to anyone willing to measure the response time. Matched in both
    # directions: an operand order of $sent !== $webhook_secret is the same bug
    # and slipped past an earlier one-sided version of this check.
    grep -qE '(\$webhook_secret\s*[!=]==?|[!=]==?\s*\$webhook_secret)' "$INDEX" \
        && bad "timing-unsafe ==/!= comparison on \$webhook_secret" \
        || ok "no timing-unsafe comparison (checked both operand orders)"

    grep -q 'http_response_code(403)' "$INDEX" \
        && ok "rejects a mismatch with 403" || bad "no 403 on mismatch"
    # An install whose config.php predates the variable must keep working
    # instead of 403-ing every update, so an empty secret deliberately fails
    # open until 'mirza repair' regenerates it.
    grep -q 'if (!empty($webhook_secret))' "$INDEX" \
        && ok "fails open when unset (pre-existing installs keep working)" \
        || bad "no empty-secret guard - older installs would reject every update"

    cfg_line=$(grep -n "^require_once 'config.php';" "$INDEX" | head -1 | cut -d: -f1)
    chk_line=$(grep -n 'HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN' "$INDEX" | head -1 | cut -d: -f1)
    api_line=$(grep -n "^require_once 'botapi.php';" "$INDEX" | head -1 | cut -d: -f1)
    if [ -n "$cfg_line" ] && [ -n "$chk_line" ] && [ "$cfg_line" -lt "$chk_line" ]; then
        ok "config.php loaded first, so \$webhook_secret is defined"
    else
        bad "check runs before config.php defines \$webhook_secret (cfg=$cfg_line chk=$chk_line)"
    fi
    # Dropping the request ahead of botapi.php means a forged update never
    # reaches the code that trusts from_id, and never touches the database.
    if [ -n "$chk_line" ] && [ -n "$api_line" ] && [ "$chk_line" -lt "$api_line" ]; then
        ok "runs before botapi.php parses the update"
    else
        bad "runs after botapi.php - a forgery is parsed before it is rejected (chk=$chk_line api=$api_line)"
    fi
fi

# The installer half: register it, persist it, and read it back on repair.
grep -q 'secret_token=' "$SRC" && ok "setWebhook registers secret_token" \
    || bad "setWebhook does not send secret_token"
sed -n '/^render_config()/,/^}$/p' "$SRC" | grep -q 'webhook_secret' \
    && ok "render_config writes \$webhook_secret" \
    || bad "config.php has no \$webhook_secret - index.php would fail open forever"
# config.php wins over the state file: it is what the running bot enforces, so
# a re-registration has to hand Telegram that same value.
sed -n '/^load_existing_config()/,/^}$/p' "$SRC" | grep -q 'config_get webhook_secret' \
    && ok "load_existing_config prefers the value in config.php" \
    || bad "repair would register a secret different from the one the bot enforces"
sed -n '/^load_existing_config()/,/^}$/p' "$SRC" | grep -q 'state_get SECRET' \
    && ok "falls back to the state file for older installs" \
    || bad "no fallback for installs written before \$webhook_secret existed"

# Every command in the dispatcher must actually exist as a function.
sec "dispatcher wiring"

for fn in install_bot update_bot cmd_diagnose cmd_repair cmd_change_domain \
          cmd_change_token renew_ssl backup_to_telegram migrate_bot cmd_uninstall show_menu; do
    grep -qE "^$fn\(\)" "$SRC" && ok "$fn defined" || bad "$fn dispatched but never defined"
done

# ── Secrets ────────────────────────────────────────────────────────────────
# A password on a command line is visible in `ps` to every local user.
sec "credential handling"
grep -nE "mysql(dump)? .*-p[\"'\$]" "$SRC" | grep -v 'MYSQL_PWD' | grep -q . \
    && bad "a mysql password is passed on the command line" \
    || ok "no mysql password on any command line"
grep -q 'MYSQL_PWD' "$SRC" && ok "MYSQL_PWD used instead" || bad "MYSQL_PWD not used"

echo ""
echo "── $pass passed, $fail failed ──"
rm -rf "$SANDBOX"
[ "$fail" -eq 0 ]
