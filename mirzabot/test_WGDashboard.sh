#!/bin/bash
# Tests for WGDashboard.php
cd "$(dirname "$0")" || { echo "Failed to cd"; exit 1; }

pass=0
fail=0

ok()  { echo "  ok   - $1"; pass=$((pass+1)); }
bad() { echo "  FAIL - $1"; fail=$((fail+1)); }

# Create a test directory and script
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# Copy the file to test directory
cp WGDashboard.php "$TEST_DIR/"

# Create a mock config.php
cat << 'PHP_EOF' > "$TEST_DIR/config.php"
<?php
// Mock config to prevent actual database connections
$request_exec_timeout = null;
$dbhost = 'localhost';
$dbname = 'test';
$usernamedb = 'root';
$passworddb = '';
$APIKEY = 'test_key';
$adminnumber = '123';
$domainhosts = 'example.com';
$usernamebot = 'test_bot';

// Mock the PDO object so it doesn't crash if accessed
class MockPDO {
    public function prepare() { return new MockPDOStatement(); }
    public function query() { return new MockPDOStatement(); }
}
class MockPDOStatement {
    public function execute() { return true; }
    public function fetch() { return []; }
}
$pdo = new MockPDO();
PHP_EOF

cat << 'PHP_EOF' > "$TEST_DIR/test_WGDashboard_runner.php"
<?php
class CurlRequest {
    public static $lastInstance = null;
    public $url;
    public $headers = [];
    public $postData;

    public function __construct($url) {
        $this->url = $url;
        self::$lastInstance = $this;
    }

    public function setHeaders($headers) {
        $this->headers = $headers;
    }

    public function post($data) {
        $this->postData = $data;
        return [
            'status' => 200,
            'body' => '{"status":true,"message":"Job deleted"}'
        ];
    }
}

// Global functions mock
function select($table, $columns, $whereColumn, $whereValue, $type) {
    if ($table === 'marzban_panel' && $whereColumn === 'name_panel' && $whereValue === 'test_panel') {
        return [
            'url_panel' => 'http://test-panel.local',
            'password_panel' => 'secret_password_123',
            'inboundid' => '456'
        ];
    }
    return false;
}

require_once 'WGDashboard.php';

// Test 1: deletejob returns the expected response
$config = ['jobId' => 'job_123', 'peerId' => 'peer_456'];
$response = deletejob('test_panel', $config);

if (is_array($response) && $response['status'] === 200 && strpos($response['body'], 'Job deleted') !== false) {
    echo "TEST_PASS_1\n";
} else {
    echo "TEST_FAIL_1: Unexpected response\n";
}

// Test 2: deletejob sets correct headers and URL
$req = CurlRequest::$lastInstance;
if ($req) {
    if ($req->url === 'http://test-panel.local/api/deletePeerScheduleJob') {
        echo "TEST_PASS_2\n";
    } else {
        echo "TEST_FAIL_2: Wrong URL: {$req->url}\n";
    }

    $expectedHeaders = [
        'Accept: application/json',
        'wg-dashboard-apikey: secret_password_123',
        'Content-Type: application/json',
    ];
    if ($req->headers === $expectedHeaders) {
        echo "TEST_PASS_3\n";
    } else {
        echo "TEST_FAIL_3: Wrong headers\n";
    }

    if ($req->postData === json_encode($config)) {
        echo "TEST_PASS_4\n";
    } else {
        echo "TEST_FAIL_4: Wrong post data\n";
    }
} else {
    echo "TEST_FAIL: CurlRequest not initialized\n";
}

PHP_EOF

# Run the test script
cd "$TEST_DIR" || { echo "Failed to cd to test dir"; exit 1; }
output=$(php test_WGDashboard_runner.php 2>&1)
cd - > /dev/null

if echo "$output" | grep -q "TEST_PASS_1"; then
    ok "deletejob() returns response from API"
else
    bad "deletejob() failed to return API response"
fi

if echo "$output" | grep -q "TEST_PASS_2"; then
    ok "deletejob() constructs correct URL"
else
    bad "deletejob() constructed wrong URL"
    echo "$output"
fi

if echo "$output" | grep -q "TEST_PASS_3"; then
    ok "deletejob() sets correct API key and headers"
else
    bad "deletejob() failed to set correct headers"
fi

if echo "$output" | grep -q "TEST_PASS_4"; then
    ok "deletejob() sends correct JSON payload"
else
    bad "deletejob() sent incorrect payload"
fi

echo ""
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
