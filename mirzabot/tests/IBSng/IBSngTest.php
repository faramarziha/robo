<?php

require_once __DIR__ . '/../../ibsng/Modules/IBSng.php';

use PHPUnit\Framework\TestCase;
use radiusApi\Modules\IBSng;

// Create a subclass to mock the login behavior which internally uses request()
class MockIBSng extends IBSng {
    public $loginSuccess = true;

    protected function login() {
        if ($this->loginSuccess) {
            return true;
        }
        throw new \Exception("Can't login to IBSng. Wrong username or password");
    }
}

class IBSngTest extends TestCase {

    private $loginData;

    protected function setUp(): void {
        $this->loginData = [
            'hostname' => 'http://localhost',
            'username' => 'testuser',
            'password' => 'testpass',
            'port' => 80,
            'timeout' => 10
        ];
    }

    public function testIsConnectedInitiallyFalse() {
        $ibsng = new IBSng($this->loginData);
        $this->assertFalse($ibsng->isConnected());
    }

    public function testIsConnectedTrueAfterConnect() {
        $ibsng = new MockIBSng($this->loginData);
        $ibsng->loginSuccess = true;

        $ibsng->connect();

        $this->assertTrue($ibsng->isConnected());
    }

    public function testIsConnectedFalseAfterFailedConnect() {
        $ibsng = new MockIBSng($this->loginData);
        $ibsng->loginSuccess = false;

        try {
            $ibsng->connect();
        } catch (\Exception $e) {
            // Expected
        }

        $this->assertFalse($ibsng->isConnected());
    }

    public function testAutoConnectSetsIsConnected() {
        // By mocking IBSng directly in this test we need to pass true to the constructor
        // or setAutoConnect before we manually construct. Let's create an anonymous class to catch it in constructor.

        $mock = new class($this->loginData) extends MockIBSng {
            public function __construct(array $loginArray) {
                // Set auto connect before calling parent constructor which connects
                $this->autoConnect = true;
                parent::__construct($loginArray);
            }
        };

        $this->assertTrue($mock->isConnected());
    }

    public function testConnectReturnsTrueIfAlreadyConnected() {
        $ibsng = new MockIBSng($this->loginData);
        $ibsng->loginSuccess = true;

        // Connect the first time
        $result1 = $ibsng->connect();
        $this->assertTrue($result1);
        $this->assertTrue($ibsng->isConnected());

        // Disable login success to ensure login() isn't called again
        $ibsng->loginSuccess = false;

        // Connect again, it should return true early because it's already connected
        $result2 = $ibsng->connect();
        $this->assertTrue($result2);
        $this->assertTrue($ibsng->isConnected());
    }
}
