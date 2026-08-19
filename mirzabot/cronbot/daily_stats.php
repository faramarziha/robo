<?php
ini_set('error_log', 'error_log');
date_default_timezone_set('Asia/Tehran');

if (!defined('TESTING')) {
    require_once __DIR__ . '/../config.php';
    require_once __DIR__ . '/../botapi.php';
    require_once __DIR__ . '/../function.php';
}

// F11 — Daily sales report posted to the report channel.
// Aggregates from Payment_report (payment_Status='paid'), whose `time` column
// is populated as 'Y/m/d H:i:s'. invoice.time_sell is not reliably populated,
// so it is deliberately not used here.
// Additive feature file: read-only aggregation, never mutates balances.

$textbotlang = languagechange();
$setting = select("setting", "*");

$yesterday = date('Y/m/d', strtotime('-1 day'));
$prefix = $yesterday . '%';
$dayStartTs = strtotime(date('Y-m-d', strtotime('-1 day')));

// Paid orders + revenue yesterday
$stmt = $pdo->prepare(
    "SELECT COUNT(*) AS c, COALESCE(SUM(price), 0) AS s
     FROM Payment_report WHERE payment_Status = 'paid' AND time LIKE :prefix"
);
$stmt->execute([':prefix' => $prefix]);
$row = $stmt->fetch(PDO::FETCH_ASSOC);
$orderCount = (int) ($row['c'] ?? 0);
$revenue = (int) ($row['s'] ?? 0);

// New users yesterday (user.register is a Unix timestamp)
$stmt = $pdo->prepare("SELECT COUNT(*) AS c FROM user WHERE register >= :ts");
$stmt->execute([':ts' => $dayStartTs]);
$newUsers = (int) ($stmt->fetch(PDO::FETCH_ASSOC)['c'] ?? 0);

// Top plans yesterday (join through the invoice for the product name)
$stmt = $pdo->prepare(
    "SELECT i.name_product, COUNT(*) AS c
     FROM Payment_report p JOIN invoice i ON i.id_invoice = p.id_invoice
     WHERE p.payment_Status = 'paid' AND p.time LIKE :prefix
     GROUP BY i.name_product ORDER BY c DESC LIMIT 5"
);
$stmt->execute([':prefix' => $prefix]);
$top = $stmt->fetchAll(PDO::FETCH_ASSOC);
$topLines = [];
foreach ($top as $t) {
    $topLines[] = (string) ($t['name_product'] ?? '-') . ' × ' . (int) $t['c'];
}
$topText = $topLines === [] ? '-' : implode("\n", $topLines);

$reportRow = select("topicid", "idreport", "report", "paymentreport", "select");
$reportId = is_array($reportRow) && isset($reportRow['idreport']) ? $reportRow['idreport'] : null;

$body = strtr(
    $textbotlang['features']['dailyStatsBody'] ?? "📊 Sales report {date}\n💰 Revenue: {revenue}\n🧾 Orders: {orders}\n👥 New users: {users}\n\n🏆 Top plans:\n{top}",
    ['{date}' => $yesterday, '{revenue}' => number_format($revenue), '{orders}' => $orderCount, '{users}' => $newUsers, '{top}' => $topText]
);

$channel = isset($setting['Channel_Report']) ? (string) $setting['Channel_Report'] : '';
if ($channel !== '') {
    telegram('sendmessage', [
        'chat_id' => $channel,
        'message_thread_id' => $reportId,
        'text' => $body,
        'parse_mode' => 'HTML',
    ]);
}
