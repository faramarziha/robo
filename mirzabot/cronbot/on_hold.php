<?php
ini_set('error_log', 'error_log');
date_default_timezone_set('Asia/Tehran');
require_once __DIR__ . '/../config.php';
require_once __DIR__ . '/../botapi.php';
require_once __DIR__ . '/../panels.php';
require_once __DIR__ . '/../function.php';
$textbotlang = languagechange();
$ManagePanel = new ManagePanel();

$setting = select("setting", "*");
// buy service 
$stmt = $pdo->prepare("SELECT * FROM marzban_panel WHERE type = 'marzban'  ORDER BY RAND() LIMIT 25");
$stmt->execute();
while ($panel = $stmt->fetch(PDO::FETCH_ASSOC)) {
    $users_data = getusers($panel['name_panel'], "on_hold");
    $users = $users_data['users'] ?? [];

    if (empty($users)) {
        continue;
    }

    $usernames = array_column($users, 'username');
    $placeholders = implode(',', array_fill(0, count($usernames), '?'));

    // Batch fetch invoices
    $sql_invoices = "SELECT * FROM invoice WHERE username IN ($placeholders)";
    $stmt_invoices = $pdo->prepare($sql_invoices);
    $stmt_invoices->execute($usernames);

    $invoices_by_username = [];
    while ($inv = $stmt_invoices->fetch(PDO::FETCH_ASSOC)) {
        $invoices_by_username[$inv['username']] = $inv;
    }

    // Batch fetch service_other
    $sql_service = "SELECT username FROM service_other WHERE type = 'change_location' AND username IN ($placeholders)";
    $stmt_service = $pdo->prepare($sql_service);
    $stmt_service->execute($usernames);

    $service_other_users = [];
    while ($row = $stmt_service->fetch(PDO::FETCH_ASSOC)) {
        $service_other_users[$row['username']] = true;
    }

    foreach ($users as $user) {
        $line = $user['username'];
        if (!isset($invoices_by_username[$line])) {
            continue;
        }
        $invoice = $invoices_by_username[$line];
        if ($invoice['Status'] == "send_on_hold") {
            continue;
        }

        $resultss = $invoice;
        $marzban_list_get = $panel;
        $get_username_Check = $user;

        if ($get_username_Check['status'] != "Unsuccessful") {
            if (in_array($get_username_Check['status'], ['on_hold'])) {
                $timebuyremin = (time() - $resultss['time_sell']) / 86400;
                if ($timebuyremin >= $setting['on_hold_day']) {
                    if (isset($service_other_users[$line])) {
                        continue;
                    }
                    $text = sprintf($textbotlang['users']['notify']['onHoldReminder'], $line, $setting['on_hold_day'], $setting['id_support']);
                    sendmessage($resultss['id_user'], $text, null, 'HTML');
                    update("invoice", "Status", "send_on_hold", "username", $line);
                }
            }
        }
    }
}