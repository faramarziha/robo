<?php

require_once __DIR__ . '/../Modules/IBSng.php';

use PHPUnit\Framework\TestCase;
use radiusApi\Modules\IBSng;

class IBSngTest extends TestCase
{
    public function testAddUserDelegatesToProtectedMethod()
    {
        // We use a partial mock to intercept the call to the protected _addUser method.
        // PHPUnit can mock protected methods, however since PHPUnit 9+ onlyMethods requires public/protected methods.
        $mock = $this->getMockBuilder(IBSng::class)
            ->disableOriginalConstructor()
            ->onlyMethods(['_addUser'])
            ->getMock();

        // Expect _addUser to be called once with specific arguments in the order
        // defined in the thin wrapper: $group, $username, $password, $credit
        $mock->expects($this->once())
            ->method('_addUser')
            ->with('test_group', 'test_user', 'test_pass', 'test_credit')
            ->willReturn(true);

        // Call the public method.
        // Note: The signature of addUser is ($username, $password, $group, $credit)
        $result = $mock->addUser('test_user', 'test_pass', 'test_group', 'test_credit');

        // Assert that the wrapper returns what the protected method returned.
        $this->assertTrue($result);
    }


    public function testDeleteUserDelegatesToProtectedMethod()
    {
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
