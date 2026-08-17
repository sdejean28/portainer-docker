#!/usr/bin/env bash

set -u

if [ "$EUID" -ne 0 ]; then
    echo "This script requires root privileges."
    echo "Restarting with sudo..."
    exec sudo "$0" "$@"
fi

DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)
CURRENT_DRIVER=$(docker info --format '{{.Driver}}' 2>/dev/null)

echo "========================================"
echo " Docker storage driver verification"
echo "========================================"
echo

if [ -z "${DOCKER_ROOT}" ] || [ -z "${CURRENT_DRIVER}" ]; then
    echo "ERROR: Unable to retrieve Docker information."
    exit 1
fi

echo "Docker root directory : ${DOCKER_ROOT}"
echo "Active storage driver : ${CURRENT_DRIVER}"
echo

echo "----------------------------------------"
echo "Storage driver directories"
echo "----------------------------------------"

KNOWN_DRIVERS=(
    overlay2
    overlay
    aufs
    vfs
    devicemapper
    btrfs
    zfs
)

FOUND=0

for driver in "${KNOWN_DRIVERS[@]}"; do
    path="${DOCKER_ROOT}/${driver}"

    if [ -d "${path}" ]; then
        FOUND=1
        size=$(du -sh "${path}" 2>/dev/null | awk '{print $1}')

        if [ "${driver}" = "${CURRENT_DRIVER}" ]; then
            printf "%-15s %-10s %s\n" "${driver}" "${size}" "[ACTIVE]"
        else
            printf "%-15s %-10s %s\n" "${driver}" "${size}" "[INACTIVE / CHECK]"
        fi
    fi
done

if [ "$FOUND" -eq 0 ]; then
    echo "No known storage-driver directory found."
fi

echo
echo "----------------------------------------"
echo "Docker volumes"
echo "----------------------------------------"

printf "%-50s %-10s %-10s %-8s\n" \
       "VOLUME" "DRIVER" "SIZE" "USED"

printf "%-50s %-10s %-10s %-8s\n" \
       "------" "------" "----" "----"

docker volume ls --format '{{.Name}}' | while read -r volume; do

    driver=$(docker volume inspect \
        --format '{{.Driver}}' \
        "${volume}" 2>/dev/null)

    mountpoint=$(docker volume inspect \
        --format '{{.Mountpoint}}' \
        "${volume}" 2>/dev/null)

    if [ -n "$mountpoint" ] && [ -d "$mountpoint" ]; then
        size=$(du -sh "$mountpoint" 2>/dev/null | awk '{print $1}')
    else
        size="?"
    fi

    # Determine whether at least one container references this volume
    used_by=$(docker ps -a \
        --filter volume="$volume" \
        --format '{{.Names}}' | wc -l)

    if [ "$used_by" -gt 0 ]; then
        used="YES"
    else
        used="NO"
    fi

    printf "%-50s %-10s %-10s %-8s\n" \
        "$volume" "$driver" "$size" "$used"
done

echo
echo "----------------------------------------"
echo "Docker disk usage"
echo "----------------------------------------"

docker system df

echo
echo "----------------------------------------"
echo "Filesystem"
echo "----------------------------------------"

df -h "$DOCKER_ROOT"

echo
echo "Verification complete."