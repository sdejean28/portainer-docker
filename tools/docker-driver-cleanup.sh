#!/usr/bin/env bash

set -u

# ============================================================
# Docker Storage Driver Check & Cleanup
# ============================================================

KNOWN_DRIVERS=(
    overlay2
    overlay
    aufs
    vfs
    devicemapper
    btrfs
    zfs
)

# ------------------------------------------------------------
# Colors
# ------------------------------------------------------------

if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# ------------------------------------------------------------
# Root
# ------------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    echo "This script requires root privileges."
    echo "Restarting with sudo..."
    exec sudo "$0" "$@"
fi

# ------------------------------------------------------------
# Check Docker
# ------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
    echo -e "${RED}ERROR: docker command not found.${NC}"
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo -e "${RED}ERROR: Docker daemon is not running or is inaccessible.${NC}"
    exit 1
fi

DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)
CURRENT_DRIVER=$(docker info --format '{{.Driver}}' 2>/dev/null)

if [ -z "$DOCKER_ROOT" ] || [ -z "$CURRENT_DRIVER" ]; then
    echo -e "${RED}ERROR: Unable to determine Docker storage configuration.${NC}"
    exit 1
fi

# ------------------------------------------------------------
# Functions
# ------------------------------------------------------------

human_size() {
    du -sh "$1" 2>/dev/null | awk '{print $1}'
}

last_write() {

    local path="$1"
    local result

    result=$(find "$path" -type f \
        -printf '%TY-%Tm-%Td %TH:%TM\n' \
        2>/dev/null \
        | sort \
        | tail -1)

    if [ -z "$result" ]; then
        echo "unknown"
    else
        echo "$result"
    fi
}

stop_docker() {

    echo
    echo -e "${YELLOW}Stopping Docker...${NC}"

    systemctl stop docker 2>/dev/null || true

    if systemctl list-unit-files containerd.service >/dev/null 2>&1; then
        systemctl stop containerd 2>/dev/null || true
    fi
}

start_docker() {

    echo -e "${YELLOW}Starting Docker...${NC}"

    if systemctl list-unit-files containerd.service >/dev/null 2>&1; then
        systemctl start containerd 2>/dev/null || true
    fi

    systemctl start docker
}

verify_docker() {

    sleep 2

    if ! docker info >/dev/null 2>&1; then
        echo -e "${RED}ERROR: Docker did not restart correctly.${NC}"
        return 1
    fi

    local new_driver
    new_driver=$(docker info --format '{{.Driver}}')

    if [ "$new_driver" != "$CURRENT_DRIVER" ]; then
        echo -e "${RED}WARNING: Docker storage driver changed!${NC}"
        echo "Before : $CURRENT_DRIVER"
        echo "After  : $new_driver"
        return 1
    fi

    echo
    echo -e "${GREEN}Docker restarted successfully.${NC}"
    echo "Storage driver : $new_driver"

    echo
    docker ps --format 'table {{.Names}}\t{{.Status}}'

    return 0
}

cleanup_driver() {

    local driver="$1"
    local path="$DOCKER_ROOT/$driver"
    local backup="${path}.old"

    echo
    echo "============================================================"
    echo " Candidate for cleanup"
    echo "============================================================"
    echo
    echo "Driver     : $driver"
    echo "Directory  : $path"
    echo "Size       : $(human_size "$path")"
    echo "Last write : $(last_write "$path")"
    echo
    echo -e "${YELLOW}This driver is NOT currently active.${NC}"
    echo
    echo "The safe procedure is:"
    echo "  1. stop Docker"
    echo "  2. rename directory to ${driver}.old"
    echo "  3. restart Docker"
    echo "  4. verify containers"
    echo "  5. optionally delete the backup"
    echo

    read -r -p "Test removal of '$driver'? [y/N] " answer

    case "$answer" in
        y|Y|yes|YES)
            ;;
        *)
            echo "Skipped."
            return
            ;;
    esac

    if [ -e "$backup" ]; then
        echo
        echo -e "${RED}ERROR: $backup already exists.${NC}"
        echo "Cleanup or inspect it manually before continuing."
        return
    fi

    stop_docker

    echo
    echo "Renaming:"
    echo "  $path"
    echo "to:"
    echo "  $backup"

    mv "$path" "$backup"

    start_docker

    if verify_docker; then

        echo
        echo -e "${GREEN}Driver '$driver' is not required by the current Docker installation.${NC}"
        echo

        read -r -p "Permanently delete '$backup'? [y/N] " delete_answer

        case "$delete_answer" in
            y|Y|yes|YES)
                echo
                echo "Deleting $backup ..."
                rm -rf --one-file-system "$backup"
                echo -e "${GREEN}Deleted.${NC}"
                ;;
            *)
                echo
                echo "Backup kept:"
                echo "$backup"
                ;;
        esac

    else

        echo
        echo -e "${RED}Docker verification failed.${NC}"
        echo "Attempting rollback..."

        systemctl stop docker 2>/dev/null || true

        if systemctl list-unit-files containerd.service >/dev/null 2>&1; then
            systemctl stop containerd 2>/dev/null || true
        fi

        if [ -d "$backup" ]; then
            mv "$backup" "$path"
        fi

        start_docker

        echo
        echo -e "${YELLOW}Rollback completed.${NC}"
    fi
}

# ------------------------------------------------------------
# Header
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Docker Storage Driver Check & Cleanup"
echo "============================================================"
echo
echo "Docker root directory : $DOCKER_ROOT"
echo "Active storage driver : $CURRENT_DRIVER"

if docker info 2>&1 | grep -qi 'deprecated'; then
    echo
    echo -e "${YELLOW}Docker reports a deprecation warning:${NC}"
    docker info 2>&1 | grep -i 'deprecated' || true
fi

echo
echo "------------------------------------------------------------"
echo "Filesystem before cleanup"
echo "------------------------------------------------------------"
df -h "$DOCKER_ROOT"

echo
echo "------------------------------------------------------------"
echo "Storage drivers"
echo "------------------------------------------------------------"
echo

printf "%-15s %-10s %-25s %-20s\n" \
       "DRIVER" "SIZE" "STATUS" "LAST WRITE"

printf "%-15s %-10s %-25s %-20s\n" \
       "------" "----" "------" "----------"

INACTIVE_DRIVERS=()

for driver in "${KNOWN_DRIVERS[@]}"; do

    path="$DOCKER_ROOT/$driver"

    if [ -d "$path" ]; then

        size=$(human_size "$path")
        date=$(last_write "$path")

        if [ "$driver" = "$CURRENT_DRIVER" ]; then

            status="ACTIVE"

            printf "%-15s %-10s %-25s %-20s\n" \
                "$driver" "$size" "$status" "$date"

        else

            status="INACTIVE / CHECK"

            printf "%-15s %-10s %-25s %-20s\n" \
                "$driver" "$size" "$status" "$date"

            INACTIVE_DRIVERS+=("$driver")
        fi
    fi
done

echo
echo "------------------------------------------------------------"
echo "Docker disk usage"
echo "------------------------------------------------------------"

docker system df

echo
echo "------------------------------------------------------------"
echo "Inactive storage drivers"
echo "------------------------------------------------------------"

if [ "${#INACTIVE_DRIVERS[@]}" -eq 0 ]; then

    echo
    echo -e "${GREEN}No inactive storage-driver directories found.${NC}"

else

    echo
    echo "The following inactive driver directories were found:"
    echo

    for driver in "${INACTIVE_DRIVERS[@]}"; do
        echo "  - $driver"
    done

    echo

    for driver in "${INACTIVE_DRIVERS[@]}"; do
        cleanup_driver "$driver"
    done
fi

echo
echo "============================================================"
echo " Final status"
echo "============================================================"
echo

docker info --format \
'Storage Driver : {{.Driver}}
Docker Root Dir : {{.DockerRootDir}}'

echo
df -h "$DOCKER_ROOT"

echo
echo "Docker storage usage:"
docker system df

echo
echo -e "${GREEN}Verification complete.${NC}"