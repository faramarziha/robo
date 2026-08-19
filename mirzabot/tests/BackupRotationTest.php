<?php

use PHPUnit\Framework\TestCase;

if (!defined('TESTING')) {
    define('TESTING', true);
}

require_once __DIR__ . '/../cronbot/backupbot.php';

class BackupRotationTest extends TestCase
{
    private string $tmpDir;

    protected function setUp(): void
    {
        $this->tmpDir = sys_get_temp_dir() . '/backup_rotation_test_' . bin2hex(random_bytes(6));
        mkdir($this->tmpDir, 0700, true);
    }

    protected function tearDown(): void
    {
        foreach (glob($this->tmpDir . '/*') ?: [] as $file) {
            @unlink($file);
        }
        @rmdir($this->tmpDir);
    }

    public function testPruneOldBackupsRemovesOnlyExpiredSqlAndZipFiles(): void
    {
        $old = time() - (8 * 86400);
        $recent = time() - 86400;

        $oldSql = $this->tmpDir . '/backup_2026-08-01.sql';
        $oldZip = $this->tmpDir . '/backup_2026-08-01.zip';
        $recentSql = $this->tmpDir . '/backup_2026-08-18.sql';
        $recentZip = $this->tmpDir . '/backup_2026-08-18.zip';
        $other = $this->tmpDir . '/notes.txt';

        file_put_contents($oldSql, 'old');
        file_put_contents($oldZip, 'old');
        file_put_contents($recentSql, 'recent');
        file_put_contents($recentZip, 'recent');
        file_put_contents($other, 'keep');

        touch($oldSql, $old);
        touch($oldZip, $old);
        touch($recentSql, $recent);
        touch($recentZip, $recent);
        touch($other, $old);

        $removed = pruneOldBackups($this->tmpDir, 7);

        $this->assertSame(2, $removed);
        $this->assertFileDoesNotExist($oldSql);
        $this->assertFileDoesNotExist($oldZip);
        $this->assertFileExists($recentSql);
        $this->assertFileExists($recentZip);
        $this->assertFileExists($other);
    }

    public function testPruneOldBackupsUsesDefaultRetentionConstant(): void
    {
        $ancient = time() - (30 * 86400);
        $file = $this->tmpDir . '/backup_2026-07-01.sql';
        file_put_contents($file, 'x');
        touch($file, $ancient);

        $removed = pruneOldBackups($this->tmpDir);

        $this->assertSame(1, $removed);
        $this->assertFileDoesNotExist($file);
    }
}
