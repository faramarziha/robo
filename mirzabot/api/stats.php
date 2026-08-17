<?php

require_once __DIR__ . '/../config.php';
require_once __DIR__ . '/../function.php';
require_once __DIR__ . '/utils.php';
$textbotlang = languagechange();
header('Content-Type: application/json');
date_default_timezone_set('Asia/Tehran');
ini_set('default_charset', 'UTF-8');
ini_set('error_log', 'error_log');

$headers = getallheaders();
requireApiTokenOrAdminSession($headers);
$data = normalizeApiInputData();
$action = isset($data['actions']) && is_scalar($data['actions']) ? (string) $data['actions'] : '';
$method = $_SERVER['REQUEST_METHOD'];

// F11 — Admin statistics for the real-time dashboard.
// actions:
//   summary?days=30  → orders, revenue, new users, daily series, top plans
//   recent?limit=20  → latest paid Payment_report rows
//
// Data sources: Payment_report.time ('Y/m/d H:i:s', always populated) for
// money figures; user.register (Unix timestamp) for new users. invoice.time_sell
// is not reliably populated and is deliberately not used.

function stats_range_days(array $data): int
{
    $days = isset($data['days']) && is_numeric($data['days']) ? (int) $data['days'] : 30;
    return min(max($days, 1), 365);
}

function stats_summary(array $data, string $method): void
{
    global $pdo;

    validateMethod('GET', $method);

    $days = stats_range_days($data);
    $since = date('Y/m/d H:i:s', strtotime("-{$days} days"));
    $sinceTs = strtotime(date('Y-m-d', strtotime("-{$days} days")));

    try {
        $stmt = $pdo->prepare(
            "SELECT COUNT(*) AS orders, COALESCE(SUM(price), 0) AS revenue
             FROM Payment_report WHERE payment_Status = 'paid' AND time >= :since"
        );
        $stmt->execute([':since' => $since]);
        $summary = $stmt->fetch(PDO::FETCH_ASSOC);

        $stmt = $pdo->prepare(
            "SELECT DATE(time) AS d, COUNT(*) AS orders, COALESCE(SUM(price), 0) AS revenue
             FROM Payment_report WHERE payment_Status = 'paid' AND time >= :since
             GROUP BY DATE(time) ORDER BY d DESC LIMIT 30"
        );
        $stmt->execute([':since' => $since]);
        $daily = $stmt->fetchAll(PDO::FETCH_ASSOC);

        $stmt = $pdo->prepare("SELECT COUNT(*) AS c FROM user WHERE register >= :ts");
        $stmt->execute([':ts' => $sinceTs]);
        $newUsers = (int) ($stmt->fetch(PDO::FETCH_ASSOC)['c'] ?? 0);

        $stmt = $pdo->prepare(
            "SELECT i.name_product, COUNT(*) AS c
             FROM Payment_report p JOIN invoice i ON i.id_invoice = p.id_invoice
             WHERE p.payment_Status = 'paid' AND p.time >= :since
             GROUP BY i.name_product ORDER BY c DESC LIMIT 5"
        );
        $stmt->execute([':since' => $since]);
        $top = $stmt->fetchAll(PDO::FETCH_ASSOC);

        sendJsonResponse(true, "Successful", [
            'days' => $days,
            'orders' => (int) ($summary['orders'] ?? 0),
            'revenue' => (int) ($summary['revenue'] ?? 0),
            'new_users' => $newUsers,
            'daily' => $daily,
            'top_plans' => $top,
        ]);
    } catch (PDOException $e) {
        error_log('stats summary failed: ' . $e->getMessage());
        sendJsonResponse(false, "query failed", [], 500);
    }
}

function stats_recent(array $data, string $method): void
{
    global $pdo;

    validateMethod('GET', $method);

    $limit = isset($data['limit']) && is_numeric($data['limit']) ? min(max((int) $data['limit'], 1), 100) : 20;

    try {
        $stmt = $pdo->prepare(
            "SELECT id_user, id_order, price, Payment_Method, payment_Status, time
             FROM Payment_report WHERE payment_Status = 'paid'
             ORDER BY id DESC LIMIT :limit"
        );
        $stmt->bindValue(':limit', $limit, PDO::PARAM_INT);
        $stmt->execute();
        $rows = $stmt->fetchAll(PDO::FETCH_ASSOC);

        sendJsonResponse(true, "Successful", $rows);
    } catch (PDOException $e) {
        error_log('stats recent failed: ' . $e->getMessage());
        sendJsonResponse(false, "query failed", [], 500);
    }
}

switch ($action) {
    case 'summary':
        stats_summary($data, $method);
        break;
    case 'recent':
        stats_recent($data, $method);
        break;
    default:
        sendJsonResponse(false, "action invalid", []);
}
