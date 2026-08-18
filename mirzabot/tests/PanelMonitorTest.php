<?php
use PHPUnit\Framework\TestCase;

if (!defined('TESTING')) {
    define('TESTING', true);
}

// Mocking required functions
if (!function_exists('select')) {
    function select($table, $col) {
        if ($table == 'setting') return ['Bot_Status' => 'on'];
        if ($table == 'admin') return [['id_admin' => 123]];
        return [];
    }
}
if (!function_exists('languagechange')) {
    function languagechange() { return []; }
}
if (!function_exists('Get_System_Stats')) {
    function Get_System_Stats($name) {
        if ($name == 'healthy_marzban') {
            return ['cpu_cores' => 4, 'cpu_usage' => 50, 'mem_total' => 100, 'mem_used' => 50];
        }
        if ($name == 'high_cpu_marzban') {
            return ['cpu_cores' => 4, 'cpu_usage' => 95, 'mem_total' => 100, 'mem_used' => 50];
        }
        if ($name == 'down_marzban') {
            return ['error' => 'Connection refused'];
        }
        return false;
    }
}
$sent_messages = [];
if (!function_exists('sendmessage')) {
    function sendmessage($id, $text, $keyboard, $mode) {
        global $sent_messages;
        $sent_messages[] = ['id' => $id, 'text' => $text];
    }
}

if (!class_exists('ManagePanel')) {
    class ManagePanel {
        public function DataUser($name, $user) {
            if ($name == 'down_other') {
                return ['status' => 'Unsuccessful', 'msg' => 'Connection failed'];
            }
            return ['status' => 'Unsuccessful', 'msg' => 'User not found']; // Normal response for fake user
        }
    }
}

class PanelMonitorTest extends TestCase {
    
    public function testPanelMonitorAlerts() {
        global $pdo, $sent_messages;
        $sent_messages = [];
        
        $pdo = $this->createMock(PDO::class);
        $stmt = $this->createMock(PDOStatement::class);
        
        $pdo->expects($this->once())
            ->method('prepare')
            ->with("SELECT * FROM marzban_panel")
            ->willReturn($stmt);
            
        $stmt->expects($this->once())->method('execute')->willReturn(true);
        $stmt->expects($this->once())->method('fetchAll')->willReturn([
            ['name_panel' => 'healthy_marzban', 'type' => 'marzban', 'status' => 'active'],
            ['name_panel' => 'high_cpu_marzban', 'type' => 'marzban', 'status' => 'active'],
            ['name_panel' => 'down_marzban', 'type' => 'marzban', 'status' => 'active'],
            ['name_panel' => 'down_other', 'type' => 'x-ui_single', 'status' => 'active'],
            ['name_panel' => 'ignored_off', 'type' => 'marzban', 'status' => 'off'] // Should be ignored
        ]);
        
        require __DIR__ . '/../cronbot/panel_monitor.php';
        
        $this->assertCount(3, $sent_messages);
        
        // Assert specific messages were triggered
        $messages_text = array_column($sent_messages, 'text');
        
        $this->assertStringContainsString('High CPU Usage: 95%', $messages_text[0]);
        $this->assertStringContainsString('high_cpu_marzban', $messages_text[0]);
        
        $this->assertStringContainsString('Unreachable or returning errors', $messages_text[1]);
        $this->assertStringContainsString('down_marzban', $messages_text[1]);
        
        $this->assertStringContainsString('Unreachable (Connection failed)', $messages_text[2]);
        $this->assertStringContainsString('down_other', $messages_text[2]);
    }
}
