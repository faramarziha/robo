<?php
ini_set('error_log', 'error_log');
date_default_timezone_set('Asia/Tehran');

if (!defined('TESTING')) {
    require_once __DIR__ . '/../config.php';
    require_once __DIR__ . '/../botapi.php';
    require_once __DIR__ . '/../function.php';
}

// F12 — Panel health monitoring.
// Warns admins when a VPN panel is unreachable or near its capacity limit.
// Additive feature file: reads marzban_panel, never mutates balances.
// Installer patch_cron_locks() injects the mirza_cron_lock call automatically.

$textbotlang = languagechange();

$stateFile = sys_get_temp_dir() . '/mirzabot_panel_health.json';
$state = [];
if (is_file($stateFile)) {
    $decoded = json_decode((string) file_get_contents($stateFile), true);
    if (is_array($decoded)) {
        $state = $decoded;
    }
}
$today = date('Y-m-d');

$panels = select("marzban_panel", "*", null, null, "fetchAll");
if (!is_array($panels) || $panels === []) {
    return;
}

// Active invoice count per panel — the capacity signal.
$stmt = $pdo->prepare(
    "SELECT Service_location, COUNT(*) AS c FROM invoice
     WHERE Status IN ('active','end_of_time','end_of_volume','sendedwarn','send_on_hold')
     GROUP BY Service_location"
);
$stmt->execute();
$activeCounts = [];
while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
    $activeCounts[$row['Service_location']] = (int) $row['c'];
}

$admin_ids = select("admin", "id_admin", null, null, "FETCH_COLUMN");
if (!is_array($admin_ids)) {
    $admin_ids = [];
}

$warnPct = 80; // mirror of marzban_panel.capacity_warn_pct (schema.sql) until the column ships

foreach ($panels as $panel) {
    $name = isset($panel['name_panel']) ? (string) $panel['name_panel'] : '';
    $url = isset($panel['url_panel']) ? (string) $panel['url_panel'] : '';
    if ($name === '' || $url === '') {
        continue;
    }

    // --- Reachability check (short timeout, any HTTP response = up) ---------
    $ch = curl_init();
    curl_setopt($ch, CURLOPT_URL, $url);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, 4);
    curl_setopt($ch, CURLOPT_TIMEOUT, 6);
    curl_setopt($ch, CURLOPT_NOBODY, true);
    curl_setopt($ch, CURLOPT_FOLLOWLOCATION, true);
    curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false); // TODO: flip on together with the request.php TLS fix
    $start = microtime(true);
    curl_exec($ch);
    $latencyMs = (int) round((microtime(true) - $start) * 1000);
    $errno = curl_errno($ch);
    curl_close($ch);

    $isUp = ($errno === 0);
    $prev = $state[$name] ?? ['status' => 'unknown'];
    $prevStatus = isset($prev['status']) ? (string) $prev['status'] : 'unknown';

    if (!$isUp && $prevStatus !== 'down') {
        $text = strtr($textbotlang['features']['panelHealthDown'] ?? '⚠️ Panel {panel} is unreachable!', ['{panel}' => $name]);
        foreach ($admin_ids as $adminId) {
            sendmessage($adminId, $text, null, 'HTML');
        }
        $state[$name]['status'] = 'down';
    } elseif ($isUp && $prevStatus === 'down') {
        $text = strtr($textbotlang['features']['panelHealthBack'] ?? '✅ Panel {panel} is back online.', ['{panel}' => $name]);
        foreach ($admin_ids as $adminId) {
            sendmessage($adminId, $text, null, 'HTML');
        }
        $state[$name]['status'] = 'up';
    } elseif ($isUp) {
        $state[$name]['status'] = 'up';
    }

    // --- Capacity check: warn once per day per panel -------------------------
    $active = isset($activeCounts[$name]) ? $activeCounts[$name] : 0;
    $limit = isset($panel['limit_panel']) ? (int) $panel['limit_panel'] : 0;
    if ($limit > 0 && $active > 0) {
        $pct = (int) round(($active / $limit) * 100);
        if ($pct >= $warnPct && (isset($prev['capacityDay']) ? $prev['capacityDay'] : '') !== $today) {
            $text = strtr(
                $textbotlang['features']['panelHealthCapacity'] ?? '⚠️ Panel {panel} reached {percent}% capacity ({active}/{limit} users).',
                ['{panel}' => $name, '{percent}' => $pct, '{active}' => $active, '{limit}' => $limit]
            );
            foreach ($admin_ids as $adminId) {
                sendmessage($adminId, $text, null, 'HTML');
            }
            $state[$name]['capacityDay'] = $today;
        }
    }
}

file_put_contents($stateFile, json_encode($state, JSON_UNESCAPED_UNICODE));
