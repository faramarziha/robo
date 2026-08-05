#!/bin/bash

# Test for IBSng module in mirzabot/ibsng/Modules/IBSng.php and mirzabot/ibsng.php

php "$(dirname "$0")/test_ibsng.php"

# Test the IBSng class isUserValid/isUserExpired methods, and the
# deleteUserIBSng() wrapper in mirzabot/ibsng.php

cd "$(dirname "$0")" || return 1
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

ok()  { printf "  \033[1;32m✔\033[0m %-40s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  \033[1;31m✘\033[0m %-40s\n      FAIL: expected %s, got %s\n" "$1" "$2" "$3"; fail=$((fail+1)); }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "'$2'" "'$3'"; }

# ---------------------------------------------------------------------------
# isUserValid() / isUserExpired() tests
# ---------------------------------------------------------------------------

# Write a simple tester script
cat << 'PHP' > "$TMP/test.php"
<?php
// Fix path to point relative to the script location
require_once __DIR__ . '/../../mirzabot/ibsng/Modules/IBSng.php';

// Mock IBSng for testing
class MockIBSng extends \radiusApi\Modules\IBSng {
    public $mockInfo = [];

    public function __construct() {
        // Skip parent constructor to avoid curl requirements/login
    }

    protected function infoByUsername($username, $withPassword = false, $output = null) {
        if (!isset($this->mockInfo[$username])) {
            throw new \Exception("User not found");
        }
        return $this->mockInfo[$username];
    }
}

$ibsng = new MockIBSng();

// Test 1: Valid user
$ibsng->mockInfo['valid_user'] = [
    'locked' => '0',
    'credit' => '100',
    'status' => 'active',
    'absolute_expire_date' => date('Y-m-d H:i:s', strtotime('+1 year')),
    'nearest_expire_date' => date('Y-m-d H:i:s', strtotime('+1 year')),
];
$isValid = $ibsng->isUserValid('valid_user') ? 'true' : 'false';
echo "valid_user:$isValid\n";

// Test 2: Locked user
$ibsng->mockInfo['locked_user'] = [
    'locked' => '1',
    'credit' => '100',
    'status' => 'active',
    'absolute_expire_date' => date('Y-m-d H:i:s', strtotime('+1 year')),
    'nearest_expire_date' => date('Y-m-d H:i:s', strtotime('+1 year')),
];
$isValid = $ibsng->isUserValid('locked_user') ? 'true' : 'false';
echo "locked_user:$isValid\n";

// Test 3: Zero credit user
$ibsng->mockInfo['zero_credit_user'] = [
    'locked' => '0',
    'credit' => '0',
    'status' => 'active',
    'absolute_expire_date' => date('Y-m-d H:i:s', strtotime('+1 year')),
    'nearest_expire_date' => date('Y-m-d H:i:s', strtotime('+1 year')),
];
$isValid = $ibsng->isUserValid('zero_credit_user') ? 'true' : 'false';
echo "zero_credit_user:$isValid\n";

// Test 4: Expired status
$ibsng->mockInfo['expired_status_user'] = [
    'locked' => '0',
    'credit' => '100',
    'status' => 'expired',
    'absolute_expire_date' => date('Y-m-d H:i:s', strtotime('+1 year')),
    'nearest_expire_date' => date('Y-m-d H:i:s', strtotime('+1 year')),
];
$isValid = $ibsng->isUserValid('expired_status_user') ? 'true' : 'false';
echo "expired_status_user:$isValid\n";

// Test 5: Absolute expiration passed
$ibsng->mockInfo['abs_expired_user'] = [
    'locked' => '0',
    'credit' => '100',
    'status' => 'active',
    'absolute_expire_date' => date('Y-m-d H:i:s', strtotime('-1 day')),
    'nearest_expire_date' => '0',
];
$isValid = $ibsng->isUserValid('abs_expired_user') ? 'true' : 'false';
echo "abs_expired_user:$isValid\n";

// Test 6: Non-existent user
$isValid = $ibsng->isUserValid('missing_user') ? 'true' : 'false';
echo "missing_user:$isValid\n";

PHP

# Use absolute path for include based on current pwd (we cd'ed to mirzabot above)
sed -i "s|require_once .*|require_once '"$(pwd)"/ibsng/Modules/IBSng.php';|" "$TMP/test.php"

php "$TMP/test.php" > "$TMP/out" 2>&1

res1=$(grep "valid_user:" "$TMP/out" | cut -d: -f2)
res2=$(grep "locked_user:" "$TMP/out" | cut -d: -f2)
res3=$(grep "zero_credit_user:" "$TMP/out" | cut -d: -f2)
res4=$(grep "expired_status_user:" "$TMP/out" | cut -d: -f2)
res5=$(grep "abs_expired_user:" "$TMP/out" | cut -d: -f2)
res6=$(grep "missing_user:" "$TMP/out" | cut -d: -f2)

if [ -z "$res1" ]; then
    cat "$TMP/out"
fi

is "valid user returns true" "true" "$res1"
is "locked user returns false" "false" "$res2"
is "zero credit user returns false" "false" "$res3"
is "expired status returns false" "false" "$res4"
is "expired date returns false" "false" "$res5"
is "missing user returns false" "false" "$res6"

# ---------------------------------------------------------------------------
# deleteUserIBSng() tests (mirzabot/ibsng.php wrapper)
# ---------------------------------------------------------------------------

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
del_out=$(php test_ibsng_mock.php 2>&1)

if echo "$del_out" | grep -q "SUCCESS_1"; then
    ok "deleteUserIBSng returns true on successful deletion"
else
    bad "deleteUserIBSng returns true on successful deletion" "SUCCESS_1" "$del_out"
fi

if echo "$del_out" | grep -q "SUCCESS_2"; then
    ok "deleteUserIBSng catches exceptions and returns false status array"
else
    bad "deleteUserIBSng catches exceptions and returns false status array" "SUCCESS_2" "$del_out"
fi

if echo "$del_out" | grep -q "SUCCESS_3"; then
    ok "deleteUserIBSng returns false when deletion fails"
else
    bad "deleteUserIBSng returns false when deletion fails" "SUCCESS_3" "$del_out"
fi

rm -f test_ibsng_mock.php test_ibsng_temp.php

# ---------------------------------------------------------------------------

echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]