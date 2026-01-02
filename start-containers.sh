#!/bin/bash
# start-containers.sh - Start lab containers (Interactive)

set -e

# Colors for better UX
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}=========================================="
echo "Container Startup Manager"
echo -e "==========================================${NC}"
echo ""

# Function to read input with default
read_with_default() {
  local prompt="$1"
  local default="$2"
  local var_name="$3"

  if [ -n "$default" ]; then
    read -p "$(echo -e ${prompt} [${GREEN}${default}${NC}]: )" input
    eval "$var_name=\"${input:-$default}\""
  else
    while true; do
      read -p "$(echo -e ${prompt}: )" input
      if [ -n "$input" ]; then
        eval "$var_name=\"$input\""
        break
      else
        echo -e "${RED}This field is required${NC}"
      fi
    done
  fi
}

# Function to get container status
get_status() {
  local ctid=$1
  if ! pct status $ctid &>/dev/null; then
    echo "not-exist"
  elif pct status $ctid | grep -q "running"; then
    echo "running"
  else
    echo "stopped"
  fi
}

# Function to get container hostname
get_hostname() {
  local ctid=$1
  pct config $ctid 2>/dev/null | grep "^hostname:" | awk '{print $2}' || echo "unknown"
}

# 1. Show current container status
echo -e "${BLUE}1. Current Container Status${NC}"
echo "Scanning for containers..."
echo ""

ALL_CONTAINERS=$(pct list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n)

if [ -z "$ALL_CONTAINERS" ]; then
  echo -e "${RED}No containers found on this system${NC}"
  exit 1
fi

# Display container status
printf "%-8s %-20s %-12s\n" "CTID" "Hostname" "Status"
echo "----------------------------------------"

declare -a STOPPED_CONTAINERS=()
declare -a RUNNING_CONTAINERS=()

for CTID in $ALL_CONTAINERS; do
  STATUS=$(get_status $CTID)
  HOSTNAME=$(get_hostname $CTID)

  if [ "$STATUS" = "running" ]; then
    printf "%-8s %-20s ${GREEN}%-12s${NC}\n" "$CTID" "$HOSTNAME" "Running"
    RUNNING_CONTAINERS+=($CTID)
  elif [ "$STATUS" = "stopped" ]; then
    printf "%-8s %-20s ${YELLOW}%-12s${NC}\n" "$CTID" "$HOSTNAME" "Stopped"
    STOPPED_CONTAINERS+=($CTID)
  fi
done

echo ""
echo "Summary: ${GREEN}${#RUNNING_CONTAINERS[@]} running${NC}, ${YELLOW}${#STOPPED_CONTAINERS[@]} stopped${NC}"

# If no stopped containers, nothing to start
if [ ${#STOPPED_CONTAINERS[@]} -eq 0 ]; then
  echo ""
  echo -e "${GREEN}All containers are already running!${NC}"
  exit 0
fi

# 2. Container Selection
echo ""
echo -e "${BLUE}2. Container Selection${NC}"
echo "What would you like to start?"
echo "  1) All stopped containers (${#STOPPED_CONTAINERS[@]} total)"
echo "  2) HQ containers only (specify range)"
echo "  3) Branch containers only (specify range)"
echo "  4) Specific containers (enter CTIDs)"
echo "  5) Range of containers (e.g., 200-205)"
read -p "Select option [1-5] (default: 1): " selection_choice

declare -a TARGET_CONTAINERS=()

case "${selection_choice:-1}" in
  1)
    # All stopped containers
    TARGET_CONTAINERS=("${STOPPED_CONTAINERS[@]}")
    ;;

  2)
    # HQ range
    read_with_default "HQ starting CTID" "200" "HQ_START"
    HQ_END=$((HQ_START + 5))

    echo "Checking HQ containers (${HQ_START}-${HQ_END})..."
    for ctid in $(seq $HQ_START $HQ_END); do
      status=$(get_status $ctid)
      if [ "$status" = "stopped" ]; then
        TARGET_CONTAINERS+=($ctid)
        echo "  CT ${ctid}: Will start"
      elif [ "$status" = "running" ]; then
        echo -e "  ${YELLOW}CT ${ctid}: Already running (skipped)${NC}"
      else
        echo -e "  ${RED}CT ${ctid}: Does not exist (skipped)${NC}"
      fi
    done
    ;;

  3)
    # Branch range
    read_with_default "Branch starting CTID" "220" "BRANCH_START"
    BRANCH_END=$((BRANCH_START + 4))

    echo "Checking Branch containers (${BRANCH_START}-${BRANCH_END})..."
    for ctid in $(seq $BRANCH_START $BRANCH_END); do
      status=$(get_status $ctid)
      if [ "$status" = "stopped" ]; then
        TARGET_CONTAINERS+=($ctid)
        echo "  CT ${ctid}: Will start"
      elif [ "$status" = "running" ]; then
        echo -e "  ${YELLOW}CT ${ctid}: Already running (skipped)${NC}"
      else
        echo -e "  ${RED}CT ${ctid}: Does not exist (skipped)${NC}"
      fi
    done
    ;;

  4)
    # Specific containers
    echo "Enter container IDs to start (space or comma-separated)"
    echo "Example: 200 201 220 or 200,201,220"
    read -p "CTIDs: " ctid_input

    # Handle both space and comma separation
    ctid_input=$(echo "$ctid_input" | tr ',' ' ')

    for ctid in $ctid_input; do
      ctid=$(echo $ctid | xargs)  # trim whitespace
      status=$(get_status $ctid)
      if [ "$status" = "stopped" ]; then
        TARGET_CONTAINERS+=($ctid)
      elif [ "$status" = "running" ]; then
        echo -e "${YELLOW}CT ${ctid}: Already running (skipped)${NC}"
      else
        echo -e "${RED}CT ${ctid}: Does not exist (skipped)${NC}"
      fi
    done
    ;;

  5)
    # Range of containers
    read -p "Enter range (e.g., 200-205): " range_input

    if [[ "$range_input" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      START="${BASH_REMATCH[1]}"
      END="${BASH_REMATCH[2]}"

      echo "Checking containers ${START}-${END}..."
      for ctid in $(seq $START $END); do
        status=$(get_status $ctid)
        if [ "$status" = "stopped" ]; then
          TARGET_CONTAINERS+=($ctid)
          echo "  CT ${ctid}: Will start"
        elif [ "$status" = "running" ]; then
          echo -e "  ${YELLOW}CT ${ctid}: Already running (skipped)${NC}"
        else
          echo -e "  ${RED}CT ${ctid}: Does not exist (skipped)${NC}"
        fi
      done
    else
      echo -e "${RED}Invalid range format${NC}"
      exit 1
    fi
    ;;

  *)
    echo -e "${RED}Invalid selection${NC}"
    exit 1
    ;;
esac

# Check if any containers to start
if [ ${#TARGET_CONTAINERS[@]} -eq 0 ]; then
  echo ""
  echo -e "${YELLOW}No containers selected or all are already running${NC}"
  exit 0
fi

# 3. Startup Options
echo ""
echo -e "${BLUE}3. Startup Options${NC}"
echo "  1) Start sequentially with status updates (slower, verbose)"
echo "  2) Start in parallel (faster, less verbose)"
read -p "Select method [1-2] (default: 2): " method_choice

SEQUENTIAL=false
case "${method_choice:-2}" in
  1)
    SEQUENTIAL=true
    ;;
  2)
    SEQUENTIAL=false
    ;;
esac

# Wait for boot option
echo ""
read -p "Wait for containers to fully boot? [Y/n]: " wait_choice
WAIT_FOR_BOOT=true
if [[ "$wait_choice" =~ ^[Nn]$ ]]; then
  WAIT_FOR_BOOT=false
fi

# Confirmation
echo ""
echo -e "${BLUE}=========================================="
echo "Startup Summary"
echo -e "==========================================${NC}"
echo "Containers to start: ${#TARGET_CONTAINERS[@]}"
echo "Method: $([ "$SEQUENTIAL" = true ] && echo "Sequential" || echo "Parallel")"
echo "Wait for boot: $([ "$WAIT_FOR_BOOT" = true ] && echo "Yes (15s)" || echo "No")"
echo ""
echo -e "${CYAN}Containers:${NC}"
for CTID in "${TARGET_CONTAINERS[@]}"; do
  HOSTNAME=$(get_hostname $CTID)
  echo "  CT ${CTID}: ${HOSTNAME}"
done

echo ""
read -p "Proceed with startup? [y/N]: " confirm

if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Aborted by user"
  exit 0
fi

# Start containers
echo ""
echo -e "${GREEN}Starting containers...${NC}"
echo ""

if $SEQUENTIAL; then
  # Sequential startup with detailed feedback
  for CTID in "${TARGET_CONTAINERS[@]}"; do
    HOSTNAME=$(get_hostname $CTID)
    echo -n "Starting CT ${CTID} (${HOSTNAME})... "

    if pct start $CTID 2>/dev/null; then
      echo -e "${GREEN}✓${NC}"
    else
      echo -e "${RED}✗ Failed${NC}"
    fi

    sleep 1
  done
else
  # Parallel startup
  declare -a PIDS=()

  for CTID in "${TARGET_CONTAINERS[@]}"; do
    HOSTNAME=$(get_hostname $CTID)
    echo "Starting CT ${CTID} (${HOSTNAME})..."
    pct start $CTID 2>/dev/null &
    PIDS+=($!)
  done

  # Wait for all background jobs
  echo ""
  echo "Waiting for startup commands to complete..."
  for pid in "${PIDS[@]}"; do
    wait $pid 2>/dev/null || true
  done
fi

# Wait for boot completion
if $WAIT_FOR_BOOT; then
  echo ""
  echo "Waiting for containers to fully boot (15 seconds)..."
  sleep 15
fi

# Verify status
echo ""
echo -e "${GREEN}=========================================="
echo "Startup Complete"
echo -e "==========================================${NC}"
echo ""

printf "%-8s %-20s %-12s\n" "CTID" "Hostname" "Status"
echo "----------------------------------------"

SUCCESS_COUNT=0
FAILED_COUNT=0

for CTID in "${TARGET_CONTAINERS[@]}"; do
  STATUS=$(get_status $CTID)
  HOSTNAME=$(get_hostname $CTID)

  if [ "$STATUS" = "running" ]; then
    printf "%-8s %-20s ${GREEN}%-12s${NC}\n" "$CTID" "$HOSTNAME" "Running"
    ((SUCCESS_COUNT++))
  else
    printf "%-8s %-20s ${RED}%-12s${NC}\n" "$CTID" "$HOSTNAME" "Failed"
    ((FAILED_COUNT++))
  fi
done

echo ""
echo -e "${GREEN}Successfully started: ${SUCCESS_COUNT}${NC}"
if [ $FAILED_COUNT -gt 0 ]; then
  echo -e "${RED}Failed to start: ${FAILED_COUNT}${NC}"
fi

# Helpful next steps
echo ""
echo "Useful commands:"
echo "  Check status:     pct list"
echo "  View logs:        pct exec <CTID> -- tail -f /var/log/messages"
echo "  Enter container:  pct enter <CTID>"
echo "  Stop containers:  pct stop <CTID>"

# Show sample CTIDs for log viewing
if [ ${#TARGET_CONTAINERS[@]} -gt 0 ]; then
  FIRST_CTID="${TARGET_CONTAINERS[0]}"
  echo ""
  echo "Example - view traffic logs:"
  echo "  pct exec ${FIRST_CTID} -- tail -f /var/log/messages"
fi
