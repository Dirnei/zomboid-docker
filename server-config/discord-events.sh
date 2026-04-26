#!/bin/bash
# Watches PZ server console log and posts events to Discord via bot API.
# Also maintains a live player list message.

LOG_DIR="/home/steam/Zomboid/Logs"
DISCORD_API="https://discord.com/api/v10/channels/${DISCORD_CHANNEL_ID}/messages"
AUTH_HEADER="Authorization: Bot ${DISCORD_TOKEN}"
PLAYER_FILE="/tmp/online_players.txt"
STATUS_MSG_FILE="/tmp/status_msg_id.txt"

> "$PLAYER_FILE"
> "$STATUS_MSG_FILE"

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

init_status_msg() {
    if [ -n "$DISCORD_STATUS_MSG_ID" ]; then
        echo "$DISCORD_STATUS_MSG_ID" > "$STATUS_MSG_FILE"
        echo "discord-events: reusing status message id=${DISCORD_STATUS_MSG_ID}"
        update_player_list
    else
        local response
        response=$(curl -s -X POST "$DISCORD_API" \
            -H "$AUTH_HEADER" \
            -H "Content-Type: application/json" \
            -d '{"content": ":busts_in_silhouette: **Spieler online (0):** keine"}')
        local msg_id
        msg_id=$(echo "$response" | grep -oP '"id"\s*:\s*"\K[0-9]+' | head -1)
        echo "$msg_id" > "$STATUS_MSG_FILE"
        echo "discord-events: created status message id=${msg_id}"
        echo "discord-events: >>> Add DISCORD_STATUS_MSG_ID=${msg_id} to .env to persist across restarts <<<"
    fi
}

update_player_list() {
    local msg_id
    msg_id=$(cat "$STATUS_MSG_FILE" 2>/dev/null)
    [ -z "$msg_id" ] && return
    local count
    count=$(wc -l < "$PLAYER_FILE" | tr -d ' ')
    if [ "$count" -eq 0 ]; then
        edit_discord "$msg_id" ":busts_in_silhouette: **Spieler online (0):** keine"
    else
        local players
        players=$(sed 's/^/• /' "$PLAYER_FILE" | tr '\n' ',' | sed 's/,$//' | sed 's/,/ | /g')
        edit_discord "$msg_id" ":busts_in_silhouette: **Spieler online (${count}):** ${players}"
    fi
}

add_player() {
    grep -qxF "$1" "$PLAYER_FILE" 2>/dev/null || echo "$1" >> "$PLAYER_FILE"
    update_player_list
}

remove_player() {
    sed -i "/^${1}$/d" "$PLAYER_FILE"
    update_player_list
}

trap 'send_discord ":octagonal_sign: **Server wird heruntergefahren...**"; kill $(jobs -p) 2>/dev/null; exit 0' SIGTERM SIGINT

init_status_msg

# Find a log file: first check for an active one (discord-only restart),
# then fall back to waiting for a fresh one (full stack restart).
# Returns: sets LOG_RESULT and TAIL_MODE ("new" or "existing")
find_log() {
    local pattern="$1"
    local active
    active=$(find "${LOG_DIR}" -name "$pattern" -mmin -5 2>/dev/null | sort -r | head -1)
    if [ -n "$active" ]; then
        LOG_RESULT="$active"
        TAIL_MODE="existing"
        return
    fi
    touch /tmp/discord-start-marker
    while true; do
        local fresh
        fresh=$(find "${LOG_DIR}" -name "$pattern" -newer /tmp/discord-start-marker 2>/dev/null | head -1)
        if [ -n "$fresh" ]; then
            LOG_RESULT="$fresh"
            TAIL_MODE="new"
            return
        fi
        sleep 5
    done
}

echo "discord-events: looking for server log..."
find_log "*_DebugLog-server.txt"
LOG_FILE="$LOG_RESULT"
if [ "$TAIL_MODE" = "existing" ]; then
    echo "discord-events: found active log ${LOG_FILE} (following new lines only)"
    TAIL_START="-n 0"
else
    echo "discord-events: found fresh log ${LOG_FILE} (reading from start)"
    TAIL_START="-n +1"
fi

while read -r line; do
    case "$line" in
        *"SERVER STARTED"*)
            send_discord ":white_check_mark: **Server ist online — bereit zum Beitreten!**" ;;
        *"fully-connected"*)
            player=$(echo "$line" | grep -oP 'username="\K[^"]+')
            send_discord ":green_circle: **${player:-Ein Spieler}** hat den Server betreten"
            [ -n "$player" ] && add_player "$player" ;;
        *"receive-disconnect"*)
            player=$(echo "$line" | grep -oP 'username="\K[^"]+')
            send_discord ":red_circle: **${player:-Ein Spieler}** hat den Server verlassen"
            [ -n "$player" ] && remove_player "$player" ;;
    esac
done < <(tail $TAIL_START -F "$LOG_FILE" 2>/dev/null) &

echo "discord-events: looking for user log..."
find_log "*_user.txt"
USER_LOG="$LOG_RESULT"
if [ "$TAIL_MODE" = "existing" ]; then
    echo "discord-events: found active user log ${USER_LOG} (following new lines only)"
    TAIL_START="-n 0"
else
    echo "discord-events: found fresh user log ${USER_LOG} (reading from start)"
    TAIL_START="-n +1"
fi

while read -r line; do
    case "$line" in
        *" died at "*)
            player=$(echo "$line" | grep -oP 'user \K\S+(?= died at)')
            send_discord ":skull: **${player:-Ein Spieler}** ist gestorben" ;;
    esac
done < <(tail $TAIL_START -F "$USER_LOG" 2>/dev/null)
