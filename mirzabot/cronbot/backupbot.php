<?php
ini_set('error_log', 'error_log');
date_default_timezone_set('Asia/Tehran');

if (!defined('TESTING')) {
    require_once '../config.php';
    require_once '../function.php';
    $textbotlang = languagechange();
    require_once '../botapi.php';
}

// Keep this many daily backup_*.sql / backup_*.zip files on disk. Older files
// are pruned at the end of each run so the bot keeps a bounded local history
// in addition to the copy it sends to Telegram.
const BACKUP_RETENTION_DAYS = 7;

/**
 * Delete backup_*.sql / backup_*.zip files in $dir whose mtime is older than
 * $keepDays days. Returns the number of files removed.
 */
function pruneOldBackups($dir, $keepDays = BACKUP_RETENTION_DAYS)
{
    $removed = 0;
    $cutoff = time() - ($keepDays * 86400);
    $base = rtrim($dir, '/\\');
    $files = array_merge(
        glob($base . '/backup_*.sql') ?: [],
        glob($base . '/backup_*.zip') ?: []
    );
    foreach ($files as $file) {
        if (is_file($file) && filemtime($file) < $cutoff) {
            if (@unlink($file)) {
                $removed++;
            }
        }
    }
    return $removed;
}

if (!defined('TESTING')) {
    $reportbackup = select("topicid", "idreport", "report", "backupfile", "select")['idreport'];
    $destination = getcwd();
    $setting = select("setting", "*");
    $sourcefir = dirname($destination);
    $botlist = select("botsaz", "*", null, null, "fetchAll");
    if ($botlist) {
        foreach ($botlist as $bot) {
            $folderName = $bot['id_user'] . $bot['username'];
            $zipFile = sys_get_temp_dir() . '/mirzabot_agent_' . preg_replace('/[^A-Za-z0-9_-]/', '_', $folderName) . '_' . bin2hex(random_bytes(4)) . '.zip';
            $paths = [
                "$sourcefir/vpnbot/$folderName/data",
                "$sourcefir/vpnbot/$folderName/product.json",
                "$sourcefir/vpnbot/$folderName/product_name.json",
            ];
            $zipCommand = 'zip -r ' . escapeshellarg($zipFile);
            foreach ($paths as $path) {
                $zipCommand .= ' ' . escapeshellarg($path);
            }
            shell_exec($zipCommand);
            telegram('sendDocument', [
                'chat_id' => $setting['Channel_Report'],
                'message_thread_id' => $reportbackup,
                'document' => new CURLFile($zipFile),
                'caption' => "@{$bot['username']} | {$bot['id_user']}",
            ]);
            @unlink($zipFile);
        }
    }

    $backup_file_name = 'backup_' . date("Y-m-d") . '.sql';
    $dbhost = empty($dbhost) ? "localhost" : $dbhost;
    $defaultsFile = tempnam(sys_get_temp_dir(), 'mirzabot_mysql_');
    file_put_contents($defaultsFile, "[client]\npassword=" . str_replace(["\\", "\n", "\r"], ["\\\\", "", ""], $passworddb) . "\n");
    @chmod($defaultsFile, 0600);
    $command = "mysqldump --defaults-extra-file=" . escapeshellarg($defaultsFile) . " -h " . escapeshellarg($dbhost) . " -u " . escapeshellarg($usernamedb) . " --no-tablespaces --ssl-mode=DISABLED " . escapeshellarg($dbname) . " > " . escapeshellarg($backup_file_name);

    $output = [];
    $return_var = 0;
    exec($command, $output, $return_var);
    @unlink($defaultsFile);
    if ($return_var !== 0) {
        telegram('sendmessage', [
            'chat_id' => $setting['Channel_Report'],
            'message_thread_id' => $reportbackup,
            'text' => $textbotlang['keyboard']['backupError'],
        ]);
    } else {
        telegram('sendDocument', [
            'chat_id' => $setting['Channel_Report'],
            'message_thread_id' => $reportbackup,
            'document' => new CURLFile($backup_file_name),
            'caption' => $textbotlang['Admin']['report']['backupCaption'],
        ]);
    }

    // Retain the local dump instead of deleting it, and rotate out anything
    // older than BACKUP_RETENTION_DAYS.
    pruneOldBackups($destination, BACKUP_RETENTION_DAYS);
}
