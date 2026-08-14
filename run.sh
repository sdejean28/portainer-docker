#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly COMPOSE_FILE="docker-compose.yml"
readonly SERVER_TEMPLATE="docker-compose-server.yml"
readonly AGENT_TEMPLATE="docker-compose-agent.yml"

cd "$SCRIPT_DIR"

if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
else
    echo "Error: Docker Compose is not installed." >&2
    exit 1
fi

install_portainer() {
    local template service label choice

    echo "No docker-compose.yml found. Choose the Portainer version to install:"
    echo "  1) Server"
    echo "  2) Agent"
    read -r -p "Choice [1-2]: " choice

    case "$choice" in
        1)
            template="$SERVER_TEMPLATE"
            service="portainer"
            label="Server"
            ;;
        2)
            template="$AGENT_TEMPLATE"
            service="portainer_agent"
            label="Agent"
            ;;
        *)
            echo "Error: enter 1 for Server or 2 for Agent." >&2
            exit 1
            ;;
    esac

    if [[ ! -f "$template" ]]; then
        echo "Error: installation template '$template' was not found." >&2
        exit 1
    fi

    cp -- "$template" "$COMPOSE_FILE"
    echo "Installing Portainer $label..."
    "${COMPOSE[@]}" -f "$COMPOSE_FILE" pull "$service"
    "${COMPOSE[@]}" -f "$COMPOSE_FILE" up -d "$service"
    echo "Portainer $label installed successfully."
}

update_portainer() {
    local service label services

    services=$("${COMPOSE[@]}" -f "$COMPOSE_FILE" config --services)

    if grep -qx "portainer_agent" <<<"$services"; then
        service="portainer_agent"
        label="Agent"
    elif grep -qx "portainer" <<<"$services"; then
        service="portainer"
        label="Server"
    else
        echo "Error: '$COMPOSE_FILE' contains neither a Portainer server nor agent service." >&2
        exit 1
    fi

    echo "Current Portainer $label state:"
    "${COMPOSE[@]}" -f "$COMPOSE_FILE" ps "$service"
    echo

    echo "Updating Portainer $label..."
    "${COMPOSE[@]}" -f "$COMPOSE_FILE" pull "$service"
    "${COMPOSE[@]}" -f "$COMPOSE_FILE" up -d --force-recreate "$service"
    echo "Portainer $label updated and restarted successfully."
}

if [[ -f "$COMPOSE_FILE" ]]; then
    update_portainer
else
    install_portainer
fi
