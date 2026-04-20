#!/bin/bash
# Continuously patches custom .ini overrides into the server-generated config.
# Runs as a sidecar — watches for changes and re-applies if the image overwrites the file.

SERVER_INI="/home/steam/Zomboid/Server/${SERVER_NAME}.ini"
OVERRIDES="/overrides/servertest.ini"
LAST_HASH=""

echo "patch-ini: watching ${SERVER_INI}..."

while true; do
    if [ ! -f "$SERVER_INI" ]; then
        sleep 5
        continue
    fi

    CURRENT_HASH=$(md5sum "$SERVER_INI" | cut -d' ' -f1)

    if [ "$CURRENT_HASH" != "$LAST_HASH" ]; then
        echo "patch-ini: .ini changed, applying overrides..."

        while IFS= read -r line; do
            [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue

            key="${line%%=*}"
            value="${line#*=}"

            if grep -q "^${key}=" "$SERVER_INI"; then
                sed -i "s|^${key}=.*|${key}=${value}|" "$SERVER_INI"
                echo "patch-ini:   updated ${key}"
            else
                echo "${key}=${value}" >> "$SERVER_INI"
                echo "patch-ini:   added ${key}"
            fi
        done < "$OVERRIDES"

        LAST_HASH=$(md5sum "$SERVER_INI" | cut -d' ' -f1)
        echo "patch-ini: done. watching for changes..."
    fi

    sleep 10
done
