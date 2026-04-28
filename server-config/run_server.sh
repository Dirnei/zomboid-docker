#!/bin/bash
set -o pipefail

BASE_GAME_DIR="/home/steam/ZomboidDedicatedServer"
CONFIG_DIR="/home/steam/Zomboid"
STEAM_INSTALL_FILE="/home/steam/install_server.scmd"

BIND_IP=${BIND_IP:-""}
if [[ -z "$BIND_IP" ]] || [[ "$BIND_IP" == "0.0.0.0" ]]; then
    BIND_IP=($(hostname -I))
    BIND_IP="${BIND_IP[0]}"
fi
echo "$BIND_IP" > "$CONFIG_DIR/ip.txt"

SERVER_NAME=${SERVER_NAME:-"ZomboidServer"}
ADMIN_USERNAME=${ADMIN_USERNAME:-"admin"}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-"changeme"}
DEFAULT_PORT=${DEFAULT_PORT:-"16261"}
MAX_RAM=${MAX_RAM:-"4096m"}
STEAM_VAC=${STEAM_VAC:-"true"}

if [[ -z "$USE_STEAM" ]] || [[ "$USE_STEAM" == "true" ]]; then
    USE_STEAM=""
else
    USE_STEAM="-nosteam"
fi

# Update game files via steamcmd
printf "\n### Updating Project Zomboid Server...\n"
steamcmd.sh +runscript "$STEAM_INSTALL_FILE"
printf "\n### Update complete.\n"

# Set JVM memory
sed -i "s/-Xmx.*/-Xmx${MAX_RAM}\",/g" "${BASE_GAME_DIR}/ProjectZomboid64.json"

# First run: start briefly to generate config files
SERVER_CONFIG="$CONFIG_DIR/Server/$SERVER_NAME.ini"
if [[ ! -f "$SERVER_CONFIG" ]]; then
    printf "\n### First run — generating config files...\n"
    timeout 60 "$BASE_GAME_DIR"/start-server.sh \
        -cachedir="$CONFIG_DIR" \
        -adminusername "$ADMIN_USERNAME" \
        -adminpassword "$ADMIN_PASSWORD" \
        -ip "$BIND_IP" -port "$DEFAULT_PORT" \
        -servername "$SERVER_NAME" \
        -steamvac "$STEAM_VAC" $USE_STEAM || true
    printf "\n### Config files generated.\n"
fi

# Start the server
printf "\n### Starting Project Zomboid Server...\n"
"$BASE_GAME_DIR"/start-server.sh \
    -cachedir="$CONFIG_DIR" \
    -adminusername "$ADMIN_USERNAME" \
    -adminpassword "$ADMIN_PASSWORD" \
    -ip "$BIND_IP" -port "$DEFAULT_PORT" \
    -servername "$SERVER_NAME" \
    -steamvac "$STEAM_VAC" $USE_STEAM
