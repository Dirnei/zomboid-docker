#!/bin/bash
set -e
FORCE=false
SERVICE=""
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=true ;;
    *) SERVICE="$arg" ;;
  esac
done

BUILD_FLAG=""
[[ "$SERVICE" == "discord" || "$SERVICE" == "zombiradar" || "$SERVICE" == "" ]] && BUILD_FLAG="--build"

(
  cd "$(dirname "$0")/.."
  before=$(git rev-parse HEAD)
  git pull
  after=$(git rev-parse HEAD)
  if $FORCE || [ "$before" != "$after" ]; then
    docker compose up -d $BUILD_FLAG --force-recreate $SERVICE
    echo "${SERVICE:-all services} updated and restarted."
  else
    echo "${SERVICE:-all services}: no changes. Use --force to restart anyway."
  fi
)
