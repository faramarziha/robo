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

if (!function_exists('readJsonFileIfExists')) {
    function readJsonFileIfExists($path) {
        return [];
    }
}

class VpnbotKeyboardProductTest extends TestCase
{
    #[RunInSeparateProcess]
    public function testVpnbotKeyboardProductBindsParameters(): void
    {
        global $pdo, $textbotlang;

        $textbotlang = [
            'users' => [
                'customSellVolume' => ['title' => 'حجم سفارشی'],
                'status' => ['backinfo' => 'بازگشت'],
            ],
        ];

        $pdo = $this->createMock(PDO::class);
        $stmt = $this->createMock(PDOStatement::class);

        $preparedQuery = null;
        $pdo->expects($this->once())
            ->method('prepare')
            ->willReturnCallback(function (string $sql) use (&$preparedQuery, $stmt) {
                $preparedQuery = $sql;
                return $stmt;
            });

        $params = [':location' => 'panel-1', ':agent' => 'agent-1'];

        $stmt->expects($this->once())
            ->method('execute')
            ->with($params)
            ->willReturn(true);

        $stmt->method('fetch')->willReturnOnConsecutiveCalls(
            [
                'code_product' => 'ABC123',
                'price_product' => 50000,
                'name_product' => 'Test Plan',
                'hide_panel' => '[]',
            ],
            false
        );

        require __DIR__ . '/../vpnbot/Default/keyboard.php';

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

        $this->assertSame(
            "SELECT * FROM product WHERE (Location = :location OR Location = '/all') AND agent = :agent",
            $preparedQuery
        );
        $this->assertStringNotContainsString('panel-1', $preparedQuery);
        $this->assertStringNotContainsString('agent-1', $preparedQuery);

        $decoded = json_decode($json, true);
        $this->assertIsArray($decoded);
        $this->assertArrayHasKey('inline_keyboard', $decoded);
        $this->assertSame('prodcutservice_ABC123', $decoded['inline_keyboard'][0][0]['callback_data']);
        $this->assertSame('backuser', $decoded['inline_keyboard'][1][0]['callback_data']);
    }
}
