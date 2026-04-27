#!/bin/bash
# Watches PZ server console log and posts events to Discord via bot API.
# Also maintains a live player list message.
# Handles three restart scenarios:
#   1. Full stack restart  — waits for fresh log, reads from start
#   2. Discord-only restart — finds active log, follows new lines only
#   3. Server-only restart  — detects new log file, switches automatically

LOG_DIR="/home/steam/Zomboid/Logs"
DISCORD_API="https://discord.com/api/v10/channels/${DISCORD_CHANNEL_ID}/messages"
AUTH_HEADER="Authorization: Bot ${DISCORD_TOKEN}"
PLAYER_FILE="/tmp/online_players.txt"
STATUS_MSG_FILE="/tmp/status_msg_id.txt"
SERVER_FIFO="/tmp/server_log_fifo"
USER_FIFO="/tmp/user_log_fifo"

> "$PLAYER_FILE"
> "$STATUS_MSG_FILE"
rm -f "$SERVER_FIFO" "$USER_FIFO"
mkfifo "$SERVER_FIFO" "$USER_FIFO"

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

# Manages tail for a log file pattern, writes lines to a FIFO.
# Auto-detects new log files (server restart) and switches to them.
# On first run: finds active log (discord restart) or waits for fresh one (full restart).
manage_tail() {
    local pattern="$1" fifo="$2" label="$3"
    exec 3>"$fifo"  # hold FIFO open so readers never get EOF between switches
    local first_run=true

    while true; do
        local log_file="" tail_start=""

        if $first_run; then
            # Check for an actively-written log (discord-only restart)
            log_file=$(find "${LOG_DIR}" -name "$pattern" -mmin -5 2>/dev/null | sort -r | head -1)
            if [ -n "$log_file" ]; then
                tail_start="-n 0"
                echo "discord-events: [${label}] found active ${log_file} (new lines only)"
            else
                # Wait for a fresh log (full stack restart)
                touch /tmp/discord-start-marker
                echo "discord-events: [${label}] waiting for fresh log..."
                while true; do
                    log_file=$(find "${LOG_DIR}" -name "$pattern" -newer /tmp/discord-start-marker 2>/dev/null | head -1)
                    [ -n "$log_file" ] && break
                    sleep 5
                done
                tail_start="-n +1"
                echo "discord-events: [${label}] found fresh ${log_file} (from start)"
            fi
            first_run=false
        else
            # Server restarted — wait for a newer log than the one we were watching
            echo "discord-events: [${label}] waiting for newer log..."
            > "$PLAYER_FILE"
            update_player_list
            if [ -f "$prev_log" ]; then
                # Reference file exists — find something newer
                while true; do
                    log_file=$(find "${LOG_DIR}" -name "$pattern" -newer "$prev_log" 2>/dev/null | head -1)
                    [ -n "$log_file" ] && break
                    sleep 5
                done
            else
                # Reference file gone (volume wiped) — wait for any matching file
                touch /tmp/discord-start-marker
                while true; do
                    log_file=$(find "${LOG_DIR}" -name "$pattern" -newer /tmp/discord-start-marker 2>/dev/null | head -1)
                    [ -n "$log_file" ] && break
                    sleep 5
                done
            fi
            tail_start="-n +1"
            echo "discord-events: [${label}] switching to ${log_file} (from start)"
        fi

        local prev_log="$log_file"

        tail $tail_start -F "$log_file" >"$fifo" 2>/dev/null &
        local tail_pid=$!

        # Poll for a newer log file (server restart detection)
        while kill -0 $tail_pid 2>/dev/null; do
            sleep 30
            if [ ! -f "$log_file" ]; then
                echo "discord-events: [${label}] log file disappeared (wipe?)"
                kill $tail_pid 2>/dev/null
                wait $tail_pid 2>/dev/null
                break
            fi
            local newer
            newer=$(find "${LOG_DIR}" -name "$pattern" -newer "$log_file" 2>/dev/null | head -1)
            if [ -n "$newer" ]; then
                echo "discord-events: [${label}] detected newer log ${newer}"
                kill $tail_pid 2>/dev/null
                wait $tail_pid 2>/dev/null
                break
            fi
        done
    done
}

trap 'send_discord ":octagonal_sign: **Server wird heruntergefahren...**"; kill $(jobs -p) 2>/dev/null; exit 0' SIGTERM SIGINT

init_status_msg

# Start tail managers (background)
manage_tail "*_DebugLog-server.txt" "$SERVER_FIFO" "server" &
manage_tail "*_user.txt" "$USER_FIFO" "user" &

# Process server events
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
done < "$SERVER_FIFO" &

# Process user events (deaths)
while read -r line; do
    case "$line" in
        *" died at "*)
            player=$(echo "$line" | grep -oP 'user \K\S+(?= died at)')
            send_discord ":skull: **${player:-Ein Spieler}** ist gestorben" ;;
    esac
done < "$USER_FIFO" &

wait
