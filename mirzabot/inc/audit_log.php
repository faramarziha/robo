<?php

/**
 * Admin audit log helper (F34).
 *
 * Appends a row to the admin_logs table. $adminId defaults to the panel
 * session user; the Telegram-bot admin path can pass its own id explicitly.
 * The INSERT is fully parameterized so $action/$target are never interpolated.
 */
function logAdmin($action, $target = null, $adminId = null)
{
    global $pdo;

    if ($adminId === null) {
        $adminId = $_SESSION['admin_user'] ?? null;
    }
    $ip = $_SERVER['REMOTE_ADDR'] ?? null;
    if ($target !== null && !is_string($target)) {
        $target = json_encode($target);
    }

    $stmt = $pdo->prepare(
        "INSERT INTO admin_logs (admin_id, action, target, ip, at) VALUES (:admin_id, :action, :target, :ip, NOW())"
    );
    $stmt->execute([
        ':admin_id' => $adminId,
        ':action' => $action,
        ':target' => $target,
        ':ip' => $ip,
    ]);

    return true;
}
