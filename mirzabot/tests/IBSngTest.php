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

    // کلاس موک اضافه شده از PR #21 جهت شبیه‌سازی لاگین
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
            global $mockFsockopenReturn, $mockFsockopenCalled, $mockFsockopenArgs;
            $mockFsockopenReturn = false;
            $mockFsockopenCalled = 0;
            $mockFsockopenArgs = [];

            // مقداردهی اولیه داده‌های لاگین برای تست‌های PR #21
            $this->loginData = [
                'hostname' => 'http://localhost',
                'username' => 'testuser',
                'password' => 'testpass',
                'port' => 80,
                'timeout' => 10
            ];
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

        // --- تست منتقل شده از PR #20 ---
        public function testListUser() {
            $loginData = [
                'username' => 'test_user',
                'password' => 'test_pass',
                'hostname' => 'http://localhost',
                'port' => 80,
                'timeout' => 10
            ];

            // Mock fetchAllUsers method
            $mock = $this->getMockBuilder(IBSng::class)
                         ->setConstructorArgs([$loginData])
                         ->onlyMethods(['fetchAllUsers'])
                         ->getMock();

            // Expect fetchAllUsers to be called once with arguments 1 and 100
            $mock->expects($this->once())
                 ->method('fetchAllUsers')
                 ->with(1, 100)
                 ->willReturn(['user1', 'user2']);

            // Call listUser and assert the result
            $result = $mock->listUser();
            $this->assertEquals(['user1', 'user2'], $result);
        }

        // --- تست‌های منتقل شده از PR #21 (isConnected) ---
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
            $mock = new class($this->loginData) extends MockIBSng {
                public function __construct(array $loginArray) {
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

        // --- تست‌های منتقل شده از PR #25 (addUser / deleteUser) ---
        public function testAddUserDelegatesToProtectedMethod() {
            $mock = $this->getMockBuilder(IBSng::class)
                ->disableOriginalConstructor()
                ->onlyMethods(['_addUser'])
                ->getMock();

            $mock->expects($this->once())
                ->method('_addUser')
                ->with('test_group', 'test_user', 'test_pass', 'test_credit')
                ->willReturn(true);

            $result = $mock->addUser('test_user', 'test_pass', 'test_group', 'test_credit');

            $this->assertTrue($result);
        }

        public function testDeleteUserDelegatesToProtectedMethod() {
            $mock = $this->getMockBuilder(IBSng::class)
                ->disableOriginalConstructor()
                ->onlyMethods(['_delUser'])
                ->getMock();

            $mock->expects($this->once())
                ->method('_delUser')
                ->with('test_user')
                ->willReturn(true);

            $result = $mock->deleteUser('test_user');

            $this->assertTrue($result);
        }
    }
}
