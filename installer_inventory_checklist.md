# Installer Inventory — what `mirzabot/install.sh` does today

Reference: the original `install.sh`, 2622 lines, preserved as **`install.old.sh`**.
This document is the **regression contract** for the rewrite described in
`implementation_plan.md`. Every unchecked box below is a behaviour the new installer
must reproduce (or consciously, explicitly drop).

How to use: when the new script is written, walk this file top to bottom and tick each
box only after verifying the behaviour exists in the new script. Anything left unticked
at the end is a regression.

## Status

The rewrite is now in place as `mirzabot/install.sh`; the original is kept beside it as
`install.old.sh` for diffing and rollback. Delete it once a real server install has been
verified.

Test suites — run all of them with `bash run_tests.sh`:

| Suite | Asserts | Count |
|---|---|---|
| `test_lint.sh` | static analysis (stands in for shellcheck, which is not installed here) | 60 |
| `test_resolve.sh` | `_resolve` across flag / prompt / resume / `--yes` | 59 |
| `test_cron.sh` | cron file generation and the `flock` wrapper | 28 |
| `test_lock.sh` | concurrent-run locking | 9 |
| `test_lifecycle.sh` | vhost, config, update, `carry_runtime_data`, uninstall | 95 |
| **Total** | | **251** |

> These assert generated **text and logic**, not live system behaviour. Apache never
> parses the vhost, MySQL never runs the grants, certbot is never called. A real
> Ubuntu 22.04/24.04 install is still required before this ships — that is the one
> outstanding item.


---

## 0. Global constants and paths

- [ ] `BOT_DIR_DEFAULT` / `BOT_DIR` = `/var/www/html/mirzaprobotconfig` (the bot's document root)
- [ ] `CONFIG_FILE_DEFAULT` = `$BOT_DIR_DEFAULT/config.php`
- [ ] `GIT_REPO` = `mahdiMGF2/mirzabot`
- [ ] `STATE_DIR` = `/root/confmirza`
- [ ] `STATE_FILE` = `$STATE_DIR/.mirza_install_state`
- [ ] `LATEST_CACHE` = `/tmp/.mirza_latest_version` (1 hour TTL)
- [ ] `IP_CACHE` — public IP cache (1 hour TTL)
- [x] Master script path `/root/install.sh`, symlinked to `/usr/local/bin/mirza`
      — `install_self` + `_link_mirza`, called from `main()` before any command.
      Installed 0700 (it takes a bot token and DB password as arguments).
- [ ] MySQL root credentials file `/root/confmirza/dbrootmirza.txt` (contains `$pass` and `$path`)
- [ ] Fixed database name `mirzaprobot`

> **Note for the rewrite:** the state dir, the root-credentials file and the master script
> path all sit under a hard-coded home directory. Confirm whether this should become
> `/root` or `/etc/mirzabot` in the new script rather than a specific user's home.

---

## 1. Terminal UI / step runner

- [ ] `_fmt_secs` — seconds → human duration
- [ ] `_bar` — percentage progress bar of N chars
- [ ] `_step_eta` — per-step expected duration lookup
- [ ] `plan_eta` — counts pending steps + total expected time, **skips already-done phases**
- [ ] `print_header` — section header
- [ ] `run_step "<label>" "<command>"` — the core runner: prints label, runs command,
      captures output to the log file, shows a spinner/bar + ETA, returns command's exit code
- [ ] `show_step_error` — dumps the captured error detail block on failure
- [ ] `_repeat`, `_rule`, `_drule`, `banner`, `_mi` — box drawing, banner, menu item rows
- [ ] `_dot` — coloured status dot
- [ ] `_sec`, `_kv` — dashboard section header and key/value row
- [ ] Colour variables: `C_OK`, `C_BAD`, `C_WARN`, `C_DIM`, `C_KEY`, `C_TXT`, `C_TITLE`, `C_BORDER`, `C_PROMPT`, `CR`
- [ ] `UI_W` — fixed UI width used by the rules
- [ ] Log file per run; path echoed as `Log file: $LOG_FILE`

---

## 2. Resume / state machine

- [ ] `state_init` — `mkdir -p $STATE_DIR`
- [ ] `state_set KEY VALUE` — persist an answer (idempotent replace, not append)
- [ ] `state_get KEY` — echo stored value, empty when missing
- [ ] `phase_done NAME` — true when `PHASE:NAME` line exists
- [ ] `mark_phase NAME` — record phase completion
- [ ] `has_resumable_state` — true when an unfinished install is on disk
- [ ] `state_clear` — delete the state file
- [ ] `install_pause "<where>"` — on step failure: show where it broke, offer retry/abort,
      leaving state intact so a re-run resumes
- [ ] Resume must **not** re-prompt for domain / token / chat id / bot name / db creds
- [ ] Phases in the current script, in order:
      `DEPS` → `FILES` → `DBROOT` → `DB` → `SSL` → `VHOST` → `CONFIG` → `WEBHOOK` → `COMPLETE`
- [ ] State keys persisted: `DOMAIN`, `BOT_TOKEN`, `CHAT_ID`, `BOTNAME`, `DBUSER`, `DBPASS`,
      `SECRET`, `PHP_VER`, `SRC_ZIP_URL`, `SRC_LABEL`

---

## 3. OS detection, apt, DNS, network

- [ ] `detect_os` — populates `OS_ID`, `OS_VERSION_ID`, `OS_CODENAME`, `OS_PRETTY`; memoised
- [ ] `os_major` — major version number
- [ ] `apt_recover` — clears locks left by a **dead** process, then `dpkg --configure -a`
- [ ] apt calls use `-o DPkg::Lock::Timeout=180`
- [ ] Rewrites apt sources when a mirror is needed — both formats:
      deb822 (`Types:/URIs:/Suites:`) and classic one-line `deb http://...`
- [ ] `php_ppa_has_series` — probes `ppa.launchpadcontent.net/ondrej/php/ubuntu/dists/$1/Release`, 3 retries
- [ ] `php_repo_disable` — disables the PHP PPA files
- [ ] `setup_php_repo` — adds `ondrej/php` only when needed
- [ ] `_apt_has_candidate` — true when apt has an installable candidate
- [ ] `resolve_php_ver` — picks the PHP series. **Corrected after reconnaissance:** the shipped
      file sets `PHP_VER_CANDIDATES="8.2 8.3 8.4 8.5"` (`install.sh:427`) with a hard-coded
      `echo "8.2"` fallback — it does *not* accept 8.1/8.0/7.4, so there is no floor bug.
      The real issue is 8.5 being offered untested. New list: `8.3 8.4 8.2`.
- [ ] `_pkg_installed` / `_pkg_installed_glob` — dpkg status checks
- [ ] `dns_works` — `getent hosts github.com`
- [ ] `ensure_dns` — repairs resolv.conf when DNS is broken
- [ ] `net_works` — reachability of `github.com` or `api.telegram.org`
- [ ] `ensure_connectivity` — `ensure_dns` + `net_works`
- [ ] `precheck_fresh_server` — refuses to install over an existing web stack;
      runs **only** on a brand-new install, never on resume
- [ ] `repair_mysql` — repairs a broken/half-configured MySQL, then the web stack install is retried

---

## 4. Input validation

- [ ] `validate_domain` — FQDN regex, rejects scheme and trailing slash
- [ ] `domain_points_here` — resolves the domain and compares to this server's public IP;
      returns 0 = points here, 1 = points elsewhere, 2 = could not resolve;
      on 1 or 2 prompts "Continue anyway? [y/N]" and aborts to the menu on No
- [ ] `validate_token` — regex `^[0-9]{8,10}:[a-zA-Z0-9_-]{35}$` **plus** a live `getMe` call;
      returns 0 = valid+live, 1 = bad format, 2 = format ok but rejected/unreachable;
      on 2 offers re-entry or "press Enter to keep it anyway"
- [ ] `valid_db_ident` — `^[A-Za-z0-9_]{1,32}$`, falls back to a generated name on failure
- [ ] `valid_db_pass` — `^[A-Za-z0-9_]{6,64}$`, falls back to a generated password on failure
- [ ] Chat id regex `^-?[0-9]+$`, re-prompts until valid
- [ ] Bot username: strips a leading `@` and all whitespace, rejects empty
- [ ] `preflight` — whole-server pre-flight before installing

---

## 5. Prompts and their defaults

- [ ] Domain — from `--domain`, else resumed from state, else interactive; validated + DNS-checked
- [ ] Bot token — from `--token`, else resumed, else interactive; format + `getMe` verified;
      displayed truncated (`${TOKEN:0:10}...`) when resumed
- [ ] Admin chat id — from `--admin`, else resumed, else interactive
- [ ] Bot username — from `--name`, else resumed, else interactive
- [ ] DB username — from `--db-user`, else interactive; blank accepts a generated 8-char name
- [ ] DB password — from `--db-pass`, else interactive; blank accepts a generated 8-char password
- [ ] Generated values: `randomdbpass`, `randomdbdb` via `openssl rand -base64 10`
- [ ] Secret token — `openssl rand -base64 10 | tr -dc 'a-zA-Z0-9' | cut -c1-8`, stored as `SECRET`

---

## 6. Source selection and versions

- [ ] `choose_source` — menu: Beta (`main` branch zip) vs a specific release tag;
      returns 0 = chosen, 1 = error, 2 = back to menu
- [ ] Beta URL: `https://github.com/$GIT_REPO/archive/refs/heads/main.zip`
- [ ] Tag URL base: `https://github.com/$GIT_REPO/archive/refs/tags/<tag>.zip`
- [ ] `--version <tag>` bypasses the menu
- [ ] `get_latest_version` — newest tag from `api.github.com/repos/$GIT_REPO/tags`, cached 1 h;
      falls back to Beta when detection fails
- [ ] `list_tags_desc` — all tags newest first
- [x] `get_installed_version` — reads `$BOT_DIR/version`, **not** `$BOT_DIR_DEFAULT`.
      The original hard-coded the default, so any `--dir` install reported
      "not installed". Returns `unknown` when the file is absent.
- [ ] `get_server_ip` — `ifconfig.me` → `api.ipify.org` → `hostname -I`, cached 1 h

---

## 7. PHASE: DEPS — packages

- [ ] `apt update --allow-releaseinfo-change` + `apt upgrade -y`
- [ ] Base tools: `software-properties-common ca-certificates git unzip curl wget jq gnupg`
- [ ] `setup_php_repo` then `resolve_php_ver` → `PHP_VER`, persisted to state
- [ ] PHP packages: `php${V}` `php${V}-cli` `php${V}-fpm` `php${V}-mysql` `php${V}-mbstring`
      `php${V}-zip` `php${V}-gd` `php${V}-curl` `php${V}-intl` `php${V}-xml` `php${V}-bcmath`
      `php${V}-soap` `php${V}-ssh2`
- [ ] `libssh2-1 libssh2-1-dev`
- [ ] Web stack: `apache2`, `libapache2-mod-php${V}`, `mysql-server`
- [ ] On web-stack failure → `repair_mysql` → retry the install once
- [ ] phpMyAdmin installed with debconf preseed (no interactive dialog), then symlinked/included
- [ ] `a2dismod mpm_event mpm_worker` + `a2enmod mpm_prefork php${V}` (required by mod_php)
- [x] `a2enmod rewrite headers ssl setenvif` — `api/.htaccess` uses `RewriteEngine` for its
      extensionless routes and `SetEnvIf` to forward `Authorization`. Without `rewrite` every
      `api/` route 404s; without `setenvif` the auth header is dropped before PHP sees it.
      `setenvif` was not enabled by the original installer. `AllowOverride All` in the vhost
      is what lets that `.htaccess` apply at all.
- [ ] Other PHP series `a2dismod`'d so only the chosen one is active
- [ ] `update-alternatives --set php /usr/bin/php${V}` pins the CLI
- [ ] `systemctl enable/start apache2` and `mysql`
- [ ] `mark_phase DEPS`

**Missing today (add in rewrite):** `zip` binary, `cron`, `logrotate`,
`a2enmod rewrite ssl headers setenvif expires`, and any verification that the required
PHP extensions actually loaded.

---

## 8. PHASE: FILES — download and place the bot

- [ ] `choose_source` (skipped when `--version` was given)
- [ ] Download the zip to a temp dir with `wget -q -O`
- [ ] `unzip -o -q` and locate the single extracted top-level directory
- [ ] Abort cleanly if the extracted directory is missing (before touching the live install)
- [ ] `ensure_composer` — bootstrap Composer to `/usr/local/bin/composer` with the
      **signature verified** against `composer.github.io/installer.sig`
- [ ] `install_php_deps <dir>` — `composer install --no-dev --optimize-autoloader --prefer-dist`
      run as `www-data` where possible, with `COMPOSER_HOME` set; asserts `vendor/autoload.php` exists
- [ ] Move the extracted tree into `$BOT_DIR`
- [ ] Copy `install.sh` to `/root/install.sh` only after `bash -n` syntax check passes
- [ ] `chown -R www-data:www-data $BOT_DIR`, `chmod -R 755 $BOT_DIR`
- [ ] `mark_phase FILES`

---

## 9. PHASES: DBROOT + DB

- [ ] `setup_mysql_root` — sets/derives the MySQL root password, writes
      `/root/confmirza/dbrootmirza.txt` containing `$pass` and `$path`
- [ ] Handles both `auth_socket` and password-auth root
- [ ] `mark_phase DBROOT`
- [ ] `CREATE DATABASE IF NOT EXISTS mirzaprobot` with utf8mb4
- [ ] `CREATE USER IF NOT EXISTS` + `GRANT ALL` for the app user
- [ ] Grants issued for **both** `'user'@'%'` and `'user'@'localhost'`
- [ ] `FLUSH PRIVILEGES`
- [ ] `mark_phase DB`

---

## 10. PHASES: SSL + VHOST

- [ ] `ufw allow 80` / `ufw allow 443` (**`ufw allow OpenSSH` must come first — see Issues**)
- [ ] `systemctl stop apache2` before issuing (certbot standalone binds :80)
- [ ] `certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos -m <email>`
- [ ] Skip issuance when `/etc/letsencrypt/live/$DOMAIN/fullchain.pem` already exists
- [ ] `mark_phase SSL`
- [ ] Write `/etc/apache2/sites-available/${DOMAIN}.conf` (port 80) —
      `DocumentRoot $BOT_DIR`, `Options Indexes FollowSymLinks`, `AllowOverride All`,
      `Require all granted`, `Include /etc/apache2/conf-available/phpmyadmin.conf`,
      per-domain `ErrorLog` + `CustomLog`
- [ ] Write `/etc/apache2/sites-available/${DOMAIN}-ssl.conf` (port 443) — same plus
      `SSLEngine on`, `SSLCertificateFile fullchain.pem`, `SSLCertificateKeyFile privkey.pem`
- [ ] `a2ensite` both; `a2dissite 000-default default-ssl`; remove the default site files
- [ ] `apache2ctl configtest` then restart
- [ ] `mark_phase VHOST`

---

## 11. PHASE: CONFIG — generate `config.php`

- [ ] Written with a heredoc to `$BOT_DIR/config.php`, **not** by substituting the shipped template
- [ ] Emitted variables, in order:
      `$request_exec_timeout`, `$dbhost`, `$dbname`, `$usernamedb`, `$passworddb`,
      `$connect = mysqli_connect(...)` with a `die()` on failure,
      `mysqli_set_charset($connect, "utf8mb4")`,
      `$options` (PDO ERRMODE_EXCEPTION / FETCH_ASSOC / EMULATE_PREPARES=false),
      `$dsn`, `$pdo` in a try/catch that `error_log`s on failure,
      `$APIKEY`, `$adminnumber`, `$domainhosts`, `$usernamebot`
- [ ] `chown www-data:www-data config.php`
- [ ] `mark_phase CONFIG`
- [ ] On resume, re-reads `SECRET` from state and skips regeneration

> **Discrepancy — RESOLVED.** `grep -rn '\$connect\b' mirzabot/` returns only `$ConnectToPanel`
> matches in `panels.php`; nothing anywhere reads `$connect`. The installer is therefore opening
> a second, entirely unused MySQL connection on every request. **Decision: drop the
> `mysqli_connect` block from the generated `config.php`.** The shipped template is authoritative.

---

## 12. PHASE: WEBHOOK — activation

- [ ] `setWebhook` with `url=https://$DOMAIN/index.php` **and** `secret_token=$secrettoken`
- [ ] `sendMessage` to the admin: "✅ The Mirza bot is installed! for start the bot send /start command."
- [ ] `systemctl start apache2`
- [ ] `cd $BOT_DIR && php${PHP_VER} table.php` — schema bootstrap
- [ ] `mark_phase WEBHOOK` then `mark_phase COMPLETE`
- [x] Final screen: Access (bot URL, phpMyAdmin URL), Database (name/user/password + save-these warning), Manage (`mirza`)
      — now also prints the installed version, and warns instead of claiming the
      `mirza` command exists if the symlink could not be created.
- [x] `chmod +x /root/install.sh` and `ln -sf` to `/usr/local/bin/mirza`
- [x] ~~`self_update_script`~~ — **deliberately not ported.** The original ran it at
      the top of every invocation: it downloaded `main`'s install.sh, md5-compared,
      overwrote `/root/install.sh` and `exec`'d into it. So `mirza diagnose` on a
      production box silently replaced the installer with whatever had just been
      pushed to main and restarted into it. It also wrote to the very file bash was
      reading, which can feed the interpreter truncated source. `install_self` copies
      locally and never re-execs; upgrading is what re-running the one-liner does.

> **Ordering bug to fix:** `table.php` runs *after* `setWebhook`, so Telegram can deliver an
> update to a bot whose tables do not exist yet. In the rewrite, `TABLES` must precede `WEBHOOK`.
>
> **Unverified result:** neither `setWebhook` nor `table.php` has its outcome checked.
> Add `getWebhookInfo` verification and a `SHOW TABLES LIKE 'PaySetting'` post-condition.

---

## 13. `update_bot` — update flow

- [ ] Aborts with a message when `$BOT_DIR` does not exist
- [x] Shows the currently installed version — before ("Installed:") and after, where
      the completion line re-reads `version` from the new tree rather than echoing the
      requested label, so it reports what actually landed.
- [ ] `ensure_connectivity` before starting
- [ ] `choose_source` (Back returns to the menu)
- [ ] `apt update && apt upgrade -y`
- [ ] Download + extract to `/tmp/mirzaprobot_update`
- [ ] Abort before touching the live install if the extracted dir is missing
- [ ] **`install_php_deps` runs inside the extracted copy first** — a composer/network
      failure aborts the update with the live install untouched
- [ ] Back up `config.php` to `/root/mirzapro_config_backup.php`
- [ ] `rm -rf $BOT_DIR`, recreate, `mv` the new files in
- [ ] Restore `config.php`
- [ ] Refresh `/root/install.sh` only when `bash -n` passes
- [ ] `chown -R www-data:www-data` + `chmod -R 755`
- [ ] Re-read the domain from `config.php` (`$domainhosts`, first path segment)
- [ ] Regenerate both vhosts and `a2ensite` them when not already active
- [ ] Run `table.php` for migrations

> ~~**Data-loss risk to fix:**~~ **FIXED** by `carry_runtime_data`, which runs after the
> new tree is unpacked and before `rm -rf $old`. It preserves `config.php`,
> every `vpnbot/<agent>/` directory (each holds that reseller's own token and live
> `data/`, and is not in the release archive — losing one is unrecoverable),
> `api/hash.txt` and `custom.jpg`. `vpnbot/Default`, `vpnbot/update` and
> `vpnbot/index.php` are intentionally taken from the NEW archive, since they are the
> shipped template. A failure is reported but non-fatal, and `$old` is left on disk so
> the operator can recover by hand. Covered by 14 assertions in `test_lifecycle.sh`.
>
> Re-checked against the tree: `sub/` holds only `.htaccess` and `index.php` and is
> served from the database, and `cronbot/` has no `*.json` — the original note was
> wrong on both. `storage/` (the 120 s webhook dedupe cache) is carried anyway as it
> costs nothing.
>
> Also: the update never re-runs cron registration or the PHP ini, and two `echo` lines
> contain a typo — `./033[0m` instead of `\033[0m`.

---

## 14. Other lifecycle commands

- [ ] Migration flow — move an install to a new server/domain
- [ ] Telegram DB backup — `mysqldump` + send the file to the admin chat
- [x] ~~`self_update_script`~~ — intentionally dropped; see §12 for the reasoning.
- [x] `_link_mirza` — maintain the `/usr/local/bin/mirza` symlink.
      `cmd_uninstall` now removes both it and `$MASTER_SCRIPT`, so an uninstall no
      longer leaves a `mirza` command pointing at a deleted install.
- [ ] Dashboard sections: `version_section`, `bot_section`, `webhook_section`,
      `system_section`, `resources_section`
- [ ] `show_menu` — the interactive main menu
- [ ] `print_usage` — help text
- [ ] `process_arguments` — flags: `--domain`, `--token`, `--admin`, `--name`,
      `--db-user`, `--db-pass`, `--version`

**Missing today (add in rewrite):** `uninstall`, `repair`, `diagnose`,
`change-domain`, `change-token`, and a `--yes` non-interactive mode.

---

## 15. Every outbound network call

The rewrite must not add hosts beyond this list.

- [ ] `api.telegram.org` — `getMe`, `setWebhook`, `sendMessage`, (new) `getWebhookInfo`
- [ ] `github.com` — source zips (`archive/refs/heads/main.zip`, `archive/refs/tags/*.zip`)
- [ ] `api.github.com` — tag list
- [ ] `raw.githubusercontent.com` — script self-update
- [ ] `getcomposer.org` — Composer installer
- [ ] `composer.github.io` — Composer installer signature
- [ ] `ppa.launchpadcontent.net` — ondrej/php PPA probe and packages
- [ ] Distro apt mirrors
- [ ] Let's Encrypt (via certbot)
- [ ] `ifconfig.me`, `api.ipify.org` — public IP display only; **must** fall back to
      `hostname -I` and never be required
- [ ] No analytics, no telemetry, no install-tracking callback anywhere

---

## 16. Issues found in the current script — fix during the rewrite

- [ ] **`ufw` before SSH allow** — 80/443 are allowed but `OpenSSH` is not explicitly
      allowed first. If ufw ends up enabled, the operator can be locked out of the server.
- [ ] **`Options Indexes`** in both vhosts — the bot directory is browsable over HTTP.
- [ ] **`table.php` after `setWebhook`** — see section 12.
- [x] ~~**PHP floor too low**~~ — withdrawn. Reconnaissance shows the candidate list is
      `8.2 8.3 8.4 8.5` with an `8.2` fallback, which already satisfies `composer.json`.
- [ ] **PHP 8.5 in the candidate list** — untested against `endroid/qr-code` +
      `phpoffice/phpspreadsheet`; drop it. New list `8.3 8.4 8.2`, preferring the best-tested series.
- [x] ~~**`secret_token` set but never validated**~~ — **fixed.** `setWebhook` already sent
      `secret_token=$secrettoken`, but nothing on the PHP side compared it, so the endpoint
      accepted hand-written POSTs from anyone who knew the domain — and since `botapi.php`
      trusts `$update['message']['from']['id']`, a forged update could impersonate any user
      id, including an admin's. The installer now persists the value as `$webhook_secret` in
      `config.php` (both the fresh-install writer and `carry_runtime_data` on update), and
      `index.php` checks `HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN` against it with `hash_equals`
      before `botapi.php` loads, returning 403 on a mismatch. The check runs ahead of any
      database work so a forged request is dropped before it can touch state. An empty
      secret fails open, so installs whose `config.php` predates the variable keep working
      until `mirza repair` regenerates it.

- [ ] **No cron registration** — all 17 `cronbot/` jobs never run. PHP-side `activecron()`
      (`function.php:1476-1516`) and the lottery edit (`admin.php:1904-1913`) write `www-data`'s
      crontab, which nothing reads. Fix: root-owned `/etc/cron.d/mirzabot`.
- [ ] **`cronbot/` is publicly reachable with no auth** — a superglobal scan of all 17 jobs
      returned zero hits, so none of them authenticates anything. Anyone on the internet can
      trigger `croncard.php` (auto-approves card payments), `backupbot.php` (dumps the database),
      `activeconfig.php`/`disableconfig.php` (mass enable/disable), `configtest.php` (deletes
      users). `table.php` is equally unguarded. Fix: run cron over PHP CLI and `Require all denied`
      both paths at the vhost.
- [ ] **`zip` binary missing** — `cronbot/backupbot.php` shells out to it; backups fail silently.
- [x] ~~**`api/hash.txt` is served over HTTP**~~ — **found during the rewrite, now fixed.**
      `admin.php:6120` writes a generated API token to `api/hash.txt`, and `api/utils.php:59`
      (`apiTokens()` → `requireApiToken()`) accepts it as full admin authentication for
      `users.php`, `panels.php`, `invoice.php` and the rest of `api/`. It is a `.txt`, so
      Apache serves it as a static file: `GET /api/hash.txt` returned working admin
      credentials to anyone who knew the domain. The `.htaccess` shipped in `api/` denies
      only `utils.php`, so it did not cover this. The vhost now denies `hash.txt`, dotfiles
      and `*.sql|sql.gz|zip|log|bak|swp|dist|ini`. Nothing breaks: the token is only ever
      read from disk, never over HTTP.
- [x] ~~**Update destroys runtime data**~~ — fixed by `carry_runtime_data`; see section 13.
- [ ] **`chmod -R 755` on files** — grants execute on every PHP file; 644 for files and
      755 for directories is correct.
- [ ] **Typo** `./033[0m` in two update-flow `echo`s.


