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
        sed -i "s|^${key}=.*|${key}=${value}|" "$SERVER_INI"
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

# Parse mods.txt into MOD_WORKSHOP_IDS and MOD_IDS
MODS_FILE="/overrides/mods.txt"
load_mods() {
    [ ! -f "$MODS_FILE" ] && return
    local workshop_ids="" mod_ids=""
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        local wid="" mid=""
        if [[ "$line" =~ id=([0-9]+) ]]; then
            wid="${BASH_REMATCH[1]}"
        else
            wid=$(echo "$line" | awk '{print $1}')
        fi
        mid=$(echo "$line" | awk '{print $2}')
        [ -z "$wid" ] && continue
        if [ -z "$mid" ]; then
            mid=$(discover_mod_id "$wid")
            [ -n "$mid" ] && echo "entrypoint: auto-discovered Mod ID for ${wid}: ${mid}"
        fi
        workshop_ids="${workshop_ids:+${workshop_ids};}${wid}"
        [ -n "$mid" ] && mod_ids="${mod_ids:+${mod_ids};}${mid}"
    done < "$MODS_FILE"
    if [ -n "$workshop_ids" ]; then
        export MOD_WORKSHOP_IDS="$workshop_ids"
        export MOD_IDS="$mod_ids"
        echo "entrypoint: loaded mods"
        echo "  MOD_WORKSHOP_IDS=${MOD_WORKSHOP_IDS}"
        echo "  MOD_IDS=${MOD_IDS}"
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

# After server starts, check if new mods need Mod ID discovery
SAVED_MOD_IDS="$MOD_IDS"
{
    LOG_DIR="/home/steam/Zomboid/Logs"
    while ! ls "${LOG_DIR}"/*_DebugLog-server.txt &>/dev/null; do sleep 5; done
    LOG_FILE=$(ls -t "${LOG_DIR}"/*_DebugLog-server.txt | head -1)
    grep -q "SERVER STARTED" "$LOG_FILE" 2>/dev/null || tail -F "$LOG_FILE" 2>/dev/null | grep -m1 "SERVER STARTED" > /dev/null
    load_mods
    if [ "$MOD_IDS" != "$SAVED_MOD_IDS" ] && [ -n "$MOD_IDS" ]; then
        echo "entrypoint: new Mod IDs discovered: ${MOD_IDS}"
        echo "entrypoint: restarting server to activate new mods..."
        kill $SERVER_PID 2>/dev/null
    fi
} &
WATCHER_PID=$!

# Keep container alive
wait $SERVER_PID 2>/dev/null
kill $WATCHER_PID 2>/dev/null

# If MOD_IDS changed, server was killed for restart
load_mods
if [ "$MOD_IDS" != "$SAVED_MOD_IDS" ] && [ -n "$MOD_IDS" ]; then
    /home/steam/run_server.sh &
    wait $!
fi
