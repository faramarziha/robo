<?php
ini_set('error_log', 'error_log');
require_once __DIR__ . '/../config.php';
require_once __DIR__ . '/../botapi.php';
require_once __DIR__ . '/../panels.php';
require_once __DIR__ . '/../function.php';
require_once __DIR__ . '/../keyboard.php';
require_once __DIR__ . '/../jdf.php';
require __DIR__ . '/../vendor/autoload.php';

$ManagePanel = new ManagePanel();



function paymentHeaderValue(array $headers, string $name): ?string
{
    foreach ($headers as $key => $value) {
        if (strcasecmp((string) $key, $name) === 0) {
            return is_array($value) ? (string) reset($value) : (string) $value;
        }
    }

    return null;
}

function nowpaymentsSignaturePayload(array $data): string
{
    ksort($data);
    return json_encode($data, JSON_UNESCAPED_SLASHES);
}

function nowpaymentsIpnSignatureValid(array $data, array $headers): bool
{
    $secretRow = select("PaySetting", "ValuePay", "NamePay", "ipn_secret_nowpayment", "select");
    $secret = is_array($secretRow) ? trim((string) ($secretRow['ValuePay'] ?? '')) : '';
    if ($secret === '') {
        error_log('nowpayment.php: ipn_secret_nowpayment is not configured; falling back to status re-check only.');
        return true;
    }

    $signature = paymentHeaderValue($headers, 'x-nowpayments-sig');
    if (!is_string($signature) || trim($signature) === '') {
        return false;
    }

    $calculated = hash_hmac('sha512', nowpaymentsSignaturePayload($data), $secret);
    return hash_equals($calculated, trim($signature));
}

$headers = getallheaders();
$setting = select("setting", "*");
$paymentreports = topicId('paymentreport');
$textbotlang = languagechange();
$data = json_decode(file_get_contents("php://input"), true);

if (!is_array($data) || empty($data['payment_id'])) {
    http_response_code(400);
    return;
}

if (!nowpaymentsIpnSignatureValid($data, $headers)) {
    http_response_code(403);
    return;
}

if (($data['payment_status'] ?? '') !== "finished") {
    return;
}

$pay = StatusPayment($data['payment_id']);
if (!is_array($pay) || ($pay['payment_status'] ?? '') !== "finished" || empty($pay['invoice_id'])) {
    return;
}

$Payment_report = select("Payment_report", "*", "dec_not_confirmed", $pay['invoice_id'], "select", ['cache' => false]);
if (!is_array($Payment_report)) {
    error_log('nowpayment.php: payment report not found for invoice ' . $pay['invoice_id']);
    return;
}

if (!empty($pay['order_id']) && (string) $pay['order_id'] !== (string) $Payment_report['id_order']) {
    error_log('nowpayment.php: order mismatch for payment ' . $data['payment_id']);
    return;
}

if (!settleOrderOnce($Payment_report['id_order'])) {
    return;
}

DirectPayment($Payment_report['id_order'], "../images.jpg");
$Balance_id = select("user", "*", "id", $Payment_report['id_user'], "select", ['cache' => false]);
$cashback = applyPaymentCashback($Payment_report['id_user'], $Payment_report['price'], "cashbacknowpayment");
if ($cashback > 0 && is_array($Balance_id)) {
    $text_report = sprintf($textbotlang['paymentGateway']['giftReport'], $cashback);
    sendmessage($Balance_id['id'], $text_report, null, 'HTML');
}

$Balance_id = is_array($Balance_id) ? $Balance_id : ['username' => '', 'id' => $Payment_report['id_user']];
$text_reportpayment = sprintf($textbotlang['paymentGateway']['reportNowpayment'], $Balance_id['username'], $Balance_id['id'], $Payment_report['price'], $pay['actually_paid'] ?? '');
if (strlen((string) ($setting['Channel_Report'] ?? '')) > 0) {
    telegram('sendmessage', [
        'chat_id' => $setting['Channel_Report'],
        'message_thread_id' => $paymentreports,
        'text' => $text_reportpayment,
        'parse_mode' => "HTML"
    ]);
}
