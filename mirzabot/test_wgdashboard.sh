#!/bin/bash
cd "$(dirname "$0")" || { echo "cd failed"; return 1; }
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
out=$(php test_env/test.php 2>&1)
rc=$?
rm -rf test_env
echo "$out"
if [ "$rc" -ne 0 ]; then return 1 2>/dev/null; fi
