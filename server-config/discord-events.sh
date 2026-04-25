#!/bin/bash
# Watches PZ server console log and posts events to Discord via bot API.

LOG_DIR="/home/steam/Zomboid/Logs"
DISCORD_API="https://discord.com/api/v10/channels/${DISCORD_CHANNEL_ID}/messages"
AUTH_HEADER="Authorization: Bot ${DISCORD_TOKEN}"

send_discord() {
    curl -s -X POST "$DISCORD_API" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "{\"content\": \"$1\"}" > /dev/null 2>&1
}

# Clean old logs so tail only picks up the fresh one
rm -f "${LOG_DIR}"/*_DebugLog-server.txt 2>/dev/null

echo "discord-events: waiting for fresh log..."
while ! ls "${LOG_DIR}"/*_DebugLog-server.txt &>/dev/null; do
    sleep 5
done

LOG_FILE=$(ls -t "${LOG_DIR}"/*_DebugLog-server.txt | head -1)
echo "discord-events: watching ${LOG_FILE}..."

# Use process substitution instead of pipe to avoid subshell
while read -r line; do
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
done < <(tail -n 0 -F "$LOG_FILE" 2>/dev/null)
