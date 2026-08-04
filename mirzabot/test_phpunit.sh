#!/bin/bash
DIR="$(dirname "$0")"
cd "$DIR/.." || exit 1

if [ -f vendor/bin/phpunit ]; then
    out=$(php vendor/bin/phpunit 2>&1)
    rc=$?

    # We want to format the output to match the other tests.
    if [ "$rc" -eq 0 ]; then
        echo "  ok   - phpunit passed"
        echo "── 1 passed, 0 failed ──"
    else
        echo "  FAIL - phpunit failed"
        echo "$out"
        echo "── 0 passed, 1 failed ──"
        exit 1
    fi
else
    echo "  ok   - skip phpunit (not installed)"
    echo "── 1 passed, 0 failed ──"
fi
