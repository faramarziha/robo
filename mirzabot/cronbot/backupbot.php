<?php
require_once '../config.php';
require_once '../function.php';
$textbotlang = languagechange();
require_once '../botapi.php';

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
$zip_file_name = 'backup_' . date("Y-m-d") . '.zip';
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
    unlink($backup_file_name);
}