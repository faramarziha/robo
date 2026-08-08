<?php
use PHPUnit\Framework\TestCase;

if (!defined('TESTING')) {
    define('TESTING', true);
}

class CroncardTest extends TestCase {
    
    public function testCroncardBatchQuery() {
        global $pdo;
        
        $pdo = $this->createMock(PDO::class);
        $selectStmt = $this->createMock(PDOStatement::class);
        $userStmt = $this->createMock(PDOStatement::class);
        
        $pdo->expects($this->any())
            ->method('prepare')
            ->willReturnCallback(function($query) use ($selectStmt, $userStmt) {
                if (strpos($query, 'SELECT * FROM Payment_report') !== false) {
                    return $selectStmt;
                }
                if (strpos($query, 'SELECT * FROM user WHERE id IN') !== false) {
                    return $userStmt;
                }
                return $this->createMock(PDOStatement::class);
            });
            
        $selectStmt->expects($this->once())
            ->method('execute')
            ->willReturn(true);
            
        // Return payments that have an updated time 10 minutes ago, satisfying constraints
        $pastTime = date('Y-m-d H:i:s', time() - 600);
        $selectStmt->expects($this->once())
            ->method('fetchAll')
            ->willReturn([
                ['id_order' => 10, 'id_user' => 1, 'payment_Status' => 'waiting', 'at_updated' => $pastTime, 'price' => 1000, 'Payment_Method' => 'cart to cart'],
                ['id_order' => 20, 'id_user' => 2, 'payment_Status' => 'waiting', 'at_updated' => $pastTime, 'price' => 2000, 'Payment_Method' => 'cart to cart']
            ]);
            
        $userStmt->expects($this->once())
            ->method('execute')
            ->with([1, 2])
            ->willReturn(true);
            
        $userStmt->expects($this->once())
            ->method('fetchAll')
            ->willReturn([
                ['id' => 1, 'Balance' => 5000],
                ['id' => 2, 'Balance' => 10000]
            ]);

        require __DIR__ . '/../cronbot/croncard.php';
    }
}
