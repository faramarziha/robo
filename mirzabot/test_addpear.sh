#!/bin/bash
# Functional test for the addpear() function in WGDashboard.php

cd "$(dirname "$0")"

php -r '
// Globals for mocking
$pass = 0;
$fail = 0;

function ok($msg) {
    global $pass;
    $pass++;
    echo "  ok   - $msg\n";
}

function bad($msg) {
    global $fail;
    $fail++;
    echo "  FAIL - $msg\n";
}

function is($name, $expected, $actual) {
    if ($expected === $actual) {
        ok($name);
    } else {
        bad($name . " (expected: " . json_encode($expected) . ", got: " . json_encode($actual) . ")");
    }
}

$mock_select_returns = [];
$mock_publickey_returns = [];
$mock_ipslast_returns = [];
$mock_curl_post_returns = [];
$mock_curl_post_called = 0;
$mock_curl_post_arg = null;
$mock_curl_headers = [];

function select($table, $cols, $where_col, $where_val, $type) {
    global $mock_select_returns;
    return array_shift($mock_select_returns);
}

function publickey() {
    global $mock_publickey_returns;
    return array_shift($mock_publickey_returns);
}

function ipslast($namepanel) {
    global $mock_ipslast_returns;
    return array_shift($mock_ipslast_returns);
}

class CurlRequest {
    public $url;
    public function __construct($url) {
        $this->url = $url;
    }
    public function setHeaders($headers) {
        global $mock_curl_headers;
        $mock_curl_headers = $headers;
    }
    public function post($data) {
        global $mock_curl_post_returns, $mock_curl_post_called, $mock_curl_post_arg;
        $mock_curl_post_called++;
        $mock_curl_post_arg = $data;
        return array_shift($mock_curl_post_returns);
    }
}

// Extract addpear() from WGDashboard.php
$source = file_get_contents("WGDashboard.php");
if (!preg_match("/function addpear.*?^}/sm", $source, $matches)) {
    die("FATAL: Could not extract addpear() from WGDashboard.php\n");
}
eval($matches[0]);

// ---------- TESTS ----------

echo "\n== error code in ipslast response ==\n";
$mock_select_returns = [["inboundid" => "inb1", "url_panel" => "http://test", "password_panel" => "pass"]];
$mock_publickey_returns = [["private_key" => "priv", "public_key" => "pub", "preshared_key" => "pre"]];
$mock_ipslast_returns = [["status" => 500]];

$res = addpear("panel1", "user1");
is("returns error on bad HTTP status", ["status" => false, "msg" => "error code : 500"], $res);


echo "\n== explicit error array key in ipslast ==\n";
$mock_select_returns = [["inboundid" => "inb1", "url_panel" => "http://test", "password_panel" => "pass"]];
$mock_publickey_returns = [["private_key" => "priv", "public_key" => "pub", "preshared_key" => "pre"]];
$mock_ipslast_returns = [["status" => 200, "error" => "some error message"]];

$res = addpear("panel1", "user1");
is("returns error on explicit error key", ["status" => false, "msg" => "some error message"], $res);


echo "\n== body decoded containing status = false ==\n";
$mock_select_returns = [["inboundid" => "inb1", "url_panel" => "http://test", "password_panel" => "pass"]];
$mock_publickey_returns = [["private_key" => "priv", "public_key" => "pub", "preshared_key" => "pre"]];
// In PHP, checking json_decode($body, true) means $ipconfig will just have what is in body.
// So $ipconfig will be `["status" => false, "msg" => "inner error"]` which triggers line 95.
$mock_ipslast_returns = [["status" => 200, "body" => json_encode(["status" => false, "msg" => "inner error"])]];

$res = addpear("panel1", "user1");
is("returns inner error when status is false", ["status" => false, "msg" => "inner error"], $res);


echo "\n== happy path: correct API calls and response generation ==\n";
$mock_select_returns = [["inboundid" => "inb1", "url_panel" => "http://test", "password_panel" => "pass"]];
$mock_publickey_returns = [["private_key" => "priv", "public_key" => "pub", "preshared_key" => "pre"]];
$mock_ipslast_returns = [["status" => 200, "body" => json_encode(["status" => true, "data" => ["some_key" => ["10.0.0.2"]]])]];
$mock_curl_post_returns = [["body" => json_encode(["success" => true])]];
$mock_curl_post_called = 0;

$res = addpear("panel1", "user1");
$expected_config = [
    "name" => "user1",
    "allowed_ips" => ["10.0.0.2"],
    "private_key" => "priv",
    "public_key" => "pub",
    "preshared_key" => "pre"
];

is("called curl post once", 1, $mock_curl_post_called);
is("curl post arg is JSON string matching config", json_encode($expected_config), $mock_curl_post_arg);

global $mock_curl_headers;
$expected_headers = [
    "Accept: application/json",
    "Content-Type: application/json",
    "wg-dashboard-apikey: pass"
];
is("curl headers correctly set", $expected_headers, $mock_curl_headers);

$expected_response = [
    "body" => [
        "name" => "user1",
        "allowed_ips" => ["10.0.0.2"],
        "private_key" => "priv",
        "public_key" => "pub",
        "preshared_key" => "pre",
        "response" => json_encode(["success" => true])
    ]
];
is("returns correct final payload", $expected_response, $res);

echo "\n── $pass passed, $fail failed ──\n";
if ($fail > 0) {
    exit(1);
} else {
    exit(0);
}
'
