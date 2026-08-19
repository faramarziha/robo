<?php

use PHPUnit\Framework\Attributes\RunInSeparateProcess;
use PHPUnit\Framework\TestCase;

if (!defined('TESTING')) {
    define('TESTING', true);
}

class FaqTest extends TestCase
{
    #[RunInSeparateProcess]
    public function testMatchFaqBindsParametersAndReturnsAnswer(): void
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
            ->with([':lang' => 'fa', ':text' => 'چطور پرداخت کنم؟'])
            ->willReturn(true);
        $stmt->method('fetchColumn')->willReturn('از منوی خرید اقدام کنید.');

        require __DIR__ . '/../inc/faq.php';

        $this->assertSame('از منوی خرید اقدام کنید.', matchFaq('چطور پرداخت کنم؟', 'fa'));
        // The question text and language must be bound, never interpolated.
        $this->assertStringContainsString(':lang', $preparedSql);
        $this->assertStringContainsString(':text', $preparedSql);
        $this->assertStringNotContainsString('چطور پرداخت کنم؟', $preparedSql);
    }

    #[RunInSeparateProcess]
    public function testMatchFaqReturnsNullWhenNoMatch(): void
    {
        global $pdo;

        $pdo = $this->createMock(PDO::class);
        $stmt = $this->createMock(PDOStatement::class);

        $pdo->method('prepare')->willReturn($stmt);
        $stmt->method('execute')->willReturn(true);
        $stmt->method('fetchColumn')->willReturn(false);

        require __DIR__ . '/../inc/faq.php';

        $this->assertNull(matchFaq('سوال بی‌ربط', 'fa'));
    }
}
