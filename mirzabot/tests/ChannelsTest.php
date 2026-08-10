<?php
use PHPUnit\Framework\TestCase;

if (!defined('TESTING')) {
    define('TESTING', true);
}

class ChannelsTest extends TestCase {
    
    public function testChannelsBatchQuery() {
        require_once __DIR__ . '/../cronbot/channel_keyboard.php';
        
        $channels = ['http://t.me/c1', 'http://t.me/c2'];
        
        // Mock PDO
        $pdo = $this->createMock(PDO::class);
        $stmt = $this->createMock(PDOStatement::class);
        
        $pdo->expects($this->once())
            ->method('prepare')
            ->with("SELECT * FROM channels WHERE link IN (?,?)")
            ->willReturn($stmt);
            
        $stmt->expects($this->once())
            ->method('execute')
            ->with($channels)
            ->willReturn(true);
            
        $stmt->expects($this->once())
            ->method('fetchAll')
            ->with(PDO::FETCH_ASSOC)
            ->willReturn([
                ['link' => 'http://t.me/c1', 'remark' => 'Channel 1', 'linkjoin' => 'http://t.me/join1'],
                ['link' => 'http://t.me/c2', 'remark' => 'Channel 2', 'linkjoin' => 'http://t.me/join2']
            ]);
            
        $keyboardchannel = getChannelsKeyboard($pdo, $channels);
        
        // Assert the keyboard was built correctly
        $this->assertCount(2, $keyboardchannel['inline_keyboard']);
        $this->assertEquals('Channel 1', $keyboardchannel['inline_keyboard'][0][0]['text']);
        $this->assertEquals('http://t.me/join1', $keyboardchannel['inline_keyboard'][0][0]['url']);
        $this->assertEquals('Channel 2', $keyboardchannel['inline_keyboard'][1][0]['text']);
        $this->assertEquals('http://t.me/join2', $keyboardchannel['inline_keyboard'][1][0]['url']);
    }
}
