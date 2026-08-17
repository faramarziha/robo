<?php
// Extracted to be easily testable without the whole admin.php context
function getDashboardMetrics($pdo) {
    $today_start = date('Y/m/d 00:00:00');
    $week_start = date('Y/m/d 00:00:00', strtotime('-7 days'));
    
    // Batch query for Revenue
    $stmt = $pdo->prepare("SELECT 
        SUM(CASE WHEN time >= ? THEN CAST(price AS UNSIGNED) ELSE 0 END) as daily_revenue,
        SUM(CASE WHEN time >= ? THEN CAST(price AS UNSIGNED) ELSE 0 END) as weekly_revenue
        FROM Payment_report WHERE payment_Status = 'paid' AND time >= ?");
    $stmt->execute([$today_start, $week_start, $week_start]);
    $revenue = $stmt->fetch(PDO::FETCH_ASSOC);
    
    // Batch query for Most Popular Plan
    $stmt2 = $pdo->prepare("SELECT 
        name_product, COUNT(*) as plan_count 
        FROM invoice 
        GROUP BY name_product 
        ORDER BY plan_count DESC LIMIT 1");
    $stmt2->execute();
    $popular_plan = $stmt2->fetch(PDO::FETCH_ASSOC);
    $plan_name = $popular_plan ? $popular_plan['name_product'] : 'N/A';
    
    // Batch query for Conversion Rate
    // Count all distinct users who have an actual paid payment vs total users
    $stmt3 = $pdo->prepare("SELECT 
        (SELECT COUNT(DISTINCT id_user) FROM Payment_report WHERE payment_Status = 'paid') as paid_users,
        (SELECT COUNT(*) FROM user) as total_users");
    $stmt3->execute();
    $conversion_data = $stmt3->fetch(PDO::FETCH_ASSOC);
    $paid_users = (int)$conversion_data['paid_users'];
    $total_users = (int)$conversion_data['total_users'];
    $conversion_rate = $total_users > 0 ? round(($paid_users / $total_users) * 100, 2) : 0;
    
    return [
        'daily_revenue' => number_format((float)($revenue['daily_revenue'] ?? 0)),
        'weekly_revenue' => number_format((float)($revenue['weekly_revenue'] ?? 0)),
        'popular_plan' => $plan_name,
        'conversion_rate' => $conversion_rate
    ];
}
