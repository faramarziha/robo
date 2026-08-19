<?php

use PHPUnit\Framework\Attributes\RunInSeparateProcess;
use PHPUnit\Framework\TestCase;

if (!defined('TESTING')) {
    define('TESTING', true);
}

if (!function_exists('select')) {
    function select($table, $col = '*', $whereCol = null, $whereVal = null, $type = 'select') {
        if ($table === 'shopSetting') {
            return ['value' => 'onshowprice'];
        }
        return [];
    }
}

class FlashDealsTest extends TestCase
{
    #[RunInSeparateProcess]
    public function testFlashDiscountForBindsCodeAndReturnsActiveDiscount(): void
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

        $stmt->expects($this->once())
            ->method('execute')
            ->with([':code' => 'ABC123'])
            ->willReturn(true);
        $stmt->method('fetchColumn')->willReturn(25);

        require __DIR__ . '/../inc/flash_deals.php';

        $this->assertSame(25, flashDiscountFor('ABC123'));
        // The code must be bound, never interpolated into the SQL.
        $this->assertStringContainsString(':code', $preparedSql);
        $this->assertStringNotContainsString('ABC123', $preparedSql);
    }

    #[RunInSeparateProcess]
    public function testFlashDiscountForReturnsZeroWhenNoDealActive(): void
    {
        global $pdo;

        $pdo = $this->createMock(PDO::class);
        $stmt = $this->createMock(PDOStatement::class);

        $pdo->method('prepare')->willReturn($stmt);
        $stmt->method('execute')->willReturn(true);
        $stmt->method('fetchColumn')->willReturn(false);

        require __DIR__ . '/../inc/flash_deals.php';

        $this->assertSame(0, flashDiscountFor('NOPE'));
    }

    #[RunInSeparateProcess]
    public function testKeyboardProductAppliesFlashDiscountToDisplayedPrice(): void
    {
        global $pdo, $from_id, $textbotlang;

        $from_id = 42;
        $textbotlang = [
            'common' => ['labels' => ['toman' => 'تومان']],
            'users' => [
                'customSellVolume' => ['title' => 'حجم سفارشی'],
                'status' => ['backinfo' => 'بازگشت'],
            ],
        ];

        $pdo = $this->createMock(PDO::class);
        $stmt = $this->createMock(PDOStatement::class);
        $invoiceStmt = $this->createMock(PDOStatement::class);
        $flashStmt = $this->createMock(PDOStatement::class);

        $pdo->expects($this->exactly(3))
            ->method('prepare')
            ->willReturnCallback(function (string $sql) use ($stmt, $invoiceStmt, $flashStmt) {
                if (strpos($sql, 'FROM product') !== false) {
                    return $stmt;
                }
                if (strpos($sql, 'FROM flash_deals') !== false) {
                    return $flashStmt;
                }
                return $invoiceStmt;
            });

        $stmt->method('execute')->willReturn(true);
        $stmt->method('fetch')->willReturnOnConsecutiveCalls(
            [
                'hide_panel' => '[]',
                'one_buy_status' => '0',
                'price_product' => 50000,
                'name_product' => 'Test Plan',
                'code_product' => 'ABC123',
            ],
            false
        );

        $invoiceStmt->method('bindValue')->willReturn(true);
        $invoiceStmt->method('execute')->willReturn(true);
        $invoiceStmt->method('rowCount')->willReturn(0);

        // 10% flash deal active for ABC123.
        $flashStmt->method('execute')->willReturn(true);
        $flashStmt->method('fetchColumn')->willReturn(10);

        require __DIR__ . '/../keyboard.php';

        $json = KeyboardProduct(
            'panel-1',
            "SELECT * FROM product WHERE (Location = :location OR Location = '/all') AND agent = :agent",
            0,
            'prodcutservice_',
            false,
            'backuser',
            null,
            'customsellvolume',
            [':location' => 'panel-1', ':agent' => 'agent-1']
        );

        $decoded = json_decode($json, true);
        $this->assertIsArray($decoded);
        // 50000 - 10% = 45000, rendered as the formatted price with the label.
        $this->assertStringContainsString('45,000', $decoded['inline_keyboard'][0][0]['text']);
        $this->assertStringContainsString('Test Plan', $decoded['inline_keyboard'][0][0]['text']);
    }
}
