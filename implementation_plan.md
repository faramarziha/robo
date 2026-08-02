# Implementation Plan

[Overview]
Fix 18 verified defects in the MirzaBot PHP Telegram VPN-sales bot, prioritising financial integrity (replayable refunds, unbound payment verification, absent transactions), then SQL injection, then access control on unauthenticated endpoints.

This codebase is a ~45,000-line procedural PHP application that sells VPN subscriptions through Telegram. It integrates 11 VPN panel types (Marzban, Marzneshin, Hiddify, X-UI, S-UI, WGDashboard, MikroTik, IBSng, Alireza, Rebecca) and 7 payment gateways (Zarinpal, Aqayepardakht, TetraPay, NowPayments, Plisio, Tronado, IranPay). Money moves through three surfaces: the bot itself (`index.php`, `admin.php`), the REST API (`api/`), and the gateway callbacks (`payment/`) plus their cron reconcilers (`cronbot/`).

Every finding below was confirmed by reading the actual code and is quoted with a real line number. An earlier exploratory pass produced six claims that direct inspection **disproved**; those are recorded in [Testing] as regression guards so nobody "fixes" working code. Specifically: `api/verify.php` implements Telegram initData validation correctly with HMAC-SHA256 plus `hash_equals`; `api/utils.php::validateToken` uses `hash_equals`; `panel/inc/config.php` has working CSRF and `require_auth`; `function.php::select` is guarded by `assertSqlIdentifier`; `api/miniapp.php` overwrites client-supplied user ids from the validated token; and `api/category.php`'s `{$setClause}` is assembled from hardcoded keys. The `lang/` directory is clean — a PHP-tokenizer parse found zero duplicate keys and exactly 2501 keys in each of the four language files with zero structural divergence. `backup_payment/` is dead code: zero references repo-wide, outside the git tree, and unreachable because `install.sh` deploys from a GitHub ZIP rather than the local directory.

The through-line defect is architectural: the project contains **zero** `beginTransaction` calls while performing read-then-write balance arithmetic in 46 distinct places. Every credit follows the pattern `$b = select(...)['Balance']; update("user","Balance",$b+$x,...)`, which loses concurrent writes. Cron jobs that settle payments have neither authentication nor locking, so two overlapping runs can double-credit. Fixes are therefore sequenced so shared primitives (`withTransaction`, `creditBalance`, `acquireCronLock`, `requireCronContext`) land before the call sites that depend on them.

[Types]
No new classes or formal types are introduced; the work adds a small set of shared helper functions and one database uniqueness constraint.

Database schema change — idempotency guard for wallet credits:

- Table: `Payment_report`
- Add column: `settled_at DATETIME NULL DEFAULT NULL`
- Add index: `UNIQUE KEY uniq_order_settled (id_order, settled_at)` is **not** viable because NULLs repeat in MySQL; instead add a non-null status guard.
- Concrete approach: rely on a conditional UPDATE returning `rowCount()` as the mutex:
  `UPDATE Payment_report SET payment_Status='paid', settled_at=NOW() WHERE id_order=:id AND payment_Status<>'paid'`
  A return of `0` means another process already settled the order, and the caller must return without crediting.

Helper contracts (plain PHP functions, no classes):

- `withTransaction(callable $fn): mixed` — begins a PDO transaction, invokes `$fn`, commits; on any `Throwable` rolls back and rethrows. Must detect an already-active transaction via `$pdo->inTransaction()` and, in that case, run `$fn` inline without nesting (MySQL has no true nested transactions).
- `creditBalance(int|string $userId, int $amount): int` — performs `UPDATE user SET Balance = Balance + :amt WHERE id = :id` and returns the new balance. Never reads-then-writes. `$amount` may be negative for debits; callers needing a non-negative guarantee must check first.
- `debitBalanceIfSufficient(int|string $userId, int $amount): bool` — `UPDATE user SET Balance = Balance - :amt WHERE id = :id AND Balance >= :amt`; returns `rowCount() === 1`. This makes "insufficient funds" race-free.
- `acquireCronLock(string $name): resource|false` — opens `sys_get_temp_dir()/mirzabot_<name>.lock` and attempts `flock($fh, LOCK_EX|LOCK_NB)`; returns the handle on success, `false` if another run holds it. The handle must be held in a variable for the process lifetime, because releasing it to the garbage collector drops the lock.
- `requireCronContext(): void` — exits unless `PHP_SAPI === 'cli'` or a valid `X-Cron-Token` header matching a new config secret is present.

[Files]
Two new files are created, twenty-three existing files are modified, and nothing is deleted.

New files:

- `mirzabot/inc/guard.php` — houses `requireCronContext()`, `acquireCronLock()`, and `releaseCronLock()`. Placed in a new `inc/` directory to avoid further bloating the 2090-line `function.php`.
- `mirzabot/cronbot/.htaccess` — currently absent from the shipped tree; add `Require all denied` as defence-in-depth behind the PHP-level guard.

Modified files, grouped by phase:

Phase 1 (money):
- `mirzabot/function.php` — append `withTransaction`, `creditBalance`, `debitBalanceIfSufficient`, `settleOrderOnce`; fix the `catch` block at 494-496; fix the Aqayepardakht callback URL.
- `mirzabot/api/invoice.php` — `inv_remove_service` idempotency and refund bounds.
- `mirzabot/payment/tetra.php` — bind verification to the stored invoice; null-check.
- `mirzabot/payment/zarinpal.php`, `aqayepardakht.php`, `nowpayment.php`, `tronado.php`, `iranpay1.php`, `plisio.php` — same idempotency review.
- `mirzabot/api/miniapp.php` — affiliate commission credits at 1001-1008 and 1025-1032.

Phase 2 (SQL injection):
- `mirzabot/index.php` — the query string built near 3538.
- `mirzabot/keyboard.php` — `KeyboardProduct` signature and body.
- `mirzabot/admin.php` — 3078-3091 and 1226.
- `mirzabot/vpnbot/update/admin.php` and `mirzabot/vpnbot/Default/admin.php` — 421-425 and the `$sql1` string.

Phase 3 (access control):
- All 18 files in `mirzabot/cronbot/` — add the guard include and a lock where they mutate money.
- `mirzabot/table.php` — add the guard.
- `mirzabot/cronbot/backupbot.php` — move the DB password out of the command line.
- `mirzabot/panel/login.php` — delete the plaintext fallback.
- `mirzabot/.htaccess` — deny direct access to installer and schema scripts.

Phase 4 (logic):
- `mirzabot/panels.php` — 2473 and 2449.
- `mirzabot/request.php`, `mirzabot/alireza_single.php`, `mirzabot/ibsng.php` — restore TLS verification.
- `mirzabot/lang/en.php`, `ru.php`, `zh.php` — placeholder-count alignment.

[Functions]
Four helper functions are added to `function.php`, two to a new `inc/guard.php`, and roughly a dozen existing functions are corrected in place.

New functions:

- `withTransaction(callable $fn)` in `mirzabot/function.php` — transaction wrapper described in [Types].
- `creditBalance($userId, $amount)` in `mirzabot/function.php` — atomic relative credit.
- `debitBalanceIfSufficient($userId, $amount)` in `mirzabot/function.php` — atomic guarded debit.
- `settleOrderOnce($orderId): bool` in `mirzabot/function.php` — the conditional-UPDATE mutex from [Types]; returns `true` only for the process that won.
- `requireCronContext()` in `mirzabot/inc/guard.php`.
- `acquireCronLock($name)` / `releaseCronLock($handle)` in `mirzabot/inc/guard.php`.

Modified functions:

- `inv_remove_service` (`mirzabot/api/invoice.php:141`) — the `tow` branch at 159-164 currently reads:
  `$refund = requireInt($data, 'amount', 0);`
  `$stmt = $pdo->prepare("UPDATE user SET Balance =  Balance + :balance WHERE id = :mp2");`
  followed by an unconditional `update("invoice","Status","removebyadmin",...)`. Because nothing checks whether `$invoice['Status']` is already `removebyadmin`, replaying the same `id_invoice` credits repeatedly, and `amount` has no upper bound. Fix: reject when the invoice is already `removebyadmin`; clamp `$refund` to `$invoice['price_product']`; wrap the credit, the status write, and `RemoveUser` in `withTransaction`.
- `KeyboardProduct` (`mirzabot/keyboard.php`) — currently `$stmt = $pdo->prepare($query); $stmt->execute();` where `$query` arrives pre-interpolated from `index.php`. Change the signature to accept `(string $sql, array $params)` and call `$stmt->execute($params)`. Both `vpnbot/Default/keyboard.php` and `vpnbot/update/keyboard.php` carry the same function and need the identical change.
- `DirectPayment` (`mirzabot/function.php:751`) — entered from six gateway callbacks and `croncard.php`. Gate its body on `settleOrderOnce($order_id)` and wrap the balance mutations in `withTransaction`.
- `getPaySettingValue` (`mirzabot/function.php:510`) — the `catch (PDOException)` around 494-496 leaves `$result` unassigned and then returns it. Initialise before the `try`.
- `createPayaqayepardakht` (`mirzabot/function.php:1909`) — `'callback' => $domainhosts . "/payment/aqayepardakht.php"` lacks the `https://` prefix that the Tronado and NowPayments builders both include.
- `select` (`mirzabot/function.php:427`) — no signature change; add null-safety at the ~40 call sites that index the result directly, e.g. `select(...)['idreport']`.

[Classes]
No classes are added, removed, or renamed; one method inside the existing `ManagePanel` class is corrected.

- `ManagePanel` (`mirzabot/panels.php`) — the Hiddify extension path at 2473 computes
  `$new_limit = ($old_limit_time / pow(1024,3)) + $limit_time_new;`
  dividing a Unix timestamp by 1,073,741,824. That constant belongs to byte-to-gigabyte conversion, not time; the correct expression adds days to the existing expiry. Separately, at 2449 the Marzneshin payload sends a raw integer `expire_date`, whereas the same class at 2145 correctly emits `date('c', $ts)`; align 2449 with 2145.

[Dependencies]
No new packages; one PHP version constraint is verified and one composer dependency is left untouched.

`composer.json` requires `chillerlan/php-qrcode` and `endroid/qr-code`; neither changes. The plan relies solely on PDO, `flock`, and `hash_equals`, all of which are core. Note that `withTransaction` requires the MySQL tables to be InnoDB — MyISAM silently ignores transactions. Verify with `SELECT table_name, engine FROM information_schema.tables WHERE table_schema = DATABASE()` and convert any MyISAM table that holds money (`user`, `invoice`, `Payment_report`) with `ALTER TABLE ... ENGINE=InnoDB` before Phase 1 lands.

[Testing]
Validation combines PHP lint, targeted concurrency scripts, and explicit regression guards for the six previously-disproved claims.

- Syntax gate after every phase: `Get-ChildItem -Recurse -Filter *.php | ForEach-Object { php -l $_.FullName }` — must report no errors across the tree.
- Refund replay: POST the same `id_invoice` with `type=tow` twice; the first must succeed, the second must be rejected, and the user balance must rise exactly once.
- Refund bound: POST `amount` larger than `price_product`; the credit must clamp.
- Concurrency: run two simultaneous `DirectPayment` calls for one `id_order` and assert exactly one credit, then two overlapping `croncard.php` runs and assert the lock serialises them.
- Cron exposure: `curl` each of the 18 `cronbot/*.php` files over HTTP and confirm every one returns 403 rather than executing.
- Gateway callback: replay a TetraPay callback with a mismatched `invoice_id` and confirm rejection instead of a null-index fatal.
- Regression guards (must keep passing, unchanged): `api/verify.php` accepts a correctly-signed initData payload and rejects a tampered hash; `api/utils.php::validateToken` still uses `hash_equals`; the panel login CSRF check still rejects a missing `_csrf`; each of the four `lang/` files still parses to exactly 2501 keys.

[Implementation Order]
Five phases ordered so shared primitives exist before their call sites, and so the highest-severity financial defects are closed first.

1. Confirm InnoDB on `user`, `invoice`, and `Payment_report`; take a full database dump and a git commit of the current tree.
2. Add `withTransaction`, `creditBalance`, `debitBalanceIfSufficient`, and `settleOrderOnce` to `function.php`, plus `inc/guard.php`. Nothing calls them yet, so this cannot regress behaviour.
3. Phase 1 — money: fix `api/invoice.php` idempotency and bounds; bind `payment/tetra.php` verification to the stored invoice and add the null-check; review the other six gateways for the same replay pattern; route `DirectPayment` and the `miniapp.php` affiliate credits through the new helpers.
4. Phase 2 — SQL injection: parameterise `KeyboardProduct` and its `index.php:3538` caller; fix `admin.php:3078-3091`, initialising `$query_where` and failing closed when `typecustomer` is unrecognised so the query can never degrade into an all-users UPDATE; fix `admin.php:1226`; apply the `:mp1`/`:mp2` fix and the `$sql1` fix to **both** `vpnbot/Default/admin.php` and `vpnbot/update/admin.php`, since `cp -r $source/*` would otherwise reintroduce the vulnerability on the next in-bot update.
5. Phase 3 — access control: add `requireCronContext()` to all 18 `cronbot/` files and `table.php`; add `acquireCronLock` to the money-touching crons; move the mysqldump password into a `--defaults-extra-file` and make `unlink` paths absolute; delete the plaintext password fallback at `panel/login.php:39-44`.
6. Phase 4 — logic: correct the Hiddify time arithmetic at `panels.php:2473` and the Marzneshin `expire_date` format at 2449; re-enable TLS verification in `request.php`, `alireza_single.php`, and `ibsng.php`; add the missing `https://` to the Aqayepardakht callback; align the two mismatched sprintf placeholder counts across the language files.
7. Phase 5 — robustness: initialise `$result` in the `function.php:494` catch block; add null-checks after unchecked `select()` calls; run the full `php -l` sweep and the complete test list above.
