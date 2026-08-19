<?php

/**
 * Anti-abuse rate limiter (F31).
 *
 * Returns true and records the attempt when the user has performed $action
 * fewer than $max times in the last $windowSeconds. Returns false (and does
 * not record) once the limit is reached. The SQL is fully parameterized.
 */
function rateLimit($userId, $action, $max, $windowSeconds)
{
    global $pdo;

    $max = (int) $max;
    $cutoff = time() - (int) $windowSeconds;

    $stmt = $pdo->prepare(
        "SELECT COUNT(*) FROM request_log WHERE id_user = :id_user AND action = :action AND at >= FROM_UNIXTIME(:cutoff)"
    );
    $stmt->execute([
        ':id_user' => $userId,
        ':action' => $action,
        ':cutoff' => $cutoff,
    ]);
    $count = (int) $stmt->fetchColumn();

    if ($count >= $max) {
        return false;
    }

    $stmt = $pdo->prepare(
        "INSERT INTO request_log (id_user, action, ip, at) VALUES (:id_user, :action, :ip, NOW())"
    );
    $stmt->execute([
        ':id_user' => $userId,
        ':action' => $action,
        ':ip' => $_SERVER['REMOTE_ADDR'] ?? null,
    ]);

    return true;
}
