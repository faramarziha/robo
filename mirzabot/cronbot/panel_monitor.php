<?php
ini_set('error_log', 'error_log');
date_default_timezone_set('Asia/Tehran');

if (!defined('TESTING')) {
    require_once __DIR__ . '/../config.php';
    require_once __DIR__ . '/../botapi.php';
    require_once __DIR__ . '/../panels.php';
    require_once __DIR__ . '/../function.php';
}

$setting = select("setting", "*");
$admins = select("admin", "id_admin");
if (!is_array($admins) || empty($admins)) {
    return; // No admins to notify
}

// Ensure it's an array of arrays
if (isset($admins['id_admin'])) {
    $admins = [$admins];
}

$admin_ids = array_column($admins, 'id_admin');

$stmt = $pdo->prepare("SELECT * FROM marzban_panel");
$stmt->execute();
$panels = $stmt->fetchAll(PDO::FETCH_ASSOC);

if (empty($panels)) {
    return;
}

$textbotlang = languagechange();
$alert_msg = "⚠️ <b>Panel Alert</b> ⚠️\n\nPanel: %s\nStatus: %s";

foreach ($panels as $panel) {
    if ($panel['status'] == 'off') {
        continue; // Skip deliberately disabled panels
    }
    
    $issue = null;
    
    if ($panel['type'] == 'marzban') {
        $stats = Get_System_Stats($panel['name_panel']);
        
        if (!$stats || isset($stats['error']) || empty($stats['cpu_cores'])) {
            $issue = "Unreachable or returning errors.";
        } else {
            // Check capacity: high CPU or memory
            $cpu_usage = isset($stats['cpu_usage']) ? floatval($stats['cpu_usage']) : 0;
            $mem_total = isset($stats['mem_total']) ? floatval($stats['mem_total']) : 0;
            $mem_used = isset($stats['mem_used']) ? floatval($stats['mem_used']) : 0;
            
            $mem_percent = $mem_total > 0 ? ($mem_used / $mem_total) * 100 : 0;
            
            if ($cpu_usage > 90) {
                $issue = "High CPU Usage: " . round($cpu_usage, 2) . "%";
            } elseif ($mem_percent > 90) {
                $issue = "High Memory Usage: " . round($mem_percent, 2) . "%";
            }
        }
    } else {
        // Generic ping for non-marzban panels using DataUser as a health check
        // Or we can just check if url is reachable
        $ManagePanel = new ManagePanel();
        $test_user = "healthcheck_" . time();
        $res = $ManagePanel->DataUser($panel['name_panel'], $test_user);
        
        // If it throws an actual connection error or panel not found error
        if (isset($res['status']) && $res['status'] == 'Unsuccessful' && strpos($res['msg'] ?? '', 'Connection') !== false) {
            $issue = "Unreachable (Connection failed)";
        }
    }
    
    if ($issue) {
        $message = sprintf($alert_msg, $panel['name_panel'], $issue);
        foreach ($admin_ids as $admin_id) {
            sendmessage($admin_id, $message, null, 'HTML');
        }
    }
}
