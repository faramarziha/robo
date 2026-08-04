#!/bin/bash
cd "$(dirname "$0")" || exit 1

if [ -f vendor/bin/phpunit ]; then
    out=$(vendor/bin/phpunit tests/ 2>&1)
    rc=$?

    if echo "$out" | grep -q "OK ("; then
        tests=$(echo "$out" | grep -o "OK ([0-9]* tests" | grep -o "[0-9]*")
        echo "│ $tests passed, 0 failed │"
        exit 0
    else
        tests=$(echo "$out" | grep -o "Tests: [0-9]*" | head -n 1 | grep -o "[0-9]*" || echo "0")
        fails=$(echo "$out" | grep -o "Failures: [0-9]*" | head -n 1 | grep -o "[0-9]*" || echo "0")
        errors=$(echo "$out" | grep -o "Errors: [0-9]*" | head -n 1 | grep -o "[0-9]*" || echo "0")
        total_fails=$((fails + errors))
        passed=$((tests - total_fails))

        echo "$out" | sed 's/^/  FAIL: /'
        echo "│ $passed passed, $total_fails failed │"
        exit 1
    fi
else
    echo "PHPUnit not found"
    echo "│ 0 passed, 1 failed │"
    exit 1
fi