-- ============================================================================
-- F22 — Batch gift codes
-- ============================================================================
-- Admin-generated, single-use redemption codes that credit a user's wallet
-- balance. The status column drives one-time use (active → used), enforced by
-- redeemGiftCode()'s conditional UPDATE. Idempotent.
-- Fresh installs also create this table via table.php.
CREATE TABLE IF NOT EXISTS gift_codes (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    code VARCHAR(32) NOT NULL UNIQUE,
    value INT NOT NULL,
    status ENUM('active','used','revoked') NOT NULL DEFAULT 'active',
    created_by VARCHAR(200) NULL,
    used_by VARCHAR(200) NULL,
    used_at DATETIME NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci;
