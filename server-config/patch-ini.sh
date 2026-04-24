#!/bin/bash
# Continuously patches custom .ini overrides into the server-generated config.
# Runs as a sidecar — watches for changes and re-applies if the image overwrites the file.
# Also applies env vars (passwords, server name, etc.) so .env stays the source of truth.

SERVER_INI="/home/steam/Zomboid/Server/${SERVER_NAME}.ini"
OVERRIDES="/overrides/servertest.ini"
LAST_HASH=""

patch_key() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$SERVER_INI"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$SERVER_INI"
        echo "patch-ini:   updated ${key}"
    else
        echo "${key}=${value}" >> "$SERVER_INI"
        echo "patch-ini:   added ${key}"
    fi
}

echo "patch-ini: watching ${SERVER_INI}..."

while true; do
    if [ ! -f "$SERVER_INI" ]; then
        sleep 5
        continue
    fi

    CURRENT_HASH=$(md5sum "$SERVER_INI" | cut -d' ' -f1)

    if [ "$CURRENT_HASH" != "$LAST_HASH" ]; then
        echo "patch-ini: .ini changed, applying overrides..."

        # Apply env var overrides (passwords, max players, etc.)
        [ -n "$SERVER_PASSWORD" ] && patch_key "Password" "$SERVER_PASSWORD"
        [ -n "$ADMIN_PASSWORD" ]  && patch_key "AdminPassword" "$ADMIN_PASSWORD"
        [ -n "$RCON_PASSWORD" ]   && patch_key "RCONPassword" "$RCON_PASSWORD"
        [ -n "$MAX_PLAYERS" ]     && patch_key "MaxPlayers" "$MAX_PLAYERS"

        # Apply file-based overrides
        while IFS= read -r line; do
            [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
            key="${line%%=*}"
            value="${line#*=}"
            patch_key "$key" "$value"
        done < "$OVERRIDES"

        LAST_HASH=$(md5sum "$SERVER_INI" | cut -d' ' -f1)
        echo "patch-ini: done. watching for changes..."
    fi

    sleep 10
done
