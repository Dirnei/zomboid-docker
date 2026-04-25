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

trap 'send_discord ":octagonal_sign: **Server wird heruntergefahren...**"; exit 0' SIGTERM SIGINT

send_discord ":hourglass: **Server startet...**"

# Clean old logs so tail only picks up the fresh one
rm -f "${LOG_DIR}"/*_DebugLog-server.txt 2>/dev/null

echo "discord-events: waiting for fresh log..."
while ! ls "${LOG_DIR}"/*_DebugLog-server.txt &>/dev/null; do
    sleep 5
done

LOG_FILE=$(ls -t "${LOG_DIR}"/*_DebugLog-server.txt | head -1)
echo "discord-events: watching ${LOG_FILE}..."

# tail -n +1 reads existing content first, then -F follows new lines
while read -r line; do
    case "$line" in
        *"SERVER STARTED"*)
            send_discord ":white_check_mark: **Server ist online — bereit zum Beitreten!**" ;;
        *"fully-connected"*)
            player=$(echo "$line" | grep -oP 'username="\K[^"]+')
            send_discord ":green_circle: **${player:-Ein Spieler}** hat den Server betreten" ;;
        *"receive-disconnect"*)
            player=$(echo "$line" | grep -oP 'username="\K[^"]+')
            send_discord ":red_circle: **${player:-Ein Spieler}** hat den Server verlassen" ;;
        *"replacing dead player"*)
            player=$(echo "$line" | grep -oP 'username="\K[^"]+')
            send_discord ":skull: **${player:-Ein Spieler}** ist gestorben" ;;
    esac
done < <(tail -n +1 -F "$LOG_FILE" 2>/dev/null)
