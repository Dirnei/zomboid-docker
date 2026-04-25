#!/bin/bash
# Watches PZ server console log and posts events to Discord via bot API.
# Also maintains a live player list message.

LOG_DIR="/home/steam/Zomboid/Logs"
DISCORD_API="https://discord.com/api/v10/channels/${DISCORD_CHANNEL_ID}/messages"
AUTH_HEADER="Authorization: Bot ${DISCORD_TOKEN}"
PLAYER_FILE="/tmp/online_players.txt"
STATUS_MSG_ID=""

> "$PLAYER_FILE"

send_discord() {
    curl -s -X POST "$DISCORD_API" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "{\"content\": \"$1\"}" > /dev/null 2>&1
}

edit_discord() {
    local msg_id="$1" content="$2"
    curl -s -X PATCH "${DISCORD_API}/${msg_id}" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "{\"content\": \"${content}\"}" > /dev/null 2>&1
}

create_status_msg() {
    local response
    response=$(curl -s -X POST "$DISCORD_API" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d '{"content": ":busts_in_silhouette: **Spieler online:** keine"}')
    STATUS_MSG_ID=$(echo "$response" | grep -oP '"id"\s*:\s*"\K[0-9]+' | head -1)
    echo "discord-events: status message id=${STATUS_MSG_ID}"
}

update_player_list() {
    [ -z "$STATUS_MSG_ID" ] && return
    local count
    count=$(wc -l < "$PLAYER_FILE" | tr -d ' ')
    if [ "$count" -eq 0 ]; then
        edit_discord "$STATUS_MSG_ID" ":busts_in_silhouette: **Spieler online (0):** keine"
    else
        local players
        players=$(sed 's/^/• /' "$PLAYER_FILE" | tr '\n' ',' | sed 's/,$//' | sed 's/,/ | /g')
        edit_discord "$STATUS_MSG_ID" ":busts_in_silhouette: **Spieler online (${count}):** ${players}"
    fi
}

add_player() {
    local player="$1"
    grep -qxF "$player" "$PLAYER_FILE" 2>/dev/null || echo "$player" >> "$PLAYER_FILE"
    update_player_list
}

remove_player() {
    local player="$1"
    grep -vxF "$player" "$PLAYER_FILE" > "${PLAYER_FILE}.tmp" && mv "${PLAYER_FILE}.tmp" "$PLAYER_FILE"
    update_player_list
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
            send_discord ":white_check_mark: **Server ist online — bereit zum Beitreten!**"
            create_status_msg ;;
        *"fully-connected"*)
            player=$(echo "$line" | grep -oP 'username="\K[^"]+')
            send_discord ":green_circle: **${player:-Ein Spieler}** hat den Server betreten"
            [ -n "$player" ] && add_player "$player" ;;
        *"receive-disconnect"*)
            player=$(echo "$line" | grep -oP 'username="\K[^"]+')
            send_discord ":red_circle: **${player:-Ein Spieler}** hat den Server verlassen"
            [ -n "$player" ] && remove_player "$player" ;;
        *"replacing dead player"*)
            player=$(echo "$line" | grep -oP 'username="\K[^"]+')
            send_discord ":skull: **${player:-Ein Spieler}** ist gestorben" ;;
    esac
done < <(tail -n +1 -F "$LOG_FILE" 2>/dev/null)
