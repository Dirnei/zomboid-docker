#!/bin/bash
# Watches PZ server logs and posts events to Discord via bot API.
# Also maintains a live player list message.

LOG_DIR="/home/steam/Zomboid/Logs"
DISCORD_API="https://discord.com/api/v10/channels/${DISCORD_CHANNEL_ID}/messages"
AUTH_HEADER="Authorization: Bot ${DISCORD_TOKEN}"
PLAYER_FILE="/tmp/online_players.txt"
STATUS_MSG_FILE="/tmp/status_msg_id.txt"
LAST_TS_FILE="/data/last_timestamp.txt"
STATS_FILE="/data/stats.json"
SESSIONS_FILE="/tmp/sessions.txt"

> "$PLAYER_FILE"
> "$STATUS_MSG_FILE"
> "$SESSIONS_FILE"

# Initialize stats file if missing
[ ! -f "$STATS_FILE" ] && echo '{"players":{},"server":{"starts":0}}' > "$STATS_FILE"

LAST_TS=$(cat "$LAST_TS_FILE" 2>/dev/null || echo "")
[ -n "$LAST_TS" ] && echo "discord-events: resuming after timestamp ${LAST_TS}"

save_ts() {
    echo "$1" > "$LAST_TS_FILE"
    LAST_TS="$1"
}

# Update stats JSON using a simple Python one-liner (jq alternative)
update_stats() {
    local action="$1" player="$2" ts="$3"
    python3 -c "
import json, sys
action, player, ts = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open('$STATS_FILE') as f: stats = json.load(f)
except: stats = {'players': {}, 'server': {'starts': 0}}
if action == 'server_start':
    stats['server']['starts'] = stats['server'].get('starts', 0) + 1
    stats['server']['last_start'] = ts
elif player:
    p = stats['players'].setdefault(player, {'deaths': 0, 'sessions': 0, 'playtime_min': 0})
    if action == 'join':
        p['sessions'] = p.get('sessions', 0) + 1
        p['last_join'] = ts
        if not p.get('first_seen'): p['first_seen'] = ts
    elif action == 'leave':
        p['last_seen'] = ts
        if p.get('last_join'):
            try:
                from datetime import datetime
                fmt = '%y-%m-%d %H:%M:%S'
                jt = datetime.strptime(p['last_join'][:17], fmt)
                lt = datetime.strptime(ts[:17], fmt)
                p['playtime_min'] = p.get('playtime_min', 0) + max(0, int((lt - jt).total_seconds() / 60))
            except: pass
            p['last_join'] = ''
    elif action == 'death':
        p['deaths'] = p.get('deaths', 0) + 1
        p['last_death'] = ts
with open('$STATS_FILE', 'w') as f: json.dump(stats, f, indent=2)
" "$action" "$player" "$ts" 2>/dev/null
}

# Extract timestamp from a log line: [25-04-26 19:34:05.001]
get_ts() {
    echo "$1" | grep -oP '^\[\K[0-9-]+ [0-9:.]+' | head -1
}

# Returns 0 if line should be processed, 1 if it should be skipped
should_process() {
    local ts
    ts=$(get_ts "$1")
    [ -z "$ts" ] && return 0
    [ -z "$LAST_TS" ] && return 0
    [[ "$ts" > "$LAST_TS" ]] && return 0
    return 1
}

EVENT_THREAD_FILE="/data/event_thread_id.txt"
EVENT_THREAD_ID=$(cat "$EVENT_THREAD_FILE" 2>/dev/null || echo "")

# Post to main channel (for player list)
send_discord() {
    curl -s -X POST "$DISCORD_API" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "{\"content\": \"$1\"}" > /dev/null 2>&1
}

# Edit message in main channel
edit_discord() {
    local msg_id="$1" content="$2"
    curl -s -X PATCH "${DISCORD_API}/${msg_id}" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "{\"content\": \"${content}\"}" > /dev/null 2>&1
}

# Create or reuse the events thread
init_event_thread() {
    if [ -n "$EVENT_THREAD_ID" ]; then
        echo "discord-events: reusing event thread id=${EVENT_THREAD_ID}"
        return
    fi
    echo "discord-events: creating event thread..."
    local response
    response=$(curl -s -X POST "https://discord.com/api/v10/channels/${DISCORD_CHANNEL_ID}/threads" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d '{"name": "Server-Events", "type": 11, "auto_archive_duration": 10080}')
    EVENT_THREAD_ID=$(echo "$response" | grep -oP '"id"\s*:\s*"\K[0-9]+' | head -1)
    if [ -n "$EVENT_THREAD_ID" ]; then
        echo "$EVENT_THREAD_ID" > "$EVENT_THREAD_FILE"
        echo "discord-events: created event thread id=${EVENT_THREAD_ID}"
    else
        echo "discord-events: WARNING — thread creation failed: ${response}"
        echo "discord-events: falling back to main channel"
    fi
}

# Post to events thread, falls back to main channel
send_event() {
    local channel="${EVENT_THREAD_ID:-${DISCORD_CHANNEL_ID}}"
    curl -s -X POST "https://discord.com/api/v10/channels/${channel}/messages" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "{\"content\": \"$1\"}" > /dev/null 2>&1
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

trap 'send_event ":octagonal_sign: **Server wird heruntergefahren...**"; kill $(jobs -p) 2>/dev/null; exit 0' SIGTERM SIGINT

init_status_msg
init_event_thread

# Server log watcher — runs in a loop to handle restarts/wipes
watch_server_log() {
    while true; do
        echo "discord-events: [server] waiting for log..."
        wait_for_log "*_DebugLog-server.txt"
        local log_file="$LOG_FOUND"
        echo "discord-events: [server] tailing ${log_file}"

        while read -r line; do
            should_process "$line" || continue
            local ts
            ts=$(get_ts "$line")
            case "$line" in
                *"SERVER STARTED"*)
                    send_event ":white_check_mark: **Server ist online — bereit zum Beitreten!**"
                    update_stats "server_start" "" "$ts"
                    [ -n "$ts" ] && save_ts "$ts" ;;
                *"fully-connected"*)
                    player=$(echo "$line" | grep -oP 'username="\K[^"]+')
                    send_event ":green_circle: **${player:-Ein Spieler}** hat den Server betreten"
                    [ -n "$player" ] && add_player "$player"
                    [ -n "$player" ] && update_stats "join" "$player" "$ts"
                    [ -n "$ts" ] && save_ts "$ts" ;;
                *"receive-disconnect"*)
                    player=$(echo "$line" | grep -oP 'username="\K[^"]+')
                    send_event ":red_circle: **${player:-Ein Spieler}** hat den Server verlassen"
                    [ -n "$player" ] && remove_player "$player"
                    [ -n "$player" ] && update_stats "leave" "$player" "$ts"
                    [ -n "$ts" ] && save_ts "$ts" ;;
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
            should_process "$line" || continue
            local ts
            ts=$(get_ts "$line")
            case "$line" in
                *" died at "*)
                    player=$(echo "$line" | grep -oP 'user \K.+(?= died at)')
                    send_event ":skull: **${player:-Ein Spieler}** ist gestorben"
                    [ -n "$player" ] && update_stats "death" "$player" "$ts"
                    [ -n "$ts" ] && save_ts "$ts" ;;
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
