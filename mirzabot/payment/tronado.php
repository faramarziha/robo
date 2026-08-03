<?php
ini_set('error_log', 'error_log');
require_once __DIR__ . '/../config.php';
require_once __DIR__ . '/../jdf.php';
require_once __DIR__ . '/../botapi.php';
require_once __DIR__ . '/../Marzban.php';
require_once __DIR__ . '/../function.php';
require_once __DIR__ . '/../panels.php';
require_once __DIR__ . '/../keyboard.php';
require __DIR__ . '/../vendor/autoload.php';
use Endroid\QrCode\Builder\Builder;
use Endroid\QrCode\Encoding\Encoding;
use Endroid\QrCode\ErrorCorrectionLevel;
use Endroid\QrCode\Label\Font\OpenSans;
use Endroid\QrCode\Label\LabelAlignment;
use Endroid\QrCode\RoundBlockSizeMode;
use Endroid\QrCode\Writer\PngWriter;

$ManagePanel = new ManagePanel();
$data = json_decode(file_get_contents("php://input"), true);
if (!is_array($data) || empty($data['PaymentID']) || empty($data['Hash'])) {
    http_response_code(400);
    return;
}
$Payment_report = paymentReportByOrder($data['PaymentID']);
if (!$Payment_report)
    return;
$apitronseller = select("PaySetting", "*", "NamePay", "apiternado", "select")['ValuePay'];
if ($Payment_report['payment_Status'] == "expire")
    return;
$setting = select("setting", "*", null, null, "select");
$price = $Payment_report['price'];
if ($Payment_report['payment_Status'] != "paid") {
    $headers = [
        'Content-Type' => "application/json",
        'x-api-key' => $apitronseller
    ];
    $req = new CurlRequest("https://bot.tronado.cloud/Order/GetStatus");
    $req->setHeaders($headers);
    $hashParts = explode('TrndOrderID_', (string) $data['Hash'], 2);
    if (count($hashParts) !== 2 || $hashParts[1] === '') {
        http_response_code(400);
        return;
    }
    $order_id = $hashParts[1];
    $response = $req->post(array('id' => $order_id));
    $response = is_string($response['body']) ? json_decode($response['body'], true) : false;
    if ($response && !empty($response['IsPaid']) && !empty($data['IsPaid']) && isset($data['TronAmount'], $response['TronAmount']) && $data['TronAmount'] == $response['TronAmount'] && settleOrderOnce($Payment_report['id_order'])) {
        echo json_encode(array("status" => true));
        $textbotlang = languagechange();
        DirectPayment($data['PaymentID'], "../images.jpg");
        $cashback = applyPaymentCashback($Payment_report['id_user'], $Payment_report['price'], "chashbackiranpay2");
        $Balance_id = select("user", "*", "id", $Payment_report['id_user'], "select", ['cache' => false]);
        if ($cashback > 0 && is_array($Balance_id)) {
            $text_report = sprintf($textbotlang['paymentGateway']['giftReport'], $cashback);
            sendmessage($Balance_id['id'], $text_report, null, 'HTML');
        }
        $paymentreports = select("topicid", "idreport", "report", "paymentreport", "select")['idreport'];
        $balancelow = "";
        if ($data['TronAmount'] < $data['ActualTronAmount']) {
            $balancelow = $textbotlang['paymentGateway']['lowAmount'];
        }
        $text_reportpayment = sprintf($textbotlang['paymentGateway']['reportTronado'], $balancelow, $Balance_id['username'], $Balance_id['id'], $price, $data['Hash'], $data['TronAmount']);
        $database = json_encode($data);
        $statement = $pdo->prepare("UPDATE Payment_report SET dec_not_confirmed = :dec_not_confirmed WHERE id_order = :id_order");
        $statement->bindValue(':dec_not_confirmed', $database);
        $statement->bindValue(':id_order', $Payment_report['id_order']);
        $statement->execute();
        clearSelectCache('Payment_report');
        if (strlen($setting['Channel_Report']) > 0) {
            telegram('sendmessage', [
                'chat_id' => $setting['Channel_Report'],
                'message_thread_id' => $paymentreports,
                'text' => $text_reportpayment,
                'parse_mode' => "HTML"
            ]);
        }
    }
}