#!/bin/bash
set -e
(cd "$(dirname "$0")/.." && git pull && docker compose up -d --build zombiradar)
echo "zombiradar updated."
