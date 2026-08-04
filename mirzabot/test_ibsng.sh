#!/bin/bash

# Absolute path setup
SRC="$(cd "$(dirname "$0")" && pwd)/ibsng.php"

pass=0; fail=0
ok()  { echo "  ok   - $1"; pass=$((pass+1)); }
bad() { echo "  FAIL - $1"; fail=$((fail+1)); }

cd "$(dirname "$0")"

# Create mock test script
cat > test_ibsng_mock.php <<'PHP_EOF'
<?php

namespace radiusApi\Modules {
    class IBSng {
        public $loginArray;
        public function __construct($loginArray) {
            $this->loginArray = $loginArray;
        }
        public function connect() {
            if (isset($GLOBALS['test_throw_exception']) && $GLOBALS['test_throw_exception']) {
                throw new \Exception("Mock connection failed");
            }
            if (isset($GLOBALS['test_connect_fail']) && $GLOBALS['test_connect_fail']) {
                return "Connection error msg";
            }
            return true;
        }
        public function deleteUser($username) {
            if (isset($GLOBALS['test_delete_fail']) && $GLOBALS['test_delete_fail']) {
                return false;
            }
            return true;
        }
        public function disconnect() {
            return true;
        }
    }
}

namespace {
    // Mock the 'select' function from function.php/core
    function select($table, $cols, $where_col, $where_val, $type) {
        if ($where_val == 'bad_panel') {
            return [
                'username_panel' => 'bad_user',
                'password_panel' => 'bad_pass',
                'url_panel' => 'http://bad-url'
            ];
        }
        return [
            'username_panel' => 'test_user',
            'password_panel' => 'test_pass',
            'url_panel' => 'http://test-url'
        ];
    }

    // We can just load the file directly, it will hit bootstrap.php, which hits Modules/IBSng.php
    // To prevent fatal error for re-declaration of the module class,
    // we need to create a temporary copy of ibsng.php without the require for bootstrap.php.

    $ibsng_code = file_get_contents(__DIR__ . '/ibsng.php');
    $ibsng_code = str_replace("require_once 'ibsng/bootstrap.php';", "// require mocked", $ibsng_code);
    file_put_contents(__DIR__ . '/test_ibsng_temp.php', $ibsng_code);

    require_once __DIR__ . '/test_ibsng_temp.php';

    // Test Cases for deleteUserIBSng

    // Test 1: Successful deletion
    $GLOBALS['test_throw_exception'] = false;
    $GLOBALS['test_delete_fail'] = false;
    $result = deleteUserIBSng('good_panel', 'testuser1');
    if ($result === true) {
        echo "SUCCESS_1\n";
    } else {
        echo "FAIL_1: Expected true, got " . json_encode($result) . "\n";
    }

    // Test 2: Exception during connection
    $GLOBALS['test_throw_exception'] = true;
    $result = deleteUserIBSng('good_panel', 'testuser2');
    if (is_array($result) && isset($result['status']) && $result['status'] === false && strpos($result['msg'], 'Mock connection') !== false) {
        echo "SUCCESS_2\n";
    } else {
        echo "FAIL_2: Expected exception array, got " . json_encode($result) . "\n";
    }

    // Test 3: Delete returns false (if user didn't exist or deletion failed)
    $GLOBALS['test_throw_exception'] = false;
    $GLOBALS['test_delete_fail'] = true;
    $result = deleteUserIBSng('good_panel', 'testuser3');
    if ($result === false) {
        echo "SUCCESS_3\n";
    } else {
        echo "FAIL_3: Expected false, got " . json_encode($result) . "\n";
    }
}
PHP_EOF

# Run the test script
out=$(php test_ibsng_mock.php 2>&1)

if echo "$out" | grep -q "SUCCESS_1"; then
    ok "returns true on successful deletion"
else
    bad "failed on successful deletion: $out"
fi

if echo "$out" | grep -q "SUCCESS_2"; then
    ok "catches exceptions and returns false status array"
else
    bad "failed exception handling: $out"
fi

if echo "$out" | grep -q "SUCCESS_3"; then
    ok "returns false when deletion fails"
else
    bad "failed on unsuccessful deletion: $out"
fi

rm test_ibsng_mock.php test_ibsng_temp.php

echo ""
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
