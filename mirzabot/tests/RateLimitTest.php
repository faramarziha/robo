<?php

use PHPUnit\Framework\TestCase;

require_once __DIR__ . '/../inc/rate_limit.php';

class RateLimitTest extends TestCase
{
    public function testRateLimitAllowsAndRecordsWhenUnderLimit(): void
    {
        global $pdo;

        $pdo = $this->createMock(PDO::class);
        $selectStmt = $this->createMock(PDOStatement::class);
        $insertStmt = $this->createMock(PDOStatement::class);

        $pdo->expects($this->exactly(2))
            ->method('prepare')
            ->willReturnCallback(function (string $sql) use ($selectStmt, $insertStmt) {
                return strpos($sql, 'SELECT COUNT(*)') === 0 ? $selectStmt : $insertStmt;
            });

        $selectStmt->expects($this->once())
            ->method('execute')
            ->willReturn(true);
        $selectStmt->expects($this->once())
            ->method('fetchColumn')
            ->willReturn(0);

        $insertStmt->expects($this->once())
            ->method('execute')
            ->with([
                ':id_user' => '42',
                ':action' => 'usertest',
                ':ip' => null,
            ])
            ->willReturn(true);

        $this->assertTrue(rateLimit('42', 'usertest', 1, 3600));
    }

    public function testRateLimitBlocksWithoutRecordingWhenLimitReached(): void
    {
        global $pdo;

        $pdo = $this->createMock(PDO::class);
        $selectStmt = $this->createMock(PDOStatement::class);

        // Only the SELECT runs: the blocked path must not issue an INSERT.
        $pdo->expects($this->once())
            ->method('prepare')
            ->with($this->stringStartsWith('SELECT COUNT(*) FROM request_log'))
            ->willReturn($selectStmt);

        $selectStmt->expects($this->once())
            ->method('execute')
            ->willReturn(true);
        $selectStmt->expects($this->once())
            ->method('fetchColumn')
            ->willReturn(3);

        $this->assertFalse(rateLimit('42', 'usertest', 3, 3600));
    }

    public function testRateLimitUsesParameterizedQueries(): void
    {
        global $pdo;

        $pdo = $this->createMock(PDO::class);
        $selectStmt = $this->createMock(PDOStatement::class);

        $pdo->expects($this->once())
            ->method('prepare')
            ->willReturnCallback(function (string $sql) use ($selectStmt) {
                $this->assertStringContainsString(':id_user', $sql);
                $this->assertStringContainsString(':action', $sql);
                $this->assertStringContainsString(':cutoff', $sql);
                $this->assertStringNotContainsString("'42'", $sql);
                $this->assertStringNotContainsString("'usertest'", $sql);
                return $selectStmt;
            });

        $selectStmt->method('execute')->willReturn(true);
        $selectStmt->method('fetchColumn')->willReturn(1);

        rateLimit('42', 'usertest', 2, 3600);
    }
}
