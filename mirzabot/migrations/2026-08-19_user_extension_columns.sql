-- ============================================================================
-- Shared user-table extension columns (F31 / F19 / F04)
-- ============================================================================
-- One migration for all three `user` columns so the three features never race
-- with three separate ALTER statements. Each column is added idempotently via
-- an information_schema guard (MySQL 8 has no ADD COLUMN IF NOT EXISTS).
-- Fresh installs also get these via table.php (addFieldToTable).

-- F31 — anti-abuse device id
SET @col := (SELECT COUNT(*) FROM information_schema.COLUMNS
             WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'user' AND COLUMN_NAME = 'device_id');
SET @sql := IF(@col = 0, 'ALTER TABLE `user` ADD COLUMN `device_id` VARCHAR(128) NULL', 'SELECT 1');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- F19 — two-way referral
SET @col := (SELECT COUNT(*) FROM information_schema.COLUMNS
             WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'user' AND COLUMN_NAME = 'referred_by');
SET @sql := IF(@col = 0, 'ALTER TABLE `user` ADD COLUMN `referred_by` VARCHAR(200) NULL', 'SELECT 1');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- F04 — limited trial
SET @col := (SELECT COUNT(*) FROM information_schema.COLUMNS
             WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'user' AND COLUMN_NAME = 'trial_used');
SET @sql := IF(@col = 0, 'ALTER TABLE `user` ADD COLUMN `trial_used` TINYINT(1) NOT NULL DEFAULT 0', 'SELECT 1');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;
