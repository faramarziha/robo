<?php

// Mock CurlRequest class
class CurlRequest {
    private $url;
    private $headers;

    public function __construct($url) {
        $this->url = $url;
    }

    public function setHeaders($headers) {
        $this->headers = $headers;
    }

    public function get() {
        return [
            'url' => $this->url,
            'headers' => $this->headers,
            'method' => 'GET'
        ];
    }
}

// We need to bypass the actual include('config.php') in WGDashboard.php
// since it tries to connect to a non-existent database.
// Let's create a temporary copy of WGDashboard.php with include('config.php') removed.
$wgDashboardContent = file_get_contents(__DIR__ . '/../WGDashboard.php');
$wgDashboardContent = str_replace("include('config.php');", "", $wgDashboardContent);
file_put_contents(__DIR__ . '/WGDashboard_mock.php', $wgDashboardContent);

// Mock select function
function select($table, $field, $whereField, $whereValue, $type) {
    if ($table === 'marzban_panel' && $whereField === 'name_panel' && $whereValue === 'test_panel') {
        return [
            'url_panel' => 'http://test-panel.local',
            'inboundid' => 'test-inbound',
            'password_panel' => 'test-api-key'
        ];
    }
    return false;
}

// Load WGDashboard
require_once __DIR__ . '/WGDashboard_mock.php';

// Test downloadconfig
$result = downloadconfig('test_panel', 'test-public+key=');

$passed = true;
$expected_url = 'http://test-panel.local/api/downloadPeer/test-inbound?id=test-public%2Bkey%3D';
if (strpos($result['url'], $expected_url) !== false) {
    // success
} else {
    echo "  FAIL - URL incorrect. Expected '{$expected_url}', got '{$result['url']}'.\n";
    $passed = false;
}

if (in_array('wg-dashboard-apikey: test-api-key', $result['headers'])) {
    // success
} else {
    echo "  FAIL - API key header missing.\n";
    $passed = false;
}

// Clean up
unlink(__DIR__ . '/WGDashboard_mock.php');

if (!$passed) {
    echo "── 0 passed, 2 failed ──\n";
    exit(1);
}
echo "── 2 passed, 0 failed ──\n";
