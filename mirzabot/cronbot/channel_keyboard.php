<?php
function getChannelsKeyboard($pdo, $channels) {
    $keyboardchannel = [
        'inline_keyboard' => [],
    ];
    if (!empty($channels)) {
        $placeholders = rtrim(str_repeat('?,', count($channels)), ',');
        $stmt = $pdo->prepare("SELECT * FROM channels WHERE link IN ($placeholders)");
        $stmt->execute($channels);
        $channel_rows = $stmt->fetchAll(PDO::FETCH_ASSOC);
        
        $channel_map = [];
        foreach ($channel_rows as $row) {
            $channel_map[$row['link']] = $row;
        }
        
        foreach ($channels as $channel) {
            $channelremark = $channel_map[$channel] ?? null;
            if (!$channelremark || $channelremark['remark'] == null || $channelremark['linkjoin'] == null)
                continue;
            $keyboardchannel['inline_keyboard'][] = [
                [
                    'text' => "{$channelremark['remark']}",
                    'url' => $channelremark['linkjoin']
                ],
            ];
        }
    }
    return $keyboardchannel;
}
