<?php

use PHPUnit\Framework\Attributes\RunInSeparateProcess;
use PHPUnit\Framework\TestCase;

if (!defined('TESTING')) {
    define('TESTING', true);
}

class DailyStatsTest extends TestCase
{
    #[RunInSeparateProcess]
    public function testDailyStatsQueriesAndReportMessage(): void
    {
        if (!function_exists('languagechange')) {
            function languagechange() {
                return [];
            }
        }
        if (!function_exists('select')) {
            function select($table, $col = '*', $whereCol = null, $whereVal = null, $type = 'select') {
                if ($table === 'setting') {
                    return ['Channel_Report' => '@report'];
                }
                if ($table === 'topicid') {
                    return ['idreport' => 42];
                }
                return [];
            }
        }
        if (!function_exists('telegram')) {
            function telegram($method, $payload) {
                $GLOBALS['telegram_calls'][] = ['method' => $method, 'payload' => $payload];
            }
        }

        $GLOBALS['telegram_calls'] = [];
        global $pdo;

        $pdo = $this->createMock(PDO::class);
        $revStmt = $this->createMock(PDOStatement::class);
        $usersStmt = $this->createMock(PDOStatement::class);
        $topStmt = $this->createMock(PDOStatement::class);

        $pdo->expects($this->exactly(3))
            ->method('prepare')
            ->willReturnCallback(function (string $sql) use ($revStmt, $usersStmt, $topStmt) {
                if (strpos($sql, 'SUM(price)') !== false) {
                    return $revStmt;
                }
                if (strpos($sql, 'register >=') !== false) {
                    return $usersStmt;
                }
                return $topStmt;
            });

        $expectedPrefix = date('Y/m/d', strtotime('-1 day')) . '%';
        $expectedTs = strtotime(date('Y-m-d', strtotime('-1 day')));

        // Paid orders + revenue yesterday: date-prefix parameter.
        $revStmt->expects($this->once())->method('execute')->with([':prefix' => $expectedPrefix])->willReturn(true);
        $revStmt->method('fetch')->willReturn(['c' => 3, 's' => 150000]);

        // New users yesterday: Unix timestamp boundary.
        $usersStmt->expects($this->once())->method('execute')->with([':ts' => $expectedTs])->willReturn(true);
        $usersStmt->method('fetch')->willReturn(['c' => 7]);

        // Top plans: result rows map into the report message.
        $topStmt->expects($this->once())->method('execute')->with([':prefix' => $expectedPrefix])->willReturn(true);
        $topStmt->method('fetchAll')->willReturn([
            ['name_product' => 'Gold', 'c' => 5],
            ['name_product' => 'Silver', 'c' => 3],
        ]);

        require __DIR__ . '/../cronbot/daily_stats.php';

        $this->assertCount(1, $GLOBALS['telegram_calls']);
        $call = $GLOBALS['telegram_calls'][0];
        $this->assertSame('sendmessage', $call['method']);
        $this->assertSame('@report', $call['payload']['chat_id']);
        $this->assertSame(42, $call['payload']['message_thread_id']);

        $text = $call['payload']['text'];
        $this->assertStringContainsString('150,000', $text);
        $this->assertStringContainsString('Gold × 5', $text);
        $this->assertStringContainsString('Silver × 3', $text);
    }
}
