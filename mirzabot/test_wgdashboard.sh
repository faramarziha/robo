#!/bin/bash
# Test harness for WGDashboard functions.

# Go to script dir
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

pass=0; fail=0
ok()   { echo "  ok   - $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL - $1"; fail=$((fail+1)); }

# Create the test PHP script
cat << 'PHP' > test_wgdashboard.php
<?php
// Mocking dependencies for remove_userwg

$mock_select_calls = [];
function select($table, $col, $where_col, $where_val, $type) {
    global $mock_select_calls;
    $mock_select_calls[] = func_get_args();
    if ($table === 'marzban_panel') {
        return [
            'url_panel' => 'http://wg.example.com',
            'inboundid' => 'wg0',
            'password_panel' => 'secret_api_key'
        ];
    }
    if ($table === 'invoice') {
        return [
            'user_info' => json_encode(['public_key' => 'pub_key_12345'])
        ];
    }
    return false;
}

$mock_allowAccessPeers_calls = [];
function allowAccessPeers($location, $username) {
    global $mock_allowAccessPeers_calls;
    $mock_allowAccessPeers_calls[] = func_get_args();
    return true;
}

class CurlRequest {
    public $url;
    public $headers;
    public $postData;

    // Static variables to track calls
    public static $lastInstance = null;

    public function __construct($url) {
        $this->url = $url;
        self::$lastInstance = $this;
    }

    public function setHeaders($headers) {
        $this->headers = $headers;
    }

    public function post($data) {
        $this->postData = $data;
        return '{"status": "success"}';
    }
}

// Extract just the remove_userwg function from WGDashboard.php so we don't have to deal with side-effects
$code = file_get_contents('WGDashboard.php');
// Extract the remove_userwg function block
preg_match('/function remove_userwg\([^)]*\)\s*\{.*?\n\}\s*\n(?:function|\Z)/s', $code, $matches);
if (!empty($matches)) {
    // Strip the last line if it starts with function
    $func_code = preg_replace('/function\Z/', '', $matches[0]);
    // Evaluate it
    eval($func_code);
} else {
    // Try an alternative regex just in case
    preg_match('/function remove_userwg[^{]*{(?:[^{}]*|{(?:[^{}]*|{[^{}]*})*})*}/s', $code, $matches);
    eval($matches[0]);
}


$res = remove_userwg('test_loc', 'test_user');

$errors = [];

// Assertions
if (count($mock_allowAccessPeers_calls) !== 1 || $mock_allowAccessPeers_calls[0] !== ['test_loc', 'test_user']) {
    $errors[] = "allowAccessPeers not called correctly.";
}

$curl = CurlRequest::$lastInstance;
if (!$curl) {
    $errors[] = "CurlRequest not instantiated.";
} else {
    if ($curl->url !== 'http://wg.example.com/api/deletePeers/wg0') {
        $errors[] = "Incorrect URL: " . $curl->url;
    }
    if (!in_array('wg-dashboard-apikey: secret_api_key', $curl->headers)) {
        $errors[] = "API key header missing.";
    }
    $postDecoded = json_decode($curl->postData, true);
    if (!isset($postDecoded['peers'][0]) || $postDecoded['peers'][0] !== 'pub_key_12345') {
        $errors[] = "Post data incorrect: " . $curl->postData;
    }
}

if ($res !== '{"status": "success"}') {
    $errors[] = "Response incorrect: " . $res;
}

if (empty($errors)) {
    echo "PASS\n";
    exit(0);
} else {
    echo "FAIL\n" . implode("\n", $errors) . "\n";
    exit(1);
}
PHP

# Run the test
output=$(php test_wgdashboard.php)
if [ $? -eq 0 ]; then
    ok "remove_userwg"
else
    bad "remove_userwg"
    echo "$output" | sed 's/^/      /'
fi

rm test_wgdashboard.php

echo ""
echo "── $pass passed, $fail failed ──"
if [ "$fail" -eq 0 ]; then
    # Return true equivalent for the shell script
    true
else
    # Return false equivalent
    false
fi
