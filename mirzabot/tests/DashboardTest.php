<?php
use PHPUnit\Framework\TestCase;

class DashboardTest extends TestCase {
    
    public function testDashboardBatchQueries() {
        require_once __DIR__ . '/../cronbot/dashboard_queries.php';
        
        $pdo = $this->createMock(PDO::class);
        
        $revStmt = $this->createMock(PDOStatement::class);
        $planStmt = $this->createMock(PDOStatement::class);
        $convStmt = $this->createMock(PDOStatement::class);
        
        $pdo->expects($this->exactly(3))
            ->method('prepare')
            ->willReturnCallback(function($query) use ($revStmt, $planStmt, $convStmt) {
                if (strpos($query, 'daily_revenue') !== false) {
                    return $revStmt;
                }
                if (strpos($query, 'plan_count') !== false) {
                    return $planStmt;
                }
                if (strpos($query, 'paid_users') !== false) {
                    return $convStmt;
                }
                return $this->createMock(PDOStatement::class);
            });
            
        // 1. Revenue
        $revStmt->expects($this->once())->method('execute')->willReturn(true);
        $revStmt->expects($this->once())->method('fetch')->willReturn([
            'daily_revenue' => 1000,
            'weekly_revenue' => 5000
        ]);
        
        // 2. Popular Plan
        $planStmt->expects($this->once())->method('execute')->willReturn(true);
        $planStmt->expects($this->once())->method('fetch')->willReturn([
            'name_product' => 'Gold Plan',
            'plan_count' => 50
        ]);
        
        // 3. Conversion Rate
        $convStmt->expects($this->once())->method('execute')->willReturn(true);
        $convStmt->expects($this->once())->method('fetch')->willReturn([
            'paid_users' => 10,
            'total_users' => 100
        ]);
        
        $metrics = getDashboardMetrics($pdo);
        
        $this->assertEquals('1,000', $metrics['daily_revenue']);
        $this->assertEquals('5,000', $metrics['weekly_revenue']);
        $this->assertEquals('Gold Plan', $metrics['popular_plan']);
        $this->assertEquals(10.0, $metrics['conversion_rate']);
    }
}
