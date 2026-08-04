#!/bin/bash
# Test for WGDashboard::updatepear

cd "$(dirname "$0")"

pass=0; fail=0
ok()  { echo "  ok   - $1"; pass=$((pass+1)); }
bad() { echo "  FAIL - $1"; fail=$((fail+1)); }

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

echo ""
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
