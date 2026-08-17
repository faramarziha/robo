-- ============================================================================
-- MirzaBot — 40-Feature Roadmap: Database Schema
-- ============================================================================
-- This file is the single source of truth for every schema change the 40
-- features need. Run it ONCE on an existing installation. Fresh installs
-- should merge these statements into table.php / install.sh.
--
-- MySQL 8 note: `ADD COLUMN IF NOT EXISTS` is not supported, so ALTER
-- statements are written idempotently the same way table.php does it
-- (SHOW COLUMNS guard in PHP) or documented as "run once".
--
-- Money rule: every new column that holds balance/value must only be written
-- through creditBalance()/debitBalanceIfSufficient()/settleOrderOnce().
-- ============================================================================

-- ---------------------------------------------------------------------------
-- F01 — Auto-Renew (تمدید خودکار)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS auto_renew_cards (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    id_user VARCHAR(200) NOT NULL,
    gateway VARCHAR(50) NOT NULL,            -- zarinpal | aqayepardakht | tetra | ...
    card_token TEXT NULL,                    -- token از درگاه
    card_last4 VARCHAR(10) NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_user_gateway (id_user, gateway)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ALTER user ADD COLUMN auto_renew_enabled TINYINT(1) NOT NULL DEFAULT 0;   -- run once
-- ALTER invoice ADD COLUMN auto_renew TINYINT(1) NOT NULL DEFAULT 0;        -- run once

-- ---------------------------------------------------------------------------
-- F02 — Family/Team Plan
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS family_plans (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    owner_user VARCHAR(200) NOT NULL,
    plan_code VARCHAR(200) NOT NULL,
    volume_total BIGINT NOT NULL DEFAULT 0,   -- بایت
    volume_used BIGINT NOT NULL DEFAULT 0,
    max_members INT NOT NULL DEFAULT 3,
    status VARCHAR(20) NOT NULL DEFAULT 'active',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ALTER invoice ADD COLUMN family_id INT NULL;   -- run once
-- ALTER user ADD COLUMN family_id INT NULL;      -- run once

-- ---------------------------------------------------------------------------
-- F03 — کوپن پیشرفته
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS coupons (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    code VARCHAR(64) NOT NULL UNIQUE,
    type ENUM('percent','fixed') NOT NULL DEFAULT 'percent',
    value INT NOT NULL,
    plan_code VARCHAR(200) NULL,               -- NULL = همه پلن‌ها
    max_uses INT NOT NULL DEFAULT 1,
    used_count INT NOT NULL DEFAULT 0,
    first_purchase_only TINYINT(1) NOT NULL DEFAULT 0,
    expires_at DATETIME NULL,
    created_by VARCHAR(200) NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- F04 — Trial محدود
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS trial_users (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    id_user VARCHAR(200) NOT NULL,
    username VARCHAR(300) NULL,
    panel VARCHAR(300) NULL,
    volume_limit BIGINT NOT NULL DEFAULT 0,    -- 0 = نامحدود
    time_limit INT NOT NULL DEFAULT 0,         -- ساعت؛ 0 = نامحدود
    started_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    expires_at DATETIME NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'active',
    followup_step TINYINT NOT NULL DEFAULT 0,  -- F28
    UNIQUE KEY uniq_user (id_user)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ALTER user ADD COLUMN trial_used TINYINT(1) NOT NULL DEFAULT 0;  -- run once

-- ---------------------------------------------------------------------------
-- F06 — اسنپ‌شات مصرف (گراف مینی‌اپ)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS usage_snapshots (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    id_user VARCHAR(200) NOT NULL,
    username VARCHAR(300) NULL,
    panel VARCHAR(300) NULL,
    used_gb DECIMAL(12,3) NOT NULL DEFAULT 0,
    at DATETIME DEFAULT CURRENT_TIMESTAMP,
    KEY idx_user_at (id_user, at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- F07 — تیکتینگ
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tickets (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    ticket_no VARCHAR(20) NOT NULL UNIQUE,     -- T-0001
    id_user VARCHAR(200) NOT NULL,
    subject VARCHAR(300) NULL,
    status ENUM('open','answered','closed') NOT NULL DEFAULT 'open',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS ticket_messages (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    ticket_id INT NOT NULL,
    sender ENUM('user','admin') NOT NULL,
    admin_id VARCHAR(200) NULL,
    text TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    KEY idx_ticket (ticket_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- F08 — FAQ
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS faq_items (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    keyword VARCHAR(100) NOT NULL,             -- کلیدواژه برای تطبیق
    lang VARCHAR(5) NOT NULL DEFAULT 'fa',
    answer TEXT NOT NULL,
    sort INT NOT NULL DEFAULT 0
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- F12/F40 — سلامت پنل‌ها (history)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS panel_health_log (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    panel VARCHAR(300) NOT NULL,
    status ENUM('up','down','degraded') NOT NULL,
    latency_ms INT NULL,
    active_invoices INT NULL,
    limit_panel INT NULL,
    checked_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    KEY idx_panel_at (panel, checked_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ALTER marzban_panel ADD COLUMN capacity_warn_pct INT NOT NULL DEFAULT 80;  -- run once
-- ALTER marzban_panel ADD COLUMN failover_group VARCHAR(100) NULL;            -- F18, run once
-- ALTER marzban_panel ADD COLUMN lb_weight INT NOT NULL DEFAULT 1;            -- F17, run once
-- ALTER marzban_panel ADD COLUMN load_factor DECIMAL(3,2) NOT NULL DEFAULT 1.00; -- F25, run once

-- ---------------------------------------------------------------------------
-- F13 — RBAC
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rbac_roles (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(50) NOT NULL UNIQUE,          -- owner | support | finance
    permissions JSON NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ALTER admin ADD COLUMN role VARCHAR(50) NOT NULL DEFAULT 'owner';  -- run once

-- ---------------------------------------------------------------------------
-- F15 — A/B تست قیمت
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ab_tests (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    variant_a_pct DECIMAL(5,2) NOT NULL DEFAULT 50,
    starts_at DATETIME NULL,
    ends_at DATETIME NULL,
    status ENUM('draft','running','ended') NOT NULL DEFAULT 'draft'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ALTER user ADD COLUMN ab_variant VARCHAR(1) NULL;  -- run once

-- ---------------------------------------------------------------------------
-- F19 — دعوت دوطرفه
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS referral_log (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    referrer VARCHAR(200) NOT NULL,
    referee VARCHAR(200) NOT NULL,
    bonus_type ENUM('balance','volume','discount') NOT NULL,
    bonus_value VARCHAR(100) NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_referee (referee)          -- هر نفر فقط یک‌بار هدیه
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ALTER user ADD COLUMN referred_by VARCHAR(200) NULL;  -- run once

-- ---------------------------------------------------------------------------
-- F21 — Sub-link یکپارچه
-- ---------------------------------------------------------------------------
-- ALTER user ADD COLUMN sub_token VARCHAR(64) NULL UNIQUE;  -- run once

-- ---------------------------------------------------------------------------
-- F22 — کد گیفت
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS gift_codes (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    code VARCHAR(32) NOT NULL UNIQUE,
    value INT NOT NULL,
    status ENUM('active','used','revoked') NOT NULL DEFAULT 'active',
    created_by VARCHAR(200) NULL,
    used_by VARCHAR(200) NULL,
    used_at DATETIME NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- F23 — اقساط
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS installments (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    id_order VARCHAR(200) NOT NULL,
    id_user VARCHAR(200) NOT NULL,
    total INT NOT NULL,
    paid INT NOT NULL DEFAULT 0,
    installments INT NOT NULL,
    status ENUM('active','completed','overdue','cancelled') NOT NULL DEFAULT 'active',
    due_dates JSON NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ALTER invoice ADD COLUMN installment_id INT NULL;  -- run once

-- ---------------------------------------------------------------------------
-- F24 — تخفیف فلش
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS flash_deals (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    product_code VARCHAR(200) NOT NULL,
    discount_pct INT NOT NULL,
    starts_at DATETIME NOT NULL,
    ends_at DATETIME NOT NULL,
    status ENUM('scheduled','active','ended') NOT NULL DEFAULT 'scheduled'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- F26 — انتقال P2P
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS p2p_transfers (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    from_user VARCHAR(200) NOT NULL,
    to_user VARCHAR(200) NULL,
    code VARCHAR(16) NOT NULL UNIQUE,
    amount INT NOT NULL,
    status ENUM('pending','done','expired') NOT NULL DEFAULT 'pending',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    done_at DATETIME NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- F31 — ضدسواستفاده
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS request_log (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    id_user VARCHAR(200) NULL,
    action VARCHAR(100) NOT NULL,
    ip VARCHAR(45) NULL,
    at DATETIME DEFAULT CURRENT_TIMESTAMP,
    KEY idx_user_action (id_user, action, at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ALTER user ADD COLUMN device_id VARCHAR(128) NULL;  -- run once

-- ---------------------------------------------------------------------------
-- F32 — Developer API
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS api_keys (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    api_key VARCHAR(128) NOT NULL UNIQUE,
    label VARCHAR(100) NOT NULL,
    scopes JSON NULL,
    revoked TINYINT(1) NOT NULL DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- F34 — لاگ امنیتی
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS admin_logs (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    admin_id VARCHAR(200) NULL,
    action VARCHAR(200) NOT NULL,
    target TEXT NULL,
    ip VARCHAR(45) NULL,
    at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- F05 — امتیاز وفاداری
-- ---------------------------------------------------------------------------
-- ستون user.score از قبل وجود دارد؛ جدول نرخ تبدیل:
CREATE TABLE IF NOT EXISTS loyalty_rewards (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    points INT NOT NULL,
    value INT NOT NULL,                        -- تومان قابل تبدیل
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- F38 — Telegram Stars
-- ---------------------------------------------------------------------------
-- بدون تغییر اسکیما: Payment_Method = 'Stars' در Payment_report موجود.
-- ستون‌های stars_auto_rate / stars_margin از قبل در PaySetting هستند
-- (function.php:2051-2066).

-- ============================================================================
-- END — run `mysql < schema.sql` once on an existing installation.
-- ============================================================================
