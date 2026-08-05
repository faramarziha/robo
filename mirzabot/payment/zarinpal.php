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
$Authority = isset($_GET['Authority']) ? htmlspecialchars(trim((string) $_GET['Authority']), ENT_QUOTES, 'UTF-8') : '';
$StatusPayment = isset($_GET['Status']) ? htmlspecialchars(trim((string) $_GET['Status']), ENT_QUOTES, 'UTF-8') : '';
$setting = select("setting", "*");
$payment_status = $textbotlang['paymentGateway']['statusFailed'] ?? 'پرداخت ناموفق بود';
$dec_payment_status = '';
$price = 0;
$invoice_id = '';

if ($Authority === '' || $StatusPayment === '') {
    http_response_code(400);
    $dec_payment_status = 'اطلاعات تراکنش ناقص است.';
} else {
    $Payment_reports = select("Payment_report", "*", "dec_not_confirmed", $Authority, "select", ['cache' => false]);
    if (!is_array($Payment_reports)) {
        http_response_code(404);
        $dec_payment_status = 'سفارش یافت نشد.';
    } else {
        $price = $Payment_reports['price'];
        $invoice_id = $Payment_reports['id_order'];
        if ($StatusPayment === "OK") {
            $PaySetting = select("PaySetting", "ValuePay", "NamePay", "merchant_zarinpal", "select")['ValuePay'];
            $curl = curl_init();
            curl_setopt_array($curl, [
                CURLOPT_URL => 'https://payment.zarinpal.com/pg/v4/payment/verify.json',
                CURLOPT_RETURNTRANSFER => true,
                CURLOPT_ENCODING => '',
                CURLOPT_MAXREDIRS => 10,
                CURLOPT_TIMEOUT => 10,
                CURLOPT_FOLLOWLOCATION => true,
                CURLOPT_HTTP_VERSION => CURL_HTTP_VERSION_1_1,
                CURLOPT_CUSTOMREQUEST => 'POST',
                CURLOPT_HTTPHEADER => ['Content-Type: application/json', 'Accept: application/json'],
                CURLOPT_POSTFIELDS => json_encode([
                    "merchant_id" => $PaySetting,
                    "amount" => $price,
                    "authority" => $Authority,
                    "description" => $Payment_reports['id_user']
                ]),
            ]);
            $response = curl_exec($curl);
            curl_close($curl);
            $response = json_decode((string) $response, true);
            $code = $response['data']['code'] ?? $response['errors']['code'] ?? null;
            if (($response['data']['message'] ?? '') === "Verified" || ($response['data']['message'] ?? '') === "Paid" || in_array((int) $code, [100, 101], true)) {
                $payment_status = $textbotlang['paymentGateway']['statusSuccess'];
                $dec_payment_status = $textbotlang['paymentGateway']['descThanks'];
                $Payment_report = paymentReportByOrder($invoice_id);
                if (is_array($Payment_report) && settleOrderOnce($Payment_report['id_order'])) {
                    DirectPayment($invoice_id, "../images.jpg");
                    $cashback = applyPaymentCashback($Payment_report['id_user'], $Payment_report['price'], "chashbackzarinpal");
                    $Balance_id = select("user", "*", "id", $Payment_report['id_user'], "select", ['cache' => false]);
                    if ($cashback > 0 && is_array($Balance_id)) {
                        $text_report = sprintf($textbotlang['paymentGateway']['giftReport'], $cashback);
                        sendmessage($Balance_id['id'], $text_report, null, 'HTML');
                    }
                    $paymentreports = topicId('paymentreport');
                    $refcode = $response['data']['ref_id'] ?? '';
                    $cart_number = $response['data']['card_pan'] ?? '';
                    $text_report = sprintf($textbotlang['paymentGateway']['reportZarinpal'], $Payment_report['id_user'], is_array($Balance_id) ? $Balance_id['username'] : '', number_format((float) $price), $refcode, $cart_number);
                    if (strlen((string) ($setting['Channel_Report'] ?? '')) > 0) {
                        telegram('sendmessage', ['chat_id' => $setting['Channel_Report'], 'message_thread_id' => $paymentreports, 'text' => $text_report, 'parse_mode' => "HTML"]);
                    }
                }
            } else {
                $payment_status = $textbotlang['paymentGateway']['zarinpalResultCodes'][$code] ?? $textbotlang['paymentGateway']['statusFailed'];
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
            font-family:vazir;
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
            width:25%;
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
        <p><?php echo $textbotlang['paymentGateway']['invoiceAmount'] ?>  <span><?php echo  $price ?></span><?php echo $textbotlang['paymentGateway']['invoiceAmountUnit'] ?></p>
        <p><?php echo $textbotlang['paymentGateway']['invoiceDate'] ?> <span>  <?php echo jdate('Y/m/d')  ?>  </span></p>
        <p><?php echo $dec_payment_status ?></p>
    </div>
</body>
</html>
