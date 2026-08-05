<?php
ini_set('error_log', 'error_log');
require_once __DIR__ . '/../config.php';
require_once __DIR__ . '/../jdf.php';
require_once __DIR__ . '/../botapi.php';
require_once __DIR__ . '/../Marzban.php';
require_once __DIR__ . '/../function.php';
require_once __DIR__ . '/../keyboard.php';
require_once __DIR__ . '/../panels.php';
require __DIR__ . '/../vendor/autoload.php';
use Endroid\QrCode\Builder\Builder;
use Endroid\QrCode\Encoding\Encoding;
use Endroid\QrCode\ErrorCorrectionLevel;
use Endroid\QrCode\Label\Font\OpenSans;
use Endroid\QrCode\Label\LabelAlignment;
use Endroid\QrCode\RoundBlockSizeMode;
use Endroid\QrCode\Writer\PngWriter;

$ManagePanel = new ManagePanel();
$textbotlang = languagechange();
$payload = json_decode(file_get_contents("php://input"), true);
$payment_status = $textbotlang['paymentGateway']['statusFailed'] ?? 'پرداخت ناموفق بود';
$dec_payment_status = '';
$price = 0;
$invoice_id = '';

if (!is_array($payload) || empty($payload['hashid']) || empty($payload['authority']) || !isset($payload['status'])) {
    http_response_code(400);
    $dec_payment_status = 'اطلاعات تراکنش ناقص است.';
} else {
    $hashid = htmlspecialchars(trim((string) $payload['hashid']), ENT_QUOTES, 'UTF-8');
    $authority = trim((string) $payload['authority']);
    $StatusPayment = $payload['status'];
    $setting = select("setting", "*");
    $PaySetting = select("PaySetting", "*", "NamePay", "marchent_floypay", "select")['ValuePay'];
    $Payment_reports = paymentReportByOrder($hashid);
    if (!is_array($Payment_reports)) {
        http_response_code(404);
        $dec_payment_status = 'سفارش یافت نشد.';
    } else {
        $invoice_id = $Payment_reports['id_order'];
        $price = $Payment_reports['price'];
        if ((string) $StatusPayment === '100') {
            $curl = curl_init();
            $verifyPayload = ["ApiKey" => $PaySetting, "authority" => $authority, "hashid" => $invoice_id];
            curl_setopt_array($curl, [
                CURLOPT_URL => "https://tetra98.com/api/verify",
                CURLOPT_RETURNTRANSFER => true,
                CURLOPT_ENCODING => '',
                CURLOPT_MAXREDIRS => 10,
                CURLOPT_TIMEOUT => 10,
                CURLOPT_FOLLOWLOCATION => true,
                CURLOPT_HTTP_VERSION => CURL_HTTP_VERSION_1_1,
                CURLOPT_POSTFIELDS => json_encode($verifyPayload),
                CURLOPT_CUSTOMREQUEST => 'POST',
                CURLOPT_HTTPHEADER => ['Content-Type: application/json', 'Accept: application/json'],
            ]);
            $response = json_decode((string) curl_exec($curl), true);
            curl_close($curl);
            if (is_array($response) && !empty($response['status']) && (string) $response['status'] === '100') {
                $payment_status = $textbotlang['paymentGateway']['statusSuccess'];
                $dec_payment_status = $textbotlang['paymentGateway']['descThanks'];
                $Payment_report = paymentReportByOrder($invoice_id);
                if (is_array($Payment_report) && settleOrderOnce($Payment_report['id_order'])) {
                    DirectPayment($invoice_id, "../images.jpg");
                    $cashback = applyPaymentCashback($Payment_report['id_user'], $Payment_report['price'], "chashbackiranpay1");
                    $Balance_id = select("user", "*", "id", $Payment_report['id_user'], "select", ['cache' => false]);
                    if ($cashback > 0 && is_array($Balance_id)) {
                        $text_report = sprintf($textbotlang['paymentGateway']['giftReport'], $cashback);
                        sendmessage($Balance_id['id'], $text_report, null, 'HTML');
                    }
                    $paymentreports = topicId('paymentreport');
                    $text_report = sprintf($textbotlang['paymentGateway']['reportIranpay'], $Payment_report['id_user'], is_array($Balance_id) ? $Balance_id['username'] : '', number_format((float) $price));
                    if (strlen((string) ($setting['Channel_Report'] ?? '')) > 0) {
                        telegram('sendmessage', ['chat_id' => $setting['Channel_Report'], 'message_thread_id' => $paymentreports, 'text' => $text_report, 'parse_mode' => "HTML"]);
                    }
                }
            }
        }
    }
}
?>
<html>

<head>
    <title><?php echo $textbotlang['paymentGateway']['invoiceTitle'] ?></title>
    <style>
        @font-face {
            font-family: 'vazir';
            src: url('/Vazir.eot');
            src: local('☺'), url('../fonts/Vazir.woff') format('woff'), url('../fonts/Vazir.ttf') format('truetype');
        }

        body {
            font-family: vazir;
            background-color: #f2f2f2;
            margin: 0;
            padding: 20px;
            display: flex;
            justify-content: center;
            align-items: center;
            min-height: 100vh;
        }

        .confirmation-box {
            background-color: #ffffff;
            border-radius: 8px;
            width: 25%;
            box-shadow: 0 2px 10px rgba(0, 0, 0, 0.1);
            padding: 40px;
            text-align: center;
        }

        h1 {
            color: #333333;
            margin-bottom: 20px;
        }

        p {
            color: #666666;
            margin-bottom: 10px;
        }
    </style>
</head>

<body>
    <div class="confirmation-box">
        <h1><?php echo $payment_status ?></h1>
        <p><?php echo $textbotlang['paymentGateway']['invoiceTransactionNo'] ?><span><?php echo $invoice_id ?></span></p>
        <p><?php echo $textbotlang['paymentGateway']['invoiceAmount'] ?> <span><?php echo $price ?></span><?php echo $textbotlang['paymentGateway']['invoiceAmountUnit'] ?></p>
        <p><?php echo $textbotlang['paymentGateway']['invoiceDate'] ?> <span> <?php echo jdate('Y/m/d') ?> </span></p>
        <p><?php echo $dec_payment_status ?></p>
    </div>
</body>

</html>