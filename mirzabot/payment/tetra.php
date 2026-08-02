<?php
ini_set('error_log', 'error_log');
require_once __DIR__ . '/../config.php';
require_once __DIR__ . '/../botapi.php';
require_once __DIR__ . '/../Marzban.php';
require_once __DIR__ . '/../function.php';
require_once __DIR__ . '/../panels.php';
require_once __DIR__ . '/../keyboard.php';
require_once __DIR__ . '/../jdf.php';

$ManagePanel = new ManagePanel();

$raw = file_get_contents('php://input') ?: '';
$json = json_decode($raw, true) ?: [];
$input = array_merge($_GET, $_POST, $json);

$invoice_id = '';
foreach (['invoice_id', 'Hash_id', 'hashid', 'order_id', 'code'] as $key) {
    if (!empty($input[$key])) {
        $invoice_id = htmlspecialchars(trim((string) $input[$key]), ENT_QUOTES, 'UTF-8');
        break;
    }
}

$authority = '';
foreach (['authority', 'Authority', 'authority_id'] as $key) {
    if (!empty($input[$key])) {
        $authority = trim((string) $input[$key]);
        break;
    }
}

$setting = select("setting", "*");
$PaySetting = select("PaySetting", "ValuePay", "NamePay", "merchant_id_tetrapay", "select")['ValuePay'];

$Payment_report = select("Payment_report", "*", "id_order", $invoice_id, "select");
$price = $Payment_report['price'] ?? 0;

$verifyOk = false;
$ref_id = $authority;

// Both invoice_id and authority arrive from the client. Every branch below
// dereferences $Payment_report, which previously fataled on null when the
// id_order did not exist, so an unknown order must leave $verifyOk false.
$orderFound = is_array($Payment_report);
if (!$orderFound) {
    error_log("tetra.php: unknown id_order '" . $invoice_id . "' from " . ($_SERVER['REMOTE_ADDR'] ?? '?'));
}

if ($orderFound && !empty($authority) && !empty($PaySetting)) {
    $verifyData = json_encode([
        'ApiKey' => $PaySetting,
        'authority' => $authority
    ]);
    
    $ch = curl_init('https://tetra98.com/api/verify');
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_POST, true);
    curl_setopt($ch, CURLOPT_POSTFIELDS, $verifyData);
    curl_setopt($ch, CURLOPT_HTTPHEADER, [
        'Content-Type: application/json',
        'Content-Length: ' . strlen($verifyData)
    ]);
    $resStr = curl_exec($ch);
    curl_close($ch);
    
    $resObj = json_decode($resStr, true);
    if (isset($resObj['status']) && (string)$resObj['status'] === '100') {
        $verifyOk = true;

        // Bind the verification to this order where the gateway echoes an
        // identifier back, so a valid authority for order A cannot settle
        // order B. Fields are checked defensively because the API is not
        // guaranteed to return all of them.
        foreach (['Hash_id', 'hash_id', 'invoice_id', 'order_id'] as $echoKey) {
            if (!empty($resObj[$echoKey])) {
                if ((string) $resObj[$echoKey] !== (string) $invoice_id) {
                    error_log("tetra.php: authority/order mismatch — echoed '{$resObj[$echoKey]}' vs requested '{$invoice_id}'");
                    $verifyOk = false;
                }
                break;
            }
        }

        // Reject a verified payment whose amount does not cover the invoice.
        if ($verifyOk) {
            foreach (['amount', 'Amount'] as $amountKey) {
                if (isset($resObj[$amountKey]) && is_numeric($resObj[$amountKey])) {
                    // The order is created with Amount = price * 10 (rials).
                    if ((int) $resObj[$amountKey] < ((int) $price) * 10) {
                        error_log("tetra.php: underpaid order '{$invoice_id}' — got {$resObj[$amountKey]}");
                        $verifyOk = false;
                    }
                    break;
                }
            }
        }

        if ($verifyOk && !empty($resObj['ref_id'])) {
            $ref_id = $resObj['ref_id'];
        }
    }
}

$textbotlang = languagechange();

if ($verifyOk) {
    // Check if invoice has expired
    $expiresAt = intval($Payment_report['expires_at'] ?? 0);
    $isExpired = ($Payment_report['payment_Status'] === 'expire') || ($expiresAt > 0 && time() > $expiresAt);

    if ($isExpired) {
        update("Payment_report", "payment_Status", "expire", "id_order", $Payment_report['id_order']);
        $payment_status = "پرداخت ناموفق بود (انقضای مهلت فاکتور)";
        $dec_payment_status = "مهلت این فاکتور به پایان رسیده بود. در صورت کسر وجه، لطفاً جهت بررسی با پشتیبانی در ارتباط باشید.\nکد پیگیری: " . $ref_id;
        
        $__q16 = $pdo->prepare("SELECT * FROM user WHERE id = ? LIMIT 1");
        $__q16->bindValue(1, $Payment_report['id_user'], PDO::PARAM_STR);
        $__q16->execute();
        $Balance_id = $__q16->fetch(PDO::FETCH_ASSOC);
        if (!empty($Balance_id)) {
            sendmessage($Balance_id['id'], "⚠️ پرداخت شما انجام شد اما مهلت فاکتور به پایان رسیده بود. لطفاً کد پیگیری <code>$ref_id</code> را به پشتیبانی ارسال کنید.", null, 'HTML');
        }
    } else {
        $payment_status = "پرداخت با موفقیت انجام شد (تتراپی)";
        $dec_payment_status = $textbotlang['paymentGateway']['descThanks'] ?? "با تشکر از خرید شما";
        
        // settleOrderOnce() is the mutex: the conditional UPDATE succeeds for
        // exactly one caller, so a replayed callback cannot credit twice.
        if (settleOrderOnce($Payment_report['id_order'])) {
            DirectPayment($invoice_id, "../images.jpg");
            $pricecashback = select("PaySetting", "ValuePay", "NamePay", "chashbacktetrapay", "select")['ValuePay'] ?? '0';
            
            $__q16 = $pdo->prepare("SELECT * FROM user WHERE id = ? LIMIT 1");
            $__q16->bindValue(1, $Payment_report['id_user'], PDO::PARAM_STR);
            $__q16->execute();
            $Balance_id = $__q16->fetch(PDO::FETCH_ASSOC);
            
            if ($pricecashback != "0" && !empty($Balance_id)) {
                $resultCashback = ($Payment_report['price'] * intval($pricecashback)) / 100;
                // Relative UPDATE — the previous read-then-write lost the
                // credit whenever DirectPayment touched the same row.
                creditBalance($Balance_id['id'], $resultCashback);
                $text_report = sprintf($textbotlang['paymentGateway']['giftReport'] ?? "هدیه خرید: %s", $resultCashback);
                sendmessage($Balance_id['id'], $text_report, null, 'HTML');
            }
            
            $text_report = "💵 <b>پرداخت جدید درگاه تتراپی</b>\n👤 کاربر: " . ($Balance_id['id'] ?? '') . "\n💰 مبلغ: " . number_format($price) . " تومان\n📌 پیگیری: " . $ref_id;
            if (!empty($setting['Channel_Report'])) {
                telegram('sendmessage', [
                    'chat_id' => $setting['Channel_Report'],
                    'text' => $text_report,
                    'parse_mode' => "HTML"
                ]);
            }
        }
    }
} elseif (!$orderFound) {
    $payment_status = "سفارش یافت نشد";
    $dec_payment_status = "این کد پیگیری در سیستم ثبت نشده است. در صورت کسر وجه با پشتیبانی تماس بگیرید.";
} else {
    $payment_status = "پرداخت ناموفق بود یا لغو گردید (تتراپی)";
    $dec_payment_status = "در صورت کسر وجه از حساب شما، طی ۲۴ ساعت آینده به حسابتان باز خواهد گشت.";
}
?>
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="UTF-8">
    <title>نتیجه پرداخت - تتراپی</title>
    <style>
        body { font-family: Tahoma, sans-serif; background-color: #f4f6f9; margin: 0; padding: 20px; display: flex; justify-content: center; align-items: center; min-height: 100vh; }
        .box { background: #fff; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.1); padding: 30px; text-align: center; max-width: 400px; width: 100%; }
        h1 { color: <?php echo $verifyOk ? '#10b981' : '#ef4444'; ?>; font-size: 1.4rem; margin-bottom: 15px; }
        p { color: #4b5563; font-size: 0.95rem; line-height: 1.6; }
        .code { background: #f3f4f6; padding: 8px 15px; border-radius: 6px; font-weight: bold; font-family: monospace; }
    </style>
</head>
<body>
    <div class="box">
        <h1><?php echo $payment_status; ?></h1>
        <p><?php echo $dec_payment_status; ?></p>
        <p>کد پیگیری سفارش: <span class="code"><?php echo htmlspecialchars($invoice_id); ?></span></p>
        <?php if ($verifyOk): ?>
            <p>شناسه تراکنش: <span class="code"><?php echo htmlspecialchars($ref_id); ?></span></p>
        <?php endif; ?>
    </div>
</body>
</html>
