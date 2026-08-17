#!/usr/bin/env bash

set -u

# ============================================================
# Docker Compose Stack Inspector
# ============================================================

if [ "$EUID" -ne 0 ]; then
    echo "This script requires root privileges."
    echo "Restarting with sudo..."
    exec sudo "$0" "$@"
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker is not installed."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker daemon is not available."
    exit 1
fi

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

pause() {
    echo
    read -r -p "Press ENTER to continue..."
}

# ------------------------------------------------------------
# Find Compose projects
# ------------------------------------------------------------

mapfile -t STACKS < <(
    docker ps -a \
        --format '{{.Label "com.docker.compose.project"}}' \
        | sed '/^$/d' \
        | sort -u
)

section "Docker Compose Stack Inspector"

if [ "${#STACKS[@]}" -eq 0 ]; then
    echo
    echo "No Docker Compose stacks found."
    exit 0
fi

echo
echo "Available stacks:"
echo

for i in "${!STACKS[@]}"; do

    stack="${STACKS[$i]}"

    running=$(
        docker ps \
            --filter "label=com.docker.compose.project=$stack" \
            -q | wc -l
    )

    total=$(
        docker ps -a \
            --filter "label=com.docker.compose.project=$stack" \
            -q | wc -l
    )

    printf "%3d) %-35s %2d/%2d running\n" \
        "$((i+1))" "$stack" "$running" "$total"

done

echo

while true; do

    read -r -p "Select stack [1-${#STACKS[@]}]: " selection

    if [[ "$selection" =~ ^[0-9]+$ ]] \
       && [ "$selection" -ge 1 ] \
       && [ "$selection" -le "${#STACKS[@]}" ]; then

        STACK="${STACKS[$((selection-1))]}"
        break
    fi

    echo "Invalid selection."

done

# ------------------------------------------------------------
# Get containers
# ------------------------------------------------------------

mapfile -t CONTAINERS < <(
    docker ps -aq \
        --filter "label=com.docker.compose.project=$STACK"
)

if [ "${#CONTAINERS[@]}" -eq 0 ]; then
    echo "No containers found for stack '$STACK'."
    exit 1
fi

FIRST_CONTAINER="${CONTAINERS[0]}"

# ------------------------------------------------------------
# Compose metadata
# ------------------------------------------------------------

WORKING_DIR=$(
    docker inspect \
        --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' \
        "$FIRST_CONTAINER" 2>/dev/null
)

CONFIG_FILES=$(
    docker inspect \
        --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' \
        "$FIRST_CONTAINER" 2>/dev/null
)

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

section "Stack: $STACK"

echo
echo "Compose project : $STACK"
echo "Working dir     : ${WORKING_DIR:-unknown}"
echo "Config file(s)  : ${CONFIG_FILES:-unknown}"
echo

RUNNING=$(
    docker ps \
        --filter "label=com.docker.compose.project=$STACK" \
        -q | wc -l
)

TOTAL="${#CONTAINERS[@]}"

echo "Containers      : $TOTAL"
echo "Running         : $RUNNING"
echo "Stopped         : $((TOTAL - RUNNING))"

# ============================================================
# CONTAINERS
# ============================================================

section "Containers"

docker ps -a \
    --filter "label=com.docker.compose.project=$STACK" \
    --format \
'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

# ============================================================
# SERVICES
# ============================================================

section "Compose Services"

printf "%-30s %-35s %-20s\n" \
    "SERVICE" "CONTAINER" "STATUS"

printf "%-30s %-35s %-20s\n" \
    "-------" "---------" "------"

for cid in "${CONTAINERS[@]}"; do

    service=$(
        docker inspect \
            --format '{{ index .Config.Labels "com.docker.compose.service" }}' \
            "$cid"
    )

    name=$(
        docker inspect \
            --format '{{.Name}}' \
            "$cid" | sed 's#^/##'
    )

    status=$(
        docker inspect \
            --format '{{.State.Status}}' \
            "$cid"
    )

    printf "%-30s %-35s %-20s\n" \
        "$service" "$name" "$status"

done

# ============================================================
# IMAGES
# ============================================================

section "Images"

printf "%-45s %-20s %-12s\n" \
    "IMAGE" "IMAGE ID" "SIZE"

printf "%-45s %-20s %-12s\n" \
    "-----" "--------" "----"

mapfile -t IMAGES < <(
    for cid in "${CONTAINERS[@]}"; do
        docker inspect --format '{{.Config.Image}}' "$cid"
    done | sort -u
)

for image in "${IMAGES[@]}"; do

    image_id=$(
        docker image inspect \
            --format '{{.Id}}' \
            "$image" 2>/dev/null \
            | sed 's/^sha256://' \
            | cut -c1-12
    )

    bytes=$(
        docker image inspect \
            --format '{{.Size}}' \
            "$image" 2>/dev/null
    )

    if [[ "$bytes" =~ ^[0-9]+$ ]]; then
        size=$(numfmt --to=iec "$bytes")
    else
        size="?"
    fi

    printf "%-45s %-20s %-12s\n" \
        "$image" "$image_id" "$size"

done

# ============================================================
# NETWORKS
# ============================================================

section "Networks"

mapfile -t NETWORKS < <(
    for cid in "${CONTAINERS[@]}"; do

        docker inspect \
            --format '{{range $name, $config := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
            "$cid"

    done | sed '/^$/d' | sort -u
)

if [ "${#NETWORKS[@]}" -eq 0 ]; then

    echo "No networks found."

else

    printf "%-40s %-12s %-20s\n" \
        "NETWORK" "DRIVER" "SCOPE"

    printf "%-40s %-12s %-20s\n" \
        "-------" "------" "-----"

    for network in "${NETWORKS[@]}"; do

        driver=$(
            docker network inspect \
                --format '{{.Driver}}' \
                "$network" 2>/dev/null
        )

        scope=$(
            docker network inspect \
                --format '{{.Scope}}' \
                "$network" 2>/dev/null
        )

        printf "%-40s %-12s %-20s\n" \
            "$network" "$driver" "$scope"

    done

fi

# ============================================================
# VOLUMES
# ============================================================

section "Docker Volumes"

mapfile -t VOLUMES < <(
    for cid in "${CONTAINERS[@]}"; do

        docker inspect \
            --format '{{range .Mounts}}{{if eq .Type "volume"}}{{println .Name}}{{end}}{{end}}' \
            "$cid"

    done | sed '/^$/d' | sort -u
)

if [ "${#VOLUMES[@]}" -eq 0 ]; then

    echo
    echo "No Docker volumes used by this stack."

else

    printf "\n%-45s %-10s %-10s %-20s\n" \
        "VOLUME" "DRIVER" "SIZE" "CREATED"

    printf "%-45s %-10s %-10s %-20s\n" \
        "------" "------" "----" "-------"

    TOTAL_BYTES=0

    for volume in "${VOLUMES[@]}"; do

        driver=$(
            docker volume inspect \
                --format '{{.Driver}}' \
                "$volume" 2>/dev/null
        )

        mountpoint=$(
            docker volume inspect \
                --format '{{.Mountpoint}}' \
                "$volume" 2>/dev/null
        )

        created=$(
            docker volume inspect \
                --format '{{.CreatedAt}}' \
                "$volume" 2>/dev/null
        )

        if [ -d "$mountpoint" ]; then

            bytes=$(
                du -sb "$mountpoint" 2>/dev/null \
                | awk '{print $1}'
            )

            size=$(
                du -sh "$mountpoint" 2>/dev/null \
                | awk '{print $1}'
            )

            if [[ "$bytes" =~ ^[0-9]+$ ]]; then
                TOTAL_BYTES=$((TOTAL_BYTES + bytes))
            fi

        else
            size="?"
        fi

        printf "%-45s %-10s %-10s %-20s\n" \
            "$volume" "$driver" "$size" "${created:0:19}"

    done

    echo

    if command -v numfmt >/dev/null 2>&1; then
        echo "Total volume data : $(numfmt --to=iec "$TOTAL_BYTES")"
    fi

fi

# ============================================================
# VOLUME DETAILS
# ============================================================

section "Volume Details"

if [ "${#VOLUMES[@]}" -eq 0 ]; then

    echo "No Docker volumes."

else

    for volume in "${VOLUMES[@]}"; do

        echo
        echo "Volume: $volume"

        mountpoint=$(
            docker volume inspect \
                --format '{{.Mountpoint}}' \
                "$volume"
        )

        driver=$(
            docker volume inspect \
                --format '{{.Driver}}' \
                "$volume"
        )

        echo "  Driver     : $driver"
        echo "  Mountpoint : $mountpoint"

        if [ -d "$mountpoint" ]; then
            echo "  Size       : $(du -sh "$mountpoint" | awk '{print $1}')"
        fi

        echo "  Used by:"

        docker ps -a \
            --filter "volume=$volume" \
            --format '    {{.Names}}'

    done

fi

# ============================================================
# BIND MOUNTS
# ============================================================

section "Bind Mounts"

FOUND_BIND=0

for cid in "${CONTAINERS[@]}"; do

    name=$(
        docker inspect \
            --format '{{.Name}}' \
            "$cid" | sed 's#^/##'
    )

    while IFS='|' read -r type source destination rw; do

        if [ "$type" = "bind" ]; then

            FOUND_BIND=1

            echo
            echo "Container   : $name"
            echo "Host path   : $source"
            echo "Destination : $destination"
            echo "Read/Write  : $rw"

            if [ -e "$source" ]; then
                echo "Size        : $(du -sh "$source" 2>/dev/null | awk '{print $1}')"
            fi

        fi

    done < <(
        docker inspect \
            --format '{{range .Mounts}}{{printf "%s|%s|%s|%t\n" .Type .Source .Destination .RW}}{{end}}' \
            "$cid"
    )

done

if [ "$FOUND_BIND" -eq 0 ]; then
    echo
    echo "No bind mounts found."
fi

# ============================================================
# CONTAINER MOUNT MAP
# ============================================================

section "Container Mount Map"

for cid in "${CONTAINERS[@]}"; do

    name=$(
        docker inspect \
            --format '{{.Name}}' \
            "$cid" | sed 's#^/##'
    )

    echo
    echo "$name"

    docker inspect \
        --format \
'{{range .Mounts}}  {{.Type}}: {{.Source}} -> {{.Destination}} (RW={{.RW}})
{{end}}' \
        "$cid"

done

# ============================================================
# RESTART POLICIES
# ============================================================

section "Restart Policies"

printf "%-40s %-20s\n" \
    "CONTAINER" "RESTART POLICY"

printf "%-40s %-20s\n" \
    "---------" "--------------"

for cid in "${CONTAINERS[@]}"; do

    name=$(
        docker inspect \
            --format '{{.Name}}' \
            "$cid" | sed 's#^/##'
    )

    restart=$(
        docker inspect \
            --format '{{.HostConfig.RestartPolicy.Name}}' \
            "$cid"
    )

    [ -z "$restart" ] && restart="none"

    printf "%-40s %-20s\n" \
        "$name" "$restart"

done

# ============================================================
# HEALTH
# ============================================================

section "Health / State"

printf "%-40s %-15s %-20s\n" \
    "CONTAINER" "STATE" "HEALTH"

printf "%-40s %-15s %-20s\n" \
    "---------" "-----" "------"

for cid in "${CONTAINERS[@]}"; do

    name=$(
        docker inspect \
            --format '{{.Name}}' \
            "$cid" | sed 's#^/##'
    )

    state=$(
        docker inspect \
            --format '{{.State.Status}}' \
            "$cid"
    )

    health=$(
        docker inspect \
            --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' \
            "$cid"
    )

    printf "%-40s %-15s %-20s\n" \
        "$name" "$state" "$health"

done

# ============================================================
# FINAL SUMMARY
# ============================================================

section "Stack Summary"

echo
echo "Stack             : $STACK"
echo "Working directory : ${WORKING_DIR:-unknown}"
echo "Compose files     : ${CONFIG_FILES:-unknown}"
echo
echo "Containers        : ${#CONTAINERS[@]}"
echo "Images            : ${#IMAGES[@]}"
echo "Networks          : ${#NETWORKS[@]}"
echo "Docker volumes    : ${#VOLUMES[@]}"

if [ "${#VOLUMES[@]}" -gt 0 ] && command -v numfmt >/dev/null 2>&1; then
    echo "Volume data       : $(numfmt --to=iec "$TOTAL_BYTES")"
fi

echo
echo "Inspection complete."