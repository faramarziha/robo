-- ============================================================================
-- F31 — Anti-abuse request log
-- ============================================================================
-- Backs rateLimit() so trial / discount / gift-code handlers can reject a user
-- who exceeds an action budget within a time window. Idempotent.
-- Fresh installs also create this table via table.php.
CREATE TABLE IF NOT EXISTS request_log (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    id_user VARCHAR(200) NULL,
    action VARCHAR(100) NOT NULL,
    ip VARCHAR(45) NULL,
    at DATETIME DEFAULT CURRENT_TIMESTAMP,
    KEY idx_user_action (id_user, action, at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci;
