#!/bin/bash
# Runs every installer test suite and reports a combined total.
#
#   bash run_tests.sh
#
# Each suite is standalone and exits non-zero on failure, so this is also
# usable as a pre-commit or CI gate.

cd "$(dirname "$0")" || exit 1

SUITES="test_lint test_resolve test_cron test_lock test_lifecycle test_wg"

total_pass=0
total_fail=0
failed_suites=""

for s in $SUITES; do
    [ -f "$s.sh" ] || { echo "  missing: $s.sh"; failed_suites="$failed_suites $s"; continue; }
    out=$(bash "$s.sh" 2>&1)
    rc=$?
    line=$(echo "$out" | tail -1)
    # "── N passed, M failed ──"
    p=$(echo "$line" | sed -n 's/.*[^0-9]\([0-9]\+\) passed.*/\1/p')
    f=$(echo "$line" | sed -n 's/.*[^0-9]\([0-9]\+\) failed.*/\1/p')
    [ -n "$p" ] && total_pass=$((total_pass + p))
    [ -n "$f" ] && total_fail=$((total_fail + f))

    if [ "$rc" -eq 0 ]; then
        printf '  \033[1;32m✔\033[0m %-16s %s passed\n' "$s" "${p:-?}"
    else
        printf '  \033[1;31m✘\033[0m %-16s %s passed, %s FAILED\n' "$s" "${p:-?}" "${f:-?}"
        failed_suites="$failed_suites $s"
        # Only the failures, so the reason is visible without re-running.
        echo "$out" | grep -- '  FAIL' | sed 's/^/      /'
    fi
done

echo ""
if [ -n "$failed_suites" ]; then
    printf '\033[1;31m── %d passed, %d failed ──\033[0m  (%s)\n' \
        "$total_pass" "$total_fail" "${failed_suites# }"
    exit 1
fi
printf '\033[1;32m── %d passed, 0 failed ──\033[0m\n' "$total_pass"
