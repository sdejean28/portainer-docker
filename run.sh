#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

COMPOSE_FILE="docker-compose.yml"

# Check if docker-compose.yml exists
if [ ! -f "$COMPOSE_FILE" ]; then
    # First run - ask which version to install
    echo -e "${YELLOW}Portainer installation detected (no docker-compose.yml found)${NC}"
    echo ""
    echo "Which version would you like to install?"
    echo "1) Server (Standalone Portainer)"
    echo "2) Agent (Connect to existing Portainer)"
    echo ""
    read -p "Enter your choice (1 or 2): " version_choice
    
    case $version_choice in
        1)
            echo -e "${YELLOW}Installing Portainer Server...${NC}"
            cp docker-compose-server.yml "$COMPOSE_FILE"
            SERVICE_TYPE="Server"
            ;;
        2)
            echo -e "${YELLOW}Installing Portainer Agent...${NC}"
            cp docker-compose-agent.yml "$COMPOSE_FILE"
            SERVICE_TYPE="Agent"
            ;;
        *)
            echo -e "${RED}Invalid choice. Exiting.${NC}"
            exit 1
            ;;
    esac
    
    # Start the service
    echo -e "${YELLOW}Starting Portainer $SERVICE_TYPE...${NC}"
    docker-compose up -d
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Portainer $SERVICE_TYPE started successfully${NC}"
    else
        echo -e "${RED}✗ Failed to start Portainer $SERVICE_TYPE${NC}"
        exit 1
    fi
else
    # Already installed - update the container
    echo -e "${YELLOW}Portainer installation found. Updating...${NC}"
    
    # Determine if it's server or agent based on existing compose file
    if grep -q "portainer_agent" "$COMPOSE_FILE"; then
        SERVICE_TYPE="Agent"
        IMAGE="portainer/agent:latest"
    else
        SERVICE_TYPE="Server"
        IMAGE="portainer/portainer-ce"
    fi
    
    echo -e "${YELLOW}Pulling latest $SERVICE_TYPE image: $IMAGE${NC}"
    docker pull "$IMAGE"
    
    if [ $? -eq 0 ]; then
        echo -e "${YELLOW}Restarting Portainer $SERVICE_TYPE container...${NC}"
        docker-compose up -d --force-recreate
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Portainer $SERVICE_TYPE updated successfully${NC}"
        else
            echo -e "${RED}✗ Failed to restart Portainer $SERVICE_TYPE${NC}"
            exit 1
        fi
    else
        echo -e "${RED}✗ Failed to pull $SERVICE_TYPE image${NC}"
        exit 1
    fi
fi
