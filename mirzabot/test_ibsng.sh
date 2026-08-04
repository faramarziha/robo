#!/bin/bash
# Test harness for IBSng module

SRC="$(dirname "$0")/ibsng/Modules/IBSng.php"
PHPUNIT="$(dirname "$0")/vendor/bin/phpunit"

pass=0; fail=0
ok()   { echo "  ok   - $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL - $1"; fail=$((fail+1)); }

if [ ! -f "$PHPUNIT" ]; then
    bad "PHPUnit is not installed"
    echo "── 0 passed, 1 failed ──"
    exit 1
fi

output=$($PHPUNIT "$(dirname "$0")/tests/IBSng/" 2>&1)
rc=$?

if [ $rc -eq 0 ]; then
    ok "IBSng tests passed"
else
    bad "IBSng tests failed"
    echo "$output" | sed 's/^/      /'
fi

echo "── $pass passed, $fail failed ──"
if [ $fail -gt 0 ]; then
    exit 1
fi
exit 0
