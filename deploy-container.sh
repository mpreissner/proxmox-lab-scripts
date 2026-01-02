#!/bin/bash
# deploy-containers.sh - Deploy lab containers (Interactive)

set -e

# Colors for better UX
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}=========================================="
echo "Lab Container Deployment"
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
    # Verify template exists and is actually a template
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

# 2. Storage Configuration
echo ""
echo -e "${BLUE}2. Storage Configuration${NC}"
echo "Common local storage options:"
echo "  1) local-lvm"
echo "  2) local-zfs"
echo "  3) Custom (enter name)"
read -p "Select storage [1-3] (default: 1): " storage_choice

case "${storage_choice:-1}" in
  1)
    STORAGE="local-lvm"
    ;;
  2)
    STORAGE="local-zfs"
    ;;
  3)
    read -p "Enter custom storage name: " STORAGE
    while [ -z "$STORAGE" ]; do
      echo -e "${RED}Storage name is required${NC}"
      read -p "Enter custom storage name: " STORAGE
    done
    ;;
  *)
    STORAGE="local-lvm"
    ;;
esac

# 3. Network Bridge
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
  1)
    DEPLOY_HQ=true
    DEPLOY_BRANCH=true
    ;;
  2)
    DEPLOY_HQ=true
    ;;
  3)
    DEPLOY_BRANCH=true
    ;;
  *)
    DEPLOY_HQ=true
    DEPLOY_BRANCH=true
    ;;
esac

# 5. HQ Configuration
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

# 6. Branch Configuration
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

# Container definitions with offsets
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

# Confirmation Summary
echo ""
echo -e "${BLUE}=========================================="
echo "Deployment Summary"
echo -e "==========================================${NC}"
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
  exit 0
fi

# Deploy HQ Containers
if $DEPLOY_HQ; then
  echo ""
  echo -e "${GREEN}=========================================="
  echo "Deploying HQServerNet Containers"
  echo -e "==========================================${NC}"

  for OFFSET in "${!HQ_CONTAINERS[@]}"; do
    CTID=$((HQ_START + OFFSET))
    HOSTNAME="${HQ_CONTAINERS[$OFFSET]}"

    # Check if CTID already exists
    if pct status $CTID &>/dev/null; then
      echo -e "${YELLOW}⚠ CT ${CTID} already exists, skipping ${HOSTNAME}${NC}"
      continue
    fi

    echo "Creating CT ${CTID}: ${HOSTNAME}..."

    pct clone $TEMPLATE_ID $CTID \
      --hostname $HOSTNAME \
      --full 1 \
      --storage $STORAGE

    # Update network to HQServerNet VLAN
    pct set $CTID --net0 name=eth0,bridge=${BRIDGE},tag=$VLAN_HQ,firewall=1,ip=dhcp

    # Set memory based on workload
    if [[ "$HOSTNAME" =~ (monitoring|devops) ]]; then
      pct set $CTID --memory 512
    else
      pct set $CTID --memory 256
    fi

    # Enable autostart
    pct set $CTID --onboot 1

    echo -e "${GREEN}✓ CT ${CTID} (${HOSTNAME}) created${NC}"
  done
fi

# Deploy Branch Containers
if $DEPLOY_BRANCH; then
  echo ""
  echo -e "${GREEN}=========================================="
  echo "Deploying BranchNet Containers"
  echo -e "==========================================${NC}"

  for OFFSET in "${!BRANCH_CONTAINERS[@]}"; do
    CTID=$((BRANCH_START + OFFSET))
    HOSTNAME="${BRANCH_CONTAINERS[$OFFSET]}"

    # Check if CTID already exists
    if pct status $CTID &>/dev/null; then
      echo -e "${YELLOW}⚠ CT ${CTID} already exists, skipping ${HOSTNAME}${NC}"
      continue
    fi

    echo "Creating CT ${CTID}: ${HOSTNAME}..."

    pct clone $TEMPLATE_ID $CTID \
      --hostname $HOSTNAME \
      --full 1 \
      --storage $STORAGE

    # Update network to BranchNet VLAN
    pct set $CTID --net0 name=eth0,bridge=${BRIDGE},tag=$VLAN_BRANCH,firewall=1,ip=dhcp

    # Set memory (dev gets more)
    if [[ "$HOSTNAME" == "branch-dev" ]]; then
      pct set $CTID --memory 512
    else
      pct set $CTID --memory 256
    fi

    # Enable autostart
    pct set $CTID --onboot 1

    echo -e "${GREEN}✓ CT ${CTID} (${HOSTNAME}) created${NC}"
  done
fi

# Final Summary
echo ""
echo -e "${GREEN}=========================================="
echo "✓ Deployment Complete"
echo -e "==========================================${NC}"

if $DEPLOY_HQ; then
  echo ""
  echo -e "${CYAN}HQServerNet (VLAN ${VLAN_HQ}):${NC}"
  for OFFSET in "${!HQ_CONTAINERS[@]}"; do
    CTID=$((HQ_START + OFFSET))
    echo "  CT ${CTID}: ${HQ_CONTAINERS[$OFFSET]}"
  done
fi

if $DEPLOY_BRANCH; then
  echo ""
  echo -e "${CYAN}BranchNet (VLAN ${VLAN_BRANCH}):${NC}"
  for OFFSET in "${!BRANCH_CONTAINERS[@]}"; do
    CTID=$((BRANCH_START + OFFSET))
    echo "  CT ${CTID}: ${BRANCH_CONTAINERS[$OFFSET]}"
  done
fi

echo ""
echo "Next steps:"
echo "  1. Start containers: ./start-containers.sh"
echo "  2. Install traffic generators: ./install-traffic-gen.sh"
