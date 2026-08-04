<?php

namespace radiusApi\Modules {
    class IBSng {
        private $config;
        public static $connectResult = true;
        public static $exceptionToThrow = null;
        public static $disconnectCalled = false;

        public function __construct($config) {
            $this->config = $config;
        }

        public function connect() {
            if (self::$exceptionToThrow !== null) {
                throw self::$exceptionToThrow;
            }
            return self::$connectResult;
        }

        public function disconnect() {
            self::$disconnectCalled = true;
        }

        public function getConfig() {
            return $this->config;
        }
    }
}

namespace {
    use PHPUnit\Framework\TestCase;

    class IBSngTest extends TestCase {

        public static function setUpBeforeClass(): void {
            if (!is_dir(__DIR__ . '/ibsng')) {
                mkdir(__DIR__ . '/ibsng');
            }
            file_put_contents(__DIR__ . '/ibsng/bootstrap.php', "<?php\n// Dummy bootstrap\n");

            set_include_path(__DIR__ . PATH_SEPARATOR . get_include_path());

            require_once __DIR__ . '/../ibsng.php';
        }

        public static function tearDownAfterClass(): void {
            unlink(__DIR__ . '/ibsng/bootstrap.php');
            rmdir(__DIR__ . '/ibsng');
        }

        public function setUp(): void {
            \radiusApi\Modules\IBSng::$connectResult = true;
            \radiusApi\Modules\IBSng::$exceptionToThrow = null;
            \radiusApi\Modules\IBSng::$disconnectCalled = false;
        }

        public function testLoginIBsngSuccess() {
            $result = loginIBsng('http://example.com', 'testuser', 'testpass');

            $this->assertTrue($result['status']);
            $this->assertEquals('Successful login', $result['msg']);
            $this->assertTrue(\radiusApi\Modules\IBSng::$disconnectCalled);
        }

        public function testLoginIBsngFailure() {
            \radiusApi\Modules\IBSng::$connectResult = 'Invalid password';

            $result = loginIBsng('http://example.com', 'testuser', 'testpass');

            $this->assertFalse($result['status']);
            $this->assertEquals('Invalid password', $result['msg']);
            $this->assertTrue(\radiusApi\Modules\IBSng::$disconnectCalled);
        }

        public function testLoginIBsngException() {
            \radiusApi\Modules\IBSng::$exceptionToThrow = new \Exception('Connection refused');

            $result = loginIBsng('http://example.com', 'testuser', 'testpass');

            $this->assertFalse($result['status']);
            $this->assertEquals('Connection refused', $result['msg']);
            $this->assertFalse(\radiusApi\Modules\IBSng::$disconnectCalled);
        }
    }
}
