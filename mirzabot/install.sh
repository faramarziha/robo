#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  Mirza Bot — variable-driven, resumable installer
#
#  This is the shipped installer. install.old.sh in the same directory holds
#  the original pre-rewrite installer as a fallback while this rewrite is
#  validated.
# ═══════════════════════════════════════════════════════════════════════════

if [[ $EUID -ne 0 ]]; then
    echo -e "\033[31m[ERROR]\033[0m Please run this script as \033[1mroot\033[0m."
    exit 1
fi

set -o pipefail
# Deliberately NO `set -e`: run_step must be able to inspect a non-zero exit
# code and hand control to install_pause instead of dying silently.

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export APT_LISTCHANGES_FRONTEND=none

INSTALL_LOG="/tmp/mirza_install.log"

# ═══════════════════════════════════════════════════════════════════════════
#  INSTALLER VARIABLE BLOCK — THE SINGLE SOURCE OF TRUTH
#
#  Every path, name and credential the deployment depends on is declared
#  exactly once, here. Nothing below this block may re-literalise these
#  values; always read the variable. The old installer declared
#  BOT_DIR_DEFAULT eleven separate times, which is precisely the class of
#  bug this block exists to prevent.
#
#  Resolution order:  CLI flag  >  environment  >  saved state  >  prompt  >  default
# ═══════════════════════════════════════════════════════════════════════════

# ── Operator-supplied (prompted or flagged) ────────────────────────────────
# These start EMPTY on purpose. _resolve treats a non-empty value as
# "operator already supplied this" and skips the prompt, so pre-seeding a
# default here would silently make the field unpromptable. Defaults live in
# the *_DEFAULT constants below and are applied inside _resolve.
BOT_DIR="${BOT_DIR:-}"                                  # --dir
DOMAIN="${DOMAIN:-}"                                    # --domain   (required)
BOT_TOKEN="${BOT_TOKEN:-}"                              # --token    (required)
CHAT_ID="${CHAT_ID:-}"                                  # --admin    (required)
BOTNAME="${BOTNAME:-}"                                  # --name     (required)
DB_NAME="${DB_NAME:-}"                                  # --db-name
DB_USER="${DB_USER:-}"                                  # --db-user  (generated when empty)
DB_PASS="${DB_PASS:-}"                                  # --db-pass  (generated when empty)
LE_EMAIL="${LE_EMAIL:-}"                                # --email    (optional)

BOT_DIR_DEFAULT="/var/www/html/mirzaprobotconfig"
DB_NAME_DEFAULT="mirzaprobot"

# ── Resolved, not prompted ─────────────────────────────────────────────────
PHP_VER="${PHP_VER:-}"
PHP_VER_CANDIDATES="${PHP_VER_CANDIDATES:-8.3 8.4 8.2}"  # 8.5 dropped: untested vs. qr-code/phpspreadsheet

# ── Project source ─────────────────────────────────────────────────────────
GIT_REPO="${GIT_REPO:-mahdiMGF2/mirzabot}"
SRC_ZIP_URL=""
SRC_LABEL=""

# ── Fixed system locations ─────────────────────────────────────────────────
STATE_DIR="${STATE_DIR:-/root/confmirza}"
MASTER_SCRIPT="${MASTER_SCRIPT:-/root/install.sh}"
BIN_LINK="${BIN_LINK:-/usr/local/bin/mirza}"
CRON_FILE="${CRON_FILE:-/etc/cron.d/mirzabot}"
LOGROTATE_FILE="${LOGROTATE_FILE:-/etc/logrotate.d/mirzabot}"
RENEW_HOOK="${RENEW_HOOK:-/etc/letsencrypt/renewal-hooks/deploy/10-reload-apache.sh}"
PMA_CONF="${PMA_CONF:-/etc/apache2/conf-available/phpmyadmin.conf}"
# "zz-" so it loads after phpmyadmin.conf: Apache merges <Directory> blocks in
# load order, and the restriction must be the one that wins.
PMA_RESTRICT_CONF="${PMA_RESTRICT_CONF:-/etc/apache2/conf-available/zz-mirza-pma-restrict.conf}"

# Hard-coded in 35 PHP files (index.php:3, api/*, cronbot/*, Marzban.php:4,
# jdf.php:16,232,447 ...). Not prompted — making it configurable means
# touching all 35 files. Used only for the php.ini date.timezone directive.
TIMEZONE="${TIMEZONE:-Asia/Tehran}"

# ── Caches ─────────────────────────────────────────────────────────────────
LATEST_CACHE="/tmp/.mirza_latest_version"
IP_CACHE="/tmp/.mirza_server_ip"

# ── Runtime flags ──────────────────────────────────────────────────────────
ASSUME_YES=0
ARG_VERSION=""
ARG_CHANNEL=""

# ── Derived paths ──────────────────────────────────────────────────────────
# Recomputed whenever DOMAIN, BOT_DIR or PHP_VER changes. Never hand a value
# containing '/' to certbot or ServerName: $domainhosts may legitimately be
# "host/subdir" (panels.php builds "https://$domainhosts/sub/<id>" from it),
# so DOMAIN_HOST is the path-stripped form for anything host-shaped.
compute_paths() {
    # Before resolve_vars runs, BOT_DIR may still be empty (menu/dashboard
    # paths read it). Fall back to the default so nothing resolves to "/…".
    local dir="${BOT_DIR:-$BOT_DIR_DEFAULT}"
    DOMAIN_HOST="${DOMAIN%%/*}"
    CONFIG_FILE="$dir/config.php"
    STATE_FILE="$STATE_DIR/.mirza_install_state"
    LOCK_FILE="$STATE_DIR/.mirza_install.lock"
    DB_ROOT_CRED="$STATE_DIR/dbrootmirza.txt"
    CONFIG_BACKUP="$STATE_DIR/config_backup.php"
    VHOST_HTTP="/etc/apache2/sites-available/${DOMAIN_HOST}.conf"
    VHOST_HTTPS="/etc/apache2/sites-available/${DOMAIN_HOST}-ssl.conf"
    LE_LIVE="/etc/letsencrypt/live/${DOMAIN_HOST}"
    PHP_BIN="/usr/bin/php${PHP_VER}"
    PHP_INI_APACHE="/etc/php/${PHP_VER}/apache2/conf.d/99-mirzabot.ini"
    PHP_INI_CLI="/etc/php/${PHP_VER}/cli/conf.d/99-mirzabot.ini"
    MYSQL_CNF="/etc/mysql/mysql.conf.d/99-mirzabot.cnf"

    # Exported because run_step's `bash -c` child cannot see plain shell
    # variables, and the functions it runs (setup_mysql_root, write_php_ini,
    # patch_cron_locks, write_cron_file) read these. Re-exported on every call
    # so the child always sees the current value rather than a stale one from
    # an earlier compute_paths.
    export DB_ROOT_CRED CONFIG_FILE BOT_DIR DOMAIN DOMAIN_HOST PHP_VER
    export STATE_DIR STATE_FILE LOCK_FILE
    export PHP_BIN CRON_FILE

}
compute_paths

# ═══════════════════════════════════════════════════════════════════════════
#  UI
# ═══════════════════════════════════════════════════════════════════════════
C_BORDER=$'\033[1;36m'; C_TITLE=$'\033[1;37m'; C_DIM=$'\033[0;37m'
C_KEY=$'\033[1;33m';    C_TXT=$'\033[0;37m';   C_OK=$'\033[1;32m'
C_BAD=$'\033[1;31m';    C_WARN=$'\033[1;33m';  C_PROMPT=$'\033[1;36m'
CR=$'\033[0m'
UI_W=52

_repeat() { local ch="$1" n="$2" out="" i; for ((i=0;i<n;i++)); do out+="$ch"; done; printf '%s' "$out"; }
_rule()   { printf "  ${C_BORDER}%s${CR}\n" "$(_repeat "─" "$UI_W")"; }
_drule()  { printf "  ${C_BORDER}%s${CR}\n" "$(_repeat "━" "$UI_W")"; }
_mi()     { printf "    ${C_KEY}[%s]${CR}  ${C_TXT}%b${CR}\n" "$1" "$2"; }
_sec()    { printf "\n  ${C_KEY}▌${CR} ${C_TITLE}%s${CR}\n" "$1"; _rule; }
_kv()     { printf "    ${C_DIM}%-11s${CR}${C_BORDER}:${CR} %b${CR}\n" "$1" "$2"; }

_dot() {
    case "$1" in
        ok)   printf "${C_OK}●${CR}"  ;;
        bad)  printf "${C_BAD}●${CR}" ;;
        warn) printf "${C_WARN}●${CR}";;
        *)    printf "${C_DIM}●${CR}" ;;
    esac
}

banner() {
    echo
    _drule
    printf "  ${C_OK}▌${CR} ${C_TITLE}MIRZA${CR}  ${C_DIM}— VPN Subscription Management${CR}\n"
    _drule
}

print_header() {
    echo ""
    echo -e "\033[1;34m╭────────────────────────────────────────────────╮\033[0m"
    printf  "\033[1;34m│\033[0m \033[1;36m%-46s\033[0m \033[1;34m│\033[0m\n" "$1"
    echo -e "\033[1;34m╰────────────────────────────────────────────────╯\033[0m"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Step runner / ETA
# ═══════════════════════════════════════════════════════════════════════════
ETA_REMAINING=0
STEP_NO=0
STEP_TOTAL=0

_fmt_secs() {
    local s=$1
    [ "$s" -lt 0 ] && s=0
    if [ "$s" -lt 60 ]; then printf '%ds' "$s"; else printf '%dm%02ds' $((s / 60)) $((s % 60)); fi
}

_bar() {
    local pct=$1 width=${2:-14} filled i out=""
    [ "$pct" -gt 100 ] && pct=100; [ "$pct" -lt 0 ] && pct=0
    filled=$(( pct * width / 100 ))
    for ((i = 0; i < width; i++)); do
        if [ "$i" -lt "$filled" ]; then out+="█"; else out+="░"; fi
    done
    printf '%s' "$out"
}

_step_eta() {
    case "$1" in
        "Preparing package manager"*)        echo 5  ;;
        "Adding PHP repository"*|"Retrying PHP repository"*) echo 15 ;;
        "Updating & upgrading"*|"Re-running system update"*) echo 120 ;;
        "Installing base tools"*)            echo 25 ;;
        "Installing PHP dependencies"*)      echo 60 ;;
        "Installing PHP "*)                  echo 30 ;;
        "Installing web stack"*)             echo 90 ;;
        "Repairing broken MySQL"*)           echo 90 ;;
        "Re-installing web stack"*)          echo 90 ;;
        "Installing extra modules"*)         echo 25 ;;
        "Installing extra binaries"*)        echo 20 ;;
        "Verifying PHP extensions"*)         echo 4  ;;
        "Enabling Apache modules"*)          echo 6  ;;
        "Applying PHP settings"*)            echo 8  ;;
        "Applying MySQL tuning"*)            echo 12 ;;
        "Installing log rotation"*)          echo 3  ;;
        "Enabling & starting services"*)     echo 8  ;;
        "Configuring firewall"*)             echo 15 ;;
        "Restarting Apache"*)                echo 5  ;;
        "Setting PHP as the active"*|"Setting PHP "*) echo 6  ;;
        "Downloading Mirza"*)                echo 20 ;;
        "Extracting source files"*)          echo 5  ;;
        "Securing file permissions"*)        echo 10 ;;
        "Configuring MySQL root access"*)    echo 10 ;;
        "Opening firewall ports"*)           echo 4  ;;
        "Stopping Apache"*)                  echo 4  ;;
        "Installing Let's Encrypt"*|"Installing certbot"*) echo 25 ;;
        "Requesting SSL certificate"*)       echo 25 ;;
        "Installing renewal hook"*)          echo 3  ;;
        "Configuring SSL on Apache"*)        echo 20 ;;
        "Enabling & starting Apache"*|"Starting Apache"*) echo 5 ;;
        "Configuring Apache virtual hosts"*) echo 6  ;;
        "Creating database & user"*)         echo 5  ;;
        "Installing phpMyAdmin"*)            echo 40 ;;
        "Restricting phpMyAdmin"*)           echo 4  ;;
        "Writing configuration"*)            echo 3  ;;
        "Initializing database tables"*)     echo 15 ;;
        "Adding cron concurrency locks"*)    echo 4  ;;
        "Registering cron jobs"*)            echo 3  ;;
        "Setting Telegram webhook"*)         echo 5  ;;
        *)                                   echo 8  ;;
    esac
}

plan_eta() {
    STEP_TOTAL=0; ETA_REMAINING=0; STEP_NO=0
    phase_done DEPS    || { STEP_TOTAL=$((STEP_TOTAL + 15)); ETA_REMAINING=$((ETA_REMAINING + 418)); }
    phase_done TUNE    || { STEP_TOTAL=$((STEP_TOTAL + 3));  ETA_REMAINING=$((ETA_REMAINING + 23)); }
    phase_done FILES   || { STEP_TOTAL=$((STEP_TOTAL + 4));  ETA_REMAINING=$((ETA_REMAINING + 95)); }
    phase_done DBROOT  || { STEP_TOTAL=$((STEP_TOTAL + 1));  ETA_REMAINING=$((ETA_REMAINING + 10)); }
    phase_done DB      || { STEP_TOTAL=$((STEP_TOTAL + 1));  ETA_REMAINING=$((ETA_REMAINING + 5)); }
    if ! phase_done SSL; then
        if [ -f "${LE_LIVE}/fullchain.pem" ]; then
            STEP_TOTAL=$((STEP_TOTAL + 1)); ETA_REMAINING=$((ETA_REMAINING + 5))
        else
            STEP_TOTAL=$((STEP_TOTAL + 7)); ETA_REMAINING=$((ETA_REMAINING + 111))
        fi
    fi
    phase_done VHOST   || { STEP_TOTAL=$((STEP_TOTAL + 1)); ETA_REMAINING=$((ETA_REMAINING + 6)); }
    phase_done CONFIG  || { STEP_TOTAL=$((STEP_TOTAL + 1)); ETA_REMAINING=$((ETA_REMAINING + 3)); }
    phase_done TABLES  || { STEP_TOTAL=$((STEP_TOTAL + 1)); ETA_REMAINING=$((ETA_REMAINING + 15)); }
    phase_done PMA     || { STEP_TOTAL=$((STEP_TOTAL + 2)); ETA_REMAINING=$((ETA_REMAINING + 44)); }
    phase_done CRON    || { STEP_TOTAL=$((STEP_TOTAL + 2)); ETA_REMAINING=$((ETA_REMAINING + 7)); }
    phase_done WEBHOOK || { STEP_TOTAL=$((STEP_TOTAL + 2)); ETA_REMAINING=$((ETA_REMAINING + 10)); }
}

run_step() {
    local msg="$1"
    local cmd="$2"
    local eta="${3:-$(_step_eta "$msg")}"
    [ "$eta" -lt 1 ] && eta=1
    STEP_NO=$((STEP_NO + 1))
    local counter="$STEP_NO"
    [ "$STEP_TOTAL" -gt 0 ] && counter="$STEP_NO/$STEP_TOTAL"
    : > "$INSTALL_LOG"
    local start; start=$(date +%s)
    bash -c "$cmd" >> "$INSTALL_LOG" 2>&1 &
    local pid=$!
    local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local n=${#frames[@]}
    local i=0
    tput civis 2>/dev/null
    while kill -0 "$pid" 2>/dev/null; do
        local el=$(( $(date +%s) - start ))
        local pct=$(( el * 100 / eta ))
        [ "$pct" -gt 95 ] && pct=95
        local left=$(( eta - el )) lefttxt
        if [ "$left" -gt 0 ]; then lefttxt="~$(_fmt_secs $left) left"; else lefttxt="finishing…"; fi
        local otxt=""
        if [ "$ETA_REMAINING" -gt 0 ]; then
            local orem=$(( ETA_REMAINING - el )); [ "$orem" -lt 0 ] && orem=0
            otxt=" \033[0;37m· total ~$(_fmt_secs $orem)\033[0m"
        fi
        printf "\r\033[K \033[1;33m%s\033[0m \033[0;37m[%s]\033[0m %s  \033[1;36m▕%s▏\033[0m \033[0;37m%s · %s\033[0m%b" \
            "${frames[$i]}" "$counter" "$msg" "$(_bar "$pct" 14)" "$(_fmt_secs $el)" "$lefttxt" "$otxt"
        i=$(( (i + 1) % n ))
        sleep 0.2
    done
    wait "$pid"
    local rc=$?
    local el=$(( $(date +%s) - start ))
    tput cnorm 2>/dev/null
    if [ "$ETA_REMAINING" -gt 0 ]; then
        ETA_REMAINING=$(( ETA_REMAINING - eta )); [ "$ETA_REMAINING" -lt 0 ] && ETA_REMAINING=0
    fi
    if [ "$rc" -eq 0 ]; then
        printf "\r\033[K \033[1;32m✔\033[0m \033[0;37m[%s]\033[0m %s \033[0;37m(%s)\033[0m\n" "$counter" "$msg" "$(_fmt_secs $el)"
    else
        printf "\r\033[K \033[1;31m✘\033[0m \033[0;37m[%s]\033[0m %s \033[0;37m(%s)\033[0m\n" "$counter" "$msg" "$(_fmt_secs $el)"
    fi
    return "$rc"
}

show_step_error() {
    echo -e "\033[1;31m──────────────── Error details ─────────────────\033[0m"
    tail -n 20 "$INSTALL_LOG" 2>/dev/null
    echo -e "\033[1;31m─────────────────────────────────────────────────\033[0m"
}

install_pause() {
    local where="$1"
    echo ""
    echo -e "  ${C_WARN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CR}"
    echo -e "  ${C_WARN}● Installation paused${CR} ${C_DIM}(${where})${CR}"
    echo -e "  ${C_DIM}This is usually caused by the server losing internet or a network error.${CR}"
    echo ""
    echo -e "  ${C_TXT}Completed steps are saved. Just run it again:${CR}"
    echo -e "      ${C_KEY}mirza install${CR}"
    echo -e "  ${C_DIM}It resumes from this step; values you already entered will not be asked again.${CR}"
    echo -e "  ${C_WARN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CR}"
    echo ""
    exit 1
}

# ═══════════════════════════════════════════════════════════════════════════
#  Resumable-install state engine
# ═══════════════════════════════════════════════════════════════════════════
state_init() {
    mkdir -p "$STATE_DIR" 2>/dev/null || return 1
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    if [ ! -f "$STATE_FILE" ]; then
        : > "$STATE_FILE" || return 1
        chmod 600 "$STATE_FILE" 2>/dev/null || true
    fi
}

_state_atomic_replace() {
    # Keep the resumable state file crash-safe: write a complete replacement
    # in the same directory, fsync best-effort, then rename over the old file.
    # A killed sed -i or append can otherwise leave a truncated/mixed state
    # file that skips unsafe phases on the next retry.
    local tmp dir
    dir="$(dirname "$STATE_FILE")"
    tmp=$(mktemp "$dir/.mirza_install_state.XXXXXX") || return 1
    chmod 600 "$tmp" 2>/dev/null || true
    cat > "$tmp" || { rm -f "$tmp"; return 1; }
    sync -f "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$STATE_FILE" || { rm -f "$tmp"; return 1; }
}

state_set() {
    state_init || return 1
    { grep -v -E "^$1=" "$STATE_FILE" 2>/dev/null || true; printf '%s=%s\n' "$1" "$2"; } | _state_atomic_replace
}

state_get() {
    [ -f "$STATE_FILE" ] || return 0
    grep -E "^$1=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
}

phase_done() {
    [ -f "$STATE_FILE" ] && grep -qxF "PHASE:$1" "$STATE_FILE" 2>/dev/null
}

mark_phase() {
    state_init || return 1
    if ! grep -qxF "PHASE:$1" "$STATE_FILE" 2>/dev/null; then
        { cat "$STATE_FILE" 2>/dev/null || true; printf 'PHASE:%s\n' "$1"; } | _state_atomic_replace
    fi
}

acquire_install_lock() {
    state_init || { echo "Could not create $STATE_DIR" >&2; exit 1; }
    exec 9>"$LOCK_FILE" || { echo "Could not open $LOCK_FILE" >&2; exit 1; }
    if ! flock -n 9; then
        printf "  ${C_BAD}●${CR} ${C_BAD}Another Mirza installer command is already running.${CR}\n" >&2
        printf "  ${C_DIM}Wait for it to finish, then retry. Lock: %s${CR}\n" "$LOCK_FILE" >&2
        exit 1
    fi
}

has_resumable_state() {
    [ -f "$STATE_FILE" ] || return 1
    { grep -q '^PHASE:' "$STATE_FILE" 2>/dev/null || grep -q '^STARTED=' "$STATE_FILE" 2>/dev/null; } \
        && ! phase_done DONE
}

state_clear() { rm -f "$STATE_FILE" 2>/dev/null; }

# ═══════════════════════════════════════════════════════════════════════════
#  Helpers
# ═══════════════════════════════════════════════════════════════════════════
gen_ident() { openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | cut -c1-8; }

get_server_ip() {
    if [ -f "$IP_CACHE" ] && [ $(( $(date +%s) - $(stat -c %Y "$IP_CACHE" 2>/dev/null || echo 0) )) -lt 3600 ]; then
        cat "$IP_CACHE"; return
    fi
    local ip
    ip=$(curl -fsSL --max-time 4 ifconfig.me 2>/dev/null)
    [ -z "$ip" ] && ip=$(curl -fsSL --max-time 4 https://api.ipify.org 2>/dev/null)
    [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$ip" ] && ip="n/a"
    echo "$ip" > "$IP_CACHE"
    echo "$ip"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Self-installation — makes the `mirza` command exist
#
#  The installer is normally fetched to a temporary path and run once. Without
#  this, the operator is told at the end to "run mirza" and there is no such
#  command. So the running script is copied to $MASTER_SCRIPT and symlinked
#  into $BIN_LINK.
#
#  This deliberately does NOT self-update from GitHub. The old installer ran
#  self_update_script at the top of every invocation: it downloaded main's
#  install.sh, md5-compared, overwrote /root/install.sh and re-exec'd. Two
#  problems with that. First, `mirza diagnose` on a production box would
#  silently replace the installer with whatever had just been pushed to main
#  and restart into it, so the operator never ran the version they thought
#  they were running. Second, it wrote to /root/install.sh while bash was
#  still reading the script from that same path; bash reads incrementally, so
#  overwriting the file it is executing can feed it truncated source. Here the
#  copy is skipped whenever the destination is the file already running, and
#  nothing is ever re-exec'd. Upgrading the installer is what re-running the
#  published one-liner does.
# ═══════════════════════════════════════════════════════════════════════════
_link_mirza() {
    chmod 0700 "$MASTER_SCRIPT" 2>/dev/null
    # -f so an existing regular file or stale link is replaced rather than
    # leaving ln to fail silently.
    ln -sf "$MASTER_SCRIPT" "$BIN_LINK" 2>/dev/null
}

install_self() {
    local src dst_real src_real
    src="${BASH_SOURCE[0]}"

    # `curl … | bash` leaves no readable script on disk ($0 is "bash" and the
    # source came from stdin). Nothing to copy, so only fix the link if a
    # master script is already present from an earlier run.
    if [ -z "$src" ] || [ ! -f "$src" ] || [ ! -r "$src" ]; then
        [ -f "$MASTER_SCRIPT" ] && _link_mirza
        return 0
    fi

    src_real="$(readlink -f "$src" 2>/dev/null || echo "$src")"
    dst_real="$(readlink -f "$MASTER_SCRIPT" 2>/dev/null || echo "$MASTER_SCRIPT")"

    # Already running from the master script: relink only. Copying here would
    # mean writing to the file bash is currently executing.
    if [ "$src_real" = "$dst_real" ]; then
        _link_mirza
        return 0
    fi

    # Byte-identical: nothing to do beyond the link.
    if [ -f "$MASTER_SCRIPT" ] && cmp -s "$src_real" "$MASTER_SCRIPT"; then
        _link_mirza
        return 0
    fi

    mkdir -p "$(dirname "$MASTER_SCRIPT")" 2>/dev/null
    # 0700: this script takes a bot token and database password as arguments
    # and is not something an unprivileged user should be able to read or run.
    if install -m 0700 "$src_real" "$MASTER_SCRIPT" 2>/dev/null; then
        :
    elif cp -f "$src_real" "$MASTER_SCRIPT" 2>/dev/null; then
        chmod 0700 "$MASTER_SCRIPT" 2>/dev/null
    else
        printf "  ${C_WARN}!${CR} ${C_WARN}Could not install the script to %s; the 'mirza' command will not exist.${CR}\n" \
            "$MASTER_SCRIPT"
        return 0   # never block the requested command over this
    fi
    _link_mirza
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
#  Environment layer — DNS, connectivity, apt, OS detection, PHP repo.
#
#  run_step executes its command with `bash -c`, i.e. a child shell. Any
#  function named in a run_step command MUST be `export -f`'d or the child
#  will die with "command not found". Exported functions also print plain
#  text, never colours: the child does not inherit the C_* variables.
# ═══════════════════════════════════════════════════════════════════════════

# ── DNS ────────────────────────────────────────────────────────────────────
RESOLV="/etc/resolv.conf"
DNS_SERVERS=("1.1.1.1" "8.8.8.8" "9.9.9.9")

dns_works() {
    getent hosts github.com       >/dev/null 2>&1 && return 0
    getent hosts api.telegram.org >/dev/null 2>&1 && return 0
    return 1
}

# Rewrites resolv.conf with public resolvers, keeping one backup of whatever
# was there. A symlink (systemd-resolved stub) is removed rather than backed
# up, because writing through it would edit the stub for the whole system.
ensure_dns() {
    dns_works && return 0
    printf "  ${C_WARN}!${CR} ${C_WARN}DNS resolution failed - configuring public DNS...${CR}\n"
    if [ -L "$RESOLV" ]; then
        rm -f "$RESOLV" 2>/dev/null
    elif [ -f "$RESOLV" ] && [ ! -f "${RESOLV}.mirza.bak" ]; then
        cp -a "$RESOLV" "${RESOLV}.mirza.bak" 2>/dev/null
    fi
    { local d; for d in "${DNS_SERVERS[@]}"; do echo "nameserver $d"; done; } > "$RESOLV" 2>/dev/null
    if command -v resolvectl >/dev/null 2>&1; then
        local ifc; ifc=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
        [ -n "$ifc" ] && resolvectl dns "$ifc" "${DNS_SERVERS[@]}" 2>/dev/null || true
    fi
    sleep 1
    dns_works && { printf "  ${C_OK}●${CR} ${C_OK}DNS is now working.${CR}\n"; return 0; }
    printf "  ${C_BAD}●${CR} ${C_BAD}DNS still failing after applying public resolvers.${CR}\n"
    return 1
}

net_works() {
    curl -fsSL --max-time 8 -o /dev/null "https://github.com"       2>/dev/null && return 0
    curl -fsSL --max-time 8 -o /dev/null "https://api.telegram.org" 2>/dev/null && return 0
    return 1
}

ensure_connectivity() {
    ensure_dns
    net_works && return 0
    printf "  ${C_WARN}!${CR} ${C_WARN}No connectivity - resetting DNS and retrying...${CR}\n"
    ensure_dns
    net_works && return 0
    return 1
}

# ── apt ────────────────────────────────────────────────────────────────────
# Clears the apt/dpkg locks left behind by an interrupted run, but only after
# confirming no real package manager is still holding them.
apt_recover() {
    local i=0
    # 1) A genuine apt/dpkg run (e.g. unattended-upgrades) gets time to finish.
    if pgrep -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null 2>&1; then
        echo "Another apt/dpkg process is running; waiting up to 3 minutes for it to finish..."
        while pgrep -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null 2>&1; do
            sleep 3; i=$((i + 1)); [ "$i" -ge 60 ] && break
        done
    fi
    # 2) Stop the auto-update timers so they cannot re-take the lock mid-install.
    systemctl stop apt-daily.service apt-daily-upgrade.service \
        unattended-upgrades.service >/dev/null 2>&1
    systemctl stop apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
    # 3) Nothing holding them now -> the locks are stale, remove them.
    if ! pgrep -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null 2>&1; then
        rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock \
              /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend 2>/dev/null
    fi
    # 4) Reconfigure anything left half-installed.
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a >/dev/null 2>&1
    return 0
}
export -f apt_recover

_pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

_pkg_installed_glob() {
    dpkg-query -W -f='${Package} ${Status}\n' "$1" 2>/dev/null | grep -q 'install ok installed'
}
export -f _pkg_installed _pkg_installed_glob

# ── OS detection ───────────────────────────────────────────────────────────
OS_ID=""; OS_VERSION_ID=""; OS_CODENAME=""; OS_PRETTY=""
detect_os() {
    [ -n "$OS_ID" ] && return 0
    [ -f /etc/os-release ] || return 1
    local fields
    # Sourced in a subshell so os-release cannot clobber our own variables.
    fields=$(. /etc/os-release 2>/dev/null; printf '%s\t%s\t%s\t%s' \
        "${ID:-}" "${VERSION_ID:-}" "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}" "${PRETTY_NAME:-unknown}")
    IFS=$'\t' read -r OS_ID OS_VERSION_ID OS_CODENAME OS_PRETTY <<< "$fields"
    return 0
}
export -f detect_os

os_major() {
    detect_os
    local m="${OS_VERSION_ID%%.*}"
    case "$m" in ''|*[!0-9]*) echo 0 ;; *) echo "$m" ;; esac
}
export -f os_major

# ── PHP repository ─────────────────────────────────────────────────────────
php_ppa_has_series() {
    [ -n "$1" ] || return 1
    local try
    for try in 1 2 3; do
        curl -fsSL --max-time 10 -o /dev/null \
            "https://ppa.launchpadcontent.net/ondrej/php/ubuntu/dists/$1/Release" 2>/dev/null && return 0
        sleep 2
    done
    return 1
}
export -f php_ppa_has_series

php_repo_disable() {
    local f n=0
    for f in /etc/apt/sources.list.d/*ondrej*php*.sources /etc/apt/sources.list.d/*ondrej*php*.list; do
        [ -f "$f" ] || continue
        mv -f "$f" "$f.disabled-by-mirza" && n=$((n + 1))
    done
    [ "$n" -gt 0 ]
}
export -f php_repo_disable

setup_php_repo() {
    detect_os
    export DEBIAN_FRONTEND=noninteractive
    # add-apt-repository ships in software-properties-common, which minimal
    # cloud images do not include.
    if ! command -v add-apt-repository >/dev/null 2>&1; then
        apt-get update -o DPkg::Lock::Timeout=180 >/dev/null 2>&1
        apt-get install -y software-properties-common ca-certificates curl gnupg \
            -o DPkg::Lock::Timeout=180 || return 1
    fi
    add-apt-repository -y ppa:ondrej/php || \
        LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php || return 1

    # On a release the PPA does not build for, leaving it enabled makes every
    # later apt-get update fail. Drop it and use the distro's own PHP.
    if [ -n "$OS_CODENAME" ] && ! php_ppa_has_series "$OS_CODENAME"; then
        echo "ondrej/php publishes no packages for '$OS_CODENAME' - disabling the PPA and using the PHP shipped with $OS_PRETTY."
        php_repo_disable || echo "Warning: no ondrej/php source file found to disable."
    fi
    return 0
}
export -f setup_php_repo

# Declared once in the variable block; only exported here so the child shell
# that run_step spawns can see it. Do not re-assign it.
export PHP_VER_CANDIDATES

_apt_has_candidate() {
    local cand
    cand=$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2; exit}')
    [ -n "$cand" ] && [ "$cand" != "(none)" ]
}
export -f _apt_has_candidate

# Both php$v and its apache module must be installable, or the web stack
# install fails halfway through. Falls back to the first candidate so the
# fallback can never name a version that is not in the supported list.
resolve_php_ver() {
    local v
    for v in $PHP_VER_CANDIDATES; do
        if _apt_has_candidate "php$v" && _apt_has_candidate "libapache2-mod-php$v"; then
            echo "$v"; return 0
        fi
    done
    echo "${PHP_VER_CANDIDATES%% *}"
    return 1
}
export -f resolve_php_ver

# ── MySQL repair ───────────────────────────────────────────────────────────
# Only safe during DEPS, before any database exists: the fallback path purges
# MySQL and deletes its data directory.
repair_mysql() {
    export DEBIAN_FRONTEND=noninteractive
    systemctl stop mysql 2>/dev/null
    dpkg --configure -a >/dev/null 2>&1
    apt-get install -f -y >/dev/null 2>&1
    if dpkg-query -W -f='${Package} ${Status}\n' 'mysql-server-[0-9]*' 2>/dev/null | grep -q 'install ok installed'; then
        return 0
    fi
    apt-get purge -y 'mysql-server*' 'mysql-client*' 'mysql-community*' mysql-common >/dev/null 2>&1
    apt-get autoremove -y >/dev/null 2>&1
    rm -rf /var/lib/mysql /var/log/mysql /etc/mysql
    dpkg --configure -a >/dev/null 2>&1
    apt-get update --allow-releaseinfo-change >/dev/null 2>&1
    return 0
}
export -f repair_mysql

# ── apt mirror fallback ────────────────────────────────────────────────────
# Rewrites the sources file with a working mirror. Restores the original if
# every candidate fails, so a failed attempt leaves apt no worse than before.
fix_update_issues() {
    printf "  ${C_WARN}!${CR} ${C_WARN}Trying to fix update issues by changing mirrors...${CR}\n"
    ensure_dns
    if ! detect_os || [ -z "$OS_CODENAME" ]; then
        printf "  ${C_BAD}●${CR} ${C_BAD}Could not detect the distribution release.${CR}\n"
        return 1
    fi

    # 24.04+ ships deb822 (ubuntu.sources) and often has no sources.list.
    local DEB822=/etc/apt/sources.list.d/ubuntu.sources
    local LEGACY=/etc/apt/sources.list
    local target="" fmt=""
    if [ -f "$DEB822" ]; then target="$DEB822"; fmt="deb822"
    else target="$LEGACY"; fmt="legacy"; fi
    [ -f "$target" ] && cp "$target" "$target.mirzabackup"

    # A leftover legacy list would keep pointing at the broken mirror, so it
    # is emptied while deb822 is in charge, and restored on failure.
    local parked=""
    if [ "$fmt" = "deb822" ] && [ -s "$LEGACY" ]; then
        cp "$LEGACY" "$LEGACY.mirzabackup" && : > "$LEGACY" && parked="$LEGACY"
    fi

    # Non-x86 architectures are published on ports.ubuntu.com only.
    local arch path MIRRORS
    arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
    case "$arch" in
        arm64|armhf|ppc64el|s390x|riscv64)
            MIRRORS=("ports.ubuntu.com")
            path="ubuntu-ports"
            ;;
        *)
            MIRRORS=(
                "archive.ubuntu.com"
                "us.archive.ubuntu.com"
                "fr.archive.ubuntu.com"
                "de.archive.ubuntu.com"
                "mirrors.digitalocean.com"
                "mirrors.linode.com"
            )
            path="ubuntu"
            ;;
    esac

    local mirror
    for mirror in "${MIRRORS[@]}"; do
        printf "  ${C_DIM}Trying mirror: %s${CR}\n" "$mirror"
        if [ "$fmt" = "deb822" ]; then
            cat > "$target" << EOF
Types: deb
URIs: http://$mirror/$path/
Suites: $OS_CODENAME $OS_CODENAME-updates $OS_CODENAME-backports $OS_CODENAME-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
        else
            cat > "$target" << EOF
deb http://$mirror/$path/ $OS_CODENAME main restricted universe multiverse
deb http://$mirror/$path/ $OS_CODENAME-updates main restricted universe multiverse
deb http://$mirror/$path/ $OS_CODENAME-security main restricted universe multiverse
EOF
        fi
        if apt-get update --allow-releaseinfo-change 2>/dev/null; then
            printf "  ${C_OK}●${CR} ${C_OK}Package lists updated using %s.${CR}\n" "$mirror"
            rm -f "$target.mirzabackup"
            [ -n "$parked" ] && rm -f "$parked.mirzabackup"
            return 0
        fi
    done

    if [ -f "$target.mirzabackup" ]; then
        mv "$target.mirzabackup" "$target"
    else
        rm -f "$target"
    fi
    [ -n "$parked" ] && [ -f "$parked.mirzabackup" ] && mv "$parked.mirzabackup" "$parked"
    printf "  ${C_BAD}●${CR} ${C_BAD}All mirrors failed. Original apt sources restored.${CR}\n"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════
#  Validators — every one returns 0 on success, non-zero on failure, and
#  prints nothing. Callers own the messaging.
# ═══════════════════════════════════════════════════════════════════════════

validate_domain() {
    local d="$1"
    [ -n "$d" ] || return 1
    case "$d" in
        http://*|https://*) return 1 ;;
        */) return 1 ;;
    esac
    # Strip an optional /subdir before testing the host portion.
    local host="${d%%/*}"
    [[ "$host" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

# 0 = resolves to this server, 1 = resolves elsewhere, 2 = cannot resolve
domain_points_here() {
    local host="${1%%/*}" resolved server
    server=$(get_server_ip)
    resolved=$(getent hosts "$host" 2>/dev/null | awk '{print $1; exit}')
    [ -z "$resolved" ] && resolved=$(dig +short A "$host" 2>/dev/null | tail -1)
    [ -z "$resolved" ] && return 2
    [ "$resolved" = "$server" ] && return 0
    return 1
}

# 0 = valid and live, 1 = malformed, 2 = well-formed but Telegram rejected it
validate_token() {
    local t="$1"
    [[ "$t" =~ ^[0-9]{8,10}:[a-zA-Z0-9_-]{35}$ ]] || return 1
    local resp
    resp=$(curl -fsSL --max-time 10 "https://api.telegram.org/bot${t}/getMe" 2>/dev/null)
    echo "$resp" | grep -q '"ok":[[:space:]]*true' || return 2
    return 0
}

validate_chat_id()  { [[ "$1" =~ ^-?[0-9]+$ ]]; }
valid_db_ident()    { [[ "$1" =~ ^[A-Za-z0-9_]{1,32}$ ]]; }
valid_db_pass()     { [[ "$1" =~ ^[A-Za-z0-9_]{6,64}$ ]]; }

validate_email() {
    [ -z "$1" ] && return 0   # optional
    # Kept deliberately stricter than RFC 5322 because this value is interpolated
    # into certbot shell commands. Allow common mailbox syntax only; reject
    # quotes, semicolons and other shell metacharacters even if a rare provider
    # would accept them.
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

# Refuse install directories that would make uninstall catastrophic.
validate_bot_dir() {
    local d="$1"
    [ -n "$d" ] || return 1
    case "$d" in
        /*) ;;
        *) return 1 ;;
    esac
    # The path is embedded in root-run shell snippets and Apache config. Keep
    # it portable and non-ambiguous: no whitespace, quotes or shell control
    # characters.
    [[ "$d" =~ ^/[A-Za-z0-9._@%+=:,/-]+$ ]] || return 1
    case "${d%/}" in
        ""|/|/root|/etc|/var|/var/www|/var/www/html|/usr|/bin|/boot|/home) return 1 ;;
    esac
    return 0
}

validate_botname() { [[ "$1" =~ ^@?[A-Za-z0-9_]{5,32}$ ]]; }

normalize_botname() {
    local n="$1"
    n="${n#@}"
    echo "$n" | tr -d '[:space:]'
}

# ═══════════════════════════════════════════════════════════════════════════
#  resolve_vars — collects every operator-supplied value exactly once.
#
#  For each variable:  already set (flag/env) → validate and keep
#                      else in state          → restore silently
#                      else --yes             → hard error naming the flag
#                      else                   → prompt, validate, loop
#  Everything resolved is persisted, so a resume never re-asks.
# ═══════════════════════════════════════════════════════════════════════════

_missing_required() {
    printf "  ${C_BAD}●${CR} ${C_BAD}Missing required value:${CR} ${C_TXT}%s${CR}\n" "$1"
    printf "  ${C_DIM}Provide it with %s, or run without --yes to be prompted.${CR}\n" "$2"
    exit 1
}

# _resolve <VARNAME> <StateKey> <Prompt> <Flag> <validator|""> <required:0|1> <default|"">
_resolve() {
    local var="$1" key="$2" prompt="$3" flag="$4" validator="$5" required="$6" default="$7"
    local cur="${!var}" input

    # 1. Supplied via flag or environment
    if [ -n "$cur" ]; then
        if [ -n "$validator" ] && ! "$validator" "$cur"; then
            printf "  ${C_BAD}●${CR} ${C_BAD}Invalid value for %s:${CR} %s\n" "$flag" "$cur"
            [ "$ASSUME_YES" -eq 1 ] && exit 1
            cur=""
        else
            state_set "$key" "$cur"
            return 0
        fi
    fi

    # 2. Restored from a previous run
    if [ -z "$cur" ]; then
        cur="$(state_get "$key")"
        if [ -n "$cur" ]; then
            printf -v "$var" '%s' "$cur"
            return 0
        fi
    fi

    # 3. Non-interactive
    if [ "$ASSUME_YES" -eq 1 ]; then
        if [ -n "$default" ]; then
            printf -v "$var" '%s' "$default"
            state_set "$key" "$default"
            return 0
        fi
        [ "$required" -eq 1 ] && _missing_required "$prompt" "$flag"
        return 0
    fi

    # 4. Prompt until valid
    while true; do
        if [ -n "$default" ]; then
            printf "  ${C_PROMPT}❯${CR} %s ${C_DIM}[%s]${CR}: " "$prompt" "$default"
        else
            printf "  ${C_PROMPT}❯${CR} %s: " "$prompt"
        fi
        read -r input
        [ -z "$input" ] && input="$default"
        if [ -z "$input" ] && [ "$required" -eq 0 ]; then
            printf -v "$var" '%s' ""
            state_set "$key" ""
            return 0
        fi
        if [ -z "$input" ]; then
            printf "    ${C_BAD}●${CR} ${C_BAD}This value is required.${CR}\n"
            continue
        fi
        if [ -n "$validator" ] && ! "$validator" "$input"; then
            printf "    ${C_BAD}●${CR} ${C_BAD}That value is not valid. Please try again.${CR}\n"
            continue
        fi
        printf -v "$var" '%s' "$input"
        state_set "$key" "$input"
        return 0
    done
}

resolve_vars() {
    state_init

    _sec "Installation settings"
    printf "    ${C_DIM}Press Enter to accept the value in brackets.${CR}\n\n"

    # ── Install directory ──────────────────────────────────────────────
    _resolve BOT_DIR BOT_DIR "Install directory" "--dir" \
        validate_bot_dir 1 "$BOT_DIR_DEFAULT"
    compute_paths

    # ── Domain ─────────────────────────────────────────────────────────
    _resolve DOMAIN DOMAIN "Domain (e.g. bot.example.com)" "--domain" \
        validate_domain 1 ""
    compute_paths

    # The A-record check is advisory: certbot will fail later if it is wrong,
    # but telling the operator now saves them a confusing SSL error.
    if [ -n "$DOMAIN" ]; then
        domain_points_here "$DOMAIN"
        case $? in
            1)
                printf "  ${C_WARN}!${CR} ${C_WARN}%s resolves to a different server (this one is %s).${CR}\n" \
                    "$DOMAIN_HOST" "$(get_server_ip)"
                if [ "$ASSUME_YES" -eq 0 ]; then
                    printf "  ${C_PROMPT}❯${CR} Continue anyway? ${C_DIM}[y/N]${CR}: "
                    local _c; read -r _c
                    [[ "$_c" =~ ^[Yy]$ ]] || exit 1
                fi
                ;;
            2)
                printf "  ${C_WARN}!${CR} ${C_WARN}%s does not resolve yet. SSL issuance will fail until it does.${CR}\n" "$DOMAIN_HOST"
                if [ "$ASSUME_YES" -eq 0 ]; then
                    printf "  ${C_PROMPT}❯${CR} Continue anyway? ${C_DIM}[y/N]${CR}: "
                    local _c2; read -r _c2
                    [[ "$_c2" =~ ^[Yy]$ ]] || exit 1
                fi
                ;;
        esac
    fi

    # ── Telegram identity ──────────────────────────────────────────────
    # validate_token returns 2 for "well-formed but rejected", which is worth
    # distinguishing: the operator may be installing before the token is live.
    if [ -z "$BOT_TOKEN" ]; then BOT_TOKEN="$(state_get BOT_TOKEN)"; fi
    while [ -z "$BOT_TOKEN" ]; do
        if [ "$ASSUME_YES" -eq 1 ]; then _missing_required "Bot token" "--token"; fi
        printf "  ${C_PROMPT}❯${CR} Bot token from @BotFather: "
        read -r BOT_TOKEN
        [ -z "$BOT_TOKEN" ] && continue
        validate_token "$BOT_TOKEN"
        case $? in
            0) ;;
            1) printf "    ${C_BAD}●${CR} ${C_BAD}That does not look like a bot token.${CR}\n"; BOT_TOKEN="" ;;
            2) printf "    ${C_WARN}●${CR} ${C_WARN}Telegram rejected this token.${CR} ${C_DIM}Press Enter to re-enter, or type 'keep' to use it anyway.${CR}\n"
               printf "  ${C_PROMPT}❯${CR} "
               local _k; read -r _k
               [ "$_k" = "keep" ] || BOT_TOKEN="" ;;
        esac
    done
    state_set BOT_TOKEN "$BOT_TOKEN"

    _resolve CHAT_ID CHAT_ID "Your numeric Telegram ID" "--admin" \
        validate_chat_id 1 ""

    if [ -z "$BOTNAME" ]; then BOTNAME="$(state_get BOTNAME)"; fi
    if [ -z "$BOTNAME" ]; then
        if [ "$ASSUME_YES" -eq 1 ]; then _missing_required "Bot username" "--name"; fi
        while [ -z "$BOTNAME" ]; do
            printf "  ${C_PROMPT}❯${CR} Bot username ${C_DIM}(without @)${CR}: "
            read -r BOTNAME
            BOTNAME="$(normalize_botname "$BOTNAME")"
            validate_botname "$BOTNAME" || BOTNAME=""
        done
    else
        BOTNAME="$(normalize_botname "$BOTNAME")"
        if ! validate_botname "$BOTNAME"; then
            printf "  ${C_BAD}●${CR} ${C_BAD}Invalid value for --name:${CR} %s\n" "$BOTNAME"
            exit 1
        fi
    fi
    state_set BOTNAME "$BOTNAME"

    # ── Database ───────────────────────────────────────────────────────
    _resolve DB_NAME DB_NAME "Database name" "--db-name" valid_db_ident 1 "$DB_NAME_DEFAULT"

    if [ -z "$DB_USER" ]; then DB_USER="$(state_get DB_USER)"; fi
    if [ -z "$DB_USER" ]; then
        local gen_user; gen_user="$(gen_ident)"
        _resolve DB_USER DB_USER "Database username" "--db-user" valid_db_ident 1 "$gen_user"
    else
        valid_db_ident "$DB_USER" || DB_USER="$(gen_ident)"
        state_set DB_USER "$DB_USER"
    fi

    if [ -z "$DB_PASS" ]; then DB_PASS="$(state_get DB_PASS)"; fi
    if [ -z "$DB_PASS" ]; then
        local gen_pass; gen_pass="$(gen_ident)$(gen_ident)"
        _resolve DB_PASS DB_PASS "Database password" "--db-pass" valid_db_pass 1 "$gen_pass"
    else
        valid_db_pass "$DB_PASS" || DB_PASS="$(gen_ident)$(gen_ident)"
        state_set DB_PASS "$DB_PASS"
    fi

    # ── SSL contact ────────────────────────────────────────────────────
    _resolve LE_EMAIL LE_EMAIL "Email for Let's Encrypt (optional)" "--email" \
        validate_email 0 ""

    compute_paths

    echo ""
    _sec "Confirm"
    _kv "Directory"  "${C_TXT}${BOT_DIR}${CR}"
    _kv "Domain"     "${C_TXT}${DOMAIN}${CR}"
    _kv "Bot"        "${C_TXT}@${BOTNAME}${CR}"
    _kv "Admin ID"   "${C_TXT}${CHAT_ID}${CR}"
    _kv "Database"   "${C_TXT}${DB_NAME}${CR} ${C_DIM}(user ${DB_USER})${CR}"
    [ -n "$LE_EMAIL" ] && _kv "SSL email" "${C_TXT}${LE_EMAIL}${CR}"
    echo ""

    if [ "$ASSUME_YES" -eq 0 ]; then
        printf "  ${C_PROMPT}❯${CR} Start the installation with these settings? ${C_DIM}[Y/n]${CR}: "
        local ok; read -r ok
        if [[ "$ok" =~ ^[Nn]$ ]]; then
            printf "  ${C_DIM}Aborted. Re-run to change any value.${CR}\n"
            exit 0
        fi
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
#  CLI surface
# ═══════════════════════════════════════════════════════════════════════════

print_usage() {
    banner
    # Interpolated, not retyped: a hard-coded default in help text drifts out
    # of sync with the variable block the moment either one changes.
    cat <<EOF

  Usage: mirza [command] [options]

  Commands:
    install            Install the bot (resumes automatically if interrupted)
    update             Update an existing install to a newer version
    diagnose           Print a health report (paste this when asking for help)
    repair             Re-apply packages, tuning, cron, permissions and webhook
    change-domain      Move the install to a new domain
    change-token       Replace the Telegram bot token
    renew-ssl          Renew or issue the SSL certificate
    backup             Send a database backup to the admin chat
    migrate            Move an install to this server
    uninstall          Remove the bot and all files it created
    menu               Interactive menu (default when no command is given)

  Options:
    --dir <path>       Install directory        (default: ${BOT_DIR_DEFAULT})
    --domain <fqdn>    Domain serving the bot
    --token <token>    Telegram bot token
    --admin <id>       Admin numeric Telegram ID
    --name <username>  Bot username, without @
    --db-name <name>   Database name            (default: ${DB_NAME_DEFAULT})
    --db-user <user>   Database username        (default: generated)
    --db-pass <pass>   Database password        (default: generated)
    --email <address>  Contact address for Let's Encrypt
    --version <tag>    Install a specific release tag
    --channel <name>   beta | release
    --yes              Non-interactive; fail instead of prompting
    -h, --help         Show this help

  Example — fully unattended:
    mirza install --yes --domain bot.example.com --token 123:ABC \\
      --admin 12345678 --name my_vpn_bot --dir /opt/mirzabot

EOF
}

process_arguments() {
    COMMAND=""
    while [ $# -gt 0 ]; do
        case "$1" in
            install|update|diagnose|repair|change-domain|change-token|renew-ssl|backup|migrate|uninstall|menu)
                COMMAND="$1"; shift ;;
            --dir)      BOT_DIR="$2";   shift 2 ;;
            --domain)   DOMAIN="$2";    shift 2 ;;
            --token)    BOT_TOKEN="$2"; shift 2 ;;
            --admin)    CHAT_ID="$2";   shift 2 ;;
            --name)     BOTNAME="$2";   shift 2 ;;
            --db-name)  DB_NAME="$2";   shift 2 ;;
            --db-user)  DB_USER="$2";   shift 2 ;;
            --db-pass)  DB_PASS="$2";   shift 2 ;;
            --email)    LE_EMAIL="$2";  shift 2 ;;
            --version)  ARG_VERSION="$2"; shift 2 ;;
            --channel)  ARG_CHANNEL="$2"; shift 2 ;;
            --yes|-y)   ASSUME_YES=1;   shift ;;
            -h|--help)  print_usage; exit 0 ;;
            *)
                printf "  ${C_BAD}●${CR} ${C_BAD}Unknown option:${CR} %s\n" "$1"
                printf "  ${C_DIM}Run 'mirza --help' for usage.${CR}\n"
                exit 1 ;;
        esac
    done
    compute_paths
    [ -z "$COMMAND" ] && COMMAND="menu"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Release selection
# ═══════════════════════════════════════════════════════════════════════════

# The release archive ships a plain-text `version` file (currently "0.3.1").
# Read from $BOT_DIR, never $BOT_DIR_DEFAULT: the old installer hard-coded the
# default here, so on a --dir install it always reported "not installed".
get_installed_version() {
    if [ -f "$BOT_DIR/version" ]; then
        tr -d ' \t\r\n' < "$BOT_DIR/version"
    else
        echo "unknown"
    fi
}

# Newest release tag, cached for 10 minutes so repeated runs stay fast.
get_latest_version() {
    if [ -f "$LATEST_CACHE" ] && [ $(( $(date +%s) - $(stat -c %Y "$LATEST_CACHE" 2>/dev/null || echo 0) )) -lt 600 ]; then
        cat "$LATEST_CACHE"; return 0
    fi
    local tag
    tag=$(curl -fsSL --max-time 10 "https://api.github.com/repos/${GIT_REPO}/releases/latest" 2>/dev/null \
          | grep -m1 '"tag_name"' | cut -d'"' -f4)
    [ -z "$tag" ] && return 1
    echo "$tag" > "$LATEST_CACHE"
    echo "$tag"
}

# Sets SRC_ZIP_URL and SRC_LABEL. --version wins over --channel; without
# either, the newest release is used, falling back to main if the API is
# unreachable (rate limits should not block an install).
choose_source() {
    SRC_ZIP_URL="$(state_get SRC_ZIP_URL)"
    SRC_LABEL="$(state_get SRC_LABEL)"
    if [ -n "$SRC_ZIP_URL" ] && [ -n "$SRC_LABEL" ]; then
        return 0
    fi

    local tag=""
    if [ -n "$ARG_VERSION" ]; then
        tag="$ARG_VERSION"
    elif [ "$ARG_CHANNEL" = "beta" ]; then
        SRC_ZIP_URL="https://github.com/${GIT_REPO}/archive/refs/heads/main.zip"
        SRC_LABEL="beta (main branch)"
        state_set SRC_ZIP_URL "$SRC_ZIP_URL"; state_set SRC_LABEL "$SRC_LABEL"
        return 0
    else
        tag="$(get_latest_version)"
    fi

    if [ -z "$tag" ]; then
        printf "  ${C_WARN}!${CR} ${C_WARN}Could not reach the GitHub API; installing from the main branch.${CR}\n"
        SRC_ZIP_URL="https://github.com/${GIT_REPO}/archive/refs/heads/main.zip"
        SRC_LABEL="main branch (release lookup failed)"
    else
        SRC_ZIP_URL="https://github.com/${GIT_REPO}/archive/refs/tags/${tag}.zip"
        SRC_LABEL="$tag"
    fi
    state_set SRC_ZIP_URL "$SRC_ZIP_URL"
    state_set SRC_LABEL "$SRC_LABEL"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
#  Pre-flight
# ═══════════════════════════════════════════════════════════════════════════

# Refuses to install over an existing stack. Skipped on resume, where our own
# half-finished install is the thing that would be detected.
precheck_fresh_server() {
    local found=()
    _pkg_installed apache2 && found+=("apache2 (web server)")
    { _pkg_installed nginx || _pkg_installed nginx-core || _pkg_installed nginx-full; } && found+=("nginx (web server)")
    { _pkg_installed mysql-server || _pkg_installed_glob 'mysql-server-[0-9]*'; } && found+=("mysql-server")
    { _pkg_installed mariadb-server || _pkg_installed_glob 'mariadb-server-[0-9]*'; } && found+=("mariadb-server")
    _pkg_installed phpmyadmin && found+=("phpMyAdmin")
    { [ -d /opt/marzban ] || [ -d /var/lib/marzban ]; } && found+=("Marzban panel")
    { [ -d /opt/hiddify-manager ] || [ -d /opt/hiddify-config ]; } && found+=("Hiddify panel")

    if [ ${#found[@]} -gt 0 ]; then
        _sec "Server is not clean"
        printf "    ${C_BAD}●${CR} ${C_BAD}This installer needs a server with no conflicting software.${CR}\n"
        printf "    ${C_DIM}Detected:${CR}\n"
        local f
        for f in "${found[@]}"; do printf "      ${C_WARN}-${CR} ${C_TXT}%s${CR}\n" "$f"; done
        echo ""
        printf "    ${C_TXT}Use a clean Ubuntu 22.04/24.04 server, or reinstall the OS, then run again.${CR}\n"
        return 1
    fi
    return 0
}

phase_preflight() {
    print_header "Pre-flight checks"

    if ! ensure_connectivity; then
        printf "  ${C_BAD}●${CR} ${C_BAD}This server cannot reach the internet.${CR}\n"
        printf "  ${C_DIM}Fix networking, then run 'mirza install' again.${CR}\n"
        exit 1
    fi
    printf "  ${C_OK}●${CR} ${C_DIM}Internet connectivity OK.${CR}\n"

    detect_os
    if [ "$OS_ID" != "ubuntu" ] && [ "$OS_ID" != "debian" ]; then
        printf "  ${C_WARN}!${CR} ${C_WARN}Unsupported distribution: %s${CR}\n" "${OS_PRETTY:-unknown}"
        printf "  ${C_DIM}Only Ubuntu and Debian are tested. Continuing may fail.${CR}\n"
        if [ "$ASSUME_YES" -eq 0 ]; then
            printf "  ${C_PROMPT}❯${CR} Continue anyway? ${C_DIM}[y/N]${CR}: "
            local c; read -r c
            [[ "$c" =~ ^[Yy]$ ]] || exit 1
        fi
    else
        printf "  ${C_OK}●${CR} ${C_DIM}Detected %s.${CR}\n" "$OS_PRETTY"
    fi

    # Only meaningful on a first run: on resume our own stack is present.
    if ! has_resumable_state; then
        precheck_fresh_server || exit 1
        printf "  ${C_OK}●${CR} ${C_DIM}No conflicting software found.${CR}\n"
    fi

    local free_mb
    free_mb=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$free_mb" ] && [ "$free_mb" -lt 2048 ]; then
        printf "  ${C_WARN}!${CR} ${C_WARN}Only %s MB free on /. At least 2 GB is recommended.${CR}\n" "$free_mb"
    else
        printf "  ${C_OK}●${CR} ${C_DIM}Disk space OK (%s MB free).${CR}\n" "${free_mb:-?}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  PHASE: DEPS — packages, PHP, web stack
# ═══════════════════════════════════════════════════════════════════════════
phase_deps() {
    if phase_done DEPS; then
        printf "  ${C_OK}●${CR} ${C_DIM}Dependencies already installed - skipping.${CR}\n"
        # PHP_VER is needed by every later phase, so restore it on resume.
        PHP_VER="$(state_get PHP_VER)"
        [ -z "$PHP_VER" ] && PHP_VER="${PHP_VER_CANDIDATES%% *}"
        compute_paths
        return 0
    fi

    print_header "Installing dependencies"

    run_step "Preparing package manager (clearing stale apt locks)" "apt_recover" \
        || { show_step_error; install_pause "Preparing package manager"; }

    if ! run_step "Adding PHP repository (ondrej/php)" "setup_php_repo"; then
        if ! run_step "Retrying PHP repository with locale override" "LC_ALL=C.UTF-8 setup_php_repo"; then
            show_step_error
            install_pause "Adding PHP repository"
        fi
    fi

    local apt_update="apt-get update --allow-releaseinfo-change -o DPkg::Lock::Timeout=180"
    local apt_upgrade="DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o DPkg::Lock::Timeout=180"
    if ! run_step "Updating & upgrading system packages" "$apt_update && $apt_upgrade"; then
        # Usually a dead mirror; rewrite sources and retry once.
        if fix_update_issues; then
            run_step "Re-running system update after mirror fix" "$apt_update && $apt_upgrade" \
                || { show_step_error; install_pause "System update/upgrade"; }
        else
            install_pause "System update/upgrade (mirror fix failed)"
        fi
    fi

    # zip: cronbot/backupbot.php shell_exec's `zip -r` (backupbot.php:15). It is
    # not installed by default on a minimal image, so backups failed silently.
    # cron/logrotate: this installer writes /etc/cron.d/mirzabot and a logrotate
    # config, neither of which does anything if the daemon is absent.
    run_step "Installing base tools (git, curl, wget, unzip, zip, jq, cron)" \
        "apt-get install -y software-properties-common ca-certificates gnupg git unzip zip curl wget jq cron logrotate sudo" \
        || { show_step_error; install_pause "Installing base tools"; }

    PHP_VER="$(resolve_php_ver)"
    [ -z "$PHP_VER" ] && PHP_VER="${PHP_VER_CANDIDATES%% *}"
    state_set PHP_VER "$PHP_VER"
    compute_paths
    printf "  ${C_DIM}Selected PHP version:${CR} ${C_KEY}%s${CR}\n" "$PHP_VER"

    run_step "Installing PHP ${PHP_VER} (fpm + mysql)" \
        "DEBIAN_FRONTEND=noninteractive apt install -y php${PHP_VER} php${PHP_VER}-cli php${PHP_VER}-fpm php${PHP_VER}-mysql" \
        || { show_step_error; install_pause "Installing PHP ${PHP_VER}"; }

    # Versioned packages only. Unversioned php-* or lamp-server^ would pull
    # whatever PHP apt considers default and break the bot's mysqli/curl.
    local webstack="DEBIAN_FRONTEND=noninteractive apt install -y mysql-server apache2 \
libapache2-mod-php${PHP_VER} php${PHP_VER}-mbstring php${PHP_VER}-zip php${PHP_VER}-gd \
php${PHP_VER}-curl php${PHP_VER}-intl php${PHP_VER}-xml php${PHP_VER}-bcmath"
    if ! run_step "Installing web stack (Apache, MySQL, PHP modules)" "$webstack"; then
        # Nearly always a half-configured MySQL from an interrupted run. Safe
        # to repair: PREFLIGHT proved no pre-existing database is present.
        run_step "Repairing broken MySQL installation" "repair_mysql" \
            || { show_step_error; install_pause "Repairing MySQL"; }
        run_step "Re-installing web stack" "$webstack" \
            || { show_step_error; install_pause "Installing web stack"; }
    fi

    run_step "Installing extra modules (soap, ssh2)" \
        "DEBIAN_FRONTEND=noninteractive apt-get install -y php${PHP_VER}-soap php${PHP_VER}-ssh2 libssh2-1-dev libssh2-1" \
        || { show_step_error; install_pause "Installing extra PHP modules"; }

    # Disable every other PHP apache module, then enable ours. mpm_event and
    # mpm_worker are incompatible with mod_php and must go.
    local other="" pv
    for pv in 8.5 8.4 8.3 8.2 8.1 8.0 7.4; do
        [ "$pv" = "$PHP_VER" ] || other="$other php$pv"
    done
    run_step "Setting PHP ${PHP_VER} as the active version" \
        "a2dismod${other} mpm_event mpm_worker 2>/dev/null; a2enmod php${PHP_VER} mpm_prefork 2>/dev/null; update-alternatives --set php /usr/bin/php${PHP_VER} 2>/dev/null; systemctl restart apache2" \
        || { show_step_error; install_pause "Setting PHP ${PHP_VER} as default"; }

    run_step "Enabling Apache modules (rewrite, headers, ssl)" \
        "a2enmod rewrite headers ssl 2>/dev/null; systemctl restart apache2" \
        || { show_step_error; install_pause "Enabling Apache modules"; }

    run_step "Enabling & starting services (MySQL, Apache)" \
        "systemctl enable mysql.service && systemctl start mysql.service && systemctl enable apache2 && systemctl start apache2" \
        || { show_step_error; install_pause "Enabling core services"; }

    # OpenSSH is allowed FIRST and unconditionally. If ufw is ever enabled -
    # by this script, another tool, or the operator - without an SSH rule
    # already present, the session is cut and the server becomes unreachable.
    run_step "Configuring firewall (UFW + Apache)" \
        "apt-get install -y ufw && { ufw allow OpenSSH 2>/dev/null || ufw allow 22/tcp; } && \
         { ufw allow 'Apache Full' 2>/dev/null || ufw allow 80,443/tcp; }" \
        || { show_step_error; install_pause "Configuring UFW"; }

    # Fail fast here rather than with a blank page after install.
    # pdo_mysql, not mysqli: config.php now hands the bot a PDO handle only.
    run_step "Verifying PHP extensions" \
        "php -m | grep -qi pdo_mysql && php -m | grep -qi curl && php -m | grep -qi mbstring && php -m | grep -qi gd" \
        || { show_step_error; install_pause "Verifying PHP extensions"; }

    mark_phase DEPS
}

# ═══════════════════════════════════════════════════════════════════════════
#  PHASE: TUNE — PHP / MySQL settings and log rotation
#
#  NET-NEW: the old installer shipped no tuning at all, so stock php.ini
#  limits applied. Defaults like upload_max_filesize=2M are too small for the
#  database backups the bot sends to Telegram, and date.timezone must match
#  the value hard-coded across the PHP sources or jdf.php date maths drifts.
#  Written as drop-in .ini/.cnf files, never by editing the distro php.ini:
#  drop-ins survive a PHP package upgrade and are trivial to remove.
# ═══════════════════════════════════════════════════════════════════════════
write_php_ini() {
    local dest="$1"
    [ -d "$(dirname "$dest")" ] || return 0   # SAPI not installed; not an error
    cat > "$dest" <<EOF
; Managed by the Mirza installer. Edits are overwritten on repair/update.
date.timezone = ${TIMEZONE}
memory_limit = 256M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 120
max_input_time = 120
default_socket_timeout = 60
EOF
}
# Runs inside run_step's child shell, so both the function and the TIMEZONE
# it interpolates must cross the process boundary.
export -f write_php_ini
export TIMEZONE


phase_tune() {
    if phase_done TUNE; then
        printf "  ${C_OK}●${CR} ${C_DIM}System tuning already applied - skipping.${CR}\n"
        return 0
    fi
    print_header "Applying system tuning"

    run_step "Applying PHP settings (timezone, upload limits)" \
        "write_php_ini '$PHP_INI_APACHE'; write_php_ini '$PHP_INI_CLI'" \
        || { show_step_error; install_pause "Applying PHP settings"; }

    # Backups are streamed as a single packet; the 16M default truncates
    # them on any install with a moderately large user table.
    run_step "Applying MySQL tuning (packet size)" \
        "printf '[mysqld]\nmax_allowed_packet = 64M\n' > '$MYSQL_CNF' && systemctl restart mysql" \
        || { show_step_error; install_pause "Applying MySQL tuning"; }

    # Without this the bot's own log grows unbounded and eventually fills /.
    run_step "Installing log rotation" \
        "printf '%s/*.log {\n  weekly\n  rotate 4\n  compress\n  missingok\n  notifempty\n  copytruncate\n}\n' '$BOT_DIR' > '$LOGROTATE_FILE'" \
        || { show_step_error; install_pause "Installing log rotation"; }

    mark_phase TUNE
}

# ═══════════════════════════════════════════════════════════════════════════
#  Composer
# ═══════════════════════════════════════════════════════════════════════════

# Installs Composer, verifying the setup script against the official
# signature before executing it.
ensure_composer() {
    command -v composer >/dev/null 2>&1 && return 0

    local php_bin setup expected actual
    php_bin="$(command -v php)" || return 1
    setup="$(mktemp /tmp/composer-setup.XXXXXX.php)"

    expected="$("$php_bin" -r "echo @file_get_contents('https://composer.github.io/installer.sig');" 2>/dev/null | tr -d '[:space:]')"
    if ! "$php_bin" -r "exit(@copy('https://getcomposer.org/installer', '$setup') ? 0 : 1);"; then
        rm -f "$setup"
        echo "Failed to download the Composer installer." >&2
        return 1
    fi

    actual="$("$php_bin" -r "echo hash_file('sha384', '$setup');" 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        rm -f "$setup"
        echo "Composer installer signature mismatch - refusing to run it." >&2
        return 1
    fi

    "$php_bin" "$setup" --quiet --install-dir=/usr/local/bin --filename=composer
    local rc=$?
    rm -f "$setup"
    [ "$rc" -eq 0 ] && command -v composer >/dev/null 2>&1
}
export -f ensure_composer

# vendor/ is not shipped in the release archive, so this runs on every
# install, update and migration.
install_php_deps() {
    local dir="$1"
    if [ ! -f "$dir/composer.json" ]; then
        echo "No composer.json in $dir - skipping dependency installation."
        return 0
    fi
    ensure_composer || return 1
    COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_NO_INTERACTION=1 \
        composer install --working-dir="$dir" \
        --no-dev --optimize-autoloader --prefer-dist --no-progress || return 1
    if [ ! -f "$dir/vendor/autoload.php" ]; then
        echo "composer install finished but $dir/vendor/autoload.php is missing." >&2
        return 1
    fi
    chown -R www-data:www-data "$dir/vendor" 2>/dev/null
    return 0
}
export -f install_php_deps

# ═══════════════════════════════════════════════════════════════════════════
#  PHASE: FILES — download and unpack the release
# ═══════════════════════════════════════════════════════════════════════════
phase_files() {
    if phase_done FILES; then
        printf "  ${C_OK}●${CR} ${C_DIM}Bot files already downloaded - skipping.${CR}\n"
        return 0
    fi
    print_header "Downloading bot files"

    choose_source
    printf "  ${C_DIM}Source:${CR} ${C_KEY}%s${CR}\n" "$SRC_LABEL"

    # validate_bot_dir has already rejected /, /etc, /var/www/html and the
    # like, so this rm cannot be pointed at a system directory.
    validate_bot_dir "$BOT_DIR" || {
        printf "  ${C_BAD}●${CR} ${C_BAD}Refusing to install into %s${CR}\n" "$BOT_DIR"
        install_pause "Validating install directory"
    }

    if [ -d "$BOT_DIR" ]; then
        rm -rf "$BOT_DIR" || install_pause "Cleaning bot directory"
    fi
    mkdir -p "$BOT_DIR" || install_pause "Creating bot directory"

    local tmp="/tmp/mirzaprobot.$$"
    rm -rf "$tmp"; mkdir -p "$tmp"

    run_step "Downloading Mirza (${SRC_LABEL})" \
        "curl -fsSL --retry 3 --retry-delay 2 -o '$tmp/bot.zip' '$SRC_ZIP_URL'" \
        || { show_step_error; rm -rf "$tmp"; install_pause "Downloading bot files"; }

    run_step "Extracting source files" "unzip -qo '$tmp/bot.zip' -d '$tmp'" \
        || { show_step_error; rm -rf "$tmp"; install_pause "Extracting bot files"; }

    local extracted
    extracted=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)
    if [ -z "$extracted" ] || [ ! -d "$extracted" ]; then
        printf "  ${C_BAD}●${CR} ${C_BAD}Extracted folder not found (bad or empty download).${CR}\n"
        rm -rf "$tmp"
        install_pause "Locating extracted files"
    fi

    # Dotfiles (.htaccess ships in the repo and matters) are not matched by *.
    shopt -s dotglob
    mv "$extracted"/* "$BOT_DIR" || { shopt -u dotglob; rm -rf "$tmp"; install_pause "Moving bot files"; }
    shopt -u dotglob
    rm -rf "$tmp"

    run_step "Installing PHP dependencies (composer)" "install_php_deps '$BOT_DIR'" \
        || { show_step_error; install_pause "Installing PHP dependencies"; }

    # 755/644, not the old blanket -R 755: config.php holds the bot token and
    # database password and must not be world-readable.
    run_step "Securing file permissions" \
        "chown -R www-data:www-data '$BOT_DIR' && find '$BOT_DIR' -type d -exec chmod 755 {} + && find '$BOT_DIR' -type f -exec chmod 644 {} +" \
        || { show_step_error; install_pause "Securing file permissions"; }

    mark_phase FILES
}

# ═══════════════════════════════════════════════════════════════════════════
#  PHASE: DBROOT — MySQL root credentials
# ═══════════════════════════════════════════════════════════════════════════

# Writes $DB_ROOT_CRED and makes root's password match it. Falls back to a
# skip-grant-tables recovery only when every normal ALTER USER path fails.
setup_mysql_root() {
    mkdir -p "$(dirname "$DB_ROOT_CRED")" || return 1
    local pw path_tok
    pw=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | cut -c1-16)
    path_tok=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | cut -c1-12)

    # Written 0600 before any secret goes in. The old installer chmod 777'd
    # this file, leaving the MySQL root password world-readable.
    : > "$DB_ROOT_CRED" || return 1
    chmod 600 "$DB_ROOT_CRED" || return 1
    {
        echo "\$user = 'root';"
        echo "\$pass = '${pw}';"
        echo "\$path = '${path_tok}';"
    } >> "$DB_ROOT_CRED"

    local ok=0
    if mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$pw'; FLUSH PRIVILEGES;" 2>/dev/null; then
        ok=1
    elif mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '$pw'; FLUSH PRIVILEGES;" 2>/dev/null; then
        ok=1
    elif mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$pw'; FLUSH PRIVILEGES;" 2>/dev/null; then
        ok=1
    fi
    # MYSQL_PWD, not -p"$pw": the latter puts the MySQL root password in the
    # process list for every local user to read.
    if [ "$ok" -eq 1 ] && MYSQL_PWD="$pw" mysql -uroot -e "SELECT 1" >/dev/null 2>&1; then
        return 0
    fi

    # Recovery: briefly start MySQL without privilege checks to reset root.
    local dropin_dir="" d
    for d in /etc/mysql/mysql.conf.d /etc/mysql/mariadb.conf.d /etc/mysql/conf.d; do
        [ -d "$d" ] && { dropin_dir="$d"; break; }
    done
    [ -n "$dropin_dir" ] || return 1
    local dropin="$dropin_dir/zz-mirza-recovery.cnf"
    printf '[mysqld]\nskip-grant-tables\n' > "$dropin" || return 1
    systemctl restart mysql
    mysql <<EOF
FLUSH PRIVILEGES;
DROP USER IF EXISTS 'root'@'localhost';
CREATE USER 'root'@'localhost' IDENTIFIED BY '${pw}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
    # The drop-in must go before the restart, or the server stays wide open.
    rm -f "$dropin"
    sed -i '/^skip-grant-tables/d' /etc/mysql/mysql.conf.d/mysqld.cnf 2>/dev/null
    systemctl restart mysql
    MYSQL_PWD="$pw" mysql -uroot -e "SELECT 1" >/dev/null 2>&1 || return 1
    return 0
}
export -f setup_mysql_root

phase_dbroot() {
    if phase_done DBROOT; then
        printf "  ${C_OK}●${CR} ${C_DIM}MySQL root access already configured - skipping.${CR}\n"
        return 0
    fi
    if [ ! -f "$DB_ROOT_CRED" ] || ! grep -q '\$pass' "$DB_ROOT_CRED" 2>/dev/null; then
        run_step "Configuring MySQL root access" "setup_mysql_root" \
            || { show_step_error; install_pause "MySQL root setup"; }
    fi
    mark_phase DBROOT
}

# ═══════════════════════════════════════════════════════════════════════════
#  PHASE: DB — application database and user
# ═══════════════════════════════════════════════════════════════════════════

# Reads the root password written by setup_mysql_root.
db_root_pass() { grep '\$pass' "$DB_ROOT_CRED" 2>/dev/null | cut -d"'" -f2; }

phase_db() {
    if phase_done DB; then
        printf "  ${C_OK}●${CR} ${C_DIM}Database already created - skipping.${CR}\n"
        return 0
    fi
    print_header "Creating the database"

    local rp; rp="$(db_root_pass)"
    if [ -z "$rp" ]; then
        printf "  ${C_BAD}●${CR} ${C_BAD}MySQL root password not found in %s${CR}\n" "$DB_ROOT_CRED"
        install_pause "Reading MySQL root credentials"
    fi

    # Credentials go in via MYSQL_PWD and stdin rather than -p on the command
    # line, which would expose the password in `ps` output to every user.
    # Only 'localhost' is granted: the old installer also created a '%' user,
    # exposing the bot database to the whole network.
    export MYSQL_PWD="$rp"
    if ! mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED WITH mysql_native_password BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED WITH mysql_native_password BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
    then
        unset MYSQL_PWD
        printf "  ${C_BAD}●${CR} ${C_BAD}Could not create the database or user.${CR}\n"
        install_pause "Creating database & user"
    fi
    unset MYSQL_PWD

    # Prove the bot's own credentials work before writing them into config.php.
    if ! MYSQL_PWD="$DB_PASS" mysql -u"$DB_USER" -e "USE \`${DB_NAME}\`;" >/dev/null 2>&1; then
        printf "  ${C_BAD}●${CR} ${C_BAD}The new database user cannot connect.${CR}\n"
        install_pause "Verifying database access"
    fi
    printf "  ${C_OK}●${CR} ${C_DIM}Database %s ready (user %s).${CR}\n" "$DB_NAME" "$DB_USER"

    mark_phase DB
}

# ═══════════════════════════════════════════════════════════════════════════
#  PHASE: PMA — phpMyAdmin, localhost-only
#
#  The old installer preseeded every phpMyAdmin password to the hard-coded
#  literal 'mirzahipass' and served it publicly at https://<domain>/phpmyadmin.
#  On a box that processes payments that is a standing brute-force target with
#  a password that is identical on every Mirza install in existence.
#
#  Here the passwords are random per-install, and access is restricted to
#  127.0.0.1, so reaching it requires an SSH tunnel:
#      ssh -L 8080:127.0.0.1:80 root@<server>
#      then browse to http://127.0.0.1:8080/phpmyadmin
#
#  Runs BEFORE phase_vhost, because that phase only emits the phpMyAdmin
#  Include line if the config file already exists.
# ═══════════════════════════════════════════════════════════════════════════
write_pma_restrict() {
    cat > "$PMA_RESTRICT_CONF" <<'EOF'
# Managed by the Mirza installer.
# phpMyAdmin is deliberately not reachable from the internet. To use it:
#   ssh -L 8080:127.0.0.1:80 root@<this-server>
#   then open http://127.0.0.1:8080/phpmyadmin
# To expose it publicly (NOT recommended), replace this file's contents with
# "Require all granted" and run: systemctl reload apache2
<Directory /usr/share/phpmyadmin>
    <RequireAny>
        Require ip 127.0.0.1
        Require ip ::1
    </RequireAny>
</Directory>
EOF
}
export -f write_pma_restrict

phase_pma() {
    if phase_done PMA; then
        printf "  ${C_OK}●${CR} ${C_DIM}phpMyAdmin already installed - skipping.${CR}\n"
        return 0
    fi
    print_header "Installing phpMyAdmin"

    local rp; rp="$(db_root_pass)"
    # Random per install. dbconfig-common needs the MySQL root password to
    # create its control user, and a separate random password for that user.
    local pma_pass; pma_pass="$(gen_ident)$(gen_ident)"

    # debconf-set-selections is the only way to install phpmyadmin without an
    # interactive dialog. Values are piped, never passed as arguments, so they
    # do not appear in `ps`.
    # Exported, not local: run_step runs this through `bash -c`, and a plain
    # shell variable does not cross that boundary — the child would pipe an
    # empty preseed to debconf and the install would then block on a dialog.
    export MIRZA_PMA_PRESEED="phpmyadmin phpmyadmin/dbconfig-install boolean true
phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2
phpmyadmin phpmyadmin/mysql/admin-pass password ${rp}
phpmyadmin phpmyadmin/mysql/app-pass password ${pma_pass}
phpmyadmin phpmyadmin/app-password-confirm password ${pma_pass}"

    if ! run_step "Installing phpMyAdmin" \
        "printf '%s\n' \"\$MIRZA_PMA_PRESEED\" | debconf-set-selections && \
         DEBIAN_FRONTEND=noninteractive apt-get install -y phpmyadmin" \
        ; then
        # Not fatal: phpMyAdmin is a convenience, and the bot works without
        # it. The install continues rather than stranding the operator.
        show_step_error
        printf "  ${C_WARN}!${CR} ${C_WARN}phpMyAdmin could not be installed; continuing without it.${CR}\n"
        printf "  ${C_DIM}The bot does not require it. Use 'mysql' on the server instead.${CR}\n"
        mark_phase PMA
        return 0
    fi
    unset MIRZA_PMA_PRESEED
    state_set PMA_PASS "$pma_pass"

    # The package ships its Apache config in /etc/phpmyadmin; conf-available
    # gets a symlink so both the vhost Include and a2enconf can find it.
    run_step "Restricting phpMyAdmin to localhost" \
        "[ -e '$PMA_CONF' ] || ln -sf /etc/phpmyadmin/apache.conf '$PMA_CONF'; \
         write_pma_restrict && a2enconf '$(basename "$PMA_RESTRICT_CONF" .conf)' 2>/dev/null; \
         a2enconf phpmyadmin 2>/dev/null; \
         apache2ctl configtest && systemctl reload apache2" \
        || { show_step_error; install_pause "Restricting phpMyAdmin"; }

    printf "  ${C_OK}●${CR} ${C_DIM}phpMyAdmin installed, reachable from localhost only.${CR}\n"
    mark_phase PMA
}

# ═══════════════════════════════════════════════════════════════════════════
#  PHASE: SSL — Let's Encrypt certificate
# ═══════════════════════════════════════════════════════════════════════════
phase_ssl() {
    if phase_done SSL; then
        printf "  ${C_OK}●${CR} ${C_DIM}SSL already configured - skipping.${CR}\n"
        return 0
    fi
    print_header "SSL certificate"

    if [ -f "${LE_LIVE}/fullchain.pem" ]; then
        printf "  ${C_OK}●${CR} ${C_DIM}A certificate for %s already exists - reusing it.${CR}\n" "$DOMAIN_HOST"
        mark_phase SSL
        return 0
    fi

    # SSH again before touching anything else, in case this phase is reached on
    # a server where ufw was enabled between runs.
    run_step "Opening firewall ports 80 & 443" \
        "ufw allow OpenSSH 2>/dev/null || ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp; true" \
        || { show_step_error; install_pause "Opening firewall ports"; }

    # certbot --standalone binds :80 itself, so Apache has to release the port.
    # Only stopped, never disabled: the old installer ran `systemctl disable
    # apache2` here, so a reboot before the end of the install left the server
    # with no web server at all.
    run_step "Stopping Apache for certificate issuance" "systemctl stop apache2" \
        || { show_step_error; install_pause "Stopping Apache"; }

    run_step "Installing Let's Encrypt (certbot)" \
        "apt-get install -y certbot && systemctl enable certbot.timer 2>/dev/null; true" \
        || { show_step_error; install_pause "Installing certbot"; }

    # An address means expiry warnings actually reach the operator, so it is
    # used whenever one was supplied.
    local email_flag="--register-unsafely-without-email"
    [ -n "$LE_EMAIL" ] && email_flag="--email $LE_EMAIL"

    # DOMAIN_HOST, never DOMAIN: certbot rejects a "host/subdir" value, which
    # is a legitimate DOMAIN here.
    if ! run_step "Requesting SSL certificate (Let's Encrypt)" \
        "certbot certonly --standalone --non-interactive --agree-tos $email_flag --preferred-challenges http -d '$DOMAIN_HOST'"; then
        show_step_error
        systemctl start apache2 2>/dev/null
        printf "\n  ${C_BAD}●${CR} ${C_BAD}Could not obtain a certificate for %s.${CR}\n" "$DOMAIN_HOST"
        printf "  ${C_DIM}Most common causes:${CR}\n"
        printf "    ${C_DIM}- The domain's A record does not point to %s${CR}\n" "$(get_server_ip)"
        printf "    ${C_DIM}- Port 80 is blocked by a provider firewall${CR}\n"
        printf "    ${C_DIM}- Let's Encrypt rate limit reached for this domain${CR}\n"
        install_pause "Requesting SSL certificate"
    fi

    # Renewal runs while Apache holds :80, so the certificate would renew but
    # never be picked up without a reload. The original installer had no hook.
    run_step "Installing renewal hook (reload Apache)" \
        "mkdir -p '$(dirname "$RENEW_HOOK")' && printf '#!/bin/sh\nsystemctl reload apache2\n' > '$RENEW_HOOK' && chmod +x '$RENEW_HOOK'" \
        || { show_step_error; install_pause "Installing renewal hook"; }

    run_step "Starting Apache" "systemctl enable apache2 && systemctl start apache2" \
        || { show_step_error; install_pause "Starting Apache"; }

    mark_phase SSL
}

# ═══════════════════════════════════════════════════════════════════════════
#  PHASE: VHOST — Apache virtual hosts
# ═══════════════════════════════════════════════════════════════════════════
phase_vhost() {
    if phase_done VHOST; then
        printf "  ${C_OK}●${CR} ${C_DIM}Virtual hosts already configured - skipping.${CR}\n"
        return 0
    fi
    print_header "Configuring Apache"

    # Included only when the file is really there. The old installer emitted
    # this line unconditionally, so Apache refused to start on any server
    # where phpMyAdmin was absent or later removed.
    # -e, not -f: $PMA_CONF is a symlink into /etc/phpmyadmin.
    local pma_include=""
    if [ -e "$PMA_CONF" ]; then
        pma_include="    Include ${PMA_CONF}"
    fi

    # cronbot/ and table.php are unauthenticated. A superglobal scan of all 17
    # jobs found no auth check of any kind, so while they were reachable over
    # HTTP anyone who knew the domain could run croncard.php (auto-confirms
    # card payments), backupbot.php (dumps the database), activeconfig.php /
    # disableconfig.php (mass enable/disable) or configtest.php (deletes
    # users). They are now driven by cron over the PHP CLI, which does not go
    # through Apache, so denying them here costs nothing.
    # api/hash.txt holds a bearer token that api/utils.php:59 accepts as full
    # admin auth (apiTokens() reads it, requireApiToken() compares against it).
    # It is a .txt, so Apache serves it as a static file: GET /api/hash.txt
    # returns working admin credentials for users.php, panels.php and the rest
    # of api/. The .htaccess shipped in api/ only denies utils.php, so this is
    # not covered. Denied here, where an operator cannot accidentally delete it.
    # The bot reads the file from disk and never over HTTP, so nothing breaks.
    local deny_block
    deny_block=$(cat <<DENY
    <Directory ${BOT_DIR}/cronbot>
        Require all denied
    </Directory>
    <Files "table.php">
        Require all denied
    </Files>
    <Files "hash.txt">
        Require all denied
    </Files>
    <FilesMatch "\.(sql|sql\.gz|zip|log|bak|swp|dist|ini)$">
        Require all denied
    </FilesMatch>
    <FilesMatch "^\.">
        Require all denied
    </FilesMatch>
DENY
)

    # ServerName gets DOMAIN_HOST: Apache expects a hostname, and DOMAIN may
    # carry a /subdir suffix.
    cat > "$VHOST_HTTP" <<EOF
<VirtualHost *:80>
    ServerName ${DOMAIN_HOST}
    DocumentRoot ${BOT_DIR}
    <Directory ${BOT_DIR}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
${deny_block}
${pma_include}
    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN_HOST}-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN_HOST}-access.log combined
</VirtualHost>
EOF

    cat > "$VHOST_HTTPS" <<EOF
<VirtualHost *:443>
    ServerName ${DOMAIN_HOST}
    DocumentRoot ${BOT_DIR}
    SSLEngine on
    SSLCertificateFile ${LE_LIVE}/fullchain.pem
    SSLCertificateKeyFile ${LE_LIVE}/privkey.pem
    <Directory ${BOT_DIR}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
${deny_block}
${pma_include}
    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN_HOST}-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN_HOST}-access.log combined
</VirtualHost>
EOF

    # a2dissite only; the old installer additionally rm'd the stock configs
    # from sites-available, which is destructive and unnecessary.
    run_step "Configuring Apache virtual hosts" \
        "a2ensite '$(basename "$VHOST_HTTP")' && a2ensite '$(basename "$VHOST_HTTPS")' && \
         a2dissite 000-default.conf default-ssl.conf 000-default-le-ssl.conf 2>/dev/null; \
         a2enmod ssl rewrite headers setenvif 2>/dev/null; \
         apache2ctl configtest && systemctl restart apache2" \
        || { show_step_error; install_pause "Configuring Apache virtual hosts"; }

    mark_phase VHOST
}

# ═══════════════════════════════════════════════════════════════════════════
#  PHASE: CONFIG — write config.php
# ═══════════════════════════════════════════════════════════════════════════

# Variable names here are consumed by the PHP sources and must match exactly:
# $domainhosts (panels.php builds subscription URLs from it), $APIKEY,
# $adminnumber, $usernamebot, $dbhost/$dbname/$usernamedb/$passworddb,
# $pdo, $options, $dsn, $request_exec_timeout.
#
# The old installer also emitted a $connect = mysqli_connect(...) block, so
# every request opened a second MySQL connection on top of the PDO one.
# Grepping the whole tree for '$connect' returns nothing but $ConnectToPanel
# in panels.php, and for 'mysqli_' returns nothing at all: no file has ever
# read it. It is dropped here; the bot uses $pdo exclusively.
render_config() {
    # Unquoted delimiter: shell variables interpolate, PHP variables are
    # escaped so they survive into the file.
    cat > "$CONFIG_FILE" <<EOF
<?php
// Generated by the Mirza installer. Re-created by 'mirza repair'.
// Raise this on panels whose API is slow to respond; null uses the default.
\$request_exec_timeout = null;
\$dbhost = 'localhost';
\$dbname = '${DB_NAME}';
\$usernamedb = '${DB_USER}';
\$passworddb = '${DB_PASS}';
\$options = [ PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC, PDO::ATTR_EMULATE_PREPARES => false, ];
\$dsn = "mysql:host=\$dbhost;dbname=\$dbname;charset=utf8mb4";
try { \$pdo = new PDO(\$dsn, \$usernamedb, \$passworddb, \$options); } catch (\PDOException \$e) { error_log("Database connection failed: " . \$e->getMessage()); die("error: database connection failed"); }
\$APIKEY = '${BOT_TOKEN}';
\$adminnumber = '${CHAT_ID}';
\$domainhosts = '${DOMAIN}';
\$usernamebot = '${BOTNAME}';
// Shared secret for the Telegram webhook. setWebhook registers this value, so
// Telegram stamps every genuine delivery with an X-Telegram-Bot-Api-Secret-Token
// header carrying it; index.php rejects any POST that does not match. Keep the
// two in step -- if you edit this, re-run 'mirza repair' so the webhook is
// re-registered, or Telegram's updates will start being refused.
\$webhook_secret = '${SECRET_TOKEN}';
?>
EOF
}

phase_config() {
    if phase_done CONFIG; then
        printf "  ${C_OK}●${CR} ${C_DIM}config.php already written - skipping.${CR}\n"
        SECRET_TOKEN="$(state_get SECRET)"
        return 0
    fi
    print_header "Writing configuration"

    SECRET_TOKEN="$(state_get SECRET)"
    if [ -z "$SECRET_TOKEN" ]; then
        SECRET_TOKEN="$(openssl rand -hex 16)"
        state_set SECRET "$SECRET_TOKEN"
    fi

    render_config || install_pause "Writing config.php"

    # 640 root-readable, www-data-readable. The old installer left config.php
    # at the directory default, so the bot token and database password were
    # readable by every local user on the box.
    chown root:www-data "$CONFIG_FILE" 2>/dev/null
    chmod 640 "$CONFIG_FILE" 2>/dev/null

    # A syntax error here produces a blank page and an unusable bot, so it is
    # caught now rather than after the webhook is live.
    if ! php -l "$CONFIG_FILE" >/dev/null 2>&1; then
        printf "  ${C_BAD}●${CR} ${C_BAD}Generated config.php is not valid PHP.${CR}\n"
        php -l "$CONFIG_FILE"
        install_pause "Validating config.php"
    fi
    printf "  ${C_OK}●${CR} ${C_DIM}config.php written and validated.${CR}\n"

    mark_phase CONFIG
}

# ═══════════════════════════════════════════════════════════════════════════
#  PHASE: TABLES — create the schema
# ═══════════════════════════════════════════════════════════════════════════
phase_tables() {
    if phase_done TABLES; then
        printf "  ${C_OK}●${CR} ${C_DIM}Database tables already initialized - skipping.${CR}\n"
        return 0
    fi
    print_header "Initializing database tables"

    # Run as www-data so any file table.php creates is owned correctly rather
    # than left root-owned for the web server to choke on.
    run_step "Initializing database tables" \
        "cd '$BOT_DIR' && sudo -u www-data ${PHP_BIN} table.php" \
        || { show_step_error; install_pause "Initializing database tables"; }

    # table.php exits 0 even when it creates nothing, so the result is
    # verified against the database itself.
    local n
    n=$(MYSQL_PWD="$DB_PASS" mysql -u"$DB_USER" -N -B -e \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" 2>/dev/null)
    if [ -z "$n" ] || [ "$n" -lt 1 ]; then
        printf "  ${C_BAD}●${CR} ${C_BAD}No tables were created in %s.${CR}\n" "$DB_NAME"
        install_pause "Verifying database tables"
    fi
    printf "  ${C_OK}●${CR} ${C_DIM}%s tables created.${CR}\n" "$n"

    mark_phase TABLES
}

# ═══════════════════════════════════════════════════════════════════════════
#  PHASE: CRON — scheduled jobs, with concurrency locks
#
#  Two independent things schedule these scripts:
#    1. this installer, via $CRON_FILE (php CLI), and
#    2. the bot itself, via activecron() in function.php, which writes 16
#       `curl https://<domain>/cronbot/<x>.php` lines into root's crontab the
#       first time an admin opens the admin panel.
#  addCronIfNotExists() dedupes only against root's crontab, so it cannot see
#  $CRON_FILE and the two schedules can overlap. None of the cronbot scripts
#  had any guard, and croncard.php auto-confirms payments by scanning for
#  payment_Status='waiting' rows — so two concurrent runs could confirm the
#  same payment twice. The lock below makes overlap harmless no matter which
#  side started the job, which is why activecron() is left alone.
#
#  The lock is inside the PHP, not in the cron line: a shell `flock` wrapper
#  would do nothing for the HTTP (curl) invocations activecron() registers.
# ═══════════════════════════════════════════════════════════════════════════

# Every job the bot's own activecron() knows about, with its frequency.
#
# lottery.php is included even though activecron() does not schedule it:
# admin.php:1923 registers it separately, by curl, when a lottery is enabled.
# Since the vhost now denies HTTP access to cronbot/, that curl job would 403
# and the lottery would silently stop running. Scheduling it here on the CLI
# at the same */1 frequency keeps it working. Running it when no lottery is
# active is harmless: it returns immediately unless scorestatus == 1, and it
# only acts at 00:00 (lottery.php:19-22).
#
# A newline-delimited string, NOT a bash array: write_cron_file runs inside
# run_step's `bash -c` child, and arrays cannot be exported across a process
# boundary — the child would see the literal text "${CRON_JOBS[@]}" and
# silently write an empty cron file.
CRON_JOBS_SPEC="\
*/15 * * * *|statusday.php
*/1 * * * *|croncard.php
*/1 * * * *|NoticationsService.php
*/5 * * * *|payment_expire.php
*/1 * * * *|sendmessage.php
*/3 * * * *|plisio.php
*/1 * * * *|activeconfig.php
*/1 * * * *|disableconfig.php
*/1 * * * *|iranpay1.php
0 */5 * * *|backupbot.php
*/2 * * * *|gift.php
*/30 * * * *|expireagent.php
*/15 * * * *|on_hold.php
*/2 * * * *|configtest.php
*/15 * * * *|uptime_node.php
*/15 * * * *|uptime_panel.php
*/1 * * * *|lottery.php"
export CRON_JOBS_SPEC

# Quoted delimiter: this is PHP source and must be written through verbatim.
write_cron_lock_helper() {
    cat > "$BOT_DIR/cronbot/_lock.php" <<'PHP'
<?php
// Managed by the Mirza installer. Re-created on install/update/repair.
//
// Stops two copies of the same cron script running at once. Needed because
// jobs can be started both by /etc/cron.d/mirzabot (php CLI) and by the
// crontab entries activecron() writes (curl over HTTP).
function mirza_cron_lock($scriptPath)
{
    // The handle is kept in a static so it stays open for the life of the
    // process: closing it would release the lock immediately.
    static $handles = [];

    $name = basename($scriptPath, '.php');
    $dir  = sys_get_temp_dir() . '/mirzabot-locks';
    if (!is_dir($dir)) {
        @mkdir($dir, 0700, true);
    }

    $fh = @fopen($dir . '/' . $name . '.lock', 'c');
    if ($fh === false) {
        // Never block the job just because the lock file is unavailable.
        return true;
    }
    if (!flock($fh, LOCK_EX | LOCK_NB)) {
        fclose($fh);
        return false;   // a copy is already running
    }
    ftruncate($fh, 0);
    fwrite($fh, (string) getmypid());
    fflush($fh);
    $handles[$name] = $fh;
    return true;
}
PHP
    chown www-data:www-data "$BOT_DIR/cronbot/_lock.php" 2>/dev/null
    chmod 644 "$BOT_DIR/cronbot/_lock.php" 2>/dev/null
}
export -f write_cron_lock_helper

# Inserts the lock call after the opening <?php of each cron script.
# Idempotent, and re-applied after an update because a fresh download
# overwrites these files.
patch_cron_locks() {
    local dir="$BOT_DIR/cronbot" f base patched=0
    [ -d "$dir" ] || { echo "No cronbot directory at $dir"; return 1; }

    for f in "$dir"/*.php; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        [ "$base" = "_lock.php" ] && continue
        # cronbot/index.php is not PHP at all (it is a plain "script runed!"
        # marker), so anything without a <?php first line is left alone.
        head -1 "$f" | grep -q '<?php' || continue
        grep -q 'mirza_cron_lock' "$f" && continue

        awk 'NR==1{
                print
                print "require_once __DIR__ . \"/_lock.php\";"
                print "if (!mirza_cron_lock(__FILE__)) { return; }"
                next
             }
             {print}' "$f" > "$f.mirzatmp" || return 1
        mv "$f.mirzatmp" "$f" || return 1
        # mv leaves the file root-owned; hand it back to the web server.
        chown www-data:www-data "$f" 2>/dev/null
        chmod 644 "$f" 2>/dev/null
        patched=$((patched + 1))
    done

    echo "Locked $patched cron script(s)."
    # Every patched file must still be valid PHP.
    for f in "$dir"/*.php; do
        [ -f "$f" ] || continue
        head -1 "$f" | grep -q '<?php' || continue
        "$PHP_BIN" -l "$f" >/dev/null 2>&1 || { echo "Syntax error after patching $f" >&2; return 1; }
    done
    return 0
}
export -f patch_cron_locks

write_cron_file() {
    # The bot's legacy activecron() writes HTTP curl jobs into root's crontab.
    # Apache now denies cronbot/ over HTTP, and /etc/cron.d/mirzabot is the
    # authoritative scheduler, so prune those stale curl entries whenever the
    # managed cron file is rebuilt. This keeps repair/update idempotent and
    # avoids a permanent stream of 403 curl jobs after upgrading old installs.
    if command -v crontab >/dev/null 2>&1; then
        local legacy_tmp
        legacy_tmp=$(mktemp /tmp/mirza-crontab.XXXXXX) || return 1
        chmod 600 "$legacy_tmp" 2>/dev/null
        if crontab -l > "$legacy_tmp.in" 2>/dev/null; then
            grep -vE 'cronbot/[^[:space:]]+\.php' "$legacy_tmp.in" > "$legacy_tmp" || true
            crontab "$legacy_tmp" 2>/dev/null || true
        fi
        rm -f "$legacy_tmp.in"
        rm -f "$legacy_tmp"
    fi

    # cron.d needs an explicit user field, and the filename may not contain a
    # dot or cron silently ignores it.
    {
        echo "# Managed by the Mirza installer. Do not edit; run 'mirza repair'."
        echo "SHELL=/bin/sh"
        echo "PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin"
        echo 'MAILTO=""'
        local sched script
        while IFS='|' read -r sched script; do
            [ -n "$script" ] || continue
            # A job whose script is absent would run every minute and log an
            # error every minute, so it is skipped.
            [ -f "$BOT_DIR/cronbot/$script" ] || continue
            printf '%s www-data cd %s && %s cronbot/%s >/dev/null 2>&1\n' \
                "$sched" "$BOT_DIR" "$PHP_BIN" "$script"
        done <<< "$CRON_JOBS_SPEC"
    } > "$CRON_FILE"
    chown root:root "$CRON_FILE" 2>/dev/null
    chmod 644 "$CRON_FILE" 2>/dev/null
}
# Runs in run_step's child shell, so it must cross the process boundary.
export -f write_cron_file

phase_cron() {
    if phase_done CRON; then
        printf "  ${C_OK}●${CR} ${C_DIM}Cron jobs already registered - skipping.${CR}\n"
        return 0
    fi
    print_header "Scheduling background jobs"

    run_step "Adding cron concurrency locks" \
        "write_cron_lock_helper && patch_cron_locks" \
        || { show_step_error; install_pause "Adding cron concurrency locks"; }

    run_step "Registering cron jobs" "write_cron_file && systemctl restart cron 2>/dev/null; true" \
        || { show_step_error; install_pause "Registering cron jobs"; }

    # Counted from the file that was actually written, not from the spec, so
    # any silently skipped job shows up in the number the operator sees.
    printf "  ${C_OK}●${CR} ${C_DIM}%s jobs scheduled in %s.${CR}\n" \
        "$(grep -cE '^[0-9*]' "$CRON_FILE" 2>/dev/null)" "$CRON_FILE"

    mark_phase CRON
}

# ═══════════════════════════════════════════════════════════════════════════
#  PHASE: WEBHOOK — point Telegram at this server
# ═══════════════════════════════════════════════════════════════════════════
phase_webhook() {
    if phase_done WEBHOOK; then
        printf "  ${C_OK}●${CR} ${C_DIM}Webhook already set - skipping.${CR}\n"
        return 0
    fi
    print_header "Connecting to Telegram"

    [ -z "$SECRET_TOKEN" ] && SECRET_TOKEN="$(state_get SECRET)"

    # DOMAIN (not DOMAIN_HOST): a subdirectory install must keep its path.
    local hook="https://${DOMAIN}/index.php"

    # secret_token is sent so Telegram stamps every update with
    # X-Telegram-Bot-Api-Secret-Token. index.php reads $webhook_secret out of
    # config.php and rejects any POST whose header does not match, so the two
    # must carry the same value -- phase_config writes the same $SECRET_TOKEN
    # that is registered here. Re-registering with a different secret without
    # rewriting config.php would make the bot refuse Telegram's own updates.


    # curl succeeds on any HTTP reply, so the JSON body decides the outcome.
    run_step "Setting Telegram webhook" \
        "resp=\$(curl -fsS --max-time 20 -F 'url=${hook}' -F 'secret_token=${SECRET_TOKEN}' 'https://api.telegram.org/bot${BOT_TOKEN}/setWebhook'); \
         echo \"\$resp\"; echo \"\$resp\" | grep -q '\"ok\":true'" \
        || { show_step_error
             printf "  ${C_BAD}●${CR} ${C_BAD}Telegram refused the webhook URL %s${CR}\n" "$hook"
             printf "  ${C_DIM}Telegram requires a publicly reachable HTTPS URL with a valid certificate.${CR}\n"
             install_pause "Setting Telegram webhook"; }

    curl -fsS --max-time 15 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d text="✅ Mirza is installed. Send /start to begin." >/dev/null 2>&1

    mark_phase WEBHOOK
}

# ═══════════════════════════════════════════════════════════════════════════
#  Completion summary
# ═══════════════════════════════════════════════════════════════════════════
install_summary() {
    clear
    banner
    _sec "Installation complete"
    printf "    ${C_OK}●${CR} ${C_OK}Mirza is installed and connected to Telegram.${CR}\n"
    printf "    ${C_DIM}Open Telegram and send ${CR}${C_KEY}/start${CR}${C_DIM} to @%s.${CR}\n" "$BOTNAME"

    _sec "Access"
    _kv "Bot URL" "${C_DIM}https://${DOMAIN}${CR}"
    if [ -e "$PMA_CONF" ]; then
        _kv "phpMyAdmin" "${C_DIM}localhost only - not exposed to the internet${CR}"
        printf "    ${C_DIM}%-11s${CR}${C_BORDER}:${CR} ${C_DIM}ssh -L 8080:127.0.0.1:80 root@%s${CR}\n" \
            "" "$(get_server_ip)"
        printf "    ${C_DIM}%-11s${CR}${C_BORDER}:${CR} ${C_DIM}then open http://127.0.0.1:8080/phpmyadmin${CR}\n" ""
    fi

    _sec "Database"
    _kv "Name"     "${C_KEY}${DB_NAME}${CR}"
    _kv "Username" "${C_KEY}${DB_USER}${CR}"
    _kv "Password" "${C_KEY}${DB_PASS}${CR}"
    printf "    ${C_WARN}!${CR} ${C_DIM}Save these somewhere safe. They are also in %s${CR}\n" "$CONFIG_FILE"

    _sec "Manage"
    _kv "Version" "${C_KEY}$(get_installed_version)${CR}"
    _kv "Command" "${C_DIM}run ${CR}${C_KEY}mirza${CR}${C_DIM} anytime to open the menu${CR}"
    # Only claimed when the link really exists: install_self is best-effort and
    # telling the operator to run a command that is not there is worse than
    # saying nothing.
    if [ ! -e "$BIN_LINK" ]; then
        printf "    ${C_WARN}!${CR} ${C_DIM}The 'mirza' command could not be installed; run %s directly.${CR}\n" \
            "$MASTER_SCRIPT"
    fi
    echo ""
    _rule
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
#  install
# ═══════════════════════════════════════════════════════════════════════════
install_bot() {
    # A completed install is only overwritten on an explicit confirmation.
    if [ -f "$CONFIG_FILE" ] && ! has_resumable_state; then
        _sec "Already installed"
        printf "    ${C_WARN}●${CR} ${C_TXT}A configuration already exists at %s${CR}\n" "$CONFIG_FILE"
        printf "    ${C_DIM}Use 'mirza update' to upgrade, or 'mirza uninstall' to remove it first.${CR}\n\n"
        return 1
    fi

    if has_resumable_state; then
        printf "\n  ${C_OK}●${CR} ${C_DIM}Resuming the previous installation; completed steps are skipped.${CR}\n"
    fi

    resolve_vars
    state_set STARTED "$(date +%s)"

    phase_preflight
    plan_eta
    phase_deps
    phase_tune
    phase_files
    phase_dbroot
    phase_db
    phase_pma
    phase_ssl
    phase_vhost
    phase_config
    phase_tables
    phase_cron
    phase_webhook

    mark_phase DONE
    install_summary
}

# ═══════════════════════════════════════════════════════════════════════════
#  Lifecycle helpers
#
#  Every command below operates on an install that already exists, so the
#  settings come from config.php rather than from prompts. config.php is the
#  authority: the state file can be stale or absent (e.g. after a migration),
#  but config.php is what the running bot actually reads.
# ═══════════════════════════════════════════════════════════════════════════

# Reads a single-quoted PHP scalar assignment out of config.php.
config_get() {
    local var="$1"
    [ -f "$CONFIG_FILE" ] || return 1
    sed -n "s/^\\\$${var}[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" "$CONFIG_FILE" 2>/dev/null | head -1
}

# BOT_DIR must be known before CONFIG_FILE can be located, so it is resolved
# from --dir, then the state file, then the default.
resolve_install_dir() {
    [ -n "$BOT_DIR" ] || BOT_DIR="$(state_get BOT_DIR)"
    [ -n "$BOT_DIR" ] || BOT_DIR="$BOT_DIR_DEFAULT"
    compute_paths
}

load_existing_config() {
    [ -f "$CONFIG_FILE" ] || return 1
    DB_NAME="$(config_get dbname)"
    DB_USER="$(config_get usernamedb)"
    DB_PASS="$(config_get passworddb)"
    BOT_TOKEN="$(config_get APIKEY)"
    CHAT_ID="$(config_get adminnumber)"
    DOMAIN="$(config_get domainhosts)"
    BOTNAME="$(config_get usernamebot)"
    # config.php wins over the state file: it is what the running bot actually
    # enforces, so a re-registration has to tell Telegram that same value. The
    # state file is only the fallback for installs written before the variable
    # existed.
    SECRET_TOKEN="$(config_get webhook_secret)"
    [ -z "$SECRET_TOKEN" ] && SECRET_TOKEN="$(state_get SECRET)"
    PHP_VER="$(state_get PHP_VER)"
    [ -z "$PHP_VER" ] && PHP_VER="$(resolve_php_ver 2>/dev/null)"
    [ -z "$PHP_VER" ] && PHP_VER="${PHP_VER_CANDIDATES%% *}"
    compute_paths
    [ -n "$DB_NAME" ] && [ -n "$BOT_TOKEN" ]
}

require_install() {
    resolve_install_dir
    if ! load_existing_config; then
        _sec "No installation found"
        printf "    ${C_BAD}●${CR} ${C_BAD}Could not read %s${CR}\n" "$CONFIG_FILE"
        printf "    ${C_DIM}Run 'mirza install' first, or pass --dir if the bot lives elsewhere.${CR}\n\n"
        exit 1
    fi
}

# Used by install, update, change-domain and change-token.
set_webhook() {
    [ -z "$SECRET_TOKEN" ] && SECRET_TOKEN="$(state_get SECRET)"
    if [ -z "$SECRET_TOKEN" ]; then
        SECRET_TOKEN="$(openssl rand -hex 16)"
        state_set SECRET "$SECRET_TOKEN"
        # Older config.php files did not have $webhook_secret. If repair or
        # update registers a newly generated secret without writing it into
        # config.php, the running bot keeps failing open and future webhook
        # repairs may register a different secret. Persist it immediately.
        [ -f "$CONFIG_FILE" ] && render_config && chown root:www-data "$CONFIG_FILE" 2>/dev/null && chmod 640 "$CONFIG_FILE" 2>/dev/null
    fi
    local resp
    resp=$(curl -fsS --max-time 20 \
        -F "url=https://${DOMAIN}/index.php" \
        -F "secret_token=${SECRET_TOKEN}" \
        "https://api.telegram.org/bot${BOT_TOKEN}/setWebhook" 2>&1)
    echo "$resp" | grep -q '"ok":true'
}

# Timestamped, kept outside BOT_DIR so an update that replaces the directory
# cannot destroy its own rollback point.
make_safety_backup() {
    local stamp; stamp=$(date +%Y%m%d-%H%M%S)
    local dest="$STATE_DIR/backup-$stamp"
    mkdir -p "$dest" || return 1
    chmod 700 "$dest" 2>/dev/null
    [ -f "$CONFIG_FILE" ] && cp -a "$CONFIG_FILE" "$dest/config.php"
    MYSQL_PWD="$DB_PASS" mysqldump -u"$DB_USER" --single-transaction --quick \
        --default-character-set=utf8mb4 "$DB_NAME" > "$dest/database.sql" 2>/dev/null
    if [ ! -s "$dest/database.sql" ]; then
        rm -f "$dest/database.sql"
        echo "Warning: database dump failed or was empty." >&2
    fi
    chmod 700 "$dest" 2>/dev/null
    echo "$dest"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Runtime data carried across an update
#
#  update replaces the whole tree with a fresh archive, so anything the bot
#  wrote into its own directory is lost unless it is copied back. The old
#  installer only ever preserved config.php, which silently destroyed every
#  reseller sub-bot on the server.
#
#  vpnbot/<telegram_id><bot_username>/ is one such directory per reseller,
#  created by copying vpnbot/Default (admin.php:9442, api/users.php:622).
#  Each holds its OWN config.php with that reseller's token, plus live JSON
#  state under data/ (see cronbot/backupbot.php:15). None of it exists in the
#  release archive, so none of it can be recovered by re-downloading.
#
#  Default, update and index.php are the shipped template and must come from
#  the NEW archive; everything else under vpnbot/ is operator data.
#  api/hash.txt is the generated API token (admin.php:6120, read back at
#  api/utils.php:59) and is gitignored, so it is likewise not in the archive.
# ═══════════════════════════════════════════════════════════════════════════
PRESERVE_PATHS="\
api/hash.txt
custom.jpg
storage"

carry_runtime_data() {
    local old="$1" new="$2" rel base n=0

    # config.php first: without it the bot cannot start at all.
    if [ -f "$old/config.php" ]; then
        cp -a "$old/config.php" "$new/config.php" || return 1
    fi

    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        [ -e "$old/$rel" ] || continue
        mkdir -p "$(dirname "$new/$rel")" 2>/dev/null
        cp -a "$old/$rel" "$new/$rel" 2>/dev/null && n=$((n + 1))
    done <<< "$PRESERVE_PATHS"

    # Reseller sub-bots. Skipping the three shipped entries keeps the template
    # at whatever version the new archive provides.
    if [ -d "$old/vpnbot" ]; then
        mkdir -p "$new/vpnbot" 2>/dev/null
        for rel in "$old/vpnbot"/*; do
            [ -e "$rel" ] || continue
            base=$(basename "$rel")
            case "$base" in
                Default|update|index.php) continue ;;
            esac
            rm -rf "$new/vpnbot/$base" 2>/dev/null
            cp -a "$rel" "$new/vpnbot/$base" 2>/dev/null && n=$((n + 1))
        done
    fi

    echo "Carried over $n runtime item(s)."
    return 0
}
export -f carry_runtime_data
export PRESERVE_PATHS
MIGRATE_DUMP="${MIGRATE_DUMP:-}"
export MIGRATE_DUMP

# ═══════════════════════════════════════════════════════════════════════════
#  update
# ═══════════════════════════════════════════════════════════════════════════

update_bot() {
    require_install
    print_header "Updating Mirza"

    # The install's pinned source must not be reused, or every update would
    # re-download the version originally installed.
    state_set SRC_ZIP_URL ""
    state_set SRC_LABEL ""
    choose_source
    printf "  ${C_DIM}Installed:${CR}  ${C_KEY}%s${CR}\n" "$(get_installed_version)"
    printf "  ${C_DIM}Updating to:${CR} ${C_KEY}%s${CR}\n" "$SRC_LABEL"

    STEP_TOTAL=9; STEP_NO=0; ETA_REMAINING=100

    local backup
    run_step "Backing up config and database" "true"
    backup="$(make_safety_backup)"
    printf "  ${C_DIM}Backup saved to %s${CR}\n" "$backup"

    local tmp="/tmp/mirzaupdate.$$"
    rm -rf "$tmp"; mkdir -p "$tmp"

    run_step "Downloading ${SRC_LABEL}" \
        "curl -fsSL --retry 3 --retry-delay 2 -o '$tmp/bot.zip' '$SRC_ZIP_URL'" \
        || { show_step_error; rm -rf "$tmp"; printf "  ${C_BAD}●${CR} ${C_BAD}Update aborted; nothing was changed.${CR}\n"; return 1; }

    run_step "Extracting files" "unzip -qo '$tmp/bot.zip' -d '$tmp'" \
        || { show_step_error; rm -rf "$tmp"; printf "  ${C_BAD}●${CR} ${C_BAD}Update aborted; nothing was changed.${CR}\n"; return 1; }

    local extracted
    extracted=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)
    if [ -z "$extracted" ]; then
        rm -rf "$tmp"
        printf "  ${C_BAD}●${CR} ${C_BAD}Downloaded archive was empty; nothing was changed.${CR}\n"
        return 1
    fi

    # The old tree is moved aside rather than deleted, so a failure here is
    # recoverable. It is removed only once the new tree is in place.
    local old="${BOT_DIR}.old.$$"
    if ! mv "$BOT_DIR" "$old"; then
        rm -rf "$tmp"
        printf "  ${C_BAD}●${CR} ${C_BAD}Could not move the existing install aside.${CR}\n"
        return 1
    fi
    mkdir -p "$BOT_DIR"
    shopt -s dotglob
    mv "$extracted"/* "$BOT_DIR"
    shopt -u dotglob
    rm -rf "$tmp"

    # Must happen before $old is deleted at the end of this function. A failure
    # is reported but not fatal: the new tree is already in place and $old is
    # still on disk, so the operator can recover the agent directories by hand.
    run_step "Preserving agent bots and runtime data" \
        "carry_runtime_data '$old' '$BOT_DIR'" \
        || { show_step_error
             printf "  ${C_WARN}!${CR} ${C_WARN}Runtime data may not have carried over. The previous tree is kept at %s${CR}\n" "$old"
             printf "  ${C_DIM}Copy vpnbot/<agent> directories and api/hash.txt across manually before deleting it.${CR}\n"; }

    chown root:www-data "$CONFIG_FILE" 2>/dev/null
    chmod 640 "$CONFIG_FILE" 2>/dev/null

    run_step "Installing PHP dependencies (composer)" "install_php_deps '$BOT_DIR'" \
        || { show_step_error; printf "  ${C_WARN}!${CR} ${C_WARN}Dependencies failed; the previous tree is at %s${CR}\n" "$old"; }

    run_step "Restoring file permissions" \
        "chown -R www-data:www-data '$BOT_DIR' && find '$BOT_DIR' -type d -exec chmod 755 {} + && find '$BOT_DIR' -type f -exec chmod 644 {} + && chown root:www-data '$CONFIG_FILE' && chmod 640 '$CONFIG_FILE'" \
        || show_step_error

    run_step "Applying database migrations" \
        "cd '$BOT_DIR' && sudo -u www-data ${PHP_BIN} table.php" \
        || { show_step_error; printf "  ${C_WARN}!${CR} ${C_WARN}Migrations reported an error. Backup: %s${CR}\n" "$backup"; }

    # The fresh archive has overwritten every patched cron script, so the
    # concurrency guards must be re-applied or croncard.php is unprotected
    # again from this moment on.
    run_step "Re-applying cron concurrency locks" \
        "write_cron_lock_helper && patch_cron_locks && write_cron_file" \
        || show_step_error

    run_step "Re-registering the Telegram webhook" "true"
    if set_webhook; then
        printf "  ${C_OK}●${CR} ${C_DIM}Webhook re-registered.${CR}\n"
    else
        printf "  ${C_WARN}!${CR} ${C_WARN}Webhook could not be re-registered; run 'mirza repair'.${CR}\n"
    fi

    rm -rf "$old"
    _sec "Update complete"
    # Read back from the new tree's version file rather than echoing
    # $SRC_LABEL: the label is what was requested, this is what actually landed.
    _kv "Version" "${C_KEY}$(get_installed_version)${CR} ${C_DIM}(${SRC_LABEL})${CR}"
    _kv "Backup"  "${C_DIM}${backup}${CR}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
#  diagnose — read-only health report
# ═══════════════════════════════════════════════════════════════════════════
cmd_diagnose() {
    resolve_install_dir
    clear; banner
    _sec "Diagnostics"

    local cfg_ok=0
    if load_existing_config; then cfg_ok=1; fi

    printf "    %s ${C_TXT}config.php${CR} ${C_DIM}(%s)${CR}\n" \
        "$([ "$cfg_ok" -eq 1 ] && _dot ok || _dot bad)" "$CONFIG_FILE"
    if [ "$cfg_ok" -eq 0 ]; then
        printf "\n    ${C_DIM}Nothing else can be checked without a readable config.${CR}\n\n"
        return 1
    fi

    local perms
    perms=$(stat -c '%a %U:%G' "$CONFIG_FILE" 2>/dev/null)
    case "$perms" in
        640*|600*) printf "    %s ${C_TXT}config.php permissions${CR} ${C_DIM}(%s)${CR}\n" "$(_dot ok)" "$perms" ;;
        *)         printf "    %s ${C_TXT}config.php permissions${CR} ${C_DIM}(%s - expected 640)${CR}\n" "$(_dot warn)" "$perms" ;;
    esac

    local svc
    for svc in apache2 mysql cron; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            printf "    %s ${C_TXT}%s${CR} ${C_DIM}(running)${CR}\n" "$(_dot ok)" "$svc"
        else
            printf "    %s ${C_TXT}%s${CR} ${C_DIM}(not running)${CR}\n" "$(_dot bad)" "$svc"
        fi
    done

    if MYSQL_PWD="$DB_PASS" mysql -u"$DB_USER" -e "USE \`${DB_NAME}\`;" >/dev/null 2>&1; then
        local tn
        tn=$(MYSQL_PWD="$DB_PASS" mysql -u"$DB_USER" -N -B -e \
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" 2>/dev/null)
        printf "    %s ${C_TXT}database${CR} ${C_DIM}(%s, %s tables)${CR}\n" "$(_dot ok)" "$DB_NAME" "${tn:-?}"
    else
        printf "    %s ${C_TXT}database${CR} ${C_DIM}(cannot connect as %s)${CR}\n" "$(_dot bad)" "$DB_USER"
    fi

    if [ -f "${LE_LIVE}/fullchain.pem" ]; then
        local exp days
        exp=$(openssl x509 -enddate -noout -in "${LE_LIVE}/fullchain.pem" 2>/dev/null | cut -d= -f2)
        days=$(( ( $(date -d "$exp" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
        if [ "$days" -gt 14 ]; then
            printf "    %s ${C_TXT}SSL certificate${CR} ${C_DIM}(%s days left)${CR}\n" "$(_dot ok)" "$days"
        else
            printf "    %s ${C_TXT}SSL certificate${CR} ${C_DIM}(%s days left - renew soon)${CR}\n" "$(_dot warn)" "$days"
        fi
    else
        printf "    %s ${C_TXT}SSL certificate${CR} ${C_DIM}(none for %s)${CR}\n" "$(_dot bad)" "$DOMAIN_HOST"
    fi

    local info url pending
    info=$(curl -fsS --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getWebhookInfo" 2>/dev/null)
    url=$(echo "$info" | grep -o '"url":"[^"]*"' | cut -d'"' -f4)
    pending=$(echo "$info" | grep -o '"pending_update_count":[0-9]*' | cut -d: -f2)
    if [ -n "$url" ]; then
        printf "    %s ${C_TXT}webhook${CR} ${C_DIM}(%s)${CR}\n" "$(_dot ok)" "$url"
        [ -n "$pending" ] && [ "$pending" -gt 50 ] && \
            printf "    %s ${C_TXT}pending updates${CR} ${C_DIM}(%s - the bot may be erroring)${CR}\n" "$(_dot warn)" "$pending"
        local err
        err=$(echo "$info" | grep -o '"last_error_message":"[^"]*"' | cut -d'"' -f4)
        [ -n "$err" ] && printf "    %s ${C_TXT}last webhook error${CR} ${C_DIM}(%s)${CR}\n" "$(_dot warn)" "$err"
    else
        printf "    %s ${C_TXT}webhook${CR} ${C_DIM}(not set)${CR}\n" "$(_dot bad)"
    fi

    if [ -f "$CRON_FILE" ]; then
        printf "    %s ${C_TXT}cron jobs${CR} ${C_DIM}(%s scheduled)${CR}\n" \
            "$(_dot ok)" "$(grep -cE '^[0-9*]' "$CRON_FILE" 2>/dev/null)"
    else
        printf "    %s ${C_TXT}cron jobs${CR} ${C_DIM}(%s missing)${CR}\n" "$(_dot bad)" "$CRON_FILE"
    fi

    local unlocked=0 f
    for f in "$BOT_DIR"/cronbot/*.php; do
        [ -f "$f" ] || continue
        [ "$(basename "$f")" = "_lock.php" ] && continue
        head -1 "$f" 2>/dev/null | grep -q '<?php' || continue
        grep -q 'mirza_cron_lock' "$f" || unlocked=$((unlocked + 1))
    done
    if [ "$unlocked" -eq 0 ]; then
        printf "    %s ${C_TXT}cron concurrency locks${CR} ${C_DIM}(all scripts guarded)${CR}\n" "$(_dot ok)"
    else
        printf "    %s ${C_TXT}cron concurrency locks${CR} ${C_DIM}(%s unguarded - run 'mirza repair')${CR}\n" "$(_dot warn)" "$unlocked"
    fi

    local free_mb
    free_mb=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$free_mb" ] && [ "$free_mb" -lt 512 ]; then
        printf "    %s ${C_TXT}disk space${CR} ${C_DIM}(%s MB free)${CR}\n" "$(_dot bad)" "$free_mb"
    else
        printf "    %s ${C_TXT}disk space${CR} ${C_DIM}(%s MB free)${CR}\n" "$(_dot ok)" "${free_mb:-?}"
    fi

    _sec "Details"
    _kv "Directory" "${C_DIM}${BOT_DIR}${CR}"
    _kv "Domain"    "${C_DIM}${DOMAIN}${CR}"
    _kv "Bot"       "${C_DIM}@${BOTNAME}${CR}"
    _kv "PHP"       "${C_DIM}${PHP_VER}${CR}"

    # Latest is only reported when GitHub actually answered; an API failure
    # must not be rendered as "up to date".
    local inst latest
    inst="$(get_installed_version)"
    latest="$(get_latest_version 2>/dev/null)"
    if [ -n "$latest" ] && [ "$inst" != "unknown" ] && [ "$inst" != "$latest" ]; then
        _kv "Version" "${C_DIM}${inst}${CR} ${C_WARN}(latest: ${latest} - run 'mirza update')${CR}"
    elif [ -n "$latest" ]; then
        _kv "Version" "${C_DIM}${inst}${CR} ${C_DIM}(latest: ${latest})${CR}"
    else
        _kv "Version" "${C_DIM}${inst}${CR}"
    fi
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
#  repair — re-apply everything that is safe to re-apply
# ═══════════════════════════════════════════════════════════════════════════
cmd_repair() {
    require_install
    print_header "Repairing the installation"
    STEP_TOTAL=6; STEP_NO=0; ETA_REMAINING=45

    run_step "Restoring file permissions" \
        "chown -R www-data:www-data '$BOT_DIR' && find '$BOT_DIR' -type d -exec chmod 755 {} + && find '$BOT_DIR' -type f -exec chmod 644 {} + && chown root:www-data '$CONFIG_FILE' && chmod 640 '$CONFIG_FILE'" \
        || show_step_error

    run_step "Re-applying PHP settings" \
        "write_php_ini '$PHP_INI_APACHE'; write_php_ini '$PHP_INI_CLI'" \
        || show_step_error

    run_step "Re-applying cron locks and schedule" \
        "write_cron_lock_helper && patch_cron_locks && write_cron_file && systemctl restart cron 2>/dev/null; true" \
        || show_step_error

    run_step "Reinstalling PHP dependencies" "install_php_deps '$BOT_DIR'" || show_step_error

    run_step "Restarting services" \
        "apache2ctl configtest && systemctl restart apache2 && systemctl restart mysql" \
        || show_step_error

    run_step "Re-registering the Telegram webhook" "true"
    if set_webhook; then
        printf "  ${C_OK}●${CR} ${C_DIM}Webhook re-registered.${CR}\n"
    else
        printf "  ${C_WARN}!${CR} ${C_WARN}Webhook could not be re-registered - check the domain and certificate.${CR}\n"
    fi

    printf "\n  ${C_OK}●${CR} ${C_DIM}Repair finished. Run 'mirza diagnose' to confirm.${CR}\n\n"
}

# ═══════════════════════════════════════════════════════════════════════════
#  change-domain
# ═══════════════════════════════════════════════════════════════════════════
cmd_change_domain() {
    require_install
    print_header "Changing the domain"

    local old_domain="$DOMAIN" new=""
    _kv "Current" "${C_DIM}${old_domain}${CR}"
    echo ""

    while true; do
        printf "  ${C_PROMPT}❯${CR} New domain: "
        read -r new
        [ -z "$new" ] && { printf "    ${C_DIM}Cancelled.${CR}\n"; return 0; }
        validate_domain "$new" && break
        printf "    ${C_BAD}●${CR} ${C_BAD}That is not a valid domain.${CR}\n"
    done

    DOMAIN="$new"
    compute_paths
    domain_points_here "$DOMAIN" || \
        printf "  ${C_WARN}!${CR} ${C_WARN}%s does not resolve to this server (%s).${CR}\n" "$DOMAIN_HOST" "$(get_server_ip)"

    STEP_TOTAL=4; STEP_NO=0; ETA_REMAINING=60

    # config.php is rewritten wholesale from the values already in memory,
    # rather than sed'ed in place: a regex edit would silently do nothing if
    # the file's formatting ever changed.
    run_step "Updating config.php" \
        "true" && render_config && chown root:www-data "$CONFIG_FILE" && chmod 640 "$CONFIG_FILE"
    php -l "$CONFIG_FILE" >/dev/null 2>&1 || {
        printf "  ${C_BAD}●${CR} ${C_BAD}Rewritten config.php is invalid; restoring the old domain.${CR}\n"
        DOMAIN="$old_domain"; compute_paths; render_config
        return 1
    }

    if [ ! -f "${LE_LIVE}/fullchain.pem" ]; then
        run_step "Requesting a certificate for ${DOMAIN_HOST}" \
            "systemctl stop apache2; certbot certonly --standalone --non-interactive --agree-tos $([ -n "$LE_EMAIL" ] && echo "--email $LE_EMAIL" || echo '--register-unsafely-without-email') --preferred-challenges http -d '$DOMAIN_HOST'; systemctl start apache2" \
            || { show_step_error
                 printf "  ${C_WARN}!${CR} ${C_WARN}Certificate issuance failed; the new vhost will not serve HTTPS.${CR}\n"; }
    fi

    mark_phase_undo VHOST
    phase_vhost

    run_step "Re-pointing the Telegram webhook" "true"
    if set_webhook; then
        state_set DOMAIN "$DOMAIN"
        printf "\n  ${C_OK}●${CR} ${C_DIM}Domain changed to %s.${CR}\n\n" "$DOMAIN"
    else
        printf "  ${C_BAD}●${CR} ${C_BAD}Telegram rejected the new webhook URL.${CR}\n"
        printf "  ${C_DIM}config.php now points at %s; fix DNS/SSL then run 'mirza repair'.${CR}\n\n" "$DOMAIN"
    fi
}

# Lets a phase re-run by clearing its completion marker.
mark_phase_undo() {
    [ -f "$STATE_FILE" ] || return 0
    grep -v -x -F "PHASE:$1" "$STATE_FILE" 2>/dev/null | _state_atomic_replace
}

# ═══════════════════════════════════════════════════════════════════════════
#  change-token
# ═══════════════════════════════════════════════════════════════════════════
cmd_change_token() {
    require_install
    print_header "Changing the bot token"

    local old_token="$BOT_TOKEN" new=""
    _kv "Current bot" "${C_DIM}@${BOTNAME}${CR}"
    echo ""

    while true; do
        printf "  ${C_PROMPT}❯${CR} New token from @BotFather: "
        read -r new
        [ -z "$new" ] && { printf "    ${C_DIM}Cancelled.${CR}\n"; return 0; }
        validate_token "$new"
        case $? in
            0) break ;;
            1) printf "    ${C_BAD}●${CR} ${C_BAD}That does not look like a bot token.${CR}\n" ;;
            2) printf "    ${C_BAD}●${CR} ${C_BAD}Telegram rejected that token.${CR}\n" ;;
        esac
    done

    # The username belongs to the token, so it is read back from Telegram
    # rather than left pointing at the previous bot.
    local newname
    newname=$(curl -fsS --max-time 10 "https://api.telegram.org/bot${new}/getMe" 2>/dev/null \
              | grep -o '"username":"[^"]*"' | cut -d'"' -f4 | head -1)
    [ -n "$newname" ] && BOTNAME="$newname"

    # The old bot keeps delivering updates to this server until its webhook is
    # cleared, so it is removed before the new one is registered.
    curl -fsS --max-time 10 "https://api.telegram.org/bot${old_token}/deleteWebhook" >/dev/null 2>&1

    BOT_TOKEN="$new"
    render_config
    chown root:www-data "$CONFIG_FILE" 2>/dev/null
    chmod 640 "$CONFIG_FILE" 2>/dev/null

    if set_webhook; then
        state_set BOT_TOKEN "$BOT_TOKEN"
        state_set BOTNAME "$BOTNAME"
        printf "\n  ${C_OK}●${CR} ${C_DIM}Token updated. The bot is now @%s.${CR}\n\n" "$BOTNAME"
    else
        BOT_TOKEN="$old_token"
        render_config
        printf "\n  ${C_BAD}●${CR} ${C_BAD}Webhook registration failed; the old token has been restored.${CR}\n\n"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  renew-ssl
# ═══════════════════════════════════════════════════════════════════════════
renew_ssl() {
    require_install
    print_header "Renewing the SSL certificate"
    STEP_TOTAL=2; STEP_NO=0; ETA_REMAINING=40

    if [ -f "${LE_LIVE}/fullchain.pem" ]; then
        # --webroot would need a matching alias; the standalone challenge is
        # what the certificate was issued with, so Apache releases :80 briefly.
        run_step "Renewing certificate for ${DOMAIN_HOST}" \
            "systemctl stop apache2; certbot renew --force-renewal --cert-name '$DOMAIN_HOST' --standalone; rc=\$?; systemctl start apache2; exit \$rc" \
            || { show_step_error; systemctl start apache2 2>/dev/null
                 printf "  ${C_BAD}●${CR} ${C_BAD}Renewal failed. The existing certificate is unchanged.${CR}\n\n"
                 return 1; }
    else
        local email_flag="--register-unsafely-without-email"
        [ -n "$LE_EMAIL" ] && email_flag="--email $LE_EMAIL"
        run_step "Issuing a certificate for ${DOMAIN_HOST}" \
            "systemctl stop apache2; certbot certonly --standalone --non-interactive --agree-tos $email_flag --preferred-challenges http -d '$DOMAIN_HOST'; rc=\$?; systemctl start apache2; exit \$rc" \
            || { show_step_error; systemctl start apache2 2>/dev/null
                 printf "  ${C_BAD}●${CR} ${C_BAD}Could not obtain a certificate.${CR}\n\n"; return 1; }
    fi

    run_step "Reloading Apache" "systemctl reload apache2 || systemctl restart apache2" || show_step_error

    local exp
    exp=$(openssl x509 -enddate -noout -in "${LE_LIVE}/fullchain.pem" 2>/dev/null | cut -d= -f2)
    printf "\n  ${C_OK}●${CR} ${C_DIM}Certificate valid until %s.${CR}\n\n" "${exp:-unknown}"
}

# ═══════════════════════════════════════════════════════════════════════════
#  backup
# ═══════════════════════════════════════════════════════════════════════════
backup_to_telegram() {
    require_install
    print_header "Backing up the database"

    local stamp tmpdir file
    stamp=$(date +%Y%m%d-%H%M%S)
    tmpdir=$(mktemp -d /tmp/mirza-backup.XXXXXX) || return 1
    chmod 700 "$tmpdir" 2>/dev/null
    file="$tmpdir/${DB_NAME}-${stamp}.sql"

    # MYSQL_PWD, not -p on the command line, which would expose the password
    # in `ps` to every user on the box. The dump is written inside a 0700 temp
    # directory so the user table is never briefly world-readable under /tmp.
    if ! MYSQL_PWD="$DB_PASS" mysqldump -u"$DB_USER" --single-transaction --quick \
            --default-character-set=utf8mb4 "$DB_NAME" > "$file" 2>/dev/null; then
        rm -rf "$tmpdir"
        printf "  ${C_BAD}●${CR} ${C_BAD}mysqldump failed.${CR}\n\n"
        return 1
    fi
    if [ ! -s "$file" ]; then
        rm -rf "$tmpdir"
        printf "  ${C_BAD}●${CR} ${C_BAD}The dump was empty; nothing was sent.${CR}\n\n"
        return 1
    fi

    gzip -f "$file" && file="${file}.gz"
    chmod 600 "$file" 2>/dev/null
    local size; size=$(du -h "$file" | cut -f1)

    local resp
    resp=$(curl -fsS --max-time 120 \
        -F "chat_id=${CHAT_ID}" \
        -F "document=@${file}" \
        -F "caption=Mirza backup ${stamp}" \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument" 2>&1)

    # Removed either way: it holds the full user table.
    rm -rf "$tmpdir"

    if echo "$resp" | grep -q '"ok":true'; then
        printf "  ${C_OK}●${CR} ${C_DIM}Backup (%s) sent to Telegram.${CR}\n\n" "$size"
    else
        printf "  ${C_BAD}●${CR} ${C_BAD}Telegram would not accept the file.${CR}\n"
        printf "  ${C_DIM}Files above 50 MB cannot be sent by a bot.${CR}\n\n"
        return 1
    fi
}


restore_database_dump() {
    set -o pipefail
    local dump="${1:-$MIGRATE_DUMP}" cat_cmd
    [ -f "$dump" ] || { echo "Dump file not found: $dump" >&2; return 1; }
    case "$dump" in
        *.gz) cat_cmd="gzip -dc --" ;;
        *)    cat_cmd="cat --" ;;
    esac
    # The dump path is operator-supplied. Keep it in an exported variable read
    # by this function instead of interpolating it into the bash -c string that
    # run_step executes; otherwise a filename containing a quote could execute
    # arbitrary shell as root during migration.
    MYSQL_PWD="$DB_PASS" $cat_cmd "$dump" | MYSQL_PWD="$DB_PASS" mysql -u"$DB_USER" "$DB_NAME"
}
export -f restore_database_dump

# ═══════════════════════════════════════════════════════════════════════════
#  migrate — restore an install from a backup onto THIS server
#
#  Replaces the original's Free->Pro conversion, which was an in-place
#  licence switch on the same machine and is intentionally not carried over.
# ═══════════════════════════════════════════════════════════════════════════
migrate_bot() {
    print_header "Migrating an install to this server"

    printf "  ${C_DIM}This restores a database dump produced by 'mirza backup'${CR}\n"
    printf "  ${C_DIM}(or by mysqldump) into a fresh install on this server.${CR}\n\n"

    resolve_install_dir
    if [ ! -f "$CONFIG_FILE" ]; then
        printf "  ${C_BAD}●${CR} ${C_BAD}Install Mirza on this server first, then run migrate.${CR}\n"
        printf "  ${C_DIM}The new server needs its own domain, certificate and database.${CR}\n\n"
        return 1
    fi
    load_existing_config

    local dump=""
    while true; do
        printf "  ${C_PROMPT}❯${CR} Path to the .sql or .sql.gz dump: "
        read -r dump
        [ -z "$dump" ] && { printf "    ${C_DIM}Cancelled.${CR}\n"; return 0; }
        [ -f "$dump" ] && break
        printf "    ${C_BAD}●${CR} ${C_BAD}No such file.${CR}\n"
    done

    _sec "This will overwrite the current database"
    _kv "Database" "${C_KEY}${DB_NAME}${CR}"
    _kv "Dump"     "${C_DIM}${dump}${CR}"
    echo ""
    printf "  ${C_PROMPT}❯${CR} Type ${C_KEY}yes${CR} to continue: "
    local c; read -r c
    [ "$c" = "yes" ] || { printf "    ${C_DIM}Cancelled.${CR}\n\n"; return 0; }

    STEP_TOTAL=4; STEP_NO=0; ETA_REMAINING=40

    local safety
    safety="$(make_safety_backup)"
    printf "  ${C_DIM}Current database saved to %s${CR}\n" "$safety"

    export MIGRATE_DUMP="$dump" DB_PASS DB_USER DB_NAME
    run_step "Restoring the database" \
        "restore_database_dump" \
        || { show_step_error
             printf "  ${C_BAD}●${CR} ${C_BAD}Restore failed. Your previous data is at %s${CR}\n\n" "$safety"
             return 1; }

    # The dump carries the OLD server's domain and token in its settings
    # tables, so the schema is re-checked and the webhook re-pointed at this
    # server. Without this the bot would keep answering on the old host.
    run_step "Applying schema migrations" \
        "cd '$BOT_DIR' && sudo -u www-data ${PHP_BIN} table.php" || show_step_error

    run_step "Re-applying cron locks and schedule" \
        "write_cron_lock_helper && patch_cron_locks && write_cron_file && systemctl restart cron 2>/dev/null; true" \
        || show_step_error

    run_step "Pointing the webhook at this server" "true"
    if set_webhook; then
        printf "\n  ${C_OK}●${CR} ${C_DIM}Migration complete; the bot now runs on %s.${CR}\n" "$DOMAIN"
        printf "  ${C_WARN}!${CR} ${C_DIM}Check the panel URLs inside the bot: they still point at the old server.${CR}\n\n"
    else
        printf "  ${C_WARN}!${CR} ${C_WARN}Data restored, but the webhook could not be set. Run 'mirza repair'.${CR}\n\n"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  uninstall
# ═══════════════════════════════════════════════════════════════════════════
cmd_uninstall() {
    resolve_install_dir
    load_existing_config

    clear; banner
    _sec "Uninstall"
    printf "    ${C_BAD}●${CR} ${C_TXT}This permanently removes:${CR}\n"
    printf "      ${C_WARN}-${CR} ${C_TXT}%s${CR} ${C_DIM}(all bot files)${CR}\n" "$BOT_DIR"
    printf "      ${C_WARN}-${CR} ${C_TXT}database %s and user %s${CR}\n" "${DB_NAME:-?}" "${DB_USER:-?}"
    printf "      ${C_WARN}-${CR} ${C_TXT}the Apache vhosts, cron jobs and log rotation${CR}\n"
    printf "      ${C_WARN}-${CR} ${C_TXT}the Telegram webhook${CR}\n"
    printf "      ${C_WARN}-${CR} ${C_TXT}%s and %s${CR}\n" "$MASTER_SCRIPT" "$BIN_LINK"
    echo ""
    printf "    ${C_DIM}Apache, MySQL, PHP and the SSL certificate are left installed.${CR}\n"
    printf "    ${C_DIM}Take a backup first if you might want this data back.${CR}\n\n"

    # A single "y" is too easy to hit by accident for an irreversible action.
    printf "  ${C_PROMPT}❯${CR} Type ${C_KEY}DELETE${CR} to confirm: "
    local c; read -r c
    if [ "$c" != "DELETE" ]; then
        printf "    ${C_DIM}Cancelled. Nothing was removed.${CR}\n\n"
        return 0
    fi

    # validate_bot_dir has already rejected /, /etc, /var/www/html and friends,
    # but this is the one place where being wrong is unrecoverable, so it is
    # checked again immediately before the rm.
    if ! validate_bot_dir "$BOT_DIR"; then
        printf "  ${C_BAD}●${CR} ${C_BAD}Refusing to delete %s - it is not a safe install directory.${CR}\n\n" "$BOT_DIR"
        return 1
    fi

    [ -n "$BOT_TOKEN" ] && curl -fsS --max-time 10 \
        "https://api.telegram.org/bot${BOT_TOKEN}/deleteWebhook" >/dev/null 2>&1
    printf "  ${C_OK}●${CR} ${C_DIM}Webhook removed.${CR}\n"

    rm -f "$CRON_FILE" 2>/dev/null
    # The bot's own activecron() also writes curl lines into root's crontab.
    if crontab -l 2>/dev/null | grep -q 'cronbot'; then
        crontab -l 2>/dev/null | grep -v 'cronbot' | crontab - 2>/dev/null
    fi
    systemctl restart cron 2>/dev/null
    printf "  ${C_OK}●${CR} ${C_DIM}Cron jobs removed.${CR}\n"

    a2dissite "$(basename "$VHOST_HTTP")" "$(basename "$VHOST_HTTPS")" >/dev/null 2>&1
    rm -f "$VHOST_HTTP" "$VHOST_HTTPS" 2>/dev/null
    a2ensite 000-default.conf >/dev/null 2>&1
    systemctl reload apache2 2>/dev/null
    printf "  ${C_OK}●${CR} ${C_DIM}Apache virtual hosts removed.${CR}\n"

    local rp; rp="$(db_root_pass)"
    if [ -n "$rp" ] && [ -n "$DB_NAME" ]; then
        MYSQL_PWD="$rp" mysql -uroot <<SQL >/dev/null 2>&1
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
DROP USER IF EXISTS '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
        printf "  ${C_OK}●${CR} ${C_DIM}Database and user dropped.${CR}\n"
    else
        printf "  ${C_WARN}!${CR} ${C_WARN}Could not read the MySQL root password; %s was left in place.${CR}\n" "${DB_NAME:-the database}"
    fi

    rm -rf "$BOT_DIR" 2>/dev/null
    rm -f "$LOGROTATE_FILE" "$PHP_INI_APACHE" "$PHP_INI_CLI" "$MYSQL_CNF" 2>/dev/null
    rm -f "$PMA_RESTRICT_CONF" 2>/dev/null
    rm -f "$MASTER_SCRIPT" "$BIN_LINK" 2>/dev/null
    state_clear
    printf "  ${C_OK}●${CR} ${C_DIM}Files and settings removed.${CR}\n"

    _sec "Uninstalled"
    printf "    ${C_DIM}The SSL certificate for %s was kept, so reinstalling is quick.${CR}\n" "$DOMAIN_HOST"
    printf "    ${C_DIM}Remove it with: certbot delete --cert-name %s${CR}\n\n" "$DOMAIN_HOST"
}

show_menu() {
    clear
    banner
    _sec "Menu"
    _mi "1" "Install"
    _mi "2" "Update"
    _mi "3" "Diagnose  ${C_DIM}(health report)${CR}"
    _mi "4" "Repair"
    _mi "5" "Renew SSL certificate"
    _mi "6" "Change domain"
    _mi "7" "Change bot token"
    _mi "8" "Backup database to Telegram"
    _mi "9" "Migrate an install to this server"
    _mi "10" "Uninstall"
    _mi "0" "Exit"
    echo ""
    printf "  ${C_PROMPT}❯${CR} Select ${C_DIM}[0-10]${CR}: "
    local s; read -r s
    case "$s" in
        1)  install_bot ;;
        2)  update_bot ;;
        3)  cmd_diagnose ;;
        4)  cmd_repair ;;
        5)  renew_ssl ;;
        6)  cmd_change_domain ;;
        7)  cmd_change_token ;;
        8)  backup_to_telegram ;;
        9)  migrate_bot ;;
        10) cmd_uninstall ;;
        0)  exit 0 ;;
        *)  printf "  ${C_BAD}Invalid selection.${CR}\n"; sleep 1; show_menu ;;
    esac
}

main() {
    process_arguments "$@"

    # Makes `mirza` exist before any command runs, so install_pause and the
    # summary can honestly tell the operator to use it. Skipped for uninstall,
    # which removes both the script and the link at the end.
    [ "$COMMAND" = "uninstall" ] || install_self
    acquire_install_lock

    case "$COMMAND" in
        install)        install_bot ;;
        update)         update_bot ;;
        diagnose)       cmd_diagnose ;;
        repair)         cmd_repair ;;
        change-domain)  cmd_change_domain ;;
        change-token)   cmd_change_token ;;
        renew-ssl)      renew_ssl ;;
        backup)         backup_to_telegram ;;
        migrate)        migrate_bot ;;
        uninstall)      cmd_uninstall ;;
        menu|*)         show_menu ;;
    esac
}

main "$@"
