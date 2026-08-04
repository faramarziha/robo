#!/bin/bash
# Test the IBSng class isUserValid and isUserExpired methods

cd "$(dirname "$0")" || return 1
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

ok()  { printf "  \033[1;32m✔\033[0m %-40s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  \033[1;31m✘\033[0m %-40s\n      FAIL: expected %s, got %s\n" "$1" "$2" "$3"; fail=$((fail+1)); }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "'$2'" "'$3'"; }

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

echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
