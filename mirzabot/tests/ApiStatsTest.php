<?php

use PHPUnit\Framework\Attributes\RunInSeparateProcess;
use PHPUnit\Framework\TestCase;

if (!defined('TESTING')) {
    define('TESTING', true);
}

class ApiStatsTest extends TestCase
{
    #[RunInSeparateProcess]
    public function testRangeDaysClampsBetweenOneAnd365(): void
    {
        require __DIR__ . '/../api/stats.php';

        $this->assertSame(1, stats_range_days(['days' => 0]));
        $this->assertSame(1, stats_range_days(['days' => -5]));
        $this->assertSame(365, stats_range_days(['days' => 365]));
        $this->assertSame(365, stats_range_days(['days' => 9999]));
        $this->assertSame(7, stats_range_days(['days' => 7]));
        $this->assertSame(30, stats_range_days([]));
        $this->assertSame(30, stats_range_days(['days' => 'not-a-number']));
    }

    #[RunInSeparateProcess]
    public function testSummaryActionQueriesAndJsonShape(): void
    {
        if (!function_exists('validateMethod')) {
            function validateMethod($expected, $actual) {
            }
        }
        if (!function_exists('sendJsonResponse')) {
            function sendJsonResponse($status, $message, $data = [], $httpCode = 200) {
                $GLOBALS['lastJsonResponse'] = [
                    'status' => $status,
                    'message' => $message,
                    'data' => $data,
                    'httpCode' => $httpCode,
                ];
                throw new RuntimeException('sendJsonResponse');
            }
        }

        global $pdo;
        $pdo = $this->createMock(PDO::class);

        $summaryStmt = $this->createMock(PDOStatement::class);
        $dailyStmt = $this->createMock(PDOStatement::class);
        $usersStmt = $this->createMock(PDOStatement::class);
        $topStmt = $this->createMock(PDOStatement::class);

        $prepared = [];
        $pdo->expects($this->exactly(4))
            ->method('prepare')
            ->willReturnCallback(function (string $sql) use (&$prepared, $summaryStmt, $dailyStmt, $usersStmt, $topStmt) {
                $prepared[] = $sql;
                if (strpos($sql, 'DATE(time)') !== false) {
                    return $dailyStmt;
                }
                if (strpos($sql, 'register >=') !== false) {
                    return $usersStmt;
                }
                if (strpos($sql, 'JOIN invoice') !== false) {
                    return $topStmt;
                }
                return $summaryStmt;
            });

        $expectedSince = date('Y/m/d H:i:s', strtotime('-7 days'));
        $expectedSinceTs = strtotime(date('Y-m-d', strtotime('-7 days')));

        $summaryStmt->expects($this->once())->method('execute')->with([':since' => $expectedSince])->willReturn(true);
        $summaryStmt->method('fetch')->willReturn(['orders' => 12, 'revenue' => 999000]);

        $dailyStmt->expects($this->once())->method('execute')->with([':since' => $expectedSince])->willReturn(true);
        $dailyStmt->method('fetchAll')->willReturn([['d' => '2026/08/18', 'orders' => 5, 'revenue' => 400000]]);

        $usersStmt->expects($this->once())->method('execute')->with([':ts' => $expectedSinceTs])->willReturn(true);
        $usersStmt->method('fetch')->willReturn(['c' => 3]);

        $topStmt->expects($this->once())->method('execute')->with([':since' => $expectedSince])->willReturn(true);
        $topStmt->method('fetchAll')->willReturn([['name_product' => 'Gold', 'c' => 2]]);

        require __DIR__ . '/../api/stats.php';

        try {
            stats_summary(['days' => 7], 'GET');
            $this->fail('Expected sendJsonResponse to be invoked');
        } catch (RuntimeException $e) {
            // expected
        }

        $resp = $GLOBALS['lastJsonResponse'];
        $this->assertTrue($resp['status']);
        $this->assertSame('Successful', $resp['message']);
        $this->assertSame(7, $resp['data']['days']);
        $this->assertSame(12, $resp['data']['orders']);
        $this->assertSame(999000, $resp['data']['revenue']);
        $this->assertSame(3, $resp['data']['new_users']);
        $this->assertCount(1, $resp['data']['daily']);
        $this->assertCount(1, $resp['data']['top_plans']);

        $this->assertStringContainsString('time >= :since', $prepared[0]);
        $this->assertStringContainsString('register >= :ts', $prepared[2]);
    }

    #[RunInSeparateProcess]
    public function testRecentActionClampsLimitAndReturnsRows(): void
    {
        if (!function_exists('validateMethod')) {
            function validateMethod($expected, $actual) {
            }
        }
        if (!function_exists('sendJsonResponse')) {
            function sendJsonResponse($status, $message, $data = [], $httpCode = 200) {
                $GLOBALS['lastJsonResponse'] = [
                    'status' => $status,
                    'message' => $message,
                    'data' => $data,
                    'httpCode' => $httpCode,
                ];
                throw new RuntimeException('sendJsonResponse');
            }
        }

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

        // limit 9999 is clamped to 100 and bound as an integer.
        $stmt->expects($this->once())->method('bindValue')->with(':limit', 100, PDO::PARAM_INT)->willReturn(true);
        $stmt->expects($this->once())->method('execute')->willReturn(true);
        $stmt->method('fetchAll')->willReturn([
            ['id_user' => 1, 'id_order' => 'o1', 'price' => 50000],
        ]);

        require __DIR__ . '/../api/stats.php';

        try {
            stats_recent(['limit' => 9999], 'GET');
            $this->fail('Expected sendJsonResponse to be invoked');
        } catch (RuntimeException $e) {
            // expected
        }

        $this->assertStringContainsString('LIMIT :limit', $preparedSql);

        $resp = $GLOBALS['lastJsonResponse'];
        $this->assertTrue($resp['status']);
        $this->assertCount(1, $resp['data']);
        $this->assertSame('o1', $resp['data'][0]['id_order']);
    }

    #[RunInSeparateProcess]
    public function testRequireApiTokenOrAdminSessionBlocksUnauthenticated(): void
    {
        if (!function_exists('sendJsonResponse')) {
            function sendJsonResponse($status, $message, $data = [], $httpCode = 200) {
                $GLOBALS['lastJsonResponse'] = [
                    'status' => $status,
                    'message' => $message,
                    'data' => $data,
                    'httpCode' => $httpCode,
                ];
                throw new RuntimeException('sendJsonResponse');
            }
        }
        if (!function_exists('hasAdminSession')) {
            function hasAdminSession() {
                return false;
            }
        }

        require __DIR__ . '/../api/utils.php';

        try {
            requireApiTokenOrAdminSession([]);
            $this->fail('Expected unauthenticated request to be blocked');
        } catch (RuntimeException $e) {
            // expected
        }

        $resp = $GLOBALS['lastJsonResponse'];
        $this->assertFalse($resp['status']);
        $this->assertSame('token invalid', $resp['message']);
        $this->assertSame([], $resp['data']);
        $this->assertSame(403, $resp['httpCode']);
    }
}
