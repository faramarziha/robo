<?php
use PHPUnit\Framework\TestCase;

if (!defined('TESTING')) {
    define('TESTING', true);
}

// Ensure ManagePanel class exists for inclusion
if (!class_exists('ManagePanel')) {
    class ManagePanel {
        public function DataUser($loc, $username) {
            return ['status' => 'active'];
        }
        public function Change_status($username, $loc) {
            return true;
        }
    }
}

class DisableconfigTest extends TestCase {
    
    public function testDisableconfigBatchQuery() {
        global $pdo;
        
        $pdo = $this->createMock(PDO::class);
        $userSelectStmt = $this->createMock(PDOStatement::class);
        $invoiceSelectStmt = $this->createMock(PDOStatement::class);
        $invoiceUpdateStmt = $this->createMock(PDOStatement::class);
        
        $pdo->expects($this->any())
            ->method('prepare')
            ->willReturnCallback(function($query) use ($userSelectStmt, $invoiceSelectStmt, $invoiceUpdateStmt) {
                if (strpos($query, "SELECT id FROM user WHERE checkstatus = '2'") !== false) {
                    return $userSelectStmt;
                }
                if (strpos($query, 'SELECT * FROM invoice') !== false) {
                    return $invoiceSelectStmt;
                }
                if (strpos($query, 'UPDATE invoice SET Status') !== false) {
                    return $invoiceUpdateStmt;
                }
                return $this->createMock(PDOStatement::class);
            });
            
        $userSelectStmt->expects($this->once())
            ->method('execute')
            ->willReturn(true);
            
        $userSelectStmt->expects($this->once())
            ->method('fetchAll')
            ->willReturn([
                ['id' => 1],
                ['id' => 2]
            ]);

        $invoiceSelectStmt->expects($this->once())
            ->method('execute')
            ->with([1, 2])
            ->willReturn(true);
            
        $invoiceSelectStmt->expects($this->once())
            ->method('fetchAll')
            ->willReturn([
                ['id_user' => 1, 'id_invoice' => 10, 'Service_location' => 'loc1', 'username' => 'user1'],
                ['id_user' => 2, 'id_invoice' => 20, 'Service_location' => 'loc2', 'username' => 'user2']
            ]);
            
        $invoiceUpdateStmt->expects($this->once())
            ->method('execute')
            ->with([10, 20])
            ->willReturn(true);

        if (!function_exists('update')) {
            function update() { return true; }
        }

        require __DIR__ . '/../cronbot/disableconfig.php';
    }
}
