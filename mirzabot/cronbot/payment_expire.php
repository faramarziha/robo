<?php
ini_set('error_log', 'error_log');
date_default_timezone_set('Asia/Tehran');
require_once __DIR__ . '/../config.php';
require_once __DIR__ . '/../botapi.php';
require_once __DIR__ . '/../panels.php';
require_once __DIR__ . '/../function.php';
require __DIR__ . '/../vendor/autoload.php';
$ManagePanel = new ManagePanel();
$setting = select("setting", "*");
$textbotlang = languagechange();
$currentTime = time();
$month_date_time_start = date('Y/m/d H:i:s', $currentTime - 86400);

// Select invoices that are Unpaid AND either older than 24 hours OR explicitly expired via expires_at
$stmt = $pdo->prepare("SELECT * FROM Payment_report WHERE payment_Status = 'Unpaid' AND (time < :mp1 OR (expires_at IS NOT NULL AND expires_at < :now))");
$stmt->execute([':mp1' => $month_date_time_start, ':now' => $currentTime]);

while ($result = $stmt->fetch(PDO::FETCH_ASSOC)) {
    $status_var = [
        'cart to cart' =>  $textbotlang['textbot']['cartToCart'] ?? 'کارت به کارت',
        'aqayepardakht' => $textbotlang['textbot']['aqayePardakht'] ?? 'آقای پرداخت',
        'zarinpal' => $textbotlang['textbot']['zarinPal'] ?? 'زرین پال',
        'plisio' => $textbotlang['textbot']['nowPayment'] ?? 'پلیسیو',
        'arze digital offline' => $textbotlang['textbot']['nowPaymentTron'] ?? 'ارز دیجیتال آفلاین',
        'Currency Rial 1' => $textbotlang['textbot']['iranPay2'] ?? 'ایران پی ۱',
        'Currency Rial 2' => $textbotlang['textbot']['iranPay3'] ?? 'ایران پی ۲',
        'Currency Rial 3' => $textbotlang['textbot']['iranPay1'] ?? 'ایران پی ۳',
        'Currency Rial tow' => $textbotlang['common']['gateways']['rial1'] ?? 'درگاه ریالی',
        'Currency Rial gateway3' => $textbotlang['common']['gateways']['rial2'] ?? 'درگاه ریالی',
        'perfect' => $textbotlang['common']['gateways']['perfectMoney'] ?? 'پرفکت مانی',
        'paymentnotverify' => $textbotlang['textbot']['paymentNotVerify'] ?? 'کارت بدون تایید',
        'Star Telegram' => $textbotlang['textbot']['starTelegram'] ?? 'استارز تلگرام',
        'telegram_stars' => 'استارز تلگرام',
        'tetrapay' => 'درگاه تتراپی',
        'nowpayment' => $textbotlang['textbot']['cryptoPayment'] ?? 'ناو پیمنت'
    ][$result['Payment_Method']] ?? 'درگاه پرداخت';

    $textexpire = sprintf($textbotlang['users']['Balance']['invoiceExpired'] ?? "⏰ مهلت فاکتور شما به پایان رسید.", $status_var, $result['id_order'], $result['price']);
    if (!empty($result['message_id'])) {
        deletemessage($result['id_user'], $result['message_id']);
    }
    update("Payment_report", "payment_Status", "expire", "id_order", $result['id_order']);
}