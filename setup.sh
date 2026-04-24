#!/bin/bash
# One-time setup: boots the server, extracts the generated .ini,
# merges custom overrides, and saves it as the final config.
# After this, the .ini is mounted as read-only and the patcher is no longer needed.

set -e

SERVER_NAME=$(grep '^SERVER_NAME=' .env | cut -d'=' -f2)

CONTAINER="zomboid-server"
INI_PATH="/home/steam/Zomboid/Server/${SERVER_NAME}.ini"
LOCAL_INI="./server-config/${SERVER_NAME}.ini"
OVERRIDES="./server-config/servertest.ini"

echo "=== Step 1: Starting server to generate default .ini ==="
docker compose up -d zomboid
echo "Waiting for ${INI_PATH} to be generated..."

while ! docker exec "$CONTAINER" test -f "$INI_PATH" 2>/dev/null; do
    sleep 3
    echo "  still waiting..."
done
echo "Found .ini!"

echo ""
echo "=== Step 2: Extracting generated .ini ==="
docker cp "${CONTAINER}:${INI_PATH}" "$LOCAL_INI"
echo "Saved to ${LOCAL_INI}"

echo ""
echo "=== Step 3: Merging overrides from ${OVERRIDES} ==="
while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue

    key="${line%%=*}"
    value="${line#*=}"

    if grep -q "^${key}=" "$LOCAL_INI"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$LOCAL_INI"
        echo "  updated: ${key}"
    else
        echo "${key}=${value}" >> "$LOCAL_INI"
        echo "  added:   ${key}"
    fi
done < "$OVERRIDES"

echo ""
echo "=== Step 4: Stopping server ==="
docker compose down

echo ""
echo "=== Done! ==="
echo ""
echo "Your merged config is at: ${LOCAL_INI}"
echo ""
echo "Next steps:"
echo "  1. Review ${LOCAL_INI} if you want"
echo "  2. Run: docker compose up -d"
echo "  3. The .ini is now mounted read-only — no more patcher needed"
