#!/bin/bash
# Tests for WGDashboard module

cd "$(dirname "$0")" || exit 1

pass=0; fail=0
ok()  { echo "  ok   - $1"; pass=$((pass+1)); }
bad() { echo "  FAIL - $1"; fail=$((fail+1)); }

# --- Test 1: updatepear (PR #28) ---
cat > updatepear_test.php << 'PHP'
<?php

// Mocks
$mockSelectData = [];
function select($table, $field, $whereField = null, $whereValue = null, $type = "select", $options = []) {
    global $mockSelectData;
    if (isset($mockSelectData[$table][$whereValue])) {
        return $mockSelectData[$table][$whereValue];
    }
    return null;
}

$mockCurlRequestInstances = [];
class CurlRequest {
    public $url;
    public $headers = [];
    public $postData = null;
    public $mockResponse = ['status' => 200, 'body' => '{"success":true}'];

    public function __construct($url) {
        global $mockCurlRequestInstances;
        $this->url = $url;
        $mockCurlRequestInstances[] = $this;
    }

    public function setHeaders($headers) {
        $this->headers = $headers;
    }

    public function post($data) {
        $this->postData = $data;
        return $this->mockResponse;
    }
}

// Intercept config.php to avoid database errors
$wgdash_source = file_get_contents('WGDashboard.php');
$wgdash_source = str_replace("include('config.php');", "", $wgdash_source);
$wgdash_source = str_replace("ini_set('error_log', 'error_log');", "", $wgdash_source);
eval("?>" . $wgdash_source);

// Test setup
$mockSelectData['marzban_panel']['test_panel'] = [
    'url_panel' => 'http://test-panel.com',
    'inboundid' => '123',
    'password_panel' => 'test-api-key'
];

$config = ['name' => 'test_user', 'allowed_ips' => ['10.0.0.2']];
$response = updatepear('test_panel', $config);

// Assertions
$errors = [];

if ($response['status'] !== 200) {
    $errors[] = "Expected status 200, got {$response['status']}";
}

if (empty($mockCurlRequestInstances)) {
    $errors[] = "CurlRequest was not called";
} else {
    $request = $mockCurlRequestInstances[0];
    if ($request->url !== 'http://test-panel.com/api/updatePeerSettings/123') {
        $errors[] = "Unexpected URL: {$request->url}";
    }

    if (!in_array('wg-dashboard-apikey: test-api-key', $request->headers)) {
        $errors[] = "Missing API key header";
    }

    $expectedPostData = json_encode($config, true);
    if ($request->postData !== $expectedPostData) {
        $errors[] = "Unexpected post data. Expected: " . print_r($expectedPostData, true) . ", Got: " . print_r($request->postData, true);
    }
}

if (!empty($errors)) {
    echo "FAIL\n";
    foreach ($errors as $error) {
        echo "$error\n";
    }
} else {
    echo "PASS\n";
}
PHP

out=$(php updatepear_test.php 2>&1)

if echo "$out" | grep -q "PASS"; then
    ok "updatepear successfully updates peer settings via API"
else
    bad "updatepear test failed"
    echo "$out"
fi

rm -f updatepear_test.php

# --- Test 2: restrictPeers (PR #33) ---
mkdir -p test_env
cat << 'PHP' > test_env/config.php
<?php
$request_exec_timeout = null;
$APIKEY = 'test';
$adminnumber = '1';
$domainhosts = 'test';
$usernamebot = 'test';
$pdo = new stdClass();
PHP

cat << 'PHP' > test_env/request.php
<?php
class CurlRequest {
    public static $lastInstance;
    public $url;
    public $headers = [];
    public $cookie = null;
    public $method = null;
    public $data = null;
    public static $responseToReturn = ['status' => 200, 'body' => '{"success":true}'];
    public function __construct($url) {
        $this->url = $url;
        self::$lastInstance = $this;
    }
    public function setHeaders($headers) {
        if ($headers) $this->headers = array_merge($this->headers, $headers);
    }
    public function setCookie($cookie) { $this->cookie = $cookie; }
    public function post($data) {
        $this->method = 'POST';
        $this->data = $data;
        return self::$responseToReturn;
    }
}
PHP

cat << 'PHP' > test_env/test.php
<?php
set_include_path(__DIR__ . PATH_SEPARATOR . get_include_path());
function select($table, $field, $whereField = null, $whereValue = null, $type = "select", $options = []) {
    if ($table == "marzban_panel") return ['url_panel' => 'http://test-panel.local', 'inboundid' => 'test-inbound-id', 'password_panel' => 'test-api-key'];
    if ($table == "invoice" && $whereField == "username" && $whereValue == "testuser") return ['user_info' => json_encode(['public_key' => 'test-pub-key-123'])];
    return null;
}
require_once "request.php";
include_once __DIR__ . "/../WGDashboard.php";
$pass = 0; $fail = 0;
function ok($msg) { global $pass; echo "  ok   - $msg\n"; $pass++; }
function bad($msg) { global $fail; echo "  FAIL - $msg\n"; $fail++; }
$result = restrictPeers("loc1", "testuser");
$req = CurlRequest::$lastInstance;
if ($req->url === "http://test-panel.local/api/restrictPeers/test-inbound-id") ok("restrictPeers URL"); else bad("URL mismatch");
if (in_array("wg-dashboard-apikey: test-api-key", $req->headers)) ok("restrictPeers API key"); else bad("API key missing");
if ($req->method === "POST") ok("restrictPeers POST method"); else bad("Method wrong");
if (strpos($req->data, "test-pub-key-123") !== false) ok("restrictPeers payload"); else bad("Payload mismatch");
if (isset($result['success']) && $result['success'] === true) ok("restrictPeers parsed response"); else bad("Parsing failed");
echo "\n── $pass passed, $fail failed ──\n";
if ($fail > 0) { die(1); }
die(0);
PHP

out33=$(php test_env/test.php 2>&1)
rc33=$?
rm -rf test_env
echo "$out33"

if [ "$rc33" -eq 0 ]; then
    ok "restrictPeers test passed"
else
    bad "restrictPeers test failed"
fi

echo ""
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]