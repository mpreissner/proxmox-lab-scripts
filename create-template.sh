#!/bin/bash
# create-template.sh - Create Alpine LXC template (Interactive)

set -e

# Colors for better UX
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=========================================="
echo "Alpine LXC Template Creator"
echo -e "==========================================${NC}"
echo ""
echo -e "${YELLOW}Note: This script only supports local storage options${NC}"
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

# 1. Template ID (required)
echo -e "${BLUE}1. Template Configuration${NC}"
while true; do
  read -p "Template ID (e.g., 150, 9000): " TEMPLATE_ID
  if [[ "$TEMPLATE_ID" =~ ^[0-9]+$ ]]; then
    # Check if ID already exists
    if pct status $TEMPLATE_ID &>/dev/null; then
      echo -e "${RED}Error: CT ${TEMPLATE_ID} already exists${NC}"
    else
      break
    fi
  else
    echo -e "${RED}Please enter a valid numeric ID${NC}"
  fi
done

# 2. Proxmox Node (required)
echo ""
echo -e "${BLUE}2. Proxmox Node${NC}"
echo "Available nodes:"
pvesh get /nodes --output-format json | jq -r '.[].node' 2>/dev/null || echo "  (Unable to detect nodes)"
read -p "Node name: " NODE
while [ -z "$NODE" ]; do
  echo -e "${RED}Node name is required${NC}"
  read -p "Node name: " NODE
done

# 3. Storage Selection
echo ""
echo -e "${BLUE}3. Storage Configuration${NC}"
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

# 4. Alpine Version (auto-detect latest)
echo ""
echo -e "${BLUE}4. Alpine Version${NC}"
echo "Fetching available Alpine versions..."
pveam update

# Get latest Alpine version
LATEST_ALPINE=$(pveam available --section system | grep "alpine.*amd64" | tail -1 | awk '{print $2}')

if [ -z "$LATEST_ALPINE" ]; then
  echo -e "${YELLOW}Warning: Could not auto-detect Alpine version${NC}"
  read -p "Enter Alpine template name (e.g., alpine-3.19-default_20231219_amd64.tar.xz): " ALPINE_TEMPLATE
else
  echo "Latest available: ${LATEST_ALPINE}"
  read_with_default "Alpine template" "$LATEST_ALPINE" "ALPINE_TEMPLATE"
fi

# 5. Resource Allocation
echo ""
echo -e "${BLUE}5. Resource Allocation${NC}"
read_with_default "Memory (MB)" "256" "MEMORY"
read_with_default "CPU Cores" "1" "CORES"

# 6. Network Configuration
echo ""
echo -e "${BLUE}6. Network Configuration${NC}"
read_with_default "Bridge" "vmbr0" "BRIDGE"

# Confirmation Summary
echo ""
echo -e "${BLUE}=========================================="
echo "Configuration Summary"
echo -e "==========================================${NC}"
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
  exit 0
fi

echo ""
echo -e "${GREEN}Creating Alpine LXC template (CT ${TEMPLATE_ID})...${NC}"

# Download Alpine template if not present
echo "Downloading Alpine template if needed..."
pveam download local "${ALPINE_TEMPLATE}" 2>/dev/null || true

# Verify template exists
if ! pveam list local | grep -q "${ALPINE_TEMPLATE}"; then
  echo -e "${RED}Error: Template ${ALPINE_TEMPLATE} not found in local storage${NC}"
  echo "Available templates:"
  pveam list local
  exit 1
fi

# Create base container
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
echo "Next steps:"
echo "  1. Deploy containers: ./deploy-container.sh"
echo "  2. Or clone manually: pct clone ${TEMPLATE_ID} <new-id>"
