<?php

require_once __DIR__ . '/ibsng/Modules/IBSng.php';

class MockIBSng extends \radiusApi\Modules\IBSng {
    public $loginCalled = false;
    public $shouldThrow = false;

    public function __construct() {
        // Bypass the parent constructor to avoid curl and required params
        $this->isConnected = false;
    }

    protected function login() {
        $this->loginCalled = true;
        if ($this->shouldThrow) {
            throw new \Exception("Can't login to IBSng. Wrong username or password");
        }
        return true;
    }

    public function setIsConnected($val) {
        $this->isConnected = $val;
    }
}

$pass = 0;
$fail = 0;

function assertEqual($expected, $actual, $msg) {
    global $pass, $fail;
    if ($expected === $actual) {
        $pass++;
    } else {
        echo "FAIL: $msg. Expected: " . var_export($expected, true) . ", Actual: " . var_export($actual, true) . "\n";
        $fail++;
    }
}

function testConnectAlreadyConnected() {
    $ibsng = new MockIBSng();
    $ibsng->setIsConnected(true);

    $result = $ibsng->connect();

    assertEqual(true, $result, "connect() should return true when already connected");
    assertEqual(false, $ibsng->loginCalled, "login() should not be called if already connected");
}

function testConnectSuccess() {
    $ibsng = new MockIBSng();
    $ibsng->setIsConnected(false);
    $ibsng->shouldThrow = false;

    $result = $ibsng->connect();

    assertEqual(true, $result, "connect() should return true upon successful login");
    assertEqual(true, $ibsng->loginCalled, "login() should be called if not connected");
    assertEqual(true, $ibsng->isConnected(), "isConnected should be set to true after successful connection");
}

function testConnectException() {
    global $pass, $fail;
    $ibsng = new MockIBSng();
    $ibsng->setIsConnected(false);
    $ibsng->shouldThrow = true;

    try {
        $ibsng->connect();
        echo "FAIL: Exception should have been thrown\n";
        $fail++;
    } catch (\Exception $e) {
        if ($e->getMessage() === "Can't login to IBSng. Wrong username or password") {
            $pass++;
        } else {
            echo "FAIL: Unexpected exception message: " . $e->getMessage() . "\n";
            $fail++;
        }
    }

    assertEqual(true, $ibsng->loginCalled, "login() should be called if not connected");
    assertEqual(false, $ibsng->isConnected(), "isConnected should remain false after failed connection");
}

try {
    testConnectAlreadyConnected();
    testConnectSuccess();
    testConnectException();
} catch (\Exception $e) {
    echo "FAIL: Uncaught exception: " . $e->getMessage() . "\n";
    $fail++;
}

if ($fail > 0) {
    echo "── $pass passed, $fail failed ──\n";
    exit(1);
} else {
    echo "── $pass passed, $fail failed ──\n";
    exit(0);
}
