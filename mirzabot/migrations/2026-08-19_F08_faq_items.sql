-- ============================================================================
-- F08 — FAQ chatbot
-- ============================================================================
-- Keyword→answer pairs used by the free-text FAQ matcher in index.php. The
-- bot matches a user question when its text contains a keyword for the user's
-- language; `sort` gives the admin priority control. Idempotent.
-- Fresh installs also create this table via table.php.
CREATE TABLE IF NOT EXISTS faq_items (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    keyword VARCHAR(100) NOT NULL,
    lang VARCHAR(5) NOT NULL DEFAULT 'fa',
    answer TEXT NOT NULL,
    sort INT NOT NULL DEFAULT 0,
    KEY idx_lang_keyword (lang, keyword)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE utf8mb4_unicode_ci;
