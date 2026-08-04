<?php

use PHPUnit\Framework\TestCase;
use radiusApi\Modules\IBSng;

class IBSngTest extends TestCase
{
    public function testListUser()
    {
        // We will create a partial mock of IBSng to test listUser
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
}
