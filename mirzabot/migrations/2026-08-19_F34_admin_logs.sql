-- ============================================================================
-- F34 — Admin audit log
-- ============================================================================
-- Records sensitive admin actions (login, price change, user delete, manual
-- balance changes). Idempotent: safe to run on an existing installation.
-- Fresh installs also create this table via table.php.
CREATE TABLE IF NOT EXISTS admin_logs (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    admin_id VARCHAR(200) NULL,
    action VARCHAR(200) NOT NULL,
    target TEXT NULL,
    ip VARCHAR(45) NULL,
    at DATETIME DEFAULT CURRENT_TIMESTAMP,
    KEY idx_admin_at (admin_id, at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci;
