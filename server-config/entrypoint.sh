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
STATUS_FILE="/home/steam/Zomboid/.server_status"

write_status() {
    echo "$1" > "$STATUS_FILE"
    echo "entrypoint: status → $1"
}

trap 'write_status "stopping"; kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null; write_status "stopped"' SIGTERM SIGINT

load_mods
patch_ini

write_status "starting"

# Start the server (handles steamcmd update + first boot config generation)
/home/steam/run_server.sh &
SERVER_PID=$!

# Wait for .ini to appear (first boot), then patch and restart once
if [ ! -f "$SERVER_INI" ]; then
    echo "entrypoint: waiting for config generation..."
    while [ ! -f "$SERVER_INI" ]; do sleep 2; done
    load_mods
    patch_ini
fi

# Keep container alive
wait $SERVER_PID
write_status "stopped"
