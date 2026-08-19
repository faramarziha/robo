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

class KeyboardProductTest extends TestCase
{
    #[RunInSeparateProcess]
    public function testKeyboardProductBindsParametersInsteadOfInterpolating(): void
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

        $preparedQueries = [];
        $pdo->expects($this->exactly(2))
            ->method('prepare')
            ->willReturnCallback(function (string $sql) use (&$preparedQueries, $stmt, $invoiceStmt) {
                $preparedQueries[] = $sql;
                return strpos($sql, 'FROM product') !== false ? $stmt : $invoiceStmt;
            });

        $params = [':location' => 'panel-1', ':agent' => 'agent-1'];

        $stmt->expects($this->once())
            ->method('execute')
            ->with($params)
            ->willReturn(true);

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
            $params
        );

        // The SQL handed to PDO must be the placeholder form — never the values.
        $this->assertSame(
            "SELECT * FROM product WHERE (Location = :location OR Location = '/all') AND agent = :agent",
            $preparedQueries[0]
        );
        $this->assertStringNotContainsString('panel-1', $preparedQueries[0]);
        $this->assertStringNotContainsString('agent-1', $preparedQueries[0]);

        $decoded = json_decode($json, true);
        $this->assertIsArray($decoded);
        $this->assertArrayHasKey('inline_keyboard', $decoded);
        $this->assertSame('prodcutservice_ABC123', $decoded['inline_keyboard'][0][0]['callback_data']);
        $this->assertStringContainsString('Test Plan', $decoded['inline_keyboard'][0][0]['text']);
        $this->assertSame('backuser', $decoded['inline_keyboard'][1][0]['callback_data']);
    }
}
