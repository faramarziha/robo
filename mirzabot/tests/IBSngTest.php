<?php

namespace radiusApi\Modules {
    $mockFsockopenReturn = null;
    $mockFsockopenCalled = 0;
    $mockFsockopenArgs = [];

    function fsockopen($hostname, $port) {
        global $mockFsockopenReturn, $mockFsockopenCalled, $mockFsockopenArgs;
        $mockFsockopenCalled++;
        $mockFsockopenArgs = ['hostname' => $hostname, 'port' => $port];
        return $mockFsockopenReturn;
    }
}

namespace Tests {
    use PHPUnit\Framework\TestCase;
    use radiusApi\Modules\IBSng;

    class TestableIBSng extends IBSng {
        public function __construct(array $loginArray) {
            // We just need to initialize safely
            $this->loginData = $loginArray;
            $this->hostname = $loginArray['hostname'] ?? 'localhost';
            $this->port = $loginArray['port'] ?? 1234;
        }

        public function callHostNameHealth($hostname = false, $port = false) {
            return $this->hostNameHealth($hostname, $port);
        }

        public function getPort() {
            return $this->port;
        }

        public function getHostname() {
            return $this->hostname;
        }
    }

    class IBSngTest extends TestCase {
        protected function setUp(): void {
            global $mockFsockopenReturn, $mockFsockopenCalled, $mockFsockopenArgs;
            $mockFsockopenReturn = false;
            $mockFsockopenCalled = 0;
            $mockFsockopenArgs = [];
        }

        public function testHostNameHealthWithProvidedArgs() {
            global $mockFsockopenReturn, $mockFsockopenCalled, $mockFsockopenArgs;

            $ibsng = new TestableIBSng([
                'username' => 'testuser',
                'password' => 'testpass',
                'hostname' => 'default.host',
                'port' => 8080
            ]);

            $mockFsockopenReturn = true; // Simulate successful connection

            $result = $ibsng->callHostNameHealth('custom.host', 9090);

            $this->assertTrue($result);
            $this->assertEquals(1, $mockFsockopenCalled);
            $this->assertEquals('custom.host', $mockFsockopenArgs['hostname']);
            $this->assertEquals(9090, $mockFsockopenArgs['port']);
        }

        public function testHostNameHealthWithDefaultArgs() {
            global $mockFsockopenReturn, $mockFsockopenCalled, $mockFsockopenArgs;

            $ibsng = new TestableIBSng([
                'username' => 'testuser',
                'password' => 'testpass',
                'hostname' => 'default.host',
                'port' => 8080
            ]);

            $mockFsockopenReturn = false; // Simulate failed connection

            $result = $ibsng->callHostNameHealth();

            $this->assertFalse($result);
            $this->assertEquals(1, $mockFsockopenCalled);
            $this->assertEquals('default.host', $mockFsockopenArgs['hostname']);
            $this->assertEquals(8080, $mockFsockopenArgs['port']);
        }
    }
}
