#!/bin/bash
# Watches PZ server logs and posts events to Discord via bot API.
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

# Wait for a log file matching a pattern. Returns path in LOG_FOUND.
wait_for_log() {
    local pattern="$1"
    LOG_FOUND=""
    while true; do
        LOG_FOUND=$(ls -t "${LOG_DIR}"/$pattern 2>/dev/null | head -1)
        [ -n "$LOG_FOUND" ] && return
        sleep 5
    done
}

trap 'send_discord ":octagonal_sign: **Server wird heruntergefahren...**"; kill $(jobs -p) 2>/dev/null; exit 0' SIGTERM SIGINT

init_status_msg

# Server log watcher — runs in a loop to handle restarts/wipes
watch_server_log() {
    while true; do
        echo "discord-events: [server] waiting for log..."
        wait_for_log "*_DebugLog-server.txt"
        local log_file="$LOG_FOUND"
        echo "discord-events: [server] tailing ${log_file}"

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
        done < <(tail -n +1 -F "$log_file" 2>/dev/null) &
        local reader_pid=$!

        # Watch for log file disappearing (wipe) or newer file (restart)
        while kill -0 $reader_pid 2>/dev/null; do
            sleep 10
            if [ ! -f "$log_file" ]; then
                echo "discord-events: [server] log disappeared"
                kill $reader_pid 2>/dev/null; wait $reader_pid 2>/dev/null
                break
            fi
            local newer
            newer=$(find "${LOG_DIR}" -name "*_DebugLog-server.txt" -newer "$log_file" 2>/dev/null | head -1)
            if [ -n "$newer" ]; then
                echo "discord-events: [server] newer log found: ${newer}"
                kill $reader_pid 2>/dev/null; wait $reader_pid 2>/dev/null
                break
            fi
        done

        > "$PLAYER_FILE"
        update_player_list
        echo "discord-events: [server] restarting watcher..."
    done
}

# User log watcher — same pattern
watch_user_log() {
    while true; do
        echo "discord-events: [user] waiting for log..."
        wait_for_log "*_user.txt"
        local log_file="$LOG_FOUND"
        echo "discord-events: [user] tailing ${log_file}"

        while read -r line; do
            case "$line" in
                *" died at "*)
                    player=$(echo "$line" | grep -oP 'user \K\S+(?= died at)')
                    send_discord ":skull: **${player:-Ein Spieler}** ist gestorben" ;;
            esac
        done < <(tail -n +1 -F "$log_file" 2>/dev/null) &
        local reader_pid=$!

        while kill -0 $reader_pid 2>/dev/null; do
            sleep 10
            if [ ! -f "$log_file" ]; then
                echo "discord-events: [user] log disappeared"
                kill $reader_pid 2>/dev/null; wait $reader_pid 2>/dev/null
                break
            fi
            local newer
            newer=$(find "${LOG_DIR}" -name "*_user.txt" -newer "$log_file" 2>/dev/null | head -1)
            if [ -n "$newer" ]; then
                echo "discord-events: [user] newer log found: ${newer}"
                kill $reader_pid 2>/dev/null; wait $reader_pid 2>/dev/null
                break
            fi
        done

        echo "discord-events: [user] restarting watcher..."
    done
}

watch_server_log &
watch_user_log &
wait
