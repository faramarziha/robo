<?php
use PHPUnit\Framework\TestCase;

if (!defined('TESTING')) {
    define('TESTING', true);
}

class PaymentExpireTest extends TestCase {
    
    public function testPaymentExpireBatchUpdate() {
        global $pdo;
        
        $pdo = $this->createMock(PDO::class);
        $selectStmt = $this->createMock(PDOStatement::class);
        $updateStmt = $this->createMock(PDOStatement::class);
        
        $pdo->expects($this->any())
            ->method('prepare')
            ->willReturnCallback(function($query) use ($selectStmt, $updateStmt) {
                if (strpos($query, 'SELECT * FROM Payment_report') !== false) {
                    return $selectStmt;
                }
                if (strpos($query, 'UPDATE Payment_report SET') !== false) {
                    return $updateStmt;
                }
                return $this->createMock(PDOStatement::class);
            });
            
        $selectStmt->expects($this->once())
            ->method('execute')
            ->willReturn(true);
            
        $selectStmt->expects($this->once())
            ->method('fetchAll')
            ->willReturn([
                ['id_order' => 101, 'Payment_Method' => 'zarinpal', 'price' => 500, 'id_user' => 1, 'message_id' => 1001],
                ['id_order' => 102, 'Payment_Method' => 'perfect', 'price' => 1000, 'id_user' => 2, 'message_id' => 1002]
            ]);
            
        $updateStmt->expects($this->once())
            ->method('execute')
            ->with([101, 102])
            ->willReturn(true);

        require __DIR__ . '/../cronbot/payment_expire.php';
    }
}
