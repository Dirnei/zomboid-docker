#!/bin/bash
# Watches PZ server console log and posts events to Discord via bot API.

LOG_DIR="/home/steam/Zomboid/Logs"

send_discord() {
    curl -s -X POST "https://discord.com/api/v10/channels/${DISCORD_CHANNEL_ID}/messages" \
        -H "Authorization: Bot ${DISCORD_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"content\": \"$1\"}" > /dev/null 2>&1
}

# Clean old logs so tail only picks up the fresh one
rm -f "${LOG_DIR}"/*_DebugLog-server.txt 2>/dev/null

echo "discord-events: waiting for fresh log..."
while ! ls "${LOG_DIR}"/*_DebugLog-server.txt &>/dev/null; do
    sleep 5
done

echo "discord-events: watching logs..."
tail -n 0 -F "${LOG_DIR}"/*_DebugLog-server.txt 2>/dev/null | while read -r line; do
    case "$line" in
        *"Starting Project Zomboid Server"*)
            send_discord ":hourglass: **Server is starting up...**" ;;
        *"LuaNet: Listening"*)
            send_discord ":white_check_mark: **Server is online — ready to join!**" ;;
        *"fully connected"*)
            player=$(echo "$line" | grep -oP '"\K[^"]+' | head -1)
            send_discord ":green_circle: **${player:-A player}** connected" ;;
        *"disconnected"*)
            player=$(echo "$line" | grep -oP '"\K[^"]+' | head -1)
            send_discord ":red_circle: **${player:-A player}** disconnected" ;;
        *"died"*|*"killed"*)
            send_discord ":skull: ${line}" ;;
    esac
done
