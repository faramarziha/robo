<?php

use PHPUnit\Framework\TestCase;

require_once __DIR__ . '/../inc/audit_log.php';

class AdminLogTest extends TestCase
{
    public function testLogAdminInsertsParameterizedRow(): void
    {
        global $pdo;

        $pdo = $this->createMock(PDO::class);
        $stmt = $this->createMock(PDOStatement::class);

        $pdo->expects($this->once())
            ->method('prepare')
            ->with(
                "INSERT INTO admin_logs (admin_id, action, target, ip, at) VALUES (:admin_id, :action, :target, :ip, NOW())"
            )
            ->willReturn($stmt);

        $stmt->expects($this->once())
            ->method('execute')
            ->with([
                ':admin_id' => 'admin-user',
                ':action' => 'user_delete',
                ':target' => '42',
                ':ip' => null,
            ])
            ->willReturn(true);

        $this->assertTrue(logAdmin('user_delete', '42', 'admin-user'));
    }

    public function testLogAdminFallsBackToSessionAdmin(): void
    {
        global $pdo;

        $_SESSION['admin_user'] = 'session-admin';

        $pdo = $this->createMock(PDO::class);
        $stmt = $this->createMock(PDOStatement::class);

        $pdo->expects($this->once())
            ->method('prepare')
            ->willReturn($stmt);

        $stmt->expects($this->once())
            ->method('execute')
            ->with([
                ':admin_id' => 'session-admin',
                ':action' => 'login_success',
                ':target' => null,
                ':ip' => null,
            ])
            ->willReturn(true);

        $this->assertTrue(logAdmin('login_success'));

        unset($_SESSION['admin_user']);
    }

    public function testLogAdminJsonEncodesNonStringTarget(): void
    {
        global $pdo;

        $pdo = $this->createMock(PDO::class);
        $stmt = $this->createMock(PDOStatement::class);

        $pdo->expects($this->once())
            ->method('prepare')
            ->willReturn($stmt);

        $stmt->expects($this->once())
            ->method('execute')
            ->with([
                ':admin_id' => 'admin-user',
                ':action' => 'price_change',
                ':target' => '{"code":"PLAN1","price":50000}',
                ':ip' => null,
            ])
            ->willReturn(true);

        $this->assertTrue(logAdmin('price_change', ['code' => 'PLAN1', 'price' => 50000], 'admin-user'));
    }
}
