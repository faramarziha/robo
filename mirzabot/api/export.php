<?php

require_once __DIR__ . '/../config.php';
require_once __DIR__ . '/../function.php';
require_once __DIR__ . '/utils.php';

header('Content-Type: application/json; charset=UTF-8');
date_default_timezone_set('Asia/Tehran');
ini_set('default_charset', 'UTF-8');
ini_set('error_log', 'error_log');

// Validates the API token and logs the request, same as the other api/*.php
// endpoints. Exits with a JSON 403 when the token is missing or wrong.
list($headers, $data, $action) = apiRequestContext();

if ($action !== 'export_gift_codes') {
    sendJsonResponse(false, 'unknown action', [], 404);
}

$status = isset($data['status']) && is_scalar($data['status']) ? (string) $data['status'] : 'active';
if (!in_array($status, ['active', 'used', 'revoked', 'all'], true)) {
    sendJsonResponse(false, 'status invalid', [], 422);
}

if ($status === 'all') {
    $stmt = $pdo->query(
        "SELECT code, value, status, created_by, used_by, used_at, created_at
         FROM gift_codes ORDER BY id"
    );
} else {
    $stmt = $pdo->prepare(
        "SELECT code, value, status, created_by, used_by, used_at, created_at
         FROM gift_codes WHERE status = :status ORDER BY id"
    );
    $stmt->execute([':status' => $status]);
}

header('Content-Type: text/csv; charset=UTF-8');
header('Content-Disposition: attachment; filename="gift_codes_' . $status . '_' . date('Ymd_His') . '.csv"');

$out = fopen('php://output', 'w');
fputcsv($out, ['code', 'value', 'status', 'created_by', 'used_by', 'used_at', 'created_at']);
while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
    fputcsv($out, $row);
}
fclose($out);
exit;
