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

# Parse mods.txt into MOD_WORKSHOP_IDS
MODS_FILE="/overrides/mods.txt"
if [ -f "$MODS_FILE" ]; then
    workshop_ids=""
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        if [[ "$line" =~ id=([0-9]+) ]]; then
            wid="${BASH_REMATCH[1]}"
        else
            wid=$(echo "$line" | awk '{print $1}')
        fi
        [ -z "$wid" ] && continue
        workshop_ids="${workshop_ids:+${workshop_ids};}${wid}"
    done < "$MODS_FILE"
    if [ -n "$workshop_ids" ]; then
        export MOD_WORKSHOP_IDS="$workshop_ids"
        echo "entrypoint: loaded mods from mods.txt"
        echo "  MOD_WORKSHOP_IDS=${MOD_WORKSHOP_IDS}"
    fi
fi

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
    echo "entrypoint: first-boot patching done. Restarting server with patched config..."
    kill $SERVER_PID
    wait $SERVER_PID 2>/dev/null
    /home/steam/run_server.sh &
    SERVER_PID=$!
fi

# Keep container alive by waiting on the server process
wait $SERVER_PID
