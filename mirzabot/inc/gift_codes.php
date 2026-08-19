<?php

/**
 * Batch gift-code helpers (F22).
 *
 * Admin generates N gift codes at a value and hands them out; a user redeems
 * one to credit their wallet balance. Redemption is one-time-only via an
 * atomic conditional UPDATE (the first caller wins), and the credit goes
 * through the existing atomic creditBalance() helper.
 */

function generateGiftCodes($count, $value, $creator = null)
{
    global $pdo;

    $count = max(1, min((int) $count, 1000));
    $value = max(0, (int) $value);

    $codes = [];
    $stmt = $pdo->prepare(
        "INSERT INTO gift_codes (code, value, created_by) VALUES (:code, :value, :creator)"
    );

    for ($i = 0; $i < $count; $i++) {
        // 12 random bytes = 24 hex chars, well within VARCHAR(32) and
        // effectively collision-free at batch sizes up to a few thousand.
        $code = strtoupper(bin2hex(random_bytes(12)));
        $stmt->execute([':code' => $code, ':value' => $value, ':creator' => $creator]);
        $codes[] = $code;
    }

    return $codes;
}

function redeemGiftCode($code, $userId)
{
    global $pdo;

    $code = trim((string) $code);
    if ($code === '') {
        return false;
    }

    // Atomic claim: only the first caller sees rowCount() === 1, so a code
    // can never be credited twice even under concurrent requests.
    $stmt = $pdo->prepare(
        "UPDATE gift_codes SET status = 'used', used_by = :uid, used_at = NOW()
         WHERE code = :code AND status = 'active'"
    );
    $stmt->execute([':uid' => $userId, ':code' => $code]);
    if ($stmt->rowCount() !== 1) {
        return false;
    }

    $stmt = $pdo->prepare("SELECT value FROM gift_codes WHERE code = :code");
    $stmt->execute([':code' => $code]);
    $value = $stmt->fetchColumn();
    if ($value === false) {
        return false;
    }

    creditBalance($userId, (int) $value);
    return (int) $value;
}
