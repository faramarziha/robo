<?php

use PHPUnit\Framework\Attributes\RunInSeparateProcess;
use PHPUnit\Framework\TestCase;

if (!defined('TESTING')) {
    define('TESTING', true);
}

// creditBalance() lives in function.php, which has no TESTING guard and is not
// loaded by this test. Stub it so redeemGiftCode()'s credit path is observable.
if (!function_exists('creditBalance')) {
    function creditBalance($userId, $amount)
    {
        global $GIFT_TEST_CREDITS;
        $GIFT_TEST_CREDITS[] = [$userId, (int) $amount];
        return (int) $amount;
    }
}

class GiftCodesTest extends TestCase
{
    #[RunInSeparateProcess]
    public function testGenerateGiftCodesInsertsBoundCodes(): void
    {
        global $pdo;

        $pdo = $this->createMock(PDO::class);
        $stmt = $this->createMock(PDOStatement::class);

        $preparedSql = null;
        $pdo->expects($this->once())
            ->method('prepare')
            ->willReturnCallback(function (string $sql) use (&$preparedSql, $stmt) {
                $preparedSql = $sql;
                return $stmt;
            });

        $executed = [];
        $stmt->expects($this->exactly(3))
            ->method('execute')
            ->willReturnCallback(function (array $params) use (&$executed) {
                $executed[] = $params;
                return true;
            });

        require __DIR__ . '/../inc/gift_codes.php';

        $codes = generateGiftCodes(3, 50000, 'admin-1');

        $this->assertCount(3, $codes);
        foreach ($codes as $code) {
            // 12 random bytes -> 24 uppercase hex chars.
            $this->assertMatchesRegularExpression('/^[0-9A-F]{24}$/', $code);
        }
        foreach ($executed as $params) {
            $this->assertSame(50000, $params[':value']);
            $this->assertSame('admin-1', $params[':creator']);
            $this->assertArrayHasKey(':code', $params);
        }
        // Placeholder form only — value and creator must never be interpolated.
        $this->assertStringContainsString(':code', $preparedSql);
        $this->assertStringContainsString(':value', $preparedSql);
        $this->assertStringContainsString(':creator', $preparedSql);
    }

    #[RunInSeparateProcess]
    public function testRedeemGiftCodeCreditsOnceAndMarksUsed(): void
    {
        global $pdo, $GIFT_TEST_CREDITS;
        $GIFT_TEST_CREDITS = [];

        $pdo = $this->createMock(PDO::class);
        $claimStmt = $this->createMock(PDOStatement::class);
        $valueStmt = $this->createMock(PDOStatement::class);

        $preparedSql = [];
        $pdo->expects($this->exactly(2))
            ->method('prepare')
            ->willReturnCallback(function (string $sql) use (&$preparedSql, $claimStmt, $valueStmt) {
                $preparedSql[] = $sql;
                return strpos($sql, 'UPDATE gift_codes') !== false ? $claimStmt : $valueStmt;
            });

        $claimStmt->expects($this->once())
            ->method('execute')
            ->with([':uid' => 42, ':code' => 'ABC123'])
            ->willReturn(true);
        $claimStmt->method('rowCount')->willReturn(1);

        $valueStmt->expects($this->once())
            ->method('execute')
            ->with([':code' => 'ABC123'])
            ->willReturn(true);
        $valueStmt->method('fetchColumn')->willReturn('50000');

        require __DIR__ . '/../inc/gift_codes.php';

        $result = redeemGiftCode('ABC123', 42);

        $this->assertSame(50000, $result);
        $this->assertSame([[42, 50000]], $GIFT_TEST_CREDITS);
        // The claim query must be a conditional UPDATE (one-time use) and bound.
        $this->assertStringContainsString("status = 'active'", $preparedSql[0]);
        $this->assertStringNotContainsString('ABC123', $preparedSql[0]);
    }

    #[RunInSeparateProcess]
    public function testRedeemGiftCodeReturnsFalseWhenAlreadyUsed(): void
    {
        global $pdo, $GIFT_TEST_CREDITS;
        $GIFT_TEST_CREDITS = [];

        $pdo = $this->createMock(PDO::class);
        $claimStmt = $this->createMock(PDOStatement::class);

        $pdo->expects($this->once())
            ->method('prepare')
            ->willReturn($claimStmt);
        $claimStmt->method('execute')->willReturn(true);
        $claimStmt->method('rowCount')->willReturn(0);

        require __DIR__ . '/../inc/gift_codes.php';

        $this->assertFalse(redeemGiftCode('USED', 42));
        // No credit when the code is already used / revoked / nonexistent.
        $this->assertSame([], $GIFT_TEST_CREDITS);
    }
}
