#!/bin/bash
# Runs PHPUnit tests

DIR=$(dirname "$0")
cd "$DIR"

out=$(composer test 2>&1)
rc=$?

# Count assertions as passed
if [ "$rc" -eq 0 ]; then
    p=$(echo "$out" | grep -o 'OK ([0-9]* tests, [0-9]* assertions)' | sed -n 's/.*, \([0-9]*\) assertions.*/\1/p')
    echo "── ${p:-1} passed, 0 failed ──"
else
    # Simple fail logic for now
    echo "── 0 passed, 1 failed ──"
    echo "  FAIL - PHPUnit tests failed"
    echo "$out"
fi
exit $rc
