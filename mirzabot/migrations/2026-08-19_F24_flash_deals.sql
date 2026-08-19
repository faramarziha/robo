-- ============================================================================
-- F24 — Flash deals
-- ============================================================================
-- Time-boxed percentage discounts applied to specific product codes. The
-- window (starts_at/ends_at) is the source of truth; flashDiscountFor() only
-- returns a discount for a row whose window currently contains NOW().
-- Idempotent: safe to run on an existing installation.
-- Fresh installs also create this table via table.php.
CREATE TABLE IF NOT EXISTS flash_deals (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    product_code VARCHAR(200) NOT NULL,
    discount_pct INT NOT NULL,
    starts_at DATETIME NOT NULL,
    ends_at DATETIME NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'scheduled',
    KEY idx_product_time (product_code, starts_at, ends_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci;
