#!/bin/bash
# Test for IBSng disconnect method

cd "$(dirname "$0")" || { echo "Failed to change directory"; }

# Setup a test file
cat << 'PHP' > test_ibsng_disconnect_tmp.php
<?php

// We will mock unlink and curl_close in the namespace radiusApi\Modules
namespace radiusApi\Modules {
    $GLOBALS['unlink_called'] = false;
    $GLOBALS['curl_close_called'] = false;

    function unlink($path) {
        $GLOBALS['unlink_called'] = true;
        return true;
    }

    function curl_close($ch) {
        $GLOBALS['curl_close_called'] = true;
    }

    require_once __DIR__ . '/ibsng/Modules/IBSng.php';

    class TestIBSng extends IBSng {
        public function __construct() {
            // Skip parent constructor to avoid checking curl extension
        }

        public function setHandler($handler) {
            $this->handler = $handler;
        }

        public function setCookiePath($path) {
            $this->cookiePathName = $path;
        }

        public function _getCookie() {
            return $this->getCookie();
        }
    }
}

namespace {
    use radiusApi\Modules\TestIBSng;

    class MockCurlHandler {
        public $closed = false;
    }

    $test = new TestIBSng();
    $test->setCookiePath('/tmp/test_cookie_path_fake');
    $test->setHandler(new MockCurlHandler());

    $test->disconnect();

    $pass = 0;
    $fail = 0;

    if ($GLOBALS['unlink_called']) {
        echo "  ok   - unlink was called\n";
        $pass++;
    } else {
        echo "  FAIL - unlink was NOT called\n";
        $fail++;
    }

    if ($GLOBALS['curl_close_called']) {
        echo "  ok   - curl_close was called\n";
        $pass++;
    } else {
        echo "  FAIL - curl_close was NOT called\n";
        $fail++;
    }

    // Also test without handler
    $GLOBALS['unlink_called'] = false;
    $GLOBALS['curl_close_called'] = false;

    $test2 = new TestIBSng();
    $test2->disconnect();

    if (!$GLOBALS['unlink_called'] && !$GLOBALS['curl_close_called']) {
        echo "  ok   - handler null, functions NOT called\n";
        $pass++;
    } else {
        echo "  FAIL - handler null, functions called\n";
        $fail++;
    }

    echo "\n── $pass passed, $fail failed ──\n";

    if ($fail > 0) {
        die("1");
    }
}
PHP

# Now run the test and capture exit code
php test_ibsng.php
EXIT_CODE=$?
rm test_ibsng.php

# We cannot use exit keyword directly in this environment, but returning the correct code works
(exit $EXIT_CODE)
