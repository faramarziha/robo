<?php
ini_set('error_log', 'error_log');
date_default_timezone_set('Asia/Tehran');

if (!defined('TESTING')) {
    require_once __DIR__ . '/../config.php';
    require_once __DIR__ . '/../botapi.php';
    require_once __DIR__ . '/../panels.php';
    require_once __DIR__ . '/../function.php';
}
$ManagePanel = new ManagePanel();


$stmt = $pdo->prepare("SELECT id FROM user WHERE checkstatus = '1' ORDER BY RAND() LIMIT 10");
$stmt->execute();
$users = $stmt->fetchAll(PDO::FETCH_ASSOC);

if (!empty($users)) {
    $userIds = array_column($users, 'id');
    $placeholders = implode(',', array_fill(0, count($userIds), '?'));
    
    // N+1 SELECT fix
    // We get all invoices for all these users in one query.
    // The previous logic used 'ORDER BY RAND() LIMIT 10' per user.
    // We will just fetch all 'disablebyadmin' invoices for these users.
    $stmts = $pdo->prepare("SELECT * FROM invoice WHERE id_user IN ($placeholders) AND Status = 'disablebyadmin'");
    $stmts->execute($userIds);
    $all_invoices = $stmts->fetchAll(PDO::FETCH_ASSOC);

    // Map invoices to users
    $invoices_by_user = [];
    foreach ($all_invoices as $inv) {
        $invoices_by_user[$inv['id_user']][] = $inv;
    }

    $invoices_to_update = [];
    foreach ($users as $result) {
        $user_id = $result['id'];
        if (empty($invoices_by_user[$user_id])) {
            update("user", "checkstatus", "0", "id", $user_id);
            continue;
        }

        $user_invoices = $invoices_by_user[$user_id];
        // To preserve original behavior exactly, take up to 10 randomly
        if (count($user_invoices) > 10) {
            shuffle($user_invoices);
            $user_invoices = array_slice($user_invoices, 0, 10);
        }

        foreach ($user_invoices as $invoice) {
            // ManagePanel API constraints - genuine external N+1 constraint.
            // Leaving this as per-row calls as requested.
            $get_username_Check = $ManagePanel->DataUser($invoice['Service_location'], $invoice['username']);
            if ($get_username_Check['status'] == "disabled") {
                $userchengestatus = $ManagePanel->Change_status($invoice['username'], $invoice['Service_location']);
            }
            $invoices_to_update[] = $invoice['id_invoice'];
        }
    }

    // N+1 UPDATE fix
    if (!empty($invoices_to_update)) {
        $updatePlaceholders = implode(',', array_fill(0, count($invoices_to_update), '?'));
        $updateStmt = $pdo->prepare("UPDATE invoice SET Status = 'active' WHERE id_invoice IN ($updatePlaceholders)");
        $updateStmt->execute($invoices_to_update);
    }
}
