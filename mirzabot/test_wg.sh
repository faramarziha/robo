#!/bin/bash
# Test harness for WGDashboard.php tests

cd "$(dirname "$0")" || return 1

pass=0
fail=0

# Run the PHP test script which does its own ok/bad reporting
output=$(php tests/test_allowAccessPeers.php 2>&1)
rc=$?

# Print the output from the PHP script
echo "$output"

if [ "$rc" -ne 0 ]; then
    echo "  FAIL - PHP script crashed or returned non-zero exit code: $rc"
    fail=$((fail+1))
fi

# Extract pass/fail counts from the PHP script output
p=$(echo "$output" | grep -c "  ok   - ")
f=$(echo "$output" | grep -c "  FAIL - ")

pass=$((pass + p))
fail=$((fail + f))

echo ""
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
