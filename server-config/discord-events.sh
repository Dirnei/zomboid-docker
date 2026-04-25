#!/bin/bash
# Watches PZ server logs and posts player events to Discord via bot API.

LOG_DIR="/home/steam/Zomboid/Logs"

send_discord() {
    local message="$1"
    curl -s -X POST "https://discord.com/api/v10/channels/${DISCORD_CHANNEL_ID}/messages" \
        -H "Authorization: Bot ${DISCORD_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"content\": \"${message}\"}" > /dev/null 2>&1
}

echo "discord-events: waiting for log directory..."
while [ ! -d "$LOG_DIR" ]; do
    sleep 5
done

# Find the most recent log file and tail it
echo "discord-events: watching logs..."
tail -n 0 -F "${LOG_DIR}"/*user.txt 2>/dev/null | while read -r line; do
    if echo "$line" | grep -qi "fully connected"; then
        player=$(echo "$line" | grep -oP 'user "\K[^"]+' || echo "$line" | sed 's/.*"\(.*\)".*/\1/')
        send_discord ":green_circle: **${player:-A player}** connected"
    elif echo "$line" | grep -qi "disconnected"; then
        player=$(echo "$line" | grep -oP 'user "\K[^"]+' || echo "$line" | sed 's/.*"\(.*\)".*/\1/')
        send_discord ":red_circle: **${player:-A player}** disconnected"
    fi
done &

tail -n 0 -F "${LOG_DIR}"/*Death*.txt 2>/dev/null | while read -r line; do
    if echo "$line" | grep -qi "died\|killed\|death"; then
        send_discord ":skull: ${line}"
    fi
done &

# Post server online message
send_discord ":white_check_mark: **Server is online**"

# Wait for background jobs
wait
