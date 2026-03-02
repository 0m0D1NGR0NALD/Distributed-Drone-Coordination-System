#!/bin/bash

# Script to start a ground station node
# Usage: ./start_ground_station.sh <station_name> [cookie]

STATION_NAME=$1
COOKIE=${2:-drone_cookie}

# Resolve script directory so the -pa path works no matter where you run it
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SRC_PATH="$PROJECT_ROOT/src"

if [ -z "$STATION_NAME" ]; then
    echo "Usage: ./start_ground_station.sh <station_name> [cookie]"
    echo "Example: ./start_ground_station.sh gs1"
    exit 1
fi

echo "Starting ground station '$STATION_NAME' with cookie: $COOKIE"
echo "Using source path: $SRC_PATH"

# Start Erlang node with correct code path
erl \
    -sname "$STATION_NAME" \
    -setcookie "$COOKIE" \
    -pa "$SRC_PATH"
