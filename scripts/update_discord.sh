#!/bin/bash
set -e
cd "$(dirname "$0")/.."
git pull
docker compose up -d --build discord
echo "discord updated."
