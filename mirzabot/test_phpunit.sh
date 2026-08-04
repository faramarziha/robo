#!/bin/bash
cd "$(dirname "$0")"
out=$(vendor/bin/phpunit ibsng/tests/IBSngTest.php 2>&1)
rc=$?
if echo "$out" | grep -q "OK ("; then
    pass=$(echo "$out" | grep -oP "OK \(\K[0-9]+(?= tests)")
    if [ -z "$pass" ]; then
        pass=$(echo "$out" | grep -oP "OK \(\K[0-9]+(?= test,)")
    fi
    fail=0
else
    pass=$(echo "$out" | grep -oP "Tests: \K[0-9]+")
    fail=$(echo "$out" | grep -oP "(Failures|Errors): \K[0-9]+")
    if [ -z "$fail" ]; then
        fail=1
    fi
    if [ -n "$pass" ] && [ -n "$fail" ]; then
        pass=$((pass - fail))
    fi
fi
if [ "$rc" -eq 0 ]; then
    printf '── %s passed, 0 failed ──\n' "${pass:-?}"
    echo -n ""
else
    echo "$out"
    printf '── %s passed, %s failed ──\n' "${pass:-?}" "${fail:-?}"
    echo -n ""
fi
exit $rc
