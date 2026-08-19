<?php

/**
 * Flash-deal discount helper (F24).
 *
 * Returns the active discount percentage for a product code, or 0 when no
 * flash_deals row currently covers it. The time window (starts_at/ends_at) is
 * the source of truth; the SQL is fully parameterized.
 */
function flashDiscountFor($productCode)
{
    global $pdo;

    $stmt = $pdo->prepare(
        "SELECT discount_pct FROM flash_deals
         WHERE product_code = :code AND starts_at <= NOW() AND ends_at >= NOW()
         ORDER BY discount_pct DESC LIMIT 1"
    );
    $stmt->execute([':code' => $productCode]);
    $pct = $stmt->fetchColumn();

    return $pct === false ? 0 : (int) $pct;
}
