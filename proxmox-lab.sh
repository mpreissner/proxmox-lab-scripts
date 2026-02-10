#!/bin/bash
# proxmox-lab.sh - Proxmox Lab Management Tool (Interactive)
# Combines: create-template, deploy-containers, start-containers, install-traffic-gen

set -e

# ============================================================
# COLORS & SHARED UTILITIES
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

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

get_hostname() {
  local ctid=$1
  pct config $ctid 2>/dev/null | grep "^hostname:" | awk '{print $2}' || echo "unknown"
}

section_header() {
  local title="$1"
  echo ""
  echo -e "${BLUE}=========================================="
  echo "$title"
  echo -e "==========================================${NC}"
  echo ""
}

pick_storage() {
  # Sets STORAGE variable based on user selection
  echo "Common local storage options:"
  echo "  1) local-lvm"
  echo "  2) local-zfs"
  echo "  3) Custom (enter name)"
  read -p "Select storage [1-3] (default: 1): " storage_choice

  case "${storage_choice:-1}" in
    1) STORAGE="local-lvm" ;;
    2) STORAGE="local-zfs" ;;
    3)
      read -p "Enter custom storage name: " STORAGE
      while [ -z "$STORAGE" ]; do
        echo -e "${RED}Storage name is required${NC}"
        read -p "Enter custom storage name: " STORAGE
      done
      ;;
    *) STORAGE="local-lvm" ;;
  esac
}

# ============================================================
# MODULE: Create Template
# ============================================================

cmd_create_template() {
  section_header "Alpine LXC Template Creator"
  echo -e "${YELLOW}Note: This script only supports local storage options${NC}"
  echo ""

  # 1. Template ID
  echo -e "${BLUE}1. Template Configuration${NC}"
  while true; do
    read -p "Template ID (e.g., 150, 9000): " TEMPLATE_ID
    if [[ "$TEMPLATE_ID" =~ ^[0-9]+$ ]]; then
      if pct status $TEMPLATE_ID &>/dev/null; then
        echo -e "${RED}Error: CT ${TEMPLATE_ID} already exists${NC}"
      else
        break
      fi
    else
      echo -e "${RED}Please enter a valid numeric ID${NC}"
    fi
  done

  # 2. Proxmox Node
  echo ""
  echo -e "${BLUE}2. Proxmox Node${NC}"
  echo "Available nodes:"
  pvesh get /nodes --output-format json | jq -r '.[].node' 2>/dev/null || echo "  (Unable to detect nodes)"
  read -p "Node name: " NODE
  while [ -z "$NODE" ]; do
    echo -e "${RED}Node name is required${NC}"
    read -p "Node name: " NODE
  done

  # 3. Storage
  echo ""
  echo -e "${BLUE}3. Storage Configuration${NC}"
  pick_storage

  # 4. Alpine Version
  echo ""
  echo -e "${BLUE}4. Alpine Version${NC}"
  echo "Fetching available Alpine versions..."
  pveam update

  LATEST_ALPINE=$(pveam available --section system | grep "alpine.*amd64" | tail -1 | awk '{print $2}')

  if [ -z "$LATEST_ALPINE" ]; then
    echo -e "${YELLOW}Warning: Could not auto-detect Alpine version${NC}"
    read -p "Enter Alpine template name (e.g., alpine-3.19-default_20231219_amd64.tar.xz): " ALPINE_TEMPLATE
  else
    echo "Latest available: ${LATEST_ALPINE}"
    read_with_default "Alpine template" "$LATEST_ALPINE" "ALPINE_TEMPLATE"
  fi

  # 5. Resources
  echo ""
  echo -e "${BLUE}5. Resource Allocation${NC}"
  read_with_default "Memory (MB)" "256" "MEMORY"
  read_with_default "CPU Cores" "1" "CORES"

  # 6. Network
  echo ""
  echo -e "${BLUE}6. Network Configuration${NC}"
  read_with_default "Bridge" "vmbr0" "BRIDGE"

  # Summary
  section_header "Configuration Summary"
  echo "Template ID:    ${TEMPLATE_ID}"
  echo "Node:           ${NODE}"
  echo "Storage:        ${STORAGE} (local)"
  echo "Alpine:         ${ALPINE_TEMPLATE}"
  echo "Memory:         ${MEMORY} MB"
  echo "CPU Cores:      ${CORES}"
  echo "Bridge:         ${BRIDGE}"
  echo ""
  read -p "Proceed with creation? [y/N]: " confirm

  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted by user"
    return 0
  fi

  echo ""
  echo -e "${GREEN}Creating Alpine LXC template (CT ${TEMPLATE_ID})...${NC}"

  echo "Downloading Alpine template if needed..."
  pveam download local "${ALPINE_TEMPLATE}" 2>/dev/null || true

  if ! pveam list local | grep -q "${ALPINE_TEMPLATE}"; then
    echo -e "${RED}Error: Template ${ALPINE_TEMPLATE} not found in local storage${NC}"
    echo "Available templates:"
    pveam list local
    return 1
  fi

  echo "Creating base container..."
  pct create $TEMPLATE_ID local:vztmpl/${ALPINE_TEMPLATE} \
    --hostname alpine-template \
    --memory $MEMORY \
    --cores $CORES \
    --net0 name=eth0,bridge=${BRIDGE},firewall=1 \
    --storage $STORAGE \
    --unprivileged 1 \
    --onboot 0 \
    --ostype alpine \
    --features nesting=1

  echo "Starting container to configure..."
  pct start $TEMPLATE_ID
  sleep 10

  echo "Installing base packages..."
  pct exec $TEMPLATE_ID -- sh -c "
    apk update
    apk add curl wget bind-tools bash jq python3 py3-pip dcron nano vim openrc

    # Enable cron
    rc-update add dcron default

    # Create traffic-gen directory structure
    mkdir -p /opt/traffic-gen/{profiles,domains,utils}

    echo 'Template configuration complete'
  "

  echo "Stopping and converting to template..."
  pct stop $TEMPLATE_ID
  pct template $TEMPLATE_ID

  echo ""
  echo -e "${GREEN}=========================================="
  echo "✓ Template CT ${TEMPLATE_ID} created successfully"
  echo -e "==========================================${NC}"
  echo ""
  echo "Next step: Deploy containers (option 2 from main menu)"
}

# ============================================================
# MODULE: Deploy Containers
# ============================================================

cmd_deploy_containers() {
  section_header "Lab Container Deployment"

  # 1. Template Selection
  echo -e "${BLUE}1. Source Template${NC}"
  echo "Looking for available templates..."
  templates=$(pct list | grep -i "template" || true)
  if [ -n "$templates" ]; then
    echo "Available templates:"
    echo "$templates" | awk '{print "  CT " $1 " - " $3}'
  fi
  echo ""

  while true; do
    read -p "Template ID to clone from: " TEMPLATE_ID
    if [[ "$TEMPLATE_ID" =~ ^[0-9]+$ ]]; then
      if pct status $TEMPLATE_ID &>/dev/null; then
        if pct config $TEMPLATE_ID | grep -q "template: 1"; then
          break
        else
          echo -e "${RED}Error: CT ${TEMPLATE_ID} is not a template${NC}"
        fi
      else
        echo -e "${RED}Error: CT ${TEMPLATE_ID} does not exist${NC}"
      fi
    else
      echo -e "${RED}Please enter a valid numeric ID${NC}"
    fi
  done

  # 2. Storage
  echo ""
  echo -e "${BLUE}2. Storage Configuration${NC}"
  pick_storage

  # 3. Network
  echo ""
  echo -e "${BLUE}3. Network Configuration${NC}"
  read_with_default "Bridge" "vmbr0" "BRIDGE"

  # 4. Deployment Scope
  echo ""
  echo -e "${BLUE}4. Deployment Scope${NC}"
  echo "What would you like to deploy?"
  echo "  1) Both HQ and Branch containers (11 total)"
  echo "  2) HQ ServerNet only (6 containers)"
  echo "  3) Branch UserNet only (5 containers)"
  read -p "Select scope [1-3] (default: 1): " scope_choice

  DEPLOY_HQ=false
  DEPLOY_BRANCH=false

  case "${scope_choice:-1}" in
    1) DEPLOY_HQ=true; DEPLOY_BRANCH=true ;;
    2) DEPLOY_HQ=true ;;
    3) DEPLOY_BRANCH=true ;;
    *) DEPLOY_HQ=true; DEPLOY_BRANCH=true ;;
  esac

  # 5. HQ Config
  if $DEPLOY_HQ; then
    echo ""
    echo -e "${BLUE}5. HQ ServerNet Configuration${NC}"
    read_with_default "Starting CTID for HQ" "200" "HQ_START"
    read_with_default "HQ VLAN tag" "200" "VLAN_HQ"

    echo -e "${CYAN}HQ containers will be:${NC}"
    echo "  CT ${HQ_START}: hq-fileserver"
    echo "  CT $((HQ_START+1)): hq-webapp"
    echo "  CT $((HQ_START+2)): hq-email"
    echo "  CT $((HQ_START+3)): hq-monitoring (512MB)"
    echo "  CT $((HQ_START+4)): hq-devops (512MB)"
    echo "  CT $((HQ_START+5)): hq-database"
  fi

  # 6. Branch Config
  if $DEPLOY_BRANCH; then
    echo ""
    if $DEPLOY_HQ; then
      echo -e "${BLUE}6. Branch UserNet Configuration${NC}"
    else
      echo -e "${BLUE}5. Branch UserNet Configuration${NC}"
    fi
    read_with_default "Starting CTID for Branch" "220" "BRANCH_START"
    read_with_default "Branch VLAN tag" "201" "VLAN_BRANCH"

    echo -e "${CYAN}Branch containers will be:${NC}"
    echo "  CT ${BRANCH_START}: branch-worker1"
    echo "  CT $((BRANCH_START+1)): branch-worker2"
    echo "  CT $((BRANCH_START+2)): branch-sales"
    echo "  CT $((BRANCH_START+3)): branch-dev (512MB)"
    echo "  CT $((BRANCH_START+4)): branch-exec"
  fi

  declare -A HQ_CONTAINERS=(
    [0]="hq-fileserver"
    [1]="hq-webapp"
    [2]="hq-email"
    [3]="hq-monitoring"
    [4]="hq-devops"
    [5]="hq-database"
  )

  declare -A BRANCH_CONTAINERS=(
    [0]="branch-worker1"
    [1]="branch-worker2"
    [2]="branch-sales"
    [3]="branch-dev"
    [4]="branch-exec"
  )

  # Summary
  section_header "Deployment Summary"
  echo "Source Template: CT ${TEMPLATE_ID}"
  echo "Storage:         ${STORAGE}"
  echo "Bridge:          ${BRIDGE}"

  if $DEPLOY_HQ; then
    echo ""
    echo -e "${CYAN}HQ ServerNet:${NC}"
    echo "  VLAN Tag:    ${VLAN_HQ}"
    echo "  CTID Range:  ${HQ_START}-$((HQ_START+5))"
    echo "  Containers:  6"
  fi

  if $DEPLOY_BRANCH; then
    echo ""
    echo -e "${CYAN}Branch UserNet:${NC}"
    echo "  VLAN Tag:    ${VLAN_BRANCH}"
    echo "  CTID Range:  ${BRANCH_START}-$((BRANCH_START+4))"
    echo "  Containers:  5"
  fi

  echo ""
  read -p "Proceed with deployment? [y/N]: " confirm

  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted by user"
    return 0
  fi

  # Deploy HQ
  if $DEPLOY_HQ; then
    echo ""
    echo -e "${GREEN}=========================================="
    echo "Deploying HQ ServerNet Containers"
    echo -e "==========================================${NC}"

    for OFFSET in "${!HQ_CONTAINERS[@]}"; do
      CTID=$((HQ_START + OFFSET))
      HOSTNAME="${HQ_CONTAINERS[$OFFSET]}"

      if pct status $CTID &>/dev/null; then
        echo -e "${YELLOW}⚠ CT ${CTID} already exists, skipping ${HOSTNAME}${NC}"
        continue
      fi

      echo "Creating CT ${CTID}: ${HOSTNAME}..."

      pct clone $TEMPLATE_ID $CTID \
        --hostname $HOSTNAME \
        --full 1 \
        --storage $STORAGE

      pct set $CTID --net0 name=eth0,bridge=${BRIDGE},tag=$VLAN_HQ,firewall=1,ip=dhcp

      if [[ "$HOSTNAME" =~ (monitoring|devops) ]]; then
        pct set $CTID --memory 512
      else
        pct set $CTID --memory 256
      fi

      pct set $CTID --onboot 1
      echo -e "${GREEN}✓ CT ${CTID} (${HOSTNAME}) created${NC}"
    done
  fi

  # Deploy Branch
  if $DEPLOY_BRANCH; then
    echo ""
    echo -e "${GREEN}=========================================="
    echo "Deploying Branch UserNet Containers"
    echo -e "==========================================${NC}"

    for OFFSET in "${!BRANCH_CONTAINERS[@]}"; do
      CTID=$((BRANCH_START + OFFSET))
      HOSTNAME="${BRANCH_CONTAINERS[$OFFSET]}"

      if pct status $CTID &>/dev/null; then
        echo -e "${YELLOW}⚠ CT ${CTID} already exists, skipping ${HOSTNAME}${NC}"
        continue
      fi

      echo "Creating CT ${CTID}: ${HOSTNAME}..."

      pct clone $TEMPLATE_ID $CTID \
        --hostname $HOSTNAME \
        --full 1 \
        --storage $STORAGE

      pct set $CTID --net0 name=eth0,bridge=${BRIDGE},tag=$VLAN_BRANCH,firewall=1,ip=dhcp

      if [[ "$HOSTNAME" == "branch-dev" ]]; then
        pct set $CTID --memory 512
      else
        pct set $CTID --memory 256
      fi

      pct set $CTID --onboot 1
      echo -e "${GREEN}✓ CT ${CTID} (${HOSTNAME}) created${NC}"
    done
  fi

  # Final Summary
  section_header "✓ Deployment Complete"

  if $DEPLOY_HQ; then
    echo -e "${CYAN}HQ ServerNet (VLAN ${VLAN_HQ}):${NC}"
    for OFFSET in "${!HQ_CONTAINERS[@]}"; do
      CTID=$((HQ_START + OFFSET))
      echo "  CT ${CTID}: ${HQ_CONTAINERS[$OFFSET]}"
    done
  fi

  if $DEPLOY_BRANCH; then
    echo ""
    echo -e "${CYAN}Branch UserNet (VLAN ${VLAN_BRANCH}):${NC}"
    for OFFSET in "${!BRANCH_CONTAINERS[@]}"; do
      CTID=$((BRANCH_START + OFFSET))
      echo "  CT ${CTID}: ${BRANCH_CONTAINERS[$OFFSET]}"
    done
  fi

  echo ""
  echo "Next steps: Start containers (option 3), then install traffic gen (option 4)"
}

# ============================================================
# MODULE: Start Containers
# ============================================================

cmd_start_containers() {
  section_header "Container Startup Manager"

  echo -e "${BLUE}1. Current Container Status${NC}"
  echo "Scanning for containers..."
  echo ""

  ALL_CONTAINERS=$(pct list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n)

  if [ -z "$ALL_CONTAINERS" ]; then
    echo -e "${RED}No containers found on this system${NC}"
    return 1
  fi

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

  if [ ${#STOPPED_CONTAINERS[@]} -eq 0 ]; then
    echo ""
    echo -e "${GREEN}All containers are already running!${NC}"
    return 0
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
      TARGET_CONTAINERS=("${STOPPED_CONTAINERS[@]}")
      ;;

    2)
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
      echo "Enter container IDs to start (space or comma-separated)"
      echo "Example: 200 201 220 or 200,201,220"
      read -p "CTIDs: " ctid_input
      ctid_input=$(echo "$ctid_input" | tr ',' ' ')
      for ctid in $ctid_input; do
        ctid=$(echo $ctid | xargs)
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
        return 1
      fi
      ;;

    *)
      echo -e "${RED}Invalid selection${NC}"
      return 1
      ;;
  esac

  if [ ${#TARGET_CONTAINERS[@]} -eq 0 ]; then
    echo ""
    echo -e "${YELLOW}No containers selected or all are already running${NC}"
    return 0
  fi

  # 3. Startup Options
  echo ""
  echo -e "${BLUE}3. Startup Options${NC}"
  echo "  1) Start sequentially with status updates (slower, verbose)"
  echo "  2) Start in parallel (faster, less verbose)"
  read -p "Select method [1-2] (default: 2): " method_choice

  SEQUENTIAL=false
  case "${method_choice:-2}" in
    1) SEQUENTIAL=true ;;
    2) SEQUENTIAL=false ;;
  esac

  echo ""
  read -p "Wait for containers to fully boot? [Y/n]: " wait_choice
  WAIT_FOR_BOOT=true
  if [[ "$wait_choice" =~ ^[Nn]$ ]]; then
    WAIT_FOR_BOOT=false
  fi

  section_header "Startup Summary"
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
    return 0
  fi

  echo ""
  echo -e "${GREEN}Starting containers...${NC}"
  echo ""

  if $SEQUENTIAL; then
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
    declare -a PIDS=()
    for CTID in "${TARGET_CONTAINERS[@]}"; do
      HOSTNAME=$(get_hostname $CTID)
      echo "Starting CT ${CTID} (${HOSTNAME})..."
      pct start $CTID 2>/dev/null &
      PIDS+=($!)
    done
    echo ""
    echo "Waiting for startup commands to complete..."
    for pid in "${PIDS[@]}"; do
      wait $pid 2>/dev/null || true
    done
  fi

  if $WAIT_FOR_BOOT; then
    echo ""
    echo "Waiting for containers to fully boot (15 seconds)..."
    sleep 15
  fi

  section_header "Startup Complete"
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

  echo ""
  echo "Useful commands:"
  echo "  Check status:     pct list"
  echo "  View logs:        pct exec <CTID> -- tail -f /var/log/messages"
  echo "  Enter container:  pct enter <CTID>"
  echo "  Stop containers:  pct stop <CTID>"

  if [ ${#TARGET_CONTAINERS[@]} -gt 0 ]; then
    FIRST_CTID="${TARGET_CONTAINERS[0]}"
    echo ""
    echo "Example - view traffic logs:"
    echo "  pct exec ${FIRST_CTID} -- tail -f /var/log/messages"
  fi
}

# ============================================================
# MODULE: Install Traffic Generator
# ============================================================

declare -A PROFILE_DESC=(
  ["fileserver"]="Cloud sync (OneDrive, Dropbox, S3), DLP test scenarios"
  ["webapp"]="Payment APIs (Stripe), CDN services, certificate validation"
  ["email"]="Office 365, Google Workspace, spam filters, AV updates"
  ["monitoring"]="Ubuntu repos, Datadog, New Relic, Docker Hub, GitHub"
  ["devops"]="npm, PyPI, GitHub, Docker Hub, EICAR malware test"
  ["database"]="AWS RDS, Azure SQL, S3 backups"
  ["office-worker"]="Office 365, Salesforce, Slack, Google Docs, news sites"
  ["sales"]="Salesforce, LinkedIn, travel booking, Zoom, HubSpot"
  ["developer"]="GitHub, StackOverflow, npm, PyPI, AWS Console, Docker"
  ["executive"]="Office 365 (+ after-hours UEBA), WSJ, Bloomberg, Zoom"
)

declare -A DEFAULT_PROFILES=(
  [200]="fileserver"
  [201]="webapp"
  [202]="email"
  [203]="monitoring"
  [204]="devops"
  [205]="database"
  [220]="office-worker"
  [221]="office-worker"
  [222]="sales"
  [223]="developer"
  [224]="executive"
)

_install_framework() {
  local ctid=$1

  pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/traffic-gen.sh' <<'EOF'
#!/bin/bash
# Main traffic generator script

PROFILE="$1"
MODE="${2:-normal}"

# Source utilities
source /opt/traffic-gen/utils/business-hours.sh 2>/dev/null || true
source /opt/traffic-gen/utils/random-timing.sh 2>/dev/null || true

# Run profile
if [ -f "/opt/traffic-gen/profiles/${PROFILE}.sh" ]; then
  /opt/traffic-gen/profiles/${PROFILE}.sh "$MODE"
else
  echo "Profile ${PROFILE} not found"
  exit 1
fi
EOF

  pct exec $ctid -- chmod +x /opt/traffic-gen/traffic-gen.sh

  pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/utils/business-hours.sh' <<'EOF'
#!/bin/bash
# Check if current time is business hours

is_business_hours() {
  local hour=$(date +%H)
  local day=$(date +%u)  # 1-7 (Monday-Sunday)

  # Monday-Friday, 8am-6pm
  if [ $day -le 5 ] && [ $hour -ge 8 ] && [ $hour -lt 18 ]; then
    return 0
  else
    return 1
  fi
}

is_lunch_time() {
  local hour=$(date +%H)
  if [ $hour -ge 12 ] && [ $hour -lt 13 ]; then
    return 0
  else
    return 1
  fi
}
EOF

  pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/utils/random-timing.sh' <<'EOF'
#!/bin/bash
# Random timing utilities

random_delay() {
  local min=${1:-5}
  local max=${2:-60}
  local delay=$((RANDOM % (max - min + 1) + min))
  echo $delay
}

random_user_agent() {
  local agents=(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"
  )
  echo "${agents[$((RANDOM % ${#agents[@]}))]}"
}

browse_random() {
  local domain_file="$1"
  local count=${2:-1}

  if [ ! -file "$domain_file" ]; then
    return
  fi

  for i in $(seq 1 $count); do
    local domain=$(shuf -n 1 "$domain_file")
    local ua=$(random_user_agent)
    curl -s -A "$ua" -m 10 "$domain" > /dev/null 2>&1 || true
    sleep $(random_delay 2 10)
  done
}
EOF
}

_install_profile() {
  local ctid=$1
  local profile=$2

  case "$profile" in
    fileserver)
      pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/profiles/fileserver.sh' <<'EOF'
#!/bin/bash
source /opt/traffic-gen/utils/random-timing.sh

HOUR=$(date +%H)

# Simulate file backup to cloud
backup_to_cloud() {
  echo "[$(date)] File server: Cloud backup sync"

  # OneDrive sync
  curl -s -A "OneDriveSync/1.0" https://onedrive.live.com > /dev/null 2>&1

  # Dropbox sync
  curl -s -A "DropboxSync/2.0" https://www.dropbox.com > /dev/null 2>&1

  # DLP trigger - simulated sensitive data upload
  if [ $((RANDOM % 10)) -eq 0 ]; then
    echo "[$(date)] File server: Uploading file with sensitive data (DLP test)"
    curl -s -X POST -d "ssn=123-45-6789&ccn=4111111111111111" \
      https://webhook.site/test > /dev/null 2>&1 || true
  fi
}

# Nightly backup (2-4 AM)
if [ $HOUR -ge 2 ] && [ $HOUR -lt 4 ]; then
  echo "[$(date)] File server: Nightly backup window"
  backup_to_cloud
  sleep $(random_delay 60 180)
fi

# Regular sync during day
backup_to_cloud
sleep $(random_delay 30 90)

# AWS S3 simulation
curl -s https://s3.amazonaws.com > /dev/null 2>&1
EOF
      ;;

    webapp)
      pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/profiles/webapp.sh' <<'EOF'
#!/bin/bash
source /opt/traffic-gen/utils/random-timing.sh

echo "[$(date)] Web app: External API calls"

# Payment processor
curl -s https://api.stripe.com > /dev/null 2>&1
sleep $(random_delay 5 15)

# CDN assets
curl -s https://cdn.jsdelivr.net > /dev/null 2>&1
curl -s https://cdnjs.cloudflare.com > /dev/null 2>&1

# Certificate validation
curl -s http://ocsp.digicert.com > /dev/null 2>&1

# Database backup to S3
if [ $((RANDOM % 20)) -eq 0 ]; then
  echo "[$(date)] Web app: S3 backup"
  curl -s https://s3.amazonaws.com > /dev/null 2>&1
fi
EOF
      ;;

    email)
      pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/profiles/email.sh' <<'EOF'
#!/bin/bash
source /opt/traffic-gen/utils/random-timing.sh

echo "[$(date)] Email server: Mail relay operations"

# Office 365 SMTP relay
curl -s https://outlook.office365.com > /dev/null 2>&1
sleep $(random_delay 10 30)

# Google Workspace
curl -s https://mail.google.com > /dev/null 2>&1

# Spam filter updates
curl -s https://www.spamhaus.org > /dev/null 2>&1

# Anti-virus definitions
curl -s https://www.clamav.net > /dev/null 2>&1
EOF
      ;;

    monitoring)
      pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/profiles/monitoring.sh' <<'EOF'
#!/bin/bash
source /opt/traffic-gen/utils/random-timing.sh

echo "[$(date)] Monitoring: System checks"

# Ubuntu/Debian repos
curl -s http://archive.ubuntu.com/ubuntu > /dev/null 2>&1
curl -s http://security.ubuntu.com/ubuntu > /dev/null 2>&1

# Monitoring services
curl -s https://api.datadoghq.com > /dev/null 2>&1
curl -s https://api.newrelic.com > /dev/null 2>&1

# Container registry
curl -s https://registry.hub.docker.com > /dev/null 2>&1

# GitHub API
curl -s https://api.github.com > /dev/null 2>&1
EOF
      ;;

    devops)
      pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/profiles/devops.sh' <<'EOF'
#!/bin/bash
source /opt/traffic-gen/utils/random-timing.sh

echo "[$(date)] DevOps: Build pipeline activity"

# npm packages
curl -s https://registry.npmjs.org > /dev/null 2>&1
sleep $(random_delay 5 15)

# PyPI
curl -s https://pypi.org > /dev/null 2>&1

# GitHub
curl -s https://github.com > /dev/null 2>&1
curl -s https://api.github.com > /dev/null 2>&1

# Docker Hub
curl -s https://hub.docker.com > /dev/null 2>&1

# Occasional risky download (supply chain test)
if [ $((RANDOM % 30)) -eq 0 ]; then
  echo "[$(date)] DevOps: Testing suspicious download"
  curl -s https://malware.wicar.org/data/eicar.com > /dev/null 2>&1 || true
fi
EOF
      ;;

    database)
      pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/profiles/database.sh' <<'EOF'
#!/bin/bash
source /opt/traffic-gen/utils/random-timing.sh

echo "[$(date)] Database: Backup and replication"

# Cloud database services
curl -s https://aws.amazon.com/rds > /dev/null 2>&1
sleep $(random_delay 10 30)

# Backup to S3
curl -s https://s3.amazonaws.com > /dev/null 2>&1

# Azure SQL
curl -s https://azure.microsoft.com > /dev/null 2>&1
EOF
      ;;

    office-worker)
      pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/profiles/office-worker.sh' <<'EOF'
#!/bin/bash
source /opt/traffic-gen/utils/business-hours.sh
source /opt/traffic-gen/utils/random-timing.sh

if ! is_business_hours; then
  # Minimal after-hours activity
  if [ $((RANDOM % 4)) -eq 0 ]; then
    echo "[$(date)] Office worker: After-hours email check"
    curl -s https://outlook.office365.com > /dev/null 2>&1
  fi
  exit 0
fi

HOUR=$(date +%H)

echo "[$(date)] Office worker: Business hours activity (Hour: $HOUR)"

# Morning routine (8-10am)
if [ $HOUR -ge 8 ] && [ $HOUR -lt 10 ]; then
  curl -s https://outlook.office365.com > /dev/null 2>&1
  sleep $(random_delay 5 15)
  curl -s https://www.cnn.com > /dev/null 2>&1
  curl -s https://www.bbc.com > /dev/null 2>&1

# Lunch time (12-1pm) - personal browsing
elif is_lunch_time; then
  echo "[$(date)] Office worker: Lunch time personal browsing"
  curl -s https://www.amazon.com > /dev/null 2>&1
  sleep $(random_delay 5 10)
  # Try social media (will be blocked)
  curl -s https://www.facebook.com > /dev/null 2>&1 || true
  curl -s https://www.youtube.com > /dev/null 2>&1

# Regular work hours
else
  # SaaS apps
  curl -s https://www.salesforce.com > /dev/null 2>&1
  sleep $(random_delay 5 15)
  curl -s https://slack.com > /dev/null 2>&1

  # Document collaboration
  curl -s https://docs.google.com > /dev/null 2>&1

  # Random policy violation (10% chance)
  if [ $((RANDOM % 10)) -eq 0 ]; then
    echo "[$(date)] Office worker: Policy violation attempt"
    curl -s https://www.dropbox.com > /dev/null 2>&1 || true
  fi
fi
EOF
      ;;

    sales)
      pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/profiles/sales.sh' <<'EOF'
#!/bin/bash
source /opt/traffic-gen/utils/business-hours.sh
source /opt/traffic-gen/utils/random-timing.sh

if ! is_business_hours; then
  exit 0
fi

echo "[$(date)] Sales: CRM and prospecting activity"

# Heavy SaaS usage
curl -s https://www.salesforce.com > /dev/null 2>&1
sleep $(random_delay 10 20)

curl -s https://www.linkedin.com > /dev/null 2>&1
sleep $(random_delay 5 15)

# Travel booking
curl -s https://www.expedia.com > /dev/null 2>&1

# Webinar platforms
curl -s https://zoom.us > /dev/null 2>&1

# Marketing automation
curl -s https://www.hubspot.com > /dev/null 2>&1
EOF
      ;;

    developer)
      pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/profiles/developer.sh' <<'EOF'
#!/bin/bash
source /opt/traffic-gen/utils/business-hours.sh
source /opt/traffic-gen/utils/random-timing.sh

if ! is_business_hours; then
  # Devs work late sometimes
  if [ $((RANDOM % 3)) -eq 0 ]; then
    echo "[$(date)] Developer: After-hours coding"
    curl -s https://github.com > /dev/null 2>&1
  fi
  exit 0
fi

echo "[$(date)] Developer: Development activity"

# Code repositories
curl -s https://github.com > /dev/null 2>&1
sleep $(random_delay 10 30)

# Stack Overflow
curl -s https://stackoverflow.com > /dev/null 2>&1

# Package managers
curl -s https://registry.npmjs.org > /dev/null 2>&1
sleep $(random_delay 5 15)

curl -s https://pypi.org > /dev/null 2>&1

# Cloud consoles
curl -s https://console.aws.amazon.com > /dev/null 2>&1

# Docker
curl -s https://hub.docker.com > /dev/null 2>&1
EOF
      ;;

    executive)
      pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/profiles/executive.sh' <<'EOF'
#!/bin/bash
source /opt/traffic-gen/utils/business-hours.sh
source /opt/traffic-gen/utils/random-timing.sh

if ! is_business_hours; then
  # Execs check email at odd hours (UEBA trigger)
  if [ $((RANDOM % 2)) -eq 0 ]; then
    echo "[$(date)] Executive: After-hours email (UEBA target)"
    curl -s https://outlook.office365.com > /dev/null 2>&1
  fi
  exit 0
fi

echo "[$(date)] Executive: Light usage pattern"

# Email
curl -s https://outlook.office365.com > /dev/null 2>&1
sleep $(random_delay 15 45)

# News sites
curl -s https://www.wsj.com > /dev/null 2>&1
curl -s https://www.bloomberg.com > /dev/null 2>&1

# Video conferencing
curl -s https://zoom.us > /dev/null 2>&1

# Travel
if [ $((RANDOM % 5)) -eq 0 ]; then
  curl -s https://www.united.com > /dev/null 2>&1
fi
EOF
      ;;
  esac

  pct exec $ctid -- chmod +x /opt/traffic-gen/profiles/${profile}.sh
}

cmd_install_traffic_gen() {
  section_header "Traffic Generator Installation"

  # 1. Container Selection
  echo -e "${BLUE}1. Container Selection${NC}"
  echo "Detecting running containers..."

  RUNNING_CONTAINERS=$(pct list | awk 'NR>1 {print $1}' | sort -n)

  if [ -z "$RUNNING_CONTAINERS" ]; then
    echo -e "${RED}No running containers found!${NC}"
    echo "Please start containers first (option 3 from main menu)"
    return 1
  fi

  echo "Running containers:"
  pct list | head -10

  echo ""
  echo "Installation scope options:"
  echo "  1) Auto-detect and configure all containers with default profiles"
  echo "  2) HQ containers only (specify range)"
  echo "  3) Branch containers only (specify range)"
  echo "  4) Custom selection (specify CTIDs)"
  read -p "Select scope [1-4] (default: 1): " scope_choice

  declare -A TARGET_PROFILES=()

  case "${scope_choice:-1}" in
    1)
      echo "Auto-detecting containers..."
      for CTID in $RUNNING_CONTAINERS; do
        if [ -n "${DEFAULT_PROFILES[$CTID]}" ]; then
          TARGET_PROFILES[$CTID]="${DEFAULT_PROFILES[$CTID]}"
        fi
      done

      if [ ${#TARGET_PROFILES[@]} -eq 0 ]; then
        echo -e "${YELLOW}No containers match default CTID ranges (200-205, 220-224)${NC}"
        echo "Please use custom selection option"
        return 1
      fi
      ;;

    2)
      read_with_default "HQ starting CTID" "200" "HQ_START"
      HQ_END=$((HQ_START + 5))

      echo "HQ containers (${HQ_START}-${HQ_END}):"
      offset=0
      for profile in fileserver webapp email monitoring devops database; do
        ctid=$((HQ_START + offset))
        if echo "$RUNNING_CONTAINERS" | grep -q "^${ctid}$"; then
          TARGET_PROFILES[$ctid]="$profile"
          echo "  CT ${ctid}: ${profile}"
        else
          echo -e "  ${YELLOW}CT ${ctid}: not running (skipped)${NC}"
        fi
        ((offset++))
      done
      ;;

    3)
      read_with_default "Branch starting CTID" "220" "BRANCH_START"
      BRANCH_END=$((BRANCH_START + 4))

      echo "Branch containers (${BRANCH_START}-${BRANCH_END}):"
      offset=0
      for profile in office-worker office-worker sales developer executive; do
        ctid=$((BRANCH_START + offset))
        if echo "$RUNNING_CONTAINERS" | grep -q "^${ctid}$"; then
          TARGET_PROFILES[$ctid]="$profile"
          echo "  CT ${ctid}: ${profile}"
        else
          echo -e "  ${YELLOW}CT ${ctid}: not running (skipped)${NC}"
        fi
        ((offset++))
      done
      ;;

    4)
      echo "Available profiles:"
      echo "  Server: fileserver, webapp, email, monitoring, devops, database"
      echo "  User:   office-worker, sales, developer, executive"
      echo ""
      echo "Enter container assignments (format: CTID:profile, comma-separated)"
      echo "Example: 200:fileserver,201:webapp,220:office-worker"
      read -p "Assignments: " assignments

      IFS=',' read -ra ASSIGNMENTS <<< "$assignments"
      for assignment in "${ASSIGNMENTS[@]}"; do
        IFS=':' read -r ctid profile <<< "$assignment"
        ctid=$(echo $ctid | xargs)
        profile=$(echo $profile | xargs)

        if echo "$RUNNING_CONTAINERS" | grep -q "^${ctid}$"; then
          TARGET_PROFILES[$ctid]="$profile"
        else
          echo -e "${YELLOW}Warning: CT ${ctid} is not running, skipping${NC}"
        fi
      done
      ;;
  esac

  if [ ${#TARGET_PROFILES[@]} -eq 0 ]; then
    echo -e "${RED}No valid containers selected${NC}"
    return 1
  fi

  # 2. Traffic Intensity
  echo ""
  echo -e "${BLUE}2. Traffic Intensity${NC}"
  echo "Select traffic generation frequency:"
  echo "  1) Light   - Servers: every 30 min, Office: every 10 min"
  echo "  2) Normal  - Servers: every 15 min, Office: every 5 min (default)"
  echo "  3) Heavy   - Servers: every 5 min,  Office: every 2 min"
  echo "  4) Custom  - Specify your own cron schedules"
  read -p "Select intensity [1-4] (default: 2): " intensity_choice

  case "${intensity_choice:-2}" in
    1)
      CRON_SERVER="*/30 * * * *"
      CRON_OFFICE="*/10 8-18 * * 1-5"
      INTENSITY="Light"
      ;;
    2)
      CRON_SERVER="*/15 * * * *"
      CRON_OFFICE="*/5 8-18 * * 1-5"
      INTENSITY="Normal"
      ;;
    3)
      CRON_SERVER="*/5 * * * *"
      CRON_OFFICE="*/2 8-18 * * 1-5"
      INTENSITY="Heavy"
      ;;
    4)
      read -p "Server cron schedule (e.g., */15 * * * *): " CRON_SERVER
      read -p "Office cron schedule (e.g., */5 8-18 * * 1-5): " CRON_OFFICE
      INTENSITY="Custom"
      ;;
  esac

  # 3. Installation Mode
  echo ""
  echo -e "${BLUE}3. Installation Mode${NC}"
  echo "  1) Full install (framework + profiles + enable cron)"
  echo "  2) Framework only (no cron, manual start)"
  echo "  3) Update profiles only (keep existing cron)"
  read -p "Select mode [1-3] (default: 1): " install_mode

  INSTALL_FRAMEWORK=true
  INSTALL_PROFILES=true
  ENABLE_CRON=true

  case "${install_mode:-1}" in
    1) INSTALL_FRAMEWORK=true; INSTALL_PROFILES=true; ENABLE_CRON=true ;;
    2) INSTALL_FRAMEWORK=true; INSTALL_PROFILES=true; ENABLE_CRON=false ;;
    3) INSTALL_FRAMEWORK=false; INSTALL_PROFILES=true; ENABLE_CRON=false ;;
  esac

  # Summary
  section_header "Installation Summary"
  echo "Containers:      ${#TARGET_PROFILES[@]}"
  echo "Intensity:       ${INTENSITY}"
  echo "Server Schedule: ${CRON_SERVER}"
  echo "Office Schedule: ${CRON_OFFICE}"
  echo ""
  echo "Installation mode:"
  [ "$INSTALL_FRAMEWORK" = true ] && echo "  ✓ Install framework"
  [ "$INSTALL_PROFILES" = true ] && echo "  ✓ Install profiles"
  [ "$ENABLE_CRON" = true ] && echo "  ✓ Enable automatic traffic generation"
  [ "$ENABLE_CRON" = false ] && echo "  ○ Manual start only (no cron)"

  echo ""
  echo -e "${CYAN}Container assignments:${NC}"
  for CTID in "${!TARGET_PROFILES[@]}"; do
    PROFILE="${TARGET_PROFILES[$CTID]}"
    echo "  CT ${CTID}: ${PROFILE}"
    echo "    → ${PROFILE_DESC[$PROFILE]}"
  done

  echo ""
  read -p "Proceed with installation? [y/N]: " confirm

  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted by user"
    return 0
  fi

  echo ""
  echo -e "${GREEN}Starting installation...${NC}"

  for CTID in "${!TARGET_PROFILES[@]}"; do
    PROFILE="${TARGET_PROFILES[$CTID]}"

    echo ""
    echo -e "${CYAN}Configuring CT ${CTID} (${PROFILE})...${NC}"

    if ! pct status $CTID | grep -q "running"; then
      echo -e "${YELLOW}  ⚠ Container not running, skipping${NC}"
      continue
    fi

    if $INSTALL_FRAMEWORK; then
      echo "  → Installing framework..."
      _install_framework $CTID
    fi

    if $INSTALL_PROFILES; then
      echo "  → Installing ${PROFILE} profile..."
      _install_profile $CTID $PROFILE
    fi

    if $ENABLE_CRON; then
      echo "  → Configuring cron schedule..."
      if [[ "$PROFILE" =~ ^(office-worker|sales|developer|executive)$ ]]; then
        pct exec $CTID -- bash -c "echo '${CRON_OFFICE} /opt/traffic-gen/traffic-gen.sh ${PROFILE}' | crontab -"
      else
        pct exec $CTID -- bash -c "echo '${CRON_SERVER} /opt/traffic-gen/traffic-gen.sh ${PROFILE}' | crontab -"
      fi
    fi

    echo -e "${GREEN}  ✓ CT ${CTID} configured successfully${NC}"
  done

  section_header "✓ Installation Complete"
  echo "Configured containers: ${#TARGET_PROFILES[@]}"
  echo "Traffic intensity: ${INTENSITY}"

  if $ENABLE_CRON; then
    echo ""
    echo "Traffic generation is ENABLED and will run automatically"
    echo ""
    echo "Useful commands:"
    echo "  View cron:    pct exec <CTID> -- crontab -l"
    echo "  View logs:    pct exec <CTID> -- tail -f /var/log/messages"
    echo "  Manual run:   pct exec <CTID> -- /opt/traffic-gen/traffic-gen.sh <profile>"
    echo "  Disable cron: pct exec <CTID> -- crontab -r"
  else
    echo ""
    echo "Traffic generation is DISABLED (manual mode)"
    echo ""
    echo "To start manually:"
    echo "  pct exec <CTID> -- /opt/traffic-gen/traffic-gen.sh <profile>"
    echo ""
    echo "To enable automatic traffic:"
    echo "  Re-run install (option 4) and choose 'Full install' mode"
  fi
}

# ============================================================
# MODULE: Show Status
# ============================================================

cmd_show_status() {
  section_header "Lab Status"

  ALL_CONTAINERS=$(pct list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n)

  if [ -z "$ALL_CONTAINERS" ]; then
    echo -e "${RED}No containers found on this system${NC}"
    return 0
  fi

  printf "%-8s %-24s %-12s %-14s\n" "CTID" "Hostname" "Status" "Traffic Gen"
  echo "------------------------------------------------------------"

  RUNNING=0
  STOPPED=0

  for CTID in $ALL_CONTAINERS; do
    STATUS=$(get_status $CTID)
    HOSTNAME=$(get_hostname $CTID)

    if [ "$STATUS" = "running" ]; then
      if pct exec $CTID -- crontab -l 2>/dev/null | grep -q "traffic-gen"; then
        TRAFFIC="${GREEN}enabled${NC}"
      else
        TRAFFIC="${YELLOW}not set${NC}"
      fi
      printf "%-8s %-24s ${GREEN}%-12s${NC} " "$CTID" "$HOSTNAME" "Running"
      RUNNING=$((RUNNING + 1))
    else
      TRAFFIC="-"
      printf "%-8s %-24s ${YELLOW}%-12s${NC} " "$CTID" "$HOSTNAME" "Stopped"
      STOPPED=$((STOPPED + 1))
    fi
    echo -e "$TRAFFIC"
  done

  echo ""
  echo -e "Total: ${GREEN}${RUNNING} running${NC}, ${YELLOW}${STOPPED} stopped${NC}"
}

# ============================================================
# MODULE: Full Setup Wizard
# ============================================================

cmd_full_wizard() {
  section_header "Full Lab Setup Wizard"
  echo "This wizard will guide you through the complete lab setup:"
  echo "  Step 1: Create Alpine LXC template"
  echo "  Step 2: Deploy containers from template"
  echo "  Step 3: Start containers"
  echo "  Step 4: Install traffic generators"
  echo ""
  read -p "Begin full setup? [y/N]: " confirm

  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted by user"
    return 0
  fi

  echo ""
  echo -e "${CYAN}===== STEP 1/4: Create Template =====${NC}"
  cmd_create_template

  echo ""
  echo -e "${CYAN}===== STEP 2/4: Deploy Containers =====${NC}"
  cmd_deploy_containers

  echo ""
  echo -e "${CYAN}===== STEP 3/4: Start Containers =====${NC}"
  cmd_start_containers

  echo ""
  echo -e "${CYAN}===== STEP 4/4: Install Traffic Generator =====${NC}"
  cmd_install_traffic_gen

  section_header "✓ Full Lab Setup Complete"
  echo "Your Proxmox lab is ready!"
  echo ""
  echo "Run with 'status' or choose option 5 to check the current state."
}

# ============================================================
# MAIN MENU
# ============================================================

main_menu() {
  while true; do
    echo ""
    echo -e "${BLUE}=========================================="
    echo "  Proxmox Lab Manager"
    echo -e "==========================================${NC}"
    echo ""
    echo "  1) Create Template"
    echo "  2) Deploy Containers"
    echo "  3) Start Containers"
    echo "  4) Install Traffic Generator"
    echo "  5) Show Status"
    echo "  6) Full Setup Wizard  (steps 1 → 2 → 3 → 4)"
    echo "  7) Exit"
    echo ""
    read -p "Select option [1-7]: " choice

    case "$choice" in
      1) ( cmd_create_template ) || echo -e "${RED}Operation failed or was aborted.${NC}" ;;
      2) ( cmd_deploy_containers ) || echo -e "${RED}Operation failed or was aborted.${NC}" ;;
      3) ( cmd_start_containers ) || echo -e "${RED}Operation failed or was aborted.${NC}" ;;
      4) ( cmd_install_traffic_gen ) || echo -e "${RED}Operation failed or was aborted.${NC}" ;;
      5) ( cmd_show_status ) || echo -e "${RED}Operation failed or was aborted.${NC}" ;;
      6) ( cmd_full_wizard ) || echo -e "${RED}Wizard failed or was aborted.${NC}" ;;
      7|q|Q)
        echo "Goodbye!"
        exit 0
        ;;
      *)
        echo -e "${RED}Invalid option. Please select 1-7.${NC}"
        ;;
    esac
  done
}

# ============================================================
# ENTRY POINT
# Support direct invocation: ./proxmox-lab.sh <command>
# ============================================================

case "${1:-}" in
  create-template)  cmd_create_template ;;
  deploy)           cmd_deploy_containers ;;
  start)            cmd_start_containers ;;
  install-traffic)  cmd_install_traffic_gen ;;
  status)           cmd_show_status ;;
  wizard)           cmd_full_wizard ;;
  "")               main_menu ;;
  *)
    echo -e "${RED}Unknown command: $1${NC}"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  create-template    Create Alpine LXC template"
    echo "  deploy             Deploy lab containers"
    echo "  start              Start containers"
    echo "  install-traffic    Install traffic generators"
    echo "  status             Show container status"
    echo "  wizard             Full setup wizard"
    echo ""
    echo "Run without arguments for the interactive menu."
    exit 1
    ;;
esac
