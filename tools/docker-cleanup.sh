#!/usr/bin/env bash

set -u

# ============================================================
# Docker Unused Resources Audit & Cleanup
#
# Default:
#   interactive audit + cleanup
#
# Usage:
#   ./docker-cleanup.sh
#   ./docker-cleanup.sh --audit
#
# ============================================================

MODE="interactive"

if [[ "${1:-}" == "--audit" ]]; then
    MODE="audit"
fi

# ------------------------------------------------------------
# Colors
# ------------------------------------------------------------

if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    BOLD=''
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
# Docker availability
# ------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
    echo -e "${RED}ERROR: docker command not found.${NC}"
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo -e "${RED}ERROR: Docker daemon is not running.${NC}"
    exit 1
fi

DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}')

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

section() {
    echo
    echo "============================================================"
    echo " $1"
    echo "============================================================"
}

subsection() {
    echo
    echo "------------------------------------------------------------"
    echo " $1"
    echo "------------------------------------------------------------"
}

ask_yes_no() {

    local question="$1"
    local answer

    if [ "$MODE" = "audit" ]; then
        return 1
    fi

    read -r -p "$question [y/N] " answer

    case "$answer" in
        y|Y|yes|YES)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

human_size_path() {

    local path="$1"

    if [ -e "$path" ]; then
        du -sh "$path" 2>/dev/null | awk '{print $1}'
    else
        echo "?"
    fi
}

# ------------------------------------------------------------
# Header
# ------------------------------------------------------------

section "Docker Unused Resources Audit & Cleanup"

echo
echo "Docker root : $DOCKER_ROOT"
echo "Mode        : $MODE"
echo

docker version --format \
'Server version : {{.Server.Version}}' 2>/dev/null || true

# ------------------------------------------------------------
# Disk before
# ------------------------------------------------------------

subsection "Filesystem BEFORE cleanup"

df -h "$DOCKER_ROOT"

# ------------------------------------------------------------
# Docker global usage
# ------------------------------------------------------------

subsection "Docker disk usage"

docker system df

echo
echo "Detailed usage:"
echo

docker system df -v

# ============================================================
# STOPPED CONTAINERS
# ============================================================

section "1. Stopped containers"

STOPPED_IDS=$(docker ps -aq --filter status=exited --filter status=created)

if [ -z "$STOPPED_IDS" ]; then

    echo
    echo -e "${GREEN}No stopped containers found.${NC}"

else

    echo
    docker ps -a \
        --filter status=exited \
        --filter status=created \
        --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}'

    COUNT=$(echo "$STOPPED_IDS" | wc -l)

    echo
    echo "Stopped containers: $COUNT"

    if ask_yes_no "Remove ALL stopped containers?"; then

        echo
        docker container prune -f

    else
        echo "Skipped."
    fi
fi

# ============================================================
# UNUSED NETWORKS
# ============================================================

section "2. Unused networks"

echo
echo "All Docker networks:"
echo

docker network ls

echo
echo "Unused networks will be detected by Docker during prune."

if ask_yes_no "Remove unused Docker networks?"; then

    echo
    docker network prune -f

else
    echo "Skipped."
fi

# ============================================================
# DANGLING IMAGES
# ============================================================

section "3. Dangling images"

DANGLING_IMAGES=$(docker image ls -q --filter dangling=true | sort -u)

if [ -z "$DANGLING_IMAGES" ]; then

    echo
    echo -e "${GREEN}No dangling images found.${NC}"

else

    echo
    docker image ls --filter dangling=true

    COUNT=$(echo "$DANGLING_IMAGES" | wc -l)

    echo
    echo "Dangling images: $COUNT"

    if ask_yes_no "Remove dangling images?"; then

        echo
        docker image prune -f

    else
        echo "Skipped."
    fi
fi

# ============================================================
# ALL UNUSED IMAGES
# ============================================================

section "4. Images unused by any container"

echo
echo "Docker currently reports:"
echo

docker system df | grep -E '^Images|TYPE' || true

echo
echo -e "${YELLOW}WARNING:${NC}"
echo "This removes ALL images that are not associated with any"
echo "existing container."
echo
echo "Images can normally be pulled or rebuilt again, but this"
echo "may take time or require access to the original registry."

if ask_yes_no "Remove ALL unused images (docker image prune -a)?"; then

    echo
    docker image prune -a -f

else
    echo "Skipped."
fi

# ============================================================
# BUILD CACHE
# ============================================================

section "5. Docker build cache"

docker system df | grep -E '^Build Cache|TYPE' || true

echo
echo "Build cache can safely be recreated by future builds."

if ask_yes_no "Remove all unused build cache?"; then

    echo
    docker builder prune -a -f

else
    echo "Skipped."
fi

# ============================================================
# UNUSED VOLUMES
# ============================================================

section "6. Unused Docker volumes"

UNUSED_VOLUMES=$(docker volume ls -q --filter dangling=true)

if [ -z "$UNUSED_VOLUMES" ]; then

    echo
    echo -e "${GREEN}No unused volumes found.${NC}"

else

    printf "\n%-66s %-12s %-20s\n" \
        "VOLUME" "SIZE" "CREATED"

    printf "%-66s %-12s %-20s\n" \
        "------" "----" "-------"

    TOTAL_UNUSED_VOLUME_BYTES=0

    while read -r volume; do

        [ -z "$volume" ] && continue

        mountpoint=$(docker volume inspect \
            --format '{{.Mountpoint}}' \
            "$volume" 2>/dev/null)

        created=$(docker volume inspect \
            --format '{{.CreatedAt}}' \
            "$volume" 2>/dev/null)

        if [ -n "$mountpoint" ] && [ -d "$mountpoint" ]; then

            size=$(du -sh "$mountpoint" 2>/dev/null | awk '{print $1}')

            bytes=$(du -sb "$mountpoint" 2>/dev/null | awk '{print $1}')

            if [[ "$bytes" =~ ^[0-9]+$ ]]; then
                TOTAL_UNUSED_VOLUME_BYTES=$(
                    (echo "$TOTAL_UNUSED_VOLUME_BYTES + $bytes") | bc
                )
            fi

        else
            size="?"
        fi

        printf "%-66s %-12s %-20s\n" \
            "$volume" "$size" "${created:0:19}"

    done <<< "$UNUSED_VOLUMES"

    echo

    if command -v numfmt >/dev/null 2>&1; then
        echo -n "Approx. unused volume data: "
        numfmt --to=iec "$TOTAL_UNUSED_VOLUME_BYTES"
    fi

    echo
    echo -e "${RED}${BOLD}IMPORTANT:${NC}"
    echo
    echo "An unused volume may still contain:"
    echo "  - database files"
    echo "  - old application data"
    echo "  - backups"
    echo "  - data from a Compose stack currently removed"
    echo
    echo "Docker only knows that no CURRENT container references it."

    if ask_yes_no "Delete UNUSED anonymous volumes?"; then

        echo
        docker volume prune -f

    else
        echo "Volume cleanup skipped."
    fi
fi

# ============================================================
# OPTIONAL NAMED VOLUMES
# ============================================================

section "7. Unused NAMED volumes"

echo
echo "By default, docker volume prune only targets unused"
echo "anonymous volumes."
echo
echo "Unused named volumes can be listed explicitly:"
echo

NAMED_UNUSED=""

while read -r volume; do

    [ -z "$volume" ] && continue

    # Docker anonymous volume names are usually 64-char hashes.
    if [[ ! "$volume" =~ ^[0-9a-f]{64}$ ]]; then

        if ! docker ps -a \
            --filter volume="$volume" \
            --format '{{.ID}}' \
            | grep -q .; then

            NAMED_UNUSED="${NAMED_UNUSED}${volume}"$'\n'
        fi
    fi

done < <(docker volume ls -q)

NAMED_UNUSED=$(echo "$NAMED_UNUSED" | sed '/^$/d')

if [ -z "$NAMED_UNUSED" ]; then

    echo -e "${GREEN}No unused named volumes detected.${NC}"

else

    printf "%-50s %-12s %-20s\n" \
        "VOLUME" "SIZE" "CREATED"

    printf "%-50s %-12s %-20s\n" \
        "------" "----" "-------"

    while read -r volume; do

        [ -z "$volume" ] && continue

        mountpoint=$(docker volume inspect \
            --format '{{.Mountpoint}}' \
            "$volume")

        created=$(docker volume inspect \
            --format '{{.CreatedAt}}' \
            "$volume")

        size=$(human_size_path "$mountpoint")

        printf "%-50s %-12s %-20s\n" \
            "$volume" "$size" "${created:0:19}"

    done <<< "$NAMED_UNUSED"

    echo
    echo -e "${RED}${BOLD}Named volumes are NOT automatically deleted.${NC}"
    echo
    echo "Review them individually."
    echo
    echo "To remove one manually:"
    echo
    echo "    docker volume rm VOLUME_NAME"
fi

# ============================================================
# LARGE DOCKER LOGS
# ============================================================

section "8. Docker container logs"

LOG_ROOT="$DOCKER_ROOT/containers"

if [ -d "$LOG_ROOT" ]; then

    echo
    echo "20 largest json-file logs:"
    echo

    find "$LOG_ROOT" \
        -type f \
        -name '*-json.log' \
        -printf '%s %p\n' \
        2>/dev/null \
        | sort -nr \
        | head -20 \
        | while read -r bytes file; do

            human=$(numfmt --to=iec "$bytes" 2>/dev/null || echo "$bytes")

            cid=$(basename "$(dirname "$file")")

            cname=$(docker inspect \
                --format '{{.Name}}' \
                "$cid" 2>/dev/null \
                | sed 's#^/##')

            printf "%-10s %-35s %s\n" \
                "$human" "$cname" "$file"

        done

else
    echo "No Docker container log directory found."
fi

echo
echo "Logs are NOT automatically deleted by this script."
echo "Configure Docker log rotation instead."

# ============================================================
# FINAL STATUS
# ============================================================

section "Final Docker status"

docker system df

subsection "Filesystem AFTER cleanup"

df -h "$DOCKER_ROOT"

echo
echo -e "${GREEN}Docker cleanup audit complete.${NC}"