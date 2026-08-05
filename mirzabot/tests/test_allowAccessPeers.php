<?php
// Define our assertions first
$pass = 0;
$fail = 0;

function ok($msg) {
    global $pass;
    echo "  ok   - $msg\n";
    $pass++;
}

function bad($msg) {
    global $fail;
    echo "  FAIL - $msg\n";
    $fail++;
}

// Track what was called
$called_tables = [];

// Mock select function
function select($table, $field, $whereField = null, $whereValue = null, $type = "select", $options = []) {
    global $called_tables;
    $called_tables[] = $table;

    if ($table === 'marzban_panel') {
        return [
            'url_panel' => 'http://panel.example.com',
            'inboundid' => 'wg0',
            'password_panel' => 'secret_api_key'
        ];
    }
    if ($table === 'invoice') {
        return [
            'user_info' => json_encode(['public_key' => 'mock_public_key_123'])
        ];
    }
    return null;
}

// Mock CurlRequest class
class CurlRequest {
    public $url;
    public $headers;
    public $payload;

    public function __construct($url) {
        $this->url = $url;
    }

    public function setHeaders($headers) {
        $this->headers = $headers;
    }

    public function post($data) {
        $this->payload = $data;
        return [
            'url' => $this->url,
            'headers' => $this->headers,
            'payload' => json_decode($data, true),
            'status' => 'mock_success'
        ];
    }
}

define('TESTING', true);
require_once __DIR__ . '/../WGDashboard.php';

echo "== allowAccessPeers ==\n";
// Run the function
$response = allowAccessPeers('mock_location', 'mock_username');

if ($response['url'] === 'http://panel.example.com/api/allowAccessPeers/wg0') {
    ok("URL is constructed correctly");
} else {
    bad("URL is incorrect: " . $response['url']);
}

if (in_array('wg-dashboard-apikey: secret_api_key', $response['headers'])) {
    ok("API key is included in headers");
} else {
    bad("API key is missing in headers");
}

if ($response['payload']['peers'][0] === 'mock_public_key_123') {
    ok("Payload contains the correct public key");
} else {
    bad("Payload is incorrect: " . print_r($response['payload'], true));
}

if (in_array('marzban_panel', $called_tables) && in_array('invoice', $called_tables)) {
    ok("Database select queries were executed");
} else {
    bad("Database select queries were not executed properly");
}

if ($fail > 0) {
    exit(1);
} else {
    exit(0);
}
