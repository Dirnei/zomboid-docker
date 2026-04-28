#!/bin/bash
# Wrapper entrypoint: patches .ini overrides, then starts the server.

SERVER_INI="/home/steam/Zomboid/Server/${SERVER_NAME}.ini"
OVERRIDES="/overrides/overrides.ini"

patch_ini() {
    [ ! -f "$SERVER_INI" ] && return

    echo "entrypoint: patching ${SERVER_INI}..."

    # Env var overrides
    [ -n "$SERVER_PASSWORD" ]    && patch_key "Password" "$SERVER_PASSWORD"
    [ -n "$ADMIN_PASSWORD" ]     && patch_key "AdminPassword" "$ADMIN_PASSWORD"
    [ -n "$RCON_PASSWORD" ]      && patch_key "RCONPassword" "$RCON_PASSWORD"
    [ -n "$MAX_PLAYERS" ]        && patch_key "MaxPlayers" "$MAX_PLAYERS"
    [ -n "$DISCORD_TOKEN" ]      && patch_key "DiscordToken" "$DISCORD_TOKEN"
    [ -n "$DISCORD_CHANNEL_ID" ] && patch_key "DiscordChannelID" "$DISCORD_CHANNEL_ID"
    [ -n "$MOD_NAMES" ]            && patch_key "Mods" "$MOD_NAMES"
    [ -n "$MOD_WORKSHOP_IDS" ]   && patch_key "WorkshopItems" "$MOD_WORKSHOP_IDS"

    # File-based overrides
    if [ -f "$OVERRIDES" ]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
            patch_key "${line%%=*}" "${line#*=}"
        done < "$OVERRIDES"
    fi

    echo "entrypoint: patching done."
}

patch_key() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$SERVER_INI"; then
        # Delete old line and append new one (avoids sed special char issues)
        grep -v "^${key}=" "$SERVER_INI" > "${SERVER_INI}.tmp"
        echo "${key}=${value}" >> "${SERVER_INI}.tmp"
        mv "${SERVER_INI}.tmp" "$SERVER_INI"
        echo "  updated: ${key}"
    else
        echo "${key}=${value}" >> "$SERVER_INI"
        echo "  added:   ${key}"
    fi
}

# Auto-discover Mod ID from downloaded workshop mod files
discover_mod_id() {
    local wid="$1"
    local search_dirs=(
        "/home/steam/ZomboidDedicatedServer/steamapps/workshop/content/108600/${wid}"
        "/home/steam/Zomboid/Workshop/${wid}"
    )
    for dir in "${search_dirs[@]}"; do
        if [ -d "$dir" ]; then
            local mod_info
            mod_info=$(find "$dir" -name "mod.info" -print -quit 2>/dev/null)
            if [ -n "$mod_info" ]; then
                local mid
                mid=$(grep -oP '^id=\K.+' "$mod_info" | head -1 | tr -d '[:space:]')
                [ -n "$mid" ] && echo "$mid" && return
            fi
        fi
    done
}

# Pre-scan all already-downloaded workshop mods
WORKSHOP_DIR="/home/steam/ZomboidDedicatedServer/steamapps/workshop/content/108600"
declare -A KNOWN_MOD_NAMES

prescan_mods() {
    KNOWN_MOD_NAMES=()
    [ ! -d "$WORKSHOP_DIR" ] && return
    for dir in "$WORKSHOP_DIR"/*/; do
        [ ! -d "$dir" ] && continue
        local wid mid mod_info
        wid=$(basename "$dir")
        mod_info=$(find "$dir" -name "mod.info" -print -quit 2>/dev/null)
        if [ -n "$mod_info" ]; then
            mid=$(grep -oP '^id=\K.+' "$mod_info" | head -1 | tr -d '[:space:]')
            [ -n "$mid" ] && KNOWN_MOD_NAMES["$wid"]="$mid"
        fi
    done
    [ ${#KNOWN_MOD_NAMES[@]} -gt 0 ] && echo "entrypoint: pre-scan found ${#KNOWN_MOD_NAMES[@]} downloaded mod(s)"
}

# Parse mods.txt into MOD_WORKSHOP_IDS and MOD_NAMES
MODS_FILE="/overrides/mods.txt"
load_mods() {
    [ ! -f "$MODS_FILE" ] && return
    prescan_mods
    local workshop_ids="" mod_ids="" updated=false
    local -a lines=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^#.*$ || -z "$line" ]]; then
            lines+=("$line")
            continue
        fi
        local wid="" mid=""
        if [[ "$line" =~ id=([0-9]+) ]]; then
            wid="${BASH_REMATCH[1]}"
        else
            wid=$(echo "$line" | awk '{print $1}')
        fi
        mid=$(echo "$line" | awk '{print $2}')
        [ -z "$wid" ] && continue
        # Use pre-scan cache, then fall back to direct discovery
        if [ -z "$mid" ]; then
            mid="${KNOWN_MOD_NAMES[$wid]}"
        fi
        if [ -z "$mid" ]; then
            mid=$(discover_mod_id "$wid")
        fi
        if [ -n "$mid" ]; then
            echo "entrypoint: ${wid} → ${mid}"
            lines+=("${wid} ${mid}")
            # Check if we discovered a new ID (line didn't have one)
            [ "$(echo "$line" | awk '{print $2}')" != "$mid" ] && updated=true
        else
            lines+=("${wid}")
        fi
        workshop_ids="${workshop_ids:+${workshop_ids};}${wid}"
        [ -n "$mid" ] && mod_ids="${mod_ids:+${mod_ids};}${mid}"
    done < "$MODS_FILE"
    # Write back discovered IDs to mods.txt
    if $updated; then
        printf '%s\n' "${lines[@]}" > "$MODS_FILE"
        echo "entrypoint: updated mods.txt with discovered Mod IDs"
    fi
    if [ -n "$workshop_ids" ]; then
        export MOD_WORKSHOP_IDS="$workshop_ids"
        export MOD_NAMES="$mod_ids"
        echo "entrypoint: MOD_WORKSHOP_IDS=${MOD_WORKSHOP_IDS}"
        echo "entrypoint: MOD_NAMES=${MOD_NAMES}"
    fi
}
load_mods

# Detect first boot before starting the server
FIRST_BOOT=false
[ ! -f "$SERVER_INI" ] && FIRST_BOOT=true

# If .ini already exists from a previous run, patch before server starts
patch_ini

# Start the server
/home/steam/run_server.sh &
SERVER_PID=$!

# First boot: wait for .ini to be generated, patch it, restart server
if $FIRST_BOOT; then
    echo "entrypoint: first boot — waiting for .ini generation..."
    while [ ! -f "$SERVER_INI" ]; do
        sleep 2
    done
    patch_ini
    echo "entrypoint: first-boot patching done. Re-discovering mods and restarting..."
    kill $SERVER_PID
    wait $SERVER_PID 2>/dev/null
    load_mods
    /home/steam/run_server.sh &
    SERVER_PID=$!
fi

# Watch for workshop downloads and auto-discover Mod IDs
SAVED_MOD_NAMES="$MOD_NAMES"
{
    LOG_DIR="/home/steam/Zomboid/Logs"
    # Wait for log file
    while ! ls "${LOG_DIR}"/*_DebugLog-server.txt &>/dev/null; do sleep 5; done
    LOG_FILE=$(ls -t "${LOG_DIR}"/*_DebugLog-server.txt | head -1)

    # Watch log for workshop installs and server start
    downloads_seen=0
    tail -n +1 -F "$LOG_FILE" 2>/dev/null | while read -r line; do
        case "$line" in
            *"Workshop:"*"installed to"*)
                wid=$(echo "$line" | grep -oP 'Workshop: \K[0-9]+')
                path=$(echo "$line" | grep -oP 'installed to \K.+')
                if [ -n "$wid" ] && [ -n "$path" ]; then
                    mid=$(find "$path" -name "mod.info" -exec grep -oP '^id=\K.+' {} \; 2>/dev/null | head -1 | tr -d '[:space:]')
                    echo "entrypoint: workshop ${wid} installed → Mod ID: ${mid:-NOT FOUND}"
                    downloads_seen=$((downloads_seen + 1))
                fi ;;
            *"SERVER STARTED"*)
                if [ $downloads_seen -gt 0 ]; then
                    echo "entrypoint: ${downloads_seen} mod(s) downloaded, re-discovering..."
                    load_mods
                    if [ "$MOD_NAMES" != "$SAVED_MOD_NAMES" ] && [ -n "$MOD_NAMES" ]; then
                        echo "entrypoint: new MOD_NAMES=${MOD_NAMES}"
                        echo "entrypoint: restarting server to activate mods..."
                        kill $SERVER_PID 2>/dev/null
                    fi
                fi
                break ;;
        esac
    done
} &
WATCHER_PID=$!

# Keep container alive
wait $SERVER_PID 2>/dev/null
kill $WATCHER_PID 2>/dev/null

# If server was killed for mod re-discovery, restart with updated IDs
load_mods
if [ "$MOD_NAMES" != "$SAVED_MOD_NAMES" ] && [ -n "$MOD_NAMES" ]; then
    echo "entrypoint: restarting with MOD_NAMES=${MOD_NAMES}"
    /home/steam/run_server.sh &
    wait $!
fi
