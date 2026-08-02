#!/bin/bash
# Functional test for the mirza_cron_lock() helper.
#
# test_cron.sh proves the *patching* is correct; this proves the lock actually
# locks. A guard that silently fails open would be worse than no guard, since
# croncard.php would then be free to confirm the same payment twice.

# Absolute before the cd below, or the sed cannot find the installer.
SRC="$(cd "$(dirname "$0")" && pwd)/install.sh"
[ -f "$SRC" ] || { echo "FATAL: $SRC not found"; exit 1; }
SANDBOX="/tmp/mirza_locktest.$$"
mkdir -p "$SANDBOX" || exit 1
cd "$SANDBOX" || exit 1

pass=0; fail=0
ok()  { echo "  ok   - $1"; pass=$((pass+1)); }
bad() { echo "  FAIL - $1"; fail=$((fail+1)); }

# Pull the PHP heredoc body straight out of the installer.
# Not eval'd as shell: the range /^}$/ would stop at the PHP function's own
# closing brace inside the heredoc and truncate the file.
sed -n "/<<'PHP'/,/^PHP\$/p" "$SRC" | sed '1d;$d' > _lock.php

echo "== extraction =="
n=$(wc -l < _lock.php)
[ "$n" -gt 10 ] && ok "_lock.php extracted ($n lines)" || { bad "_lock.php looks empty ($n lines)"; exit 1; }
grep -q 'function mirza_cron_lock' _lock.php && ok "contains mirza_cron_lock()" || bad "function missing"
php -l _lock.php >/dev/null 2>&1 && ok "php -l clean" || bad "php -l failed"

# Worker: takes the lock, holds it, reports which path it took.
cat > job.php <<'EOF'
<?php
require __DIR__ . '/_lock.php';
if (!mirza_cron_lock('job.php')) { echo "BLOCKED\n"; exit(9); }
echo "ACQUIRED\n";
sleep((int)($argv[1] ?? 2));
EOF

echo ""
echo "== concurrency =="
php job.php 3 > a.out 2>&1 &
first=$!
sleep 1                       # let the first process take the lock
php job.php 1 > b.out 2>&1
second_rc=$?
wait "$first"; first_rc=$?

grep -q ACQUIRED a.out && ok "first process acquired the lock" || bad "first did not acquire: $(cat a.out)"
[ "$first_rc" -eq 0 ] && ok "first exited 0" || bad "first exited $first_rc"

if grep -q BLOCKED b.out; then
    ok "second process was blocked while the first held the lock"
else
    bad "second process ran concurrently - LOCK DOES NOT WORK: $(cat b.out)"
fi
[ "$second_rc" -eq 9 ] && ok "second exited with the blocked code" || bad "second exited $second_rc, expected 9"

echo ""
echo "== release =="
# Once the holder is gone the lock must be free again, or every later run dies.
php job.php 0 > c.out 2>&1
grep -q ACQUIRED c.out && ok "lock released after the holder exited" || bad "lock never released: $(cat c.out)"

echo ""
echo "== isolation =="
# Different scripts must not contend with each other.
cat > job2.php <<'EOF'
<?php
require __DIR__ . '/_lock.php';
if (!mirza_cron_lock('other.php')) { echo "BLOCKED\n"; exit(9); }
echo "ACQUIRED\n";
EOF
php job.php 2 > d.out 2>&1 &
held=$!
sleep 1
php job2.php > e.out 2>&1
grep -q ACQUIRED e.out && ok "a different script is not blocked" || bad "unrelated scripts contend: $(cat e.out)"
wait "$held" 2>/dev/null

echo ""
echo "── $pass passed, $fail failed ──"
cd /tmp && rm -rf "$SANDBOX"
[ "$fail" -eq 0 ]
