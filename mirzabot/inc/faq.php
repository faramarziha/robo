<?php

/**
 * FAQ chatbot helper (F08).
 *
 * Matches a free-text question against faq_items keywords for the user's
 * language and returns the best answer, or null when nothing matches. The SQL
 * is fully parameterized; keyword is a column value, never interpolated.
 * Ordering prefers admin-set `sort`, then the most specific (longest) keyword.
 */
function matchFaq($text, $lang = 'fa')
{
    global $pdo;

    $text = trim($text);
    if ($text === '') {
        return null;
    }

    $stmt = $pdo->prepare(
        "SELECT answer FROM faq_items
         WHERE lang = :lang AND :text LIKE CONCAT('%', keyword, '%')
         ORDER BY sort ASC, CHAR_LENGTH(keyword) DESC, id ASC
         LIMIT 1"
    );
    $stmt->execute([':lang' => $lang, ':text' => $text]);
    $answer = $stmt->fetchColumn();

    return $answer === false ? null : $answer;
}
