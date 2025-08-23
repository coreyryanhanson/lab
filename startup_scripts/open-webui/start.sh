#!/bin/bash

# Define the paths to your docker-compose file and the open-webui data directory
DOCKER_COMPOSE_FILE="docker-compose.searxng.yaml"
DATA_DIR=~/.open-webui
PODMAN_COMPOSE="podman-compose"

# Function to start the searxng container
manage_searxng() {
    local action=$1
    local cmd_args=""
    
    case "$action" in
        start)
            cmd_args=("up" "-d")
            echo "Starting the searxng container..."
            ;;
        stop)
            cmd_args=("down")
            echo "Stopping any previously running searxng container..."
            ;;
        *)
            echo "Invalid action: $action (use 'start' or 'stop')"
            exit 1
            ;;
    esac
    $PODMAN_COMPOSE -f $DOCKER_COMPOSE_FILE "${cmd_args[@]}"
}

# Start searxng container
manage_searxng stop
manage_searxng start

# Check if searxng container started successfully
if [ $? -eq 0 ]; then
    echo "searxng container started successfully."
else
    echo "Failed to start searxng container."
    exit 1
fi

# Start open-webui
echo "Starting open-webui..."
DATA_DIR=$DATA_DIR uvx --python 3.11 open-webui@latest serve
manage_searxng stop
