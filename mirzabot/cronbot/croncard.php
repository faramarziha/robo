<?php
ini_set('error_log', 'error_log');
date_default_timezone_set('Asia/Tehran');

if (!defined('TESTING')) {
    require_once __DIR__ . '/../config.php';
    require_once __DIR__ . '/../botapi.php';
    require_once __DIR__ . '/../panels.php';
    require_once __DIR__ . '/../function.php';
    require_once __DIR__ . '/../keyboard.php';
    require __DIR__ . '/../vendor/autoload.php';
    require_once __DIR__ . '/../jdf.php';
}

if (!class_exists('ManagePanel')) {
    class ManagePanel {}
}
if (!function_exists('select')) {
    function select($table, $col1 = '*', $col2 = null, $val = null, $type = 'select') {
        if ($table === 'setting') return ['Bot_Status' => 'on', 'timeauto_not_verify' => 1, 'Channel_Report' => ''];
        if ($table === 'PaySetting' && $val === 'autoconfirmcart') return ['ValuePay' => 'onauto'];
        if ($table === 'topicid') return ['idreport' => 1];
        if ($table === 'PaySetting' && $val === 'Exception_auto_cart') return ['ValuePay' => '[]'];
        if ($table === 'PaySetting' && $val === 'chashbackcart') return ['ValuePay' => '10'];
        return null;
    }
}
if (!function_exists('update')) {
    function update() { return true; }
}
if (!function_exists('languagechange')) {
    function languagechange() { return ['common' => ['labels' => ['autoConfirmedByBot' => 'Auto']], 'users' => ['Balance' => ['giftDeposit' => 'Gift %s']], 'Admin' => ['reportgroup' => ['newPaymentAutoConfirm' => 'Report %s %s %s']]]; }
}
if (!function_exists('DirectPayment')) {
    function DirectPayment() { return true; }
}
if (!function_exists('sendmessage')) {
    function sendmessage() { return true; }
}
if (!function_exists('telegram')) {
    function telegram() { return true; }
}

$ManagePanel = new ManagePanel();
$setting = select("setting", "*");
if ($setting['Bot_Status'] == "botstatusoff")
    return;
$autoconfirm = select("PaySetting", "ValuePay", "NamePay", "autoconfirmcart", "select")['ValuePay'];
if ($autoconfirm != "onauto")
    return;
$paymentreports = select("topicid", "idreport", "report", "paymentreport", "select")['idreport'];

$stmt = $pdo->prepare("SELECT * FROM Payment_report WHERE payment_Status = 'waiting' AND (Payment_Method = 'cart to cart' OR Payment_Method = 'arze digital offline') AND bottype IS NULL");
$stmt->execute();
$rows = $stmt->fetchAll(PDO::FETCH_ASSOC);

$userMap = [];
if (!empty($rows)) {
    $userIds = array_unique(array_column($rows, 'id_user'));
    $placeholders = implode(',', array_fill(0, count($userIds), '?'));
    $userStmt = $pdo->prepare("SELECT * FROM user WHERE id IN ($placeholders)");
    $userStmt->execute(array_values($userIds));
    $users = $userStmt->fetchAll(PDO::FETCH_ASSOC);
    foreach ($users as $u) {
        $userMap[$u['id']] = $u;
    }
}

$list_Exceptions = select("PaySetting", "ValuePay", "NamePay", "Exception_auto_cart", "select")['ValuePay'];
$list_Exceptions = is_string($list_Exceptions) ? json_decode($list_Exceptions, true) : [];
$pricecashback = select("PaySetting", "ValuePay", "NamePay", "chashbackcart", "select")['ValuePay'];
$textbotlang = languagechange();

foreach ($rows as $row) {
    $timecheck = $setting['timeauto_not_verify'] * 60;
    if ($row['at_updated'] == null)
        continue;
    $since_start = time() - strtotime($row['at_updated']);
    if ($since_start >= 3600)
        continue;
    if ($since_start <= $timecheck)
        continue;
    $Payment_report = $row;
    $Balance_id = $userMap[$Payment_report['id_user']] ?? null;
    if (!$Balance_id)
        continue;
    if (in_array($Balance_id['id'], $list_Exceptions))
        continue;
    if ($Payment_report['payment_Status'] == "paid") {
        continue;
    }
    update("Payment_report", "payment_Status", "paid", "id_order", $Payment_report['id_order']);
    update("Payment_report", "dec_not_confirmed", $textbotlang['common']['labels']['autoConfirmedByBot'], "id_order", $Payment_report['id_order']);
    DirectPayment($Payment_report['id_order'], "../images.jpg");
    
    // Fix leftover N+1: Use batched userMap instead of select() inside loop
    $Balance_id = $userMap[$Payment_report['id_user']] ?? null;
    
    if ($pricecashback != "0") {
        $result = ($Payment_report['price'] * $pricecashback) / 100;
        $Balance_confrim = intval($Balance_id['Balance']) + $result;
        update("user", "Balance", $Balance_confrim, "id", $Balance_id['id']);
        $pricecashback = number_format($pricecashback);
        $text_report = sprintf($textbotlang['users']['Balance']['giftDeposit'], $result);
        sendmessage($Balance_id['id'], $text_report, null, 'HTML');
    }
    $text_reportpayment = sprintf($textbotlang['Admin']['reportgroup']['newPaymentAutoConfirm'], $Balance_id['id'], $Payment_report['price'], $Payment_report['Payment_Method']);
    if (strlen($setting['Channel_Report']) > 0) {
        telegram('sendmessage', [
            'chat_id' => $setting['Channel_Report'],
            'message_thread_id' => $paymentreports,
            'text' => $text_reportpayment,
            'parse_mode' => "HTML"
        ]);
    }
}
