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
VERSION="2.6.3"

CONFIG_FILE="${HOME}/.proxmox-lab.conf"
if [ -f "$CONFIG_FILE" ]; then
  bash -n "$CONFIG_FILE" 2>/dev/null && source "$CONFIG_FILE" || \
    echo -e "${YELLOW}Warning: ~/.proxmox-lab.conf has errors, using defaults${NC}"
fi

# Backward compat: promote old single-node config to NODES list
if [ -n "${NODE:-}" ] && [ -z "${NODES:-}" ]; then
  NODES="$NODE"
fi

read_with_default() {
  local prompt="$1"
  local default="$2"
  local var_name="$3"

  if [ -n "$default" ]; then
    read -p "$(echo -e "${prompt} [${GREEN}${default}${NC}]: ")" input
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

WIZARD_MODE=false

save_config() {
  cat > "$CONFIG_FILE" <<EOF
# proxmox-lab configuration — saved $(date)
SAVED_VERSION="${VERSION}"
NODES="${NODES:-}"
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-local-lvm}"
IMAGE_STORAGE="${IMAGE_STORAGE:-local}"
VLAN_HQ="${VLAN_HQ:-}"
VLAN_BRANCH="${VLAN_BRANCH:-}"
HQ_RANGE="${HQ_RANGE:-}"
BRANCH_RANGE="${BRANCH_RANGE:-}"
TEMPLATE_ID="${TEMPLATE_ID:-}"
MEMORY="${MEMORY:-256}"
CORES="${CORES:-1}"
CRON_SERVER="${CRON_SERVER:-*/15 * * * *}"
CRON_OFFICE="${CRON_OFFICE:-*/5 8-18 * * 1-5}"
CRON_SECURITY="${CRON_SECURITY:-*/30 * * * *}"
CERT_PATH="${CERT_PATH:-}"
WIN_VMID="${WIN_VMID:-}"
WIN_TRAFFIC_PS1="${WIN_TRAFFIC_PS1:-/root/win-traffic.ps1}"
WIN_SETUP_PS1="${WIN_SETUP_PS1:-/root/setup-scheduled-tasks.ps1}"
EOF
  echo -e "${GREEN}✓ Settings saved to ~/.proxmox-lab.conf${NC}"
}

_load_config() {
  [ -f "$CONFIG_FILE" ] && bash -n "$CONFIG_FILE" 2>/dev/null && \
    source "$CONFIG_FILE" 2>/dev/null || true
}

_maybe_save_config() {
  $WIZARD_MODE && return 0
  echo ""
  read -p "Save these settings as defaults? [Y/n]: " save_choice
  if [[ ! "$save_choice" =~ ^[Nn]$ ]]; then
    save_config
  fi
}

_migrate_config() {
  [ ! -f "$CONFIG_FILE" ] && return 0
  local saved_ver="${SAVED_VERSION:-0.0.0}"
  version_gt "$VERSION" "$saved_ver" || return 0

  local changed=false

  # v2.3.0: HQ_START/BRANCH_START replaced by HQ_RANGE/BRANCH_RANGE
  if version_gt "2.3.0" "$saved_ver"; then
    if grep -qE '^(HQ_START|BRANCH_START)=' "$CONFIG_FILE" 2>/dev/null; then
      sed -i '/^HQ_START=/d; /^BRANCH_START=/d' "$CONFIG_FILE"
      if [ -z "${HQ_RANGE:-}" ] || [ -z "${BRANCH_RANGE:-}" ]; then
        echo -e "${YELLOW}  Config: removed HQ_START/BRANCH_START (replaced by HQ_RANGE/BRANCH_RANGE in v2.3.0).${NC}"
        echo -e "${YELLOW}  CTID ranges will be prompted on next deploy.${NC}"
      fi
      changed=true
    fi
  fi

  # Update SAVED_VERSION in conf
  if grep -q '^SAVED_VERSION=' "$CONFIG_FILE"; then
    sed -i "s/^SAVED_VERSION=.*/SAVED_VERSION=\"${VERSION}\"/" "$CONFIG_FILE"
  else
    echo "SAVED_VERSION=\"${VERSION}\"" >> "$CONFIG_FILE"
  fi

  if $changed; then
    echo -e "${GREEN}✓ Config migrated from v${saved_ver} to v${VERSION}${NC}"
  else
    echo -e "${CYAN}  Config: updated from v${saved_ver} to v${VERSION} (no changes required)${NC}"
  fi
  _load_config
}

pick_storage() {
  local target_node="${1:-$(get_local_node)}"

  if [ -n "${STORAGE:-}" ]; then
    echo "  Using saved storage: ${STORAGE}"
    read -p "  Change storage? [y/N]: " chg
    [[ "$chg" =~ ^[Yy]$ ]] || return 0
  fi

  echo "Available storage pools on ${target_node}:"
  pvesh get /nodes/"$target_node"/storage --output-format json 2>/dev/null | python3 -c "
import sys,json
for p in json.load(sys.stdin):
    shared = '(shared)' if p.get('shared') else '(local) '
    print(f'  {p[\"storage\"]:20s} {p[\"type\"]:12s} {shared}')
" 2>/dev/null || echo "  (unable to list storage)"

  read -p "Storage pool name [${STORAGE:-local-zfs}]: " input
  STORAGE="${input:-${STORAGE:-local-zfs}}"
  while [ -z "$STORAGE" ]; do
    read -p "Storage pool name: " STORAGE
  done
}

# Prompt for IMAGE_STORAGE — the pool where the Alpine .tar.xz template image
# will be downloaded. Must have the 'vztmpl' content type enabled.
pick_image_storage() {
  local target_node="${1:-$(get_local_node)}"

  if [ -n "${IMAGE_STORAGE:-}" ]; then
    echo "  Using saved image storage: ${IMAGE_STORAGE}"
    read -p "  Change image storage? [y/N]: " chg
    [[ "$chg" =~ ^[Yy]$ ]] || return 0
  fi

  echo "Storage pools with 'vztmpl' content type on ${target_node}:"
  pvesh get /nodes/"$target_node"/storage --output-format json 2>/dev/null | python3 -c "
import sys,json
for p in json.load(sys.stdin):
    if 'vztmpl' in (p.get('content') or ''):
        shared = '(shared)' if p.get('shared') else '(local) '
        print(f'  {p[\"storage\"]:20s} {p[\"type\"]:12s} {shared}')
" 2>/dev/null || echo "  (unable to list storage)"

  read -p "Image storage pool [${IMAGE_STORAGE:-local}]: " input
  IMAGE_STORAGE="${input:-${IMAGE_STORAGE:-local}}"
  while [ -z "$IMAGE_STORAGE" ]; do
    read -p "Image storage pool: " IMAGE_STORAGE
  done
}

version_gt() {
  # Returns 0 (true) if $1 > $2 using version sort
  test "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$1"
}

get_local_node() {
  cat /etc/pve/.nodename 2>/dev/null || hostname
}

get_cluster_nodes() {
  pvesh get /nodes --output-format json 2>/dev/null | \
    python3 -c "import sys,json; [print(n['node']) for n in json.load(sys.stdin)]" 2>/dev/null
}

get_node_resources() {
  local node="$1"
  pvesh get /nodes/"$node"/status --output-format json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
m = d.get('memory', {})
total = m.get('total', 0) // 1024 // 1024
used  = m.get('used',  0) // 1024 // 1024
free  = m.get('free',  0) // 1024 // 1024
cpus  = d.get('cpuinfo', {}).get('cpus', 0)
cpup  = round(d.get('cpu', 0) * 100, 1)
print(f'{total} {used} {free} {cpus} {cpup}')
"
  pvesh get /nodes/"$node"/lxc --output-format json 2>/dev/null | \
    python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0
}

ctid_to_node() {
  local ctid="$1"
  local local_node nodes node raw
  local_node=$(get_local_node)
  nodes=$(get_cluster_nodes 2>/dev/null)
  [ -z "$nodes" ] && nodes="$local_node"
  for node in $nodes; do
    raw=$(pvesh get /nodes/"$node"/lxc --output-format json 2>/dev/null) || continue
    if echo "$raw" | python3 -c "
import sys,json
for r in json.load(sys.stdin):
    if str(r.get('vmid','')) == '${ctid}':
        raise SystemExit(0)
raise SystemExit(1)
" 2>/dev/null; then
      echo "$node"
      return
    fi
  done
  echo "$local_node"
}

node_to_ip() {
  local node="$1"
  # Try /etc/hosts first
  local ip
  ip=$(getent hosts "$node" 2>/dev/null | awk '{print $1; exit}')
  [ -n "$ip" ] && echo "$ip" && return
  # Parse corosync.conf for the ring0_addr matching this node name
  ip=$(python3 -c "
import re, sys
try:
    txt = open('/etc/pve/corosync.conf').read()
    for block in re.findall(r'node\s*\{[^}]+\}', txt, re.DOTALL):
        nm = re.search(r'name:\s*(\S+)', block)
        addr = re.search(r'ring0_addr:\s*(\S+)', block)
        if nm and addr and nm.group(1) == '$node':
            print(addr.group(1))
            break
except: pass
" 2>/dev/null)
  [ -n "$ip" ] && echo "$ip" && return
  # Fall back to node name as-is
  echo "$node"
}

run_on_node() {
  local node="$1"; shift
  local local_node
  local_node=$(get_local_node)
  if [ "$node" = "$local_node" ]; then
    "$@"
  else
    local ip cmd
    ip=$(node_to_ip "$node")
    cmd=$(printf '%q ' "$@")
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@"$ip" "$cmd"
  fi
}

# Populate global _CT_NODE, _CT_STATUS, _CT_HOSTNAME, _CT_TAGS indexed by CTID.
# Queries each cluster node individually via pvesh /nodes/{node}/lxc and
# /nodes/{node}/qemu — Proxmox uses a unified CTID/VMID namespace, so both
# LXC containers and QEMU VMs are added to _CT_NODE to prevent ID collisions.
_load_ct_data() {
  declare -gA _CT_NODE=() _CT_STATUS=() _CT_HOSTNAME=() _CT_TAGS=()
  local local_node nodes all_parsed=""
  local_node=$(get_local_node)

  # Get all cluster nodes; fall back to local node on standalone installs
  nodes=$(get_cluster_nodes 2>/dev/null)
  [ -z "$nodes" ] && nodes="$local_node"

  for node in $nodes; do
    local raw node_parsed

    # LXC containers — full metadata
    raw=$(pvesh get /nodes/"$node"/lxc --output-format json 2>/dev/null) || raw="[]"
    node_parsed=$(echo "$raw" | python3 -c "
import sys,json
node='$node'
try:
    for r in json.load(sys.stdin):
        print('{}\t{}\t{}\t{}\t{}'.format(
            r.get('vmid',''), node, r.get('status',''),
            r.get('name',''), r.get('tags') or ''))
except: pass
" 2>/dev/null)
    [ -n "$node_parsed" ] && all_parsed="${all_parsed}${all_parsed:+$'\n'}${node_parsed}"

    # QEMU VMs — IDs only (no tags/hostname needed; just occupy the ID space)
    raw=$(pvesh get /nodes/"$node"/qemu --output-format json 2>/dev/null) || raw="[]"
    node_parsed=$(echo "$raw" | python3 -c "
import sys,json
node='$node'
try:
    for r in json.load(sys.stdin):
        vmid=r.get('vmid','')
        if vmid: print('{}\t{}\t{}\t{}\t'.format(vmid, node, r.get('status',''), r.get('name','')))
except: pass
" 2>/dev/null)
    [ -n "$node_parsed" ] && all_parsed="${all_parsed}${all_parsed:+$'\n'}${node_parsed}"
  done

  while IFS=$'\t' read -r ctid node status name tags; do
    [ -z "$ctid" ] && continue
    _CT_NODE[$ctid]="${node:-$local_node}"
    _CT_STATUS[$ctid]="$status"
    _CT_HOSTNAME[$ctid]="$name"
    _CT_TAGS[$ctid]="$tags"
  done <<< "$all_parsed"
}

# Find the next CTID >= start that is not already in use on the cluster
# (_CT_NODE must be populated via _load_ct_data) and not in the
# space-separated claimed list (for within-session deduplication).
_next_free_ctid() {
  local start="$1"
  local claimed="${2:-}"
  local candidate=$start
  while true; do
    if [ -n "${_CT_NODE[$candidate]+x}" ]; then
      candidate=$((candidate + 1))
      continue
    fi
    if [[ " $claimed " == *" $candidate "* ]]; then
      candidate=$((candidate + 1))
      continue
    fi
    echo "$candidate"
    return
  done
}

# Find the next free CTID within [range_start, range_end].
# Returns 1 (prints nothing) if the range is exhausted.
_next_free_ctid_in_range() {
  local range_start="$1" range_end="$2" claimed="${3:-}"
  local candidate=$range_start
  while [ $candidate -le $range_end ]; do
    if [ -z "${_CT_NODE[$candidate]+x}" ] && [[ " $claimed " != *" $candidate "* ]]; then
      echo "$candidate"
      return 0
    fi
    candidate=$((candidate + 1))
  done
  return 1
}

# Prompt for a CTID range (format: START-END) with format and capacity validation.
# Args: <display_label> <min_containers> <var_name>
read_ctid_range() {
  local label="$1" min_count="$2" var_name="$3"
  local current="${!var_name}"
  while true; do
    if [ -n "$current" ]; then
      read -p "  ${label} [${current}]: " input
      input="${input:-$current}"
    else
      read -p "  ${label} (e.g., 100-110): " input
    fi
    if [[ "$input" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      local rstart="${BASH_REMATCH[1]}" rend="${BASH_REMATCH[2]}"
      if [ "$rstart" -ge "$rend" ]; then
        echo -e "${RED}  Start must be less than end.${NC}"
        continue
      fi
      local capacity=$(( rend - rstart + 1 ))
      if [ "$capacity" -lt "$min_count" ]; then
        echo -e "${RED}  Range ${input} holds ${capacity} CTIDs; need at least ${min_count}.${NC}"
        continue
      fi
      printf -v "$var_name" '%s' "$input"
      break
    else
      echo -e "${RED}  Invalid format. Use START-END (e.g., 100-110).${NC}"
    fi
  done
}

# Find which cluster node holds a given CTID (container or template).
# Prints the node name to stdout; prints nothing if not found.
_find_template_node() {
  local ctid="$1"
  local nodes node
  nodes=$(get_cluster_nodes 2>/dev/null)
  [ -z "$nodes" ] && nodes=$(get_local_node)
  for node in $nodes; do
    if pvesh get /nodes/"$node"/lxc --output-format json 2>/dev/null | \
        python3 -c "
import sys,json
for r in json.load(sys.stdin):
    if str(r.get('vmid','')) == '${ctid}':
        raise SystemExit(0)
raise SystemExit(1)
" 2>/dev/null; then
      echo "$node"
      return
    fi
  done
}

_find_vm_node() {
  local vmid="$1"
  local nodes node
  nodes=$(get_cluster_nodes 2>/dev/null)
  [ -z "$nodes" ] && nodes=$(get_local_node)
  for node in $nodes; do
    if pvesh get /nodes/"$node"/qemu --output-format json 2>/dev/null | \
        python3 -c "
import sys,json
for r in json.load(sys.stdin):
    if str(r.get('vmid','')) == '${vmid}':
        raise SystemExit(0)
raise SystemExit(1)
" 2>/dev/null; then
      echo "$node"
      return
    fi
  done
}

# ============================================================
# MODULE: Create Template
# ============================================================

cmd_create_template() {
  _load_config
  section_header "Alpine LXC Template Creator"
  echo ""

  # 1. Template ID
  echo -e "${BLUE}1. Template Configuration${NC}"
  while true; do
    read -p "Template ID (e.g., 150, 9000): " TEMPLATE_ID
    if [[ "$TEMPLATE_ID" =~ ^[0-9]+$ ]]; then
      _exists_on=$(_find_template_node "$TEMPLATE_ID")
      if [ -n "$_exists_on" ]; then
        echo -e "${RED}Error: CT ${TEMPLATE_ID} already exists (on ${_exists_on})${NC}"
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
  pvesh get /nodes --output-format json 2>/dev/null | \
    python3 -c "import sys,json; [print('  ' + n['node']) for n in json.load(sys.stdin)]" \
    2>/dev/null || echo "  (Unable to detect nodes)"
  [ -n "${NODE:-}" ] && echo "  Last used: ${NODE}"
  read -p "Node name [${NODE:-}]: " input
  NODE="${input:-${NODE:-}}"
  while [ -z "$NODE" ]; do
    echo -e "${RED}Node name is required${NC}"
    read -p "Node name: " NODE
  done

  # 3. Storage
  echo ""
  echo -e "${BLUE}3. Storage Configuration${NC}"
  pick_storage "$NODE"

  # Recommend shared storage if local was chosen in a multi-node cluster
  _tmpl_is_shared=$(pvesh get /storage/"$STORAGE" --output-format json 2>/dev/null | \
    python3 -c "
import sys,json
try: print('1' if json.load(sys.stdin).get('shared') else '0')
except: print('0')
" 2>/dev/null || echo "0")
  if [ "$_tmpl_is_shared" = "0" ]; then
    _cluster_size=$(pvesh get /nodes --output-format json 2>/dev/null | \
      python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "1")
    _shared_pools=$(pvesh get /nodes/"$NODE"/storage --output-format json 2>/dev/null | \
      python3 -c "
import sys,json
pools=[p['storage'] for p in json.load(sys.stdin) if p.get('shared')]
print(' '.join(pools))
" 2>/dev/null || echo "")
    if [ "$_cluster_size" -gt 1 ] && [ -n "$_shared_pools" ]; then
      echo ""
      echo -e "${YELLOW}  Tip: You selected local storage in a multi-node cluster.${NC}"
      echo -e "${YELLOW}  Placing the template on shared storage enables linked clones${NC}"
      echo -e "${YELLOW}  across all nodes for faster deployment.${NC}"
      echo "  Available shared pools: ${_shared_pools}"
      echo ""
      read -p "  Switch to shared storage? [y/N]: " _switch
      if [[ "$_switch" =~ ^[Yy]$ ]]; then
        pick_storage "$NODE"
      fi
    fi
  fi

  # 3b. Image Storage (where the Alpine .tar.xz will be downloaded)
  echo ""
  echo -e "${BLUE}3b. Image Storage${NC}"
  echo "Storage pool for downloading the Alpine template image (must support 'vztmpl')."
  pick_image_storage "$NODE"

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
  read_with_default "Memory (MB)" "${MEMORY:-256}" "MEMORY"
  read_with_default "CPU Cores" "${CORES:-1}" "CORES"

  # 6. Network
  echo ""
  echo -e "${BLUE}6. Network Configuration${NC}"
  read_with_default "Bridge" "${BRIDGE:-vmbr0}" "BRIDGE"

  # 7. TLS Inspection Certificate (optional)
  echo ""
  echo -e "${BLUE}7. TLS Inspection Certificate (optional)${NC}"
  echo "If your network uses TLS inspection (e.g., Zscaler), provide the path"
  echo "to the root CA certificate on this host. It will be installed into the"
  echo "template so all cloned containers trust it automatically."
  echo "Press Enter to skip."
  read -p "Certificate path [${CERT_PATH:-}]: " input
  CERT_PATH="${input:-${CERT_PATH:-}}"
  if [ -n "${CERT_PATH:-}" ] && [ ! -f "$CERT_PATH" ]; then
    echo -e "${YELLOW}Warning: File not found at '${CERT_PATH}' — certificate will not be installed${NC}"
    CERT_PATH=""
  fi

  # Summary
  section_header "Configuration Summary"
  echo "Template ID:    ${TEMPLATE_ID}"
  echo "Node:           ${NODE}"
  echo "CT Disk Storage: ${STORAGE}"
  echo "Image Storage:   ${IMAGE_STORAGE:-local}"
  echo "Alpine:         ${ALPINE_TEMPLATE}"
  echo "Memory:         ${MEMORY} MB"
  echo "CPU Cores:      ${CORES}"
  echo "Bridge:         ${BRIDGE}"
  if [ -n "${CERT_PATH:-}" ]; then
    echo "Certificate:    ${CERT_PATH}"
  else
    echo "Certificate:    (none)"
  fi
  echo ""
  read -p "Proceed with creation? [y/N]: " confirm

  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted by user"
    return 0
  fi

  echo ""
  echo -e "${GREEN}Creating Alpine LXC template (CT ${TEMPLATE_ID}) on ${NODE}...${NC}"

  echo "Downloading Alpine template to ${NODE} if needed..."
  run_on_node "$NODE" pveam update 2>/dev/null || true
  run_on_node "$NODE" pveam download "${IMAGE_STORAGE}" "${ALPINE_TEMPLATE}" 2>/dev/null || true

  if ! run_on_node "$NODE" pveam list "${IMAGE_STORAGE}" | grep -q "${ALPINE_TEMPLATE}"; then
    echo -e "${RED}Error: Template ${ALPINE_TEMPLATE} not found in ${IMAGE_STORAGE} on ${NODE}${NC}"
    echo "Available templates:"
    run_on_node "$NODE" pveam list "${IMAGE_STORAGE}"
    return 1
  fi

  echo "Creating base container on ${NODE}..."
  run_on_node "$NODE" pct create $TEMPLATE_ID ${IMAGE_STORAGE}:vztmpl/${ALPINE_TEMPLATE} \
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
  run_on_node "$NODE" pct start $TEMPLATE_ID
  sleep 10

  echo "Installing base packages..."
  run_on_node "$NODE" pct exec $TEMPLATE_ID -- sh -c "
    apk update
    apk add curl wget bind-tools bash jq python3 py3-pip dcron nano vim openrc ca-certificates

    # Enable cron
    rc-update add dcron default

    # Create traffic-gen directory structure
    mkdir -p /opt/traffic-gen/profiles /opt/traffic-gen/domains /opt/traffic-gen/utils

    echo 'Template configuration complete'
  "

  if [ -n "${CERT_PATH:-}" ] && [ -f "$CERT_PATH" ]; then
    echo "Installing TLS inspection certificate..."
    CERT_FILENAME=$(basename "$CERT_PATH")
    # Stream the cert file into the container via pct exec stdin — avoids needing
    # pct push (which requires the file to already be on the target node).
    run_on_node "$NODE" sh -c "cat | pct exec $TEMPLATE_ID -- sh -c 'cat > /tmp/${CERT_FILENAME}'" \
      < "$CERT_PATH"
    run_on_node "$NODE" pct exec $TEMPLATE_ID -- sh -c "
      mkdir -p /usr/local/share/ca-certificates
      cp /tmp/${CERT_FILENAME} /usr/local/share/ca-certificates/${CERT_FILENAME}
      update-ca-certificates 2>/dev/null || \
        cat /usr/local/share/ca-certificates/${CERT_FILENAME} >> /etc/ssl/certs/ca-certificates.crt
      rm /tmp/${CERT_FILENAME}
    "
    echo -e "${GREEN}✓ Certificate installed in template${NC}"
  fi

  echo "Stopping and converting to template..."
  run_on_node "$NODE" pct stop $TEMPLATE_ID
  run_on_node "$NODE" pct template $TEMPLATE_ID

  echo ""
  echo -e "${GREEN}=========================================="
  echo "✓ Template CT ${TEMPLATE_ID} created successfully"
  echo -e "==========================================${NC}"
  echo ""
  echo "Next step: Deploy containers (option 2 from main menu)"
  _maybe_save_config
}

# ============================================================
# MODULE: Deploy Containers
# ============================================================

cmd_deploy_containers() {
  _load_config
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

  [ -n "${TEMPLATE_ID:-}" ] && echo "  Last used: ${TEMPLATE_ID}"
  while true; do
    read -p "Template ID to clone from [${TEMPLATE_ID:-}]: " input
    TEMPLATE_ID="${input:-${TEMPLATE_ID:-}}"
    if [[ "$TEMPLATE_ID" =~ ^[0-9]+$ ]]; then
      _tmpl_node=$(_find_template_node "$TEMPLATE_ID")
      if [ -z "$_tmpl_node" ]; then
        echo -e "${RED}Error: CT ${TEMPLATE_ID} does not exist on any cluster node${NC}"
      elif ! run_on_node "$_tmpl_node" pct config $TEMPLATE_ID 2>/dev/null | grep -q "template: 1"; then
        echo -e "${RED}Error: CT ${TEMPLATE_ID} on ${_tmpl_node} is not a template${NC}"
      else
        echo "  Found template CT ${TEMPLATE_ID} on ${_tmpl_node}"
        break
      fi
    else
      echo -e "${RED}Please enter a valid numeric ID${NC}"
    fi
  done

  # 2. Cluster Nodes
  echo ""
  echo -e "${BLUE}2. Cluster Nodes${NC}"
  echo "Fetching node info..."
  echo ""

  declare -a ALL_NODES=()
  while IFS= read -r n; do
    [ -n "$n" ] && ALL_NODES+=("$n")
  done < <(get_cluster_nodes)

  if [ ${#ALL_NODES[@]} -eq 0 ]; then
    ALL_NODES=("$(get_local_node)")
    echo -e "${YELLOW}Could not detect cluster nodes; using local node: ${ALL_NODES[0]}${NC}"
  fi

  # Build resource table
  declare -A NODE_TOTAL=()
  declare -A NODE_USED=()
  declare -A NODE_FREE=()
  declare -A NODE_CPUS=()
  declare -A NODE_CPU_PCT=()
  declare -A NODE_CT_COUNT=()

  printf "  %-10s %-12s %-12s %-12s %-8s %-8s %-6s\n" \
    "Node" "RAM Total" "RAM Used" "RAM Free" "CPUs" "CPU%" "CTs"
  echo "  ----------------------------------------------------------------------"

  for node in "${ALL_NODES[@]}"; do
    local_res=$(get_node_resources "$node")
    stats=$(echo "$local_res" | head -1)
    ct_count=$(echo "$local_res" | tail -1)
    read -r total used free cpus cpupct <<< "$stats"
    NODE_TOTAL[$node]="${total:-0}"
    NODE_USED[$node]="${used:-0}"
    NODE_FREE[$node]="${free:-0}"
    NODE_CPUS[$node]="${cpus:-0}"
    NODE_CPU_PCT[$node]="${cpupct:-0}"
    NODE_CT_COUNT[$node]="${ct_count:-0}"
    total_gb=$(( ${total:-0} / 1024 ))
    used_gb=$(( ${used:-0} / 1024 ))
    free_gb=$(( ${free:-0} / 1024 ))
    printf "  %-10s %-12s %-12s %-12s %-8s %-8s %-6s\n" \
      "$node" "${total_gb} GB" "${used_gb} GB" "${free_gb} GB" \
      "${cpus:-?}" "${cpupct:-?}%" "${ct_count:-?}"
  done
  echo ""

  declare -a SELECTED_NODES=()

  if [ ${#ALL_NODES[@]} -eq 1 ]; then
    SELECTED_NODES=("${ALL_NODES[@]}")
    echo "  Single node detected: ${SELECTED_NODES[0]}"
  else
    echo "  1) All nodes (${#ALL_NODES[@]})"
    echo "  2) Select specific nodes"
    read -p "  Select [1-2] (default: 1): " node_sel_choice

    case "${node_sel_choice:-1}" in
      2)
        echo "  Available nodes: ${ALL_NODES[*]}"
        echo "  Saved nodes: ${NODES:-}"
        read -p "  Enter node names (space or comma-separated) [${NODES:-}]: " node_input
        node_input="${node_input:-${NODES:-}}"
        node_input=$(echo "$node_input" | tr ',' ' ')
        for n in $node_input; do
          n=$(echo "$n" | xargs)
          [ -n "$n" ] && SELECTED_NODES+=("$n")
        done
        if [ ${#SELECTED_NODES[@]} -eq 0 ]; then
          SELECTED_NODES=("${ALL_NODES[@]}")
        fi
        ;;
      *)
        SELECTED_NODES=("${ALL_NODES[@]}")
        ;;
    esac
  fi

  NODES="${SELECTED_NODES[*]}"
  echo "  Deploying to: ${SELECTED_NODES[*]}"

  # 3. Storage
  echo ""
  echo -e "${BLUE}3. Storage Configuration${NC}"
  pick_storage "${SELECTED_NODES[0]:-$(get_local_node)}"

  # 4. Network
  echo ""
  echo -e "${BLUE}4. Network Configuration${NC}"
  read_with_default "Bridge" "${BRIDGE:-vmbr0}" "BRIDGE"

  # 5. Deployment Scope
  echo ""
  echo -e "${BLUE}5. Deployment Scope${NC}"
  echo "What would you like to deploy?"
  echo "  1) Both Data Center and Branch containers (11 total)"
  echo "  2) Data Center only (6 containers)"
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

  # 6. Distribution Mode (only when multiple nodes selected)
  DIST_MODE="auto"
  declare -A MANUAL_NODE_HQ=()
  declare -A MANUAL_NODE_BRANCH=()

  if [ ${#SELECTED_NODES[@]} -gt 1 ]; then
    echo ""
    echo -e "${BLUE}6. Distribution${NC}"
    echo "  1) Auto-balanced by free RAM (recommended)"
    echo "  2) Manual — assign each group to a specific node"
    read -p "  Select [1-2] (default: 1): " dist_choice

    case "${dist_choice:-1}" in
      2)
        DIST_MODE="manual"
        if $DEPLOY_HQ; then
          read -p "  Data Center containers → node: " hq_node
          hq_node="${hq_node:-${SELECTED_NODES[0]}}"
          for i in 0 1 2 3 4 5; do
            MANUAL_NODE_HQ[$i]="$hq_node"
          done
        fi
        if $DEPLOY_BRANCH; then
          read -p "  Branch containers → node: " br_node
          br_node="${br_node:-${SELECTED_NODES[0]}}"
          for i in 0 1 2 3 4; do
            MANUAL_NODE_BRANCH[$i]="$br_node"
          done
        fi
        ;;
      *)
        DIST_MODE="auto"
        ;;
    esac
  fi

  # 7. HQ Config
  if $DEPLOY_HQ; then
    echo ""
    echo -e "${BLUE}7. Data Center Configuration${NC}"
    read_ctid_range "Data Center CTID range" 6 "HQ_RANGE"
    read_with_default "Data Center VLAN tag" "${VLAN_HQ:-}" "VLAN_HQ"

    echo -e "${CYAN}Data Center containers (assigned within ${HQ_RANGE}, skipping any in use):${NC}"
    echo "  hq-fileserver (256 MB)"
    echo "  hq-webapp (256 MB)"
    echo "  hq-email (256 MB)"
    echo "  hq-monitoring (512 MB)"
    echo "  hq-devops (512 MB)"
    echo "  hq-database (256 MB)"
  fi

  # 8. Branch Config
  if $DEPLOY_BRANCH; then
    echo ""
    echo -e "${BLUE}8. Branch UserNet Configuration${NC}"
    read_ctid_range "Branch CTID range" 5 "BRANCH_RANGE"
    read_with_default "Branch VLAN tag" "${VLAN_BRANCH:-}" "VLAN_BRANCH"

    echo -e "${CYAN}Branch containers (assigned within ${BRANCH_RANGE}, skipping any in use):${NC}"
    echo "  branch-worker1 (256 MB)"
    echo "  branch-worker2 (256 MB)"
    echo "  branch-sales (256 MB)"
    echo "  branch-dev (512 MB)"
    echo "  branch-exec (256 MB)"
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

  # Scan existing cluster CTs so we can assign only free CTIDs.
  echo "Scanning for existing containers..."
  _load_ct_data

  # Parse configured ranges
  IFS='-' read -r _hq_start _hq_end <<< "${HQ_RANGE:-}"
  IFS='-' read -r _br_start _br_end <<< "${BRANCH_RANGE:-}"

  # Build full container list with CTID, hostname, profile, VLAN, memory.
  # CTIDs are assigned in order within the configured range, skipping any
  # already in use. Errors out if the range cannot fit the full stack.
  # Format: CTID hostname vlan mem group offset
  declare -a DEPLOY_LIST=()
  _claimed_ctids=""
  if $DEPLOY_HQ; then
    for OFFSET in 0 1 2 3 4 5; do
      CTID=$(_next_free_ctid_in_range "$_hq_start" "$_hq_end" "$_claimed_ctids") || {
        echo -e "${RED}Error: Range ${HQ_RANGE} has no room for all 6 Data Center containers.${NC}"
        return 1
      }
      _claimed_ctids="$_claimed_ctids $CTID"
      HOSTNAME="${HQ_CONTAINERS[$OFFSET]}"
      if [[ "$HOSTNAME" =~ (monitoring|devops) ]]; then MEM=512; else MEM=256; fi
      DEPLOY_LIST+=("${CTID} ${HOSTNAME} ${VLAN_HQ} ${MEM} hq ${OFFSET}")
    done
  fi
  if $DEPLOY_BRANCH; then
    for OFFSET in 0 1 2 3 4; do
      CTID=$(_next_free_ctid_in_range "$_br_start" "$_br_end" "$_claimed_ctids") || {
        echo -e "${RED}Error: Range ${BRANCH_RANGE} has no room for all 5 Branch containers.${NC}"
        return 1
      }
      _claimed_ctids="$_claimed_ctids $CTID"
      HOSTNAME="${BRANCH_CONTAINERS[$OFFSET]}"
      if [[ "$HOSTNAME" == "branch-dev" ]]; then MEM=512; else MEM=256; fi
      DEPLOY_LIST+=("${CTID} ${HOSTNAME} ${VLAN_BRANCH} ${MEM} branch ${OFFSET}")
    done
  fi

  # Assign each container to a node
  declare -A CTID_NODES=()

  if [ ${#SELECTED_NODES[@]} -eq 1 ]; then
    for entry in "${DEPLOY_LIST[@]}"; do
      read -r ctid _ _ _ _ _ <<< "$entry"
      CTID_NODES[$ctid]="${SELECTED_NODES[0]}"
    done
  elif [ "$DIST_MODE" = "manual" ]; then
    for entry in "${DEPLOY_LIST[@]}"; do
      read -r ctid hostname vlan mem group offset <<< "$entry"
      if [ "$group" = "hq" ]; then
        CTID_NODES[$ctid]="${MANUAL_NODE_HQ[$offset]:-${SELECTED_NODES[0]}}"
      else
        CTID_NODES[$ctid]="${MANUAL_NODE_BRANCH[$offset]:-${SELECTED_NODES[0]}}"
      fi
    done
  else
    # Auto-balance: sort by memory descending, assign to node with most free RAM
    declare -A avail_ram=()
    for node in "${SELECTED_NODES[@]}"; do
      avail_ram[$node]="${NODE_FREE[$node]:-0}"
    done

    # Sort DEPLOY_LIST by memory descending (512 first)
    declare -a sorted_deploy=()
    # Get 512MB containers first, then 256MB
    for entry in "${DEPLOY_LIST[@]}"; do
      read -r _ _ _ mem _ _ <<< "$entry"
      [ "$mem" -eq 512 ] && sorted_deploy+=("$entry")
    done
    for entry in "${DEPLOY_LIST[@]}"; do
      read -r _ _ _ mem _ _ <<< "$entry"
      [ "$mem" -eq 256 ] && sorted_deploy+=("$entry")
    done

    for entry in "${sorted_deploy[@]}"; do
      read -r ctid _ _ mem _ _ <<< "$entry"
      # Pick node with most available RAM
      best_node="${SELECTED_NODES[0]}"
      best_ram="${avail_ram[${SELECTED_NODES[0]}]:-0}"
      for node in "${SELECTED_NODES[@]}"; do
        if [ "${avail_ram[$node]:-0}" -gt "$best_ram" ]; then
          best_ram="${avail_ram[$node]}"
          best_node="$node"
        fi
      done
      CTID_NODES[$ctid]="$best_node"
      avail_ram[$best_node]=$(( ${avail_ram[$best_node]:-0} - mem ))
    done
  fi

  # Resource Feasibility Check
  echo ""
  echo -e "${BLUE}Resource Feasibility Check:${NC}"
  printf "  %-10s %-12s %-14s %-12s %-10s\n" "Node" "Assigned" "After Use" "Headroom" "Status"
  echo "  ---------------------------------------------------------------"

  ABORT_DEPLOY=false
  declare -A NODE_ASSIGNED_MEM=()
  for node in "${SELECTED_NODES[@]}"; do
    NODE_ASSIGNED_MEM[$node]=0
  done
  for entry in "${DEPLOY_LIST[@]}"; do
    read -r ctid _ _ mem _ _ <<< "$entry"
    target="${CTID_NODES[$ctid]}"
    NODE_ASSIGNED_MEM[$target]=$(( ${NODE_ASSIGNED_MEM[$target]:-0} + mem ))
  done

  for node in "${SELECTED_NODES[@]}"; do
    total_mb="${NODE_TOTAL[$node]:-0}"
    used_mb="${NODE_USED[$node]:-0}"
    assigned_mb="${NODE_ASSIGNED_MEM[$node]:-0}"
    if [ "$total_mb" -gt 0 ]; then
      after_mb=$(( used_mb + assigned_mb ))
      headroom_mb=$(( total_mb - after_mb ))
      after_pct=$(( after_mb * 100 / total_mb ))
    else
      after_mb=0; headroom_mb=0; after_pct=0
    fi
    if [ "$after_pct" -ge 95 ]; then
      status="${RED}✗ OVER 95%${NC}"
      ABORT_DEPLOY=true
    elif [ "$after_pct" -ge 80 ]; then
      status="${YELLOW}⚠ WARN (${after_pct}%)${NC}"
    else
      status="${GREEN}✓ OK (${after_pct}%)${NC}"
    fi
    printf "  %-10s %-12s %-14s %-12s " \
      "$node" "${assigned_mb} MB" "${after_mb} MB" "${headroom_mb} MB"
    echo -e "$status"
  done

  if $ABORT_DEPLOY; then
    echo ""
    echo -e "${RED}Error: One or more nodes would exceed 95% RAM utilization. Aborting.${NC}"
    echo "Reduce deployment scope or select additional nodes."
    return 1
  fi

  # Assignment Preview
  echo ""
  echo -e "${BLUE}Container Assignment:${NC}"
  printf "  %-8s %-20s %-14s %-10s %-6s\n" "CTID" "Hostname" "Profile" "Node" "RAM"
  echo "  ---------------------------------------------------------------"
  for entry in "${DEPLOY_LIST[@]}"; do
    read -r ctid hostname vlan mem group offset <<< "$entry"
    target="${CTID_NODES[$ctid]}"
    if [ "$group" = "hq" ]; then
      profiles=("fileserver" "webapp" "email" "monitoring" "devops" "database")
      profile="${profiles[$offset]}"
    else
      profiles=("office-worker" "office-worker" "sales" "developer" "executive")
      profile="${profiles[$offset]}"
    fi
    printf "  %-8s %-20s %-14s %-10s %-6s\n" \
      "$ctid" "$hostname" "$profile" "$target" "${mem} MB"
  done

  # Summary
  section_header "Deployment Summary"
  echo "Source Template: CT ${TEMPLATE_ID}"
  echo "Storage:         ${STORAGE}"
  echo "Bridge:          ${BRIDGE}"
  echo "Nodes:           ${SELECTED_NODES[*]}"

  if $DEPLOY_HQ; then
    _hq_ctids=""
    for entry in "${DEPLOY_LIST[@]}"; do
      read -r ctid _ _ _ grp _ <<< "$entry"
      [ "$grp" = "hq" ] && _hq_ctids="$_hq_ctids $ctid"
    done
    echo ""
    echo -e "${CYAN}Data Center:${NC}"
    echo "  VLAN Tag:    ${VLAN_HQ}"
    echo "  Range:       ${HQ_RANGE}"
    echo "  CTIDs:       ${_hq_ctids# }"
    echo "  Containers:  6"
  fi

  if $DEPLOY_BRANCH; then
    _br_ctids=""
    for entry in "${DEPLOY_LIST[@]}"; do
      read -r ctid _ _ _ grp _ <<< "$entry"
      [ "$grp" = "branch" ] && _br_ctids="$_br_ctids $ctid"
    done
    echo ""
    echo -e "${CYAN}Branch UserNet:${NC}"
    echo "  VLAN Tag:    ${VLAN_BRANCH}"
    echo "  Range:       ${BRANCH_RANGE}"
    echo "  CTIDs:       ${_br_ctids# }"
    echo "  Containers:  5"
  fi

  echo ""
  read -p "Proceed with deployment? [y/N]: " confirm

  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted by user"
    return 0
  fi

  # Locate the template in the cluster and determine the clone strategy.
  LOCAL_NODE=$(get_local_node)
  TMPL_NODE=$(_find_template_node "$TEMPLATE_ID")
  [ -z "$TMPL_NODE" ] && TMPL_NODE="$LOCAL_NODE"
  TMPL_POOL=$(run_on_node "$TMPL_NODE" pct config "$TEMPLATE_ID" 2>/dev/null | \
    grep '^rootfs:' | sed 's/rootfs: *//' | cut -d: -f1)
  TMPL_SHARED=$(pvesh get /storage/"$TMPL_POOL" --output-format json 2>/dev/null | \
    python3 -c "
import sys,json
try: print('1' if json.load(sys.stdin).get('shared') else '0')
except: print('0')
" 2>/dev/null || echo "0")

  # If using shared storage, verify it's accessible on all target nodes before deploying
  if [ "$TMPL_SHARED" = "1" ]; then
    echo "Verifying shared storage '${TMPL_POOL}' on all target nodes..."
    _storage_ok=true
    _checked_nodes=""
    for entry in "${DEPLOY_LIST[@]}"; do
      read -r _vctid _ _ _ _ _ <<< "$entry"
      _vnode="${CTID_NODES[$_vctid]}"
      [[ " $_checked_nodes " == *" $_vnode "* ]] && continue
      _checked_nodes="$_checked_nodes $_vnode"
      if pvesh get /nodes/"$_vnode"/storage --output-format json 2>/dev/null | \
         python3 -c "
import sys,json
pools=[p['storage'] for p in json.load(sys.stdin)]
exit(0 if '${TMPL_POOL}' in pools else 1)
" 2>/dev/null; then
        echo -e "  ${GREEN}✓ ${_vnode}: ${TMPL_POOL} available${NC}"
      else
        echo -e "  ${RED}✗ ${_vnode}: ${TMPL_POOL} not found${NC}"
        _storage_ok=false
      fi
    done
    if ! $_storage_ok; then
      echo ""
      echo -e "${RED}Error: Shared storage '${TMPL_POOL}' is not available on all target nodes.${NC}"
      echo "Ensure the storage is mounted and active on each node before deploying."
      return 1
    fi
    echo ""
  fi

  # Deploy containers
  echo ""
  echo -e "${GREEN}=========================================="
  echo "Deploying Containers"
  echo -e "==========================================${NC}"
  if [ "$TMPL_SHARED" = "1" ]; then
    echo "(Template CT ${TEMPLATE_ID} on ${TMPL_NODE} — shared storage, cloning on each target node)"
  else
    echo "(Template CT ${TEMPLATE_ID} on ${TMPL_NODE} — local storage, will clone-and-migrate for remote targets)"
  fi
  echo ""

  for entry in "${DEPLOY_LIST[@]}"; do
    read -r CTID HOSTNAME VLAN MEM group offset <<< "$entry"
    TARGET_NODE="${CTID_NODES[$CTID]}"

    echo "Creating CT ${CTID}: ${HOSTNAME} → ${TARGET_NODE}..."

    # Determine where to run pct clone:
    #   Shared storage → clone on the target (it can reach the template directly)
    #   Local storage, same node as template → clone on that node, no migration
    #   Local storage, different node → clone on template's node, then migrate
    if [ "$TMPL_SHARED" = "1" ]; then
      CLONE_NODE="$TARGET_NODE"
    else
      CLONE_NODE="$TMPL_NODE"
    fi

    run_on_node "$CLONE_NODE" pct clone $TEMPLATE_ID $CTID \
      --hostname $HOSTNAME \
      --full 1 \
      --storage $STORAGE
    run_on_node "$CLONE_NODE" pct set $CTID \
      --net0 name=eth0,bridge=${BRIDGE},tag=${VLAN},firewall=1,ip=dhcp
    run_on_node "$CLONE_NODE" pct set $CTID --memory $MEM --onboot 1 --tags lab-managed

    if [ "$TMPL_SHARED" != "1" ] && [ "$CLONE_NODE" != "$TARGET_NODE" ]; then
      echo "  Migrating CT ${CTID} from ${CLONE_NODE} to ${TARGET_NODE}..."
      run_on_node "$CLONE_NODE" pct migrate $CTID $TARGET_NODE --target-storage $STORAGE
    fi

    echo -e "${GREEN}✓ CT ${CTID} (${HOSTNAME}) created on ${TARGET_NODE}${NC}"
  done

  # Final Summary
  section_header "✓ Deployment Complete"

  if $DEPLOY_HQ; then
    echo -e "${CYAN}Data Center (VLAN ${VLAN_HQ}):${NC}"
    for entry in "${DEPLOY_LIST[@]}"; do
      read -r ctid hostname _ _ grp _ <<< "$entry"
      [ "$grp" = "hq" ] && echo "  CT ${ctid}: ${hostname} → ${CTID_NODES[$ctid]}"
    done
  fi

  if $DEPLOY_BRANCH; then
    echo ""
    echo -e "${CYAN}Branch UserNet (VLAN ${VLAN_BRANCH}):${NC}"
    for entry in "${DEPLOY_LIST[@]}"; do
      read -r ctid hostname _ _ grp _ <<< "$entry"
      [ "$grp" = "branch" ] && echo "  CT ${ctid}: ${hostname} → ${CTID_NODES[$ctid]}"
    done
  fi

  echo ""
  echo "Next steps: Start containers (option 3), then install traffic gen (option 4)"
  _maybe_save_config
}

# ============================================================
# MODULE: Start Containers
# ============================================================

cmd_start_containers() {
  _load_config
  section_header "Container Startup Manager"

  echo -e "${BLUE}1. Current Container Status${NC}"
  echo "Scanning for containers (cluster-wide)..."
  echo ""

  _load_ct_data

  if [ ${#_CT_NODE[@]} -eq 0 ]; then
    echo -e "${RED}No containers found${NC}"
    return 1
  fi

  printf "%-8s %-20s %-12s %-10s\n" "CTID" "Hostname" "Status" "Node"
  echo "------------------------------------------------"

  declare -a STOPPED_CONTAINERS=()
  declare -a RUNNING_CONTAINERS=()

  for CTID in $(echo "${!_CT_NODE[@]}" | tr ' ' '\n' | sort -n); do
    tags="${_CT_TAGS[$CTID]:-}"
    name="${_CT_HOSTNAME[$CTID]:-}"
    # Filter to lab-managed containers
    if [[ "$tags" != *"lab-managed"* ]]; then
      continue
    fi
    STATUS="${_CT_STATUS[$CTID]:-stopped}"
    HOSTNAME="${_CT_HOSTNAME[$CTID]:-unknown}"
    NODE_OF_CT="${_CT_NODE[$CTID]:-}"

    if [ "$STATUS" = "running" ]; then
      printf "%-8s %-20s ${GREEN}%-12s${NC} %-10s\n" "$CTID" "$HOSTNAME" "Running" "$NODE_OF_CT"
      RUNNING_CONTAINERS+=($CTID)
    else
      printf "%-8s %-20s ${YELLOW}%-12s${NC} %-10s\n" "$CTID" "$HOSTNAME" "Stopped" "$NODE_OF_CT"
      STOPPED_CONTAINERS+=($CTID)
    fi
  done

  echo ""
  echo -e "Summary: ${GREEN}${#RUNNING_CONTAINERS[@]} running${NC}, ${YELLOW}${#STOPPED_CONTAINERS[@]} stopped${NC}"

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
  echo "  2) Data Center containers only"
  echo "  3) Branch containers only"
  echo "  4) Specific containers (enter CTIDs)"
  echo "  5) Range of containers (e.g., 200-205)"
  read -p "Select option [1-5] (default: 1): " selection_choice

  declare -a TARGET_CONTAINERS=()

  _cluster_ct_status() {
    local id="$1"
    if [ -n "${_CT_STATUS[$id]:-}" ]; then
      echo "${_CT_STATUS[$id]}"
    else
      echo "not-exist"
    fi
  }

  case "${selection_choice:-1}" in
    1)
      TARGET_CONTAINERS=("${STOPPED_CONTAINERS[@]}")
      ;;

    2)
      if [ -z "${HQ_RANGE:-}" ]; then
        read_ctid_range "Data Center CTID range" 6 "HQ_RANGE"
      else
        echo "  Using Data Center range: ${HQ_RANGE}"
      fi
      IFS='-' read -r _hq_start _hq_end <<< "$HQ_RANGE"
      echo "Checking Data Center containers (${HQ_RANGE})..."
      for ctid in $(seq $_hq_start $_hq_end); do
        status=$(_cluster_ct_status $ctid)
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
      if [ -z "${BRANCH_RANGE:-}" ]; then
        read_ctid_range "Branch CTID range" 5 "BRANCH_RANGE"
      else
        echo "  Using Branch range: ${BRANCH_RANGE}"
      fi
      IFS='-' read -r _br_start _br_end <<< "$BRANCH_RANGE"
      echo "Checking Branch containers (${BRANCH_RANGE})..."
      for ctid in $(seq $_br_start $_br_end); do
        status=$(_cluster_ct_status $ctid)
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
        status=$(_cluster_ct_status $ctid)
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
          status=$(_cluster_ct_status $ctid)
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
    HOSTNAME="${_CT_HOSTNAME[$CTID]:-unknown}"
    CT_NODE="${_CT_NODE[$CTID]:-$(get_local_node)}"
    echo "  CT ${CTID}: ${HOSTNAME} (${CT_NODE})"
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
      HOSTNAME="${_CT_HOSTNAME[$CTID]:-unknown}"
      CT_NODE="${_CT_NODE[$CTID]:-$(get_local_node)}"
      echo -n "Starting CT ${CTID} (${HOSTNAME}) on ${CT_NODE}... "
      if run_on_node "$CT_NODE" pct start $CTID 2>/dev/null; then
        echo -e "${GREEN}✓${NC}"
      else
        echo -e "${RED}✗ Failed${NC}"
      fi
      sleep 1
    done
  else
    declare -a PIDS=()
    for CTID in "${TARGET_CONTAINERS[@]}"; do
      HOSTNAME="${_CT_HOSTNAME[$CTID]:-unknown}"
      CT_NODE="${_CT_NODE[$CTID]:-$(get_local_node)}"
      echo "Starting CT ${CTID} (${HOSTNAME}) on ${CT_NODE}..."
      run_on_node "$CT_NODE" pct start $CTID 2>/dev/null &
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
  printf "%-8s %-20s %-12s %-10s\n" "CTID" "Hostname" "Status" "Node"
  echo "------------------------------------------------"

  SUCCESS_COUNT=0
  FAILED_COUNT=0

  for CTID in "${TARGET_CONTAINERS[@]}"; do
    CT_NODE="${_CT_NODE[$CTID]:-$(get_local_node)}"
    HOSTNAME="${_CT_HOSTNAME[$CTID]:-unknown}"
    if run_on_node "$CT_NODE" pct status "$CTID" 2>/dev/null | grep -q "running"; then
      printf "%-8s %-20s ${GREEN}%-12s${NC} %-10s\n" "$CTID" "$HOSTNAME" "Running" "$CT_NODE"
      ((++SUCCESS_COUNT))
    else
      printf "%-8s %-20s ${RED}%-12s${NC} %-10s\n" "$CTID" "$HOSTNAME" "Failed" "$CT_NODE"
      ((++FAILED_COUNT))
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
# MODULE: Stop Containers
# ============================================================

cmd_stop_containers() {
  _load_config
  section_header "Stop Containers"

  # 1. Current Container Status
  echo -e "${BLUE}1. Current Container Status${NC}"
  echo "Scanning for containers (cluster-wide)..."
  echo ""

  _load_ct_data

  if [ ${#_CT_NODE[@]} -eq 0 ]; then
    echo -e "${RED}No containers found${NC}"
    return 1
  fi

  printf "%-8s %-20s %-12s %-10s\n" "CTID" "Hostname" "Status" "Node"
  echo "------------------------------------------------"

  declare -a ALL_RUNNING=()

  for CTID in $(echo "${!_CT_NODE[@]}" | tr ' ' '\n' | sort -n); do
    tags="${_CT_TAGS[$CTID]:-}"
    name="${_CT_HOSTNAME[$CTID]:-}"
    if [[ "$tags" != *"lab-managed"* ]]; then
      continue
    fi
    STATUS="${_CT_STATUS[$CTID]:-stopped}"
    HOSTNAME="${_CT_HOSTNAME[$CTID]:-unknown}"
    NODE_OF_CT="${_CT_NODE[$CTID]:-}"

    if [ "$STATUS" = "running" ]; then
      printf "%-8s %-20s ${GREEN}%-12s${NC} %-10s\n" "$CTID" "$HOSTNAME" "Running" "$NODE_OF_CT"
      ALL_RUNNING+=($CTID)
    else
      printf "%-8s %-20s ${YELLOW}%-12s${NC} %-10s\n" "$CTID" "$HOSTNAME" "Stopped" "$NODE_OF_CT"
    fi
  done

  echo ""
  echo -e "Summary: ${GREEN}${#ALL_RUNNING[@]} running${NC}"

  if [ ${#ALL_RUNNING[@]} -eq 0 ]; then
    echo ""
    echo -e "${GREEN}No running containers found.${NC}"
    return 0
  fi

  # 2. Container Selection
  echo ""
  echo -e "${BLUE}2. Container Selection${NC}"
  echo "What would you like to stop?"
  echo "  1) All running containers (${#ALL_RUNNING[@]} total)"
  echo "  2) Data Center containers only"
  echo "  3) Branch containers only"
  echo "  4) Specific containers (enter CTIDs)"
  echo "  5) Range of containers (e.g., 200-205)"
  read -p "Select option [1-5] (default: 1): " selection_choice

  declare -a TARGET_CONTAINERS=()

  _cluster_ct_running() {
    local id="$1"
    [ "${_CT_STATUS[$id]:-}" = "running" ] && echo "running" || echo "not-running"
  }

  case "${selection_choice:-1}" in
    1)
      TARGET_CONTAINERS=("${ALL_RUNNING[@]}")
      ;;

    2)
      if [ -z "${HQ_RANGE:-}" ]; then
        read_ctid_range "Data Center CTID range" 6 "HQ_RANGE"
      else
        echo "  Using Data Center range: ${HQ_RANGE}"
      fi
      IFS='-' read -r _hq_start _hq_end <<< "$HQ_RANGE"
      echo "Checking Data Center containers (${HQ_RANGE})..."
      for ctid in $(seq $_hq_start $_hq_end); do
        status=$(_cluster_ct_running $ctid)
        if [ "$status" = "running" ]; then
          TARGET_CONTAINERS+=($ctid)
          echo "  CT ${ctid}: Will stop"
        else
          echo -e "  ${YELLOW}CT ${ctid}: Not running (skipped)${NC}"
        fi
      done
      ;;

    3)
      if [ -z "${BRANCH_RANGE:-}" ]; then
        read_ctid_range "Branch CTID range" 5 "BRANCH_RANGE"
      else
        echo "  Using Branch range: ${BRANCH_RANGE}"
      fi
      IFS='-' read -r _br_start _br_end <<< "$BRANCH_RANGE"
      echo "Checking Branch containers (${BRANCH_RANGE})..."
      for ctid in $(seq $_br_start $_br_end); do
        status=$(_cluster_ct_running $ctid)
        if [ "$status" = "running" ]; then
          TARGET_CONTAINERS+=($ctid)
          echo "  CT ${ctid}: Will stop"
        else
          echo -e "  ${YELLOW}CT ${ctid}: Not running (skipped)${NC}"
        fi
      done
      ;;

    4)
      echo "Enter container IDs to stop (space or comma-separated)"
      echo "Example: 200 201 220 or 200,201,220"
      read -p "CTIDs: " ctid_input
      ctid_input=$(echo "$ctid_input" | tr ',' ' ')
      for ctid in $ctid_input; do
        ctid=$(echo $ctid | xargs)
        status=$(_cluster_ct_running $ctid)
        if [ "$status" = "running" ]; then
          TARGET_CONTAINERS+=($ctid)
        else
          echo -e "${YELLOW}CT ${ctid}: Not running (skipped)${NC}"
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
          status=$(_cluster_ct_running $ctid)
          if [ "$status" = "running" ]; then
            TARGET_CONTAINERS+=($ctid)
            echo "  CT ${ctid}: Will stop"
          else
            echo -e "  ${YELLOW}CT ${ctid}: Not running (skipped)${NC}"
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
    echo -e "${YELLOW}No containers selected or none are running${NC}"
    return 0
  fi

  echo ""
  echo "${#TARGET_CONTAINERS[@]} container(s) will be stopped."
  echo ""
  read -p "Proceed? [y/N]: " confirm

  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    return 0
  fi

  echo ""
  echo -e "${GREEN}Stopping containers...${NC}"
  echo ""
  declare -a PIDS=()
  for CTID in "${TARGET_CONTAINERS[@]}"; do
    HOSTNAME="${_CT_HOSTNAME[$CTID]:-unknown}"
    CT_NODE="${_CT_NODE[$CTID]:-$(get_local_node)}"
    echo "Stopping CT ${CTID} (${HOSTNAME}) on ${CT_NODE}..."
    run_on_node "$CT_NODE" pct stop $CTID 2>/dev/null &
    PIDS+=($!)
  done

  for pid in "${PIDS[@]}"; do
    wait $pid 2>/dev/null || true
  done

  section_header "Stop Complete"
  SUCCESS=0
  FAILED=0
  for CTID in "${TARGET_CONTAINERS[@]}"; do
    HOSTNAME="${_CT_HOSTNAME[$CTID]:-unknown}"
    CT_NODE="${_CT_NODE[$CTID]:-$(get_local_node)}"
    if ! run_on_node "$CT_NODE" pct status "$CTID" 2>/dev/null | grep -q "running"; then
      echo -e "${GREEN}✓ CT ${CTID} (${HOSTNAME}) stopped${NC}"
      ((++SUCCESS))
    else
      echo -e "${RED}✗ CT ${CTID} (${HOSTNAME}) failed${NC}"
      ((++FAILED))
    fi
  done

  echo ""
  echo -e "${GREEN}Successfully stopped: ${SUCCESS}${NC}"
  if [ $FAILED -gt 0 ]; then
    echo -e "${RED}Failed: ${FAILED}${NC}"
  fi
}

# ============================================================
# MODULE: Install Traffic Generator
# ============================================================

declare -A PROFILE_DESC=(
  ["fileserver"]="Cloud sync (OneDrive, Dropbox, S3)"
  ["webapp"]="Payment APIs (Stripe), CDN services, certificate validation"
  ["email"]="Office 365, Google Workspace, spam filters, AV updates"
  ["monitoring"]="Ubuntu repos, Datadog, New Relic, Docker Hub, GitHub"
  ["devops"]="npm, PyPI, GitHub, Docker Hub, GenAI tools"
  ["database"]="AWS RDS, Azure SQL, S3 backups"
  ["office-worker"]="Office 365, Salesforce, Slack, Google Docs, news sites"
  ["sales"]="Salesforce, LinkedIn, travel booking, Zoom, HubSpot, GenAI tools"
  ["developer"]="GitHub, StackOverflow, npm, PyPI, AWS Console, GenAI tools"
  ["executive"]="Office 365, WSJ, Bloomberg, Zoom, GenAI tools"
)

# DEFAULT_PROFILES is built dynamically from HQ_RANGE/BRANCH_RANGE after
# _load_ct_data runs. Lab-managed containers within each range are sorted by
# CTID and mapped positionally to the profile order, so the profile is always
# the source of truth regardless of which specific CTIDs were assigned.
declare -A DEFAULT_PROFILES=()
_build_default_profiles() {
  local hq_profiles=(fileserver webapp email monitoring devops database)
  # Branch: minimum two office-worker workloads, followed by remaining profiles
  local br_ow_min=2
  local br_other_profiles=(sales developer executive)
  local idx ctid profile

  if [ -n "${HQ_RANGE:-}" ]; then
    IFS='-' read -r _hq_s _hq_e <<< "$HQ_RANGE"
    idx=0
    for ctid in $(seq $_hq_s $_hq_e); do
      [ $idx -ge ${#hq_profiles[@]} ] && break
      if [ -n "${_CT_NODE[$ctid]+x}" ] && [[ "${_CT_TAGS[$ctid]:-}" == *"lab-managed"* ]]; then
        DEFAULT_PROFILES[$ctid]="${hq_profiles[$idx]}"
        ((++idx))
      fi
    done
  fi

  if [ -n "${BRANCH_RANGE:-}" ]; then
    IFS='-' read -r _br_s _br_e <<< "$BRANCH_RANGE"
    local total_branch=$(( br_ow_min + ${#br_other_profiles[@]} ))
    idx=0
    for ctid in $(seq $_br_s $_br_e); do
      [ $idx -ge $total_branch ] && break
      if [ -n "${_CT_NODE[$ctid]+x}" ] && [[ "${_CT_TAGS[$ctid]:-}" == *"lab-managed"* ]]; then
        if [ $idx -lt $br_ow_min ]; then
          profile="office-worker"
        else
          profile="${br_other_profiles[$((idx - br_ow_min))]}"
        fi
        DEFAULT_PROFILES[$ctid]="$profile"
        ((++idx))
      fi
    done
  fi
}

_default_security_tests_for_profile() {
  local profile="$1"
  case "$profile" in
    fileserver)    echo "dlp-network" ;;
    devops)        echo "eicar dlp-genai-prompt dlp-genai-file dlp-genai-image" ;;
    developer)     echo "eicar dlp-genai-prompt dlp-genai-file" ;;
    office-worker) echo "policy-violation dlp-genai-prompt" ;;
    sales)         echo "policy-violation dlp-genai-prompt dlp-genai-file" ;;
    executive)     echo "ueba dlp-genai-prompt" ;;
    *)             echo "" ;;
  esac
}

_install_security_test() {
  local ctid=$1
  local test_name=$2

  run_on_node "$CT_NODE" pct exec $ctid -- mkdir -p /opt/traffic-gen/security-tests

  case "$test_name" in
    eicar)
      run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/security-tests/eicar.sh' <<'EOF'
#!/bin/bash
echo "[$(date)] Security test: EICAR download"
curl -s -m 15 https://malware.wicar.org/data/eicar.com > /dev/null 2>&1 || true
if [ $((RANDOM % 2)) -eq 0 ]; then
  curl -s -m 15 https://www.eicar.org/download/eicar.com > /dev/null 2>&1 || true
fi
EOF
      ;;

    dlp-network)
      run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/security-tests/dlp-network.sh' <<'EOF'
#!/bin/bash
FAKE_SSN="$((RANDOM % 900 + 100))-$((RANDOM % 90 + 10))-$((RANDOM % 9000 + 1000))"
FAKE_CCN="4111$((RANDOM % 9000 + 1000))$((RANDOM % 9000 + 1000))$((RANDOM % 9000 + 1000))"
echo "[$(date)] DLP test: Network data exfiltration attempt (SSN/CCN)"
curl -s -m 15 -X POST \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "ssn=${FAKE_SSN}&card=${FAKE_CCN}&name=John+Smith" \
  https://httpbin.org/post > /dev/null 2>&1 || true
EOF
      ;;

    dlp-genai-prompt)
      run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/security-tests/dlp-genai-prompt.sh' <<'EOF'
#!/bin/bash
FAKE_SSN="$((RANDOM % 900 + 100))-$((RANDOM % 90 + 10))-$((RANDOM % 9000 + 1000))"
FAKE_CCN="4111$((RANDOM % 9000 + 1000))$((RANDOM % 9000 + 1000))$((RANDOM % 9000 + 1000))"
PLATFORMS=("openai" "anthropic" "google")
PLATFORM="${PLATFORMS[$((RANDOM % 3))]}"
case "$PLATFORM" in
  openai)
    URL="https://api.openai.com/v1/chat/completions"
    PAYLOAD="{\"model\":\"gpt-4o\",\"messages\":[{\"role\":\"user\",\"content\":\"I need help verifying my identity. My SSN is ${FAKE_SSN} and my credit card is ${FAKE_CCN}. Please confirm my account access.\"}]}"
    ;;
  anthropic)
    URL="https://api.anthropic.com/v1/messages"
    PAYLOAD="{\"model\":\"claude-3-5-sonnet-20241022\",\"max_tokens\":100,\"messages\":[{\"role\":\"user\",\"content\":\"I need help verifying my identity. My SSN is ${FAKE_SSN} and my credit card is ${FAKE_CCN}. Please confirm my account access.\"}]}"
    ;;
  google)
    URL="https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-pro:generateContent"
    PAYLOAD="{\"contents\":[{\"parts\":[{\"text\":\"I need help verifying my identity. My SSN is ${FAKE_SSN} and my credit card is ${FAKE_CCN}. Please confirm my account access.\"}]}]}"
    ;;
esac
echo "[$(date)] DLP test: Submitting prompt with PII to GenAI API (${PLATFORM})"
curl -s -m 15 -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer dlp-test" \
  -d "$PAYLOAD" "$URL" > /dev/null 2>&1 || true
EOF
      ;;

    dlp-genai-file)
      run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/security-tests/dlp-genai-file.sh' <<'EOF'
#!/bin/bash
FAKE_SSN="$((RANDOM % 900 + 100))-$((RANDOM % 90 + 10))-$((RANDOM % 9000 + 1000))"
FAKE_CCN="4111$((RANDOM % 9000 + 1000))$((RANDOM % 9000 + 1000))$((RANDOM % 9000 + 1000))"
FAKE_ACCT="$((RANDOM % 900000000 + 100000000))"
TMPFILE=$(mktemp /tmp/dlp-doc.XXXXXX)
cat > "$TMPFILE" <<PIIEOF
CONFIDENTIAL - Employee Financial Record
========================================
Name: John Smith
Employee ID: EMP-$((RANDOM % 9000 + 1000))
Department: Finance
Social Security Number: ${FAKE_SSN}
Credit Card Number: ${FAKE_CCN}
Bank Account: ${FAKE_ACCT}
Routing Number: 021000021
Classification: RESTRICTED
PIIEOF
echo "[$(date)] DLP test: Uploading document with PII to GenAI file API"
curl -s -m 20 -X POST \
  -H "Authorization: Bearer dlp-test" \
  -F "purpose=assistants" \
  -F "file=@${TMPFILE}" \
  https://api.openai.com/v1/files > /dev/null 2>&1 || true
rm -f "$TMPFILE"
EOF
      ;;

    dlp-genai-image)
      run_on_node "$CT_NODE" pct exec $ctid -- apk add --quiet imagemagick 2>/dev/null || true
      run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/security-tests/dlp-genai-image.sh' <<'EOF'
#!/bin/bash
# Requires imagemagick (installed by proxmox-lab.sh)
FAKE_SSN="$((RANDOM % 900 + 100))-$((RANDOM % 90 + 10))-$((RANDOM % 9000 + 1000))"
FAKE_CCN="4111$((RANDOM % 9000 + 1000))$((RANDOM % 9000 + 1000))$((RANDOM % 9000 + 1000))"
TMPIMG="/tmp/dlp-img.$$.png"
TMPJSON="/tmp/dlp-req.$$.json"
convert -size 500x180 xc:white \
  -font DejaVu-Sans -pointsize 14 -fill black \
  -draw "text 20,30 'CONFIDENTIAL - Employee Record'" \
  -draw "text 20,60 'Name: John Smith'" \
  -draw "text 20,85 'SSN: ${FAKE_SSN}'" \
  -draw "text 20,110 'Credit Card: ${FAKE_CCN}'" \
  -draw "text 20,135 'Classification: RESTRICTED'" \
  "$TMPIMG" 2>/dev/null
if [ ! -s "$TMPIMG" ]; then
  echo "[$(date)] GenAI OCR DLP: imagemagick unavailable, skipping"
  rm -f "$TMPIMG" "$TMPJSON"
  exit 0
fi
IMGDATA=$(base64 -w 0 "$TMPIMG" 2>/dev/null || base64 "$TMPIMG" 2>/dev/null)
cat > "$TMPJSON" <<JSONEOF
{"model":"gpt-4o","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,${IMGDATA}"}},{"type":"text","text":"Can you read and summarize this document?"}]}]}
JSONEOF
echo "[$(date)] DLP test: Uploading image with PII to GenAI vision API (OCR)"
curl -s -m 30 -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer dlp-test" \
  -d @"$TMPJSON" \
  https://api.openai.com/v1/chat/completions > /dev/null 2>&1 || true
rm -f "$TMPIMG" "$TMPJSON"
EOF
      ;;

    policy-violation)
      run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/security-tests/policy-violation.sh' <<'EOF'
#!/bin/bash
TARGETS=(
  "https://www.dropbox.com"
  "https://wetransfer.com"
  "https://www.box.com"
  "https://mega.nz"
)
UA_POOL=(
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36"
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36 Edg/119.0.0.0"
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36"
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:120.0) Gecko/20100101 Firefox/120.0"
)
UA="${UA_POOL[$((RANDOM % ${#UA_POOL[@]}))]}"
TARGET="${TARGETS[$((RANDOM % ${#TARGETS[@]}))]}"
echo "[$(date)] Policy test: Attempting access to blocked site (${TARGET})"
curl -s -A "$UA" -m 10 "$TARGET" > /dev/null 2>&1 || true
EOF
      ;;

    ueba)
      run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/security-tests/ueba.sh' <<'EOF'
#!/bin/bash
source /opt/traffic-gen/utils/business-hours.sh 2>/dev/null || true
source /opt/traffic-gen/utils/random-timing.sh 2>/dev/null || true
# UEBA: only fire after business hours — that is the anomaly
if is_business_hours; then
  exit 0
fi
echo "[$(date)] UEBA test: After-hours access simulation"
UA_POOL=(
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15"
  "Mozilla/5.0 (iPhone; CPU iPhone OS 17_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Mobile/15E148 Safari/604.1"
  "Mozilla/5.0 (iPad; CPU OS 17_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Mobile/15E148 Safari/604.1"
)
UA="${UA_POOL[$((RANDOM % ${#UA_POOL[@]}))]}"
curl -s -A "$UA" -m 10 https://outlook.office365.com > /dev/null 2>&1
sleep $(random_delay 5 15)
curl -s -A "$UA" -m 10 https://teams.microsoft.com > /dev/null 2>&1
if [ $((RANDOM % 2)) -eq 0 ]; then
  curl -s -A "$UA" -m 10 https://sharepoint.com > /dev/null 2>&1
fi
if [ $((RANDOM % 3)) -eq 0 ]; then
  curl -s -A "$UA" -m 10 https://portal.azure.com > /dev/null 2>&1
fi
EOF
      ;;
  esac

  run_on_node "$CT_NODE" pct exec $ctid -- chmod +x /opt/traffic-gen/security-tests/${test_name}.sh
}

_add_security_test_cron() {
  local ctid=$1
  local cron_schedule=$2
  run_on_node "$CT_NODE" pct exec $ctid -- bash -c "
    existing=\$(crontab -l 2>/dev/null | grep -v 'run-security-tests' || true)
    printf '%s\n%s\n' \"\$existing\" '${cron_schedule} /opt/traffic-gen/run-security-tests.sh' | crontab -
  "
}

_install_framework() {
  local ctid=$1

  run_on_node "$CT_NODE" pct exec $ctid -- mkdir -p /opt/traffic-gen/security-tests

  run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/run-security-tests.sh' <<'EOF'
#!/bin/bash
# Security test dispatcher — runs all enabled security tests
TESTS_DIR="/opt/traffic-gen/security-tests"
[ -d "$TESTS_DIR" ] || exit 0
for test_script in "$TESTS_DIR"/*.sh; do
  [ -f "$test_script" ] && bash "$test_script" 2>&1 | logger -t "security-test" || true
done
EOF

  run_on_node "$CT_NODE" pct exec $ctid -- chmod +x /opt/traffic-gen/run-security-tests.sh

  run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/utils/genai.sh' <<'EOF'
#!/bin/bash
# GenAI traffic utilities — realistic enterprise AI usage simulation

GENAI_PROMPTS=(
  "Summarize the key points of our Q3 financial performance for the board"
  "Draft a professional email declining a vendor proposal politely"
  "What are best practices for implementing zero-trust network architecture"
  "Help me prepare talking points for a client presentation on data security"
  "What are the main enterprise AI adoption trends this year"
  "Write a brief project status update for executive stakeholders"
  "Explain the ROI calculation methodology for cloud migration projects"
  "Suggest agenda items for a quarterly business review meeting"
  "What are the key compliance requirements for handling PII data"
  "Summarize best practices for generative AI governance in enterprises"
  "Draft a job description for a senior cloud security architect"
  "What security controls should I implement for a hybrid cloud deployment"
)

genai_random_prompt() {
  echo "${GENAI_PROMPTS[$((RANDOM % ${#GENAI_PROMPTS[@]}))]}"
}

genai_browse() {
  # Browse public GenAI platform pages (no CoPilot — websockets not supported)
  local platforms=(
    "https://chat.openai.com"
    "https://claude.ai"
    "https://gemini.google.com"
    "https://huggingface.co/chat"
    "https://www.perplexity.ai"
    "https://poe.com"
  )
  local platform="${platforms[$((RANDOM % ${#platforms[@]}))]}"
  local ua=$(random_user_agent)
  echo "[$(date)] GenAI: Browsing ${platform}"
  curl -s -A "$ua" -m 10 -L "$platform" > /dev/null 2>&1 || true
}

genai_api_call() {
  local prompt="${1:-What are best practices for enterprise security}"
  # HuggingFace anonymous inference API — free tier, no auth required for basic models
  # Zscaler inspects the outbound prompt regardless of rate-limit response
  echo "[$(date)] GenAI: API call — ${prompt:0:60}..."
  curl -s -m 15 \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"inputs\": \"${prompt}\"}" \
    https://api-inference.huggingface.co/models/distilgpt2 > /dev/null 2>&1 || true
}
EOF

  run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/traffic-gen.sh' <<'EOF'
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

  run_on_node "$CT_NODE" pct exec $ctid -- chmod +x /opt/traffic-gen/traffic-gen.sh

  run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/utils/business-hours.sh' <<'EOF'
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

  run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/utils/random-timing.sh' <<'EOF'
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
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36 Edg/119.0.0.0"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Safari/537.36 Edg/118.0.2088.76"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:120.0) Gecko/20100101 Firefox/120.0"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:120.0) Gecko/20100101 Firefox/120.0"
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36"
  )
  echo "${agents[$((RANDOM % ${#agents[@]}))]}"
}

browse_random() {
  local domain_file="$1"
  local count=${2:-1}

  if [ ! -f "$domain_file" ]; then
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
      run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/profiles/fileserver.sh' <<'EOF'
#!/bin/bash
source /opt/traffic-gen/utils/random-timing.sh

HOUR=$(date +%H)

# Simulate file backup to cloud
backup_to_cloud() {
  echo "[$(date)] File server: Cloud backup sync"

  # OneDrive sync
  curl -s -A "Microsoft OneDrive Sync 21.220.1024.0005 (Windows NT 10.0; Win64; x64)" https://onedrive.live.com > /dev/null 2>&1

  # Dropbox sync
  curl -s -A "Dropbox/164.4.3551 (Windows; 10; Pro)" https://www.dropbox.com > /dev/null 2>&1

  # (DLP tests handled by security-tests/dlp-network.sh if enabled)
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
curl -s -A "aws-cli/2.13.25 Python/3.11.5 Windows/10 exe/AMD64" https://s3.amazonaws.com > /dev/null 2>&1
EOF
      ;;

    webapp)
      run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/profiles/webapp.sh' <<'EOF'
#!/bin/bash
source /opt/traffic-gen/utils/random-timing.sh

echo "[$(date)] Web app: External API calls"

# Payment processor
curl -s -A "Stripe-Node/12.18.0 (https://github.com/stripe/stripe-node)" https://api.stripe.com > /dev/null 2>&1
sleep $(random_delay 5 15)

# CDN assets
curl -s -A "Mozilla/5.0 (compatible; WebServer/1.0; +http://example.com)" https://cdn.jsdelivr.net > /dev/null 2>&1
curl -s -A "Mozilla/5.0 (compatible; WebServer/1.0; +http://example.com)" https://cdnjs.cloudflare.com > /dev/null 2>&1

# Certificate validation
curl -s -A "OpenSSL/1.1.1" http://ocsp.digicert.com > /dev/null 2>&1

# Database backup to S3
if [ $((RANDOM % 20)) -eq 0 ]; then
  echo "[$(date)] Web app: S3 backup"
  curl -s -A "aws-cli/2.13.25 Python/3.11.5 Linux/x86_64" https://s3.amazonaws.com > /dev/null 2>&1
fi
EOF
      ;;

    email)
      run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/profiles/email.sh' <<'EOF'
#!/bin/bash
source /opt/traffic-gen/utils/random-timing.sh

echo "[$(date)] Email server: Mail relay operations"

# Office 365 SMTP relay
curl -s -A "Microsoft Exchange Server 2019" https://outlook.office365.com > /dev/null 2>&1
sleep $(random_delay 10 30)

# Google Workspace
curl -s -A "Postfix/3.7.2" https://mail.google.com > /dev/null 2>&1

# Spam filter updates
curl -s -A "SpamAssassin/3.4.6" https://www.spamhaus.org > /dev/null 2>&1

# Anti-virus definitions
curl -s -A "ClamAV/1.0.3" https://www.clamav.net > /dev/null 2>&1
EOF
      ;;

    monitoring)
      run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/profiles/monitoring.sh' <<'EOF'
#!/bin/bash
source /opt/traffic-gen/utils/random-timing.sh

echo "[$(date)] Monitoring: System checks"

# Ubuntu/Debian repos
curl -s -A "Debian APT-HTTP/1.3 (2.6.1) non-interactive" http://archive.ubuntu.com/ubuntu > /dev/null 2>&1
curl -s -A "Debian APT-HTTP/1.3 (2.6.1) non-interactive" http://security.ubuntu.com/ubuntu > /dev/null 2>&1

# Monitoring services
curl -s -A "Datadog Agent/7.47.0" https://api.datadoghq.com > /dev/null 2>&1
curl -s -A "NewRelic-PythonAgent/8.10.0 (Python 3.11.5; Linux)" https://api.newrelic.com > /dev/null 2>&1

# Container registry
curl -s -A "docker/24.0.5 go/go1.20.6 git-commit/ced0996 kernel/5.15.0 os/linux arch/amd64" https://registry.hub.docker.com > /dev/null 2>&1

# GitHub API
curl -s -A "GitHubActions/1.0" https://api.github.com > /dev/null 2>&1
EOF
      ;;

    devops)
      run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/profiles/devops.sh' <<'EOF'
#!/bin/bash
source /opt/traffic-gen/utils/random-timing.sh
source /opt/traffic-gen/utils/genai.sh 2>/dev/null || true

echo "[$(date)] DevOps: Build pipeline activity"

# npm packages
curl -s -A "npm/10.2.0 node/v20.9.0 linux x64 workspaces/false" https://registry.npmjs.org > /dev/null 2>&1
sleep $(random_delay 5 15)

# PyPI
curl -s -A "pip/23.3.1 {\"ci\":null,\"cpu\":\"x86_64\",\"distro\":{\"name\":\"Ubuntu\",\"version\":\"22.04\"}}" https://pypi.org > /dev/null 2>&1

# GitHub
curl -s -A "git/2.40.1" https://github.com > /dev/null 2>&1
curl -s -A "GitHub-Actions/1.0" https://api.github.com > /dev/null 2>&1

# Docker Hub
curl -s -A "docker/24.0.5 go/go1.20.6 git-commit/ced0996 kernel/5.15.0 os/linux arch/amd64" https://hub.docker.com > /dev/null 2>&1

# GenAI — devops uses AI for automation scripts and documentation
if [ $((RANDOM % 3)) -eq 0 ]; then
  genai_browse
fi
if [ $((RANDOM % 2)) -eq 0 ]; then
  genai_api_call "$(genai_random_prompt)"
fi
# (AV/EICAR tests handled by security-tests/eicar.sh if enabled)
EOF
      ;;

    database)
      run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/profiles/database.sh' <<'EOF'
#!/bin/bash
source /opt/traffic-gen/utils/random-timing.sh

echo "[$(date)] Database: Backup and replication"

# Cloud database services
curl -s -A "aws-sdk-java/1.12.500 Linux/5.15.0-86-generic OpenJDK_64-Bit_Server_VM/11.0.19" https://aws.amazon.com/rds > /dev/null 2>&1
sleep $(random_delay 10 30)

# Backup to S3
curl -s -A "Boto3/1.28.57 Python/3.11.5 Linux/5.15.0-86-generic Botocore/1.31.57" https://s3.amazonaws.com > /dev/null 2>&1

# Azure SQL
curl -s -A "azsdk-python-azure-mgmt-sql/4.0.0 Python/3.11.5 (Linux-5.15.0-86-generic-x86_64)" https://azure.microsoft.com > /dev/null 2>&1
EOF
      ;;

    office-worker)
      run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/domains/office-worker.txt' <<'EOF'
https://outlook.office365.com
https://teams.microsoft.com
https://sharepoint.com
https://docs.google.com
https://drive.google.com
https://www.salesforce.com
https://slack.com
https://zoom.us
https://www.linkedin.com
https://www.cnn.com
https://www.bbc.com
https://www.npr.org
https://www.nytimes.com
https://weather.com
https://www.amazon.com
https://www.reddit.com
https://www.espn.com
https://www.indeed.com
https://www.bankofamerica.com
https://www.chase.com
EOF

      run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/profiles/office-worker.sh' <<'EOF'
#!/bin/bash
source /opt/traffic-gen/utils/business-hours.sh
source /opt/traffic-gen/utils/random-timing.sh

DOMAINS=/opt/traffic-gen/domains/office-worker.txt

UA_POOL=(
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36"
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36 Edg/119.0.0.0"
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36"
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:120.0) Gecko/20100101 Firefox/120.0"
)
UA="${UA_POOL[$((RANDOM % ${#UA_POOL[@]}))]}"

if ! is_business_hours; then
  if [ $((RANDOM % 4)) -eq 0 ]; then
    echo "[$(date)] Office worker: After-hours email check"
    curl -s -A "$UA" https://outlook.office365.com > /dev/null 2>&1
  fi
  exit 0
fi

HOUR=$(date +%H)

echo "[$(date)] Office worker: Business hours activity (Hour: $HOUR)"

# Morning routine (8-10am)
if [ $HOUR -ge 8 ] && [ $HOUR -lt 10 ]; then
  curl -s -A "$UA" https://outlook.office365.com > /dev/null 2>&1
  sleep $(random_delay 5 15)
  browse_random "$DOMAINS" 2

# Lunch time (12-1pm) - personal browsing
elif is_lunch_time; then
  echo "[$(date)] Office worker: Lunch time personal browsing"
  curl -s -A "$UA" https://www.amazon.com > /dev/null 2>&1
  sleep $(random_delay 5 10)
  curl -s -A "$UA" https://www.facebook.com > /dev/null 2>&1 || true
  curl -s -A "$UA" https://www.youtube.com > /dev/null 2>&1
  browse_random "$DOMAINS" 3

# Regular work hours
else
  curl -s -A "$UA" https://www.salesforce.com > /dev/null 2>&1
  sleep $(random_delay 5 15)
  curl -s -A "$UA" https://slack.com > /dev/null 2>&1
  curl -s -A "$UA" https://docs.google.com > /dev/null 2>&1
  browse_random "$DOMAINS" 2
  # (Policy violation tests handled by security-tests/policy-violation.sh if enabled)
fi
EOF
      ;;

    sales)
      run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/profiles/sales.sh' <<'EOF'
#!/bin/bash
source /opt/traffic-gen/utils/business-hours.sh
source /opt/traffic-gen/utils/random-timing.sh
source /opt/traffic-gen/utils/genai.sh 2>/dev/null || true

if ! is_business_hours; then
  exit 0
fi

echo "[$(date)] Sales: CRM and prospecting activity"

UA_POOL=(
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15"
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36"
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
)
UA="${UA_POOL[$((RANDOM % ${#UA_POOL[@]}))]}"

curl -s -A "$UA" https://www.salesforce.com > /dev/null 2>&1
sleep $(random_delay 10 20)

curl -s -A "$UA" https://www.linkedin.com > /dev/null 2>&1
sleep $(random_delay 5 15)

curl -s -A "$UA" https://www.expedia.com > /dev/null 2>&1
curl -s -A "$UA" https://zoom.us > /dev/null 2>&1
curl -s -A "$UA" https://www.hubspot.com > /dev/null 2>&1

# GenAI — sales uses AI to draft outreach, research prospects, prep for calls
if [ $((RANDOM % 2)) -eq 0 ]; then
  genai_browse
fi
genai_api_call "$(genai_random_prompt)"
EOF
      ;;

    developer)
      run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/profiles/developer.sh' <<'EOF'
#!/bin/bash
source /opt/traffic-gen/utils/business-hours.sh
source /opt/traffic-gen/utils/random-timing.sh
source /opt/traffic-gen/utils/genai.sh 2>/dev/null || true

if ! is_business_hours; then
  if [ $((RANDOM % 3)) -eq 0 ]; then
    echo "[$(date)] Developer: After-hours coding"
    curl -s -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36" https://github.com > /dev/null 2>&1
  fi
  exit 0
fi

echo "[$(date)] Developer: Development activity"

UA_POOL=(
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36"
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:120.0) Gecko/20100101 Firefox/120.0"
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36"
  "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120.0"
)
UA="${UA_POOL[$((RANDOM % ${#UA_POOL[@]}))]}"

# Code repositories — alternate browser and git CLI
if [ $((RANDOM % 2)) -eq 0 ]; then
  curl -s -A "git/2.42.0" https://github.com > /dev/null 2>&1
else
  curl -s -A "$UA" https://github.com > /dev/null 2>&1
fi
sleep $(random_delay 10 30)

curl -s -A "$UA" https://stackoverflow.com > /dev/null 2>&1

# Package managers — CLI agents
curl -s -A "npm/10.2.0 node/v20.9.0 darwin arm64" https://registry.npmjs.org > /dev/null 2>&1
sleep $(random_delay 5 15)

curl -s -A "pip/23.3.1" https://pypi.org > /dev/null 2>&1

curl -s -A "$UA" https://console.aws.amazon.com > /dev/null 2>&1

curl -s -A "docker/24.0.5 go/go1.21.3 darwin/arm64" https://hub.docker.com > /dev/null 2>&1

# GenAI — developers are heavy AI coding assistant users
genai_api_call "$(genai_random_prompt)"
if [ $((RANDOM % 2)) -eq 0 ]; then
  genai_browse
fi
EOF
      ;;

    executive)
      run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/domains/executive.txt' <<'EOF'
https://www.wsj.com
https://www.bloomberg.com
https://www.ft.com
https://www.reuters.com
https://www.cnbc.com
https://www.businessinsider.com
https://hbr.org
https://www.economist.com
https://www.forbes.com
https://www.linkedin.com
https://zoom.us
https://teams.microsoft.com
https://outlook.office365.com
https://www.united.com
https://www.delta.com
https://www.marriott.com
https://www.hilton.com
https://www.amextravel.com
https://www.apple.com
https://www.salesforce.com
EOF

      run_on_node "$CT_NODE" pct exec $ctid -- bash -c 'cat > /opt/traffic-gen/profiles/executive.sh' <<'EOF'
#!/bin/bash
source /opt/traffic-gen/utils/business-hours.sh
source /opt/traffic-gen/utils/random-timing.sh
source /opt/traffic-gen/utils/genai.sh 2>/dev/null || true

DOMAINS=/opt/traffic-gen/domains/executive.txt

if ! is_business_hours; then
  exit 0
  # (After-hours UEBA handled by security-tests/ueba.sh if enabled)
fi

echo "[$(date)] Executive: Light usage pattern"

UA_POOL=(
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15"
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
)
UA="${UA_POOL[$((RANDOM % ${#UA_POOL[@]}))]}"

curl -s -A "$UA" https://outlook.office365.com > /dev/null 2>&1
sleep $(random_delay 15 45)

curl -s -A "$UA" https://www.wsj.com > /dev/null 2>&1
curl -s -A "$UA" https://www.bloomberg.com > /dev/null 2>&1
browse_random "$DOMAINS" 3

genai_browse
if [ $((RANDOM % 2)) -eq 0 ]; then
  genai_api_call "$(genai_random_prompt)"
fi

curl -s -A "$UA" https://zoom.us > /dev/null 2>&1

if [ $((RANDOM % 5)) -eq 0 ]; then
  curl -s -A "$UA" https://www.united.com > /dev/null 2>&1
fi
EOF
      ;;
  esac

  run_on_node "$CT_NODE" pct exec $ctid -- chmod +x /opt/traffic-gen/profiles/${profile}.sh
}

cmd_install_traffic_gen() {
  _load_config
  section_header "Traffic Generator Installation"

  # 1. Container Selection
  echo -e "${BLUE}1. Container Selection${NC}"
  echo "Detecting running containers (cluster-wide)..."

  _load_ct_data
  _build_default_profiles

  RUNNING_CONTAINERS=$(for ctid in "${!_CT_NODE[@]}"; do
    [ "${_CT_STATUS[$ctid]:-}" = "running" ] && echo "$ctid"
  done | sort -n)

  if [ -z "$RUNNING_CONTAINERS" ]; then
    echo -e "${RED}No running containers found!${NC}"
    echo "Please start containers first (option 3 from main menu)"
    return 1
  fi

  echo "Running containers:"
  for ctid in $RUNNING_CONTAINERS; do
    printf "  %-6s %-20s %-10s %-8s\n" \
      "$ctid" "${_CT_HOSTNAME[$ctid]:-?}" "${_CT_NODE[$ctid]:-?}" "running"
  done

  echo ""
  echo "Installation scope options:"
  echo "  1) Auto-detect and configure all containers with default profiles"
  echo "  2) Data Center containers only"
  echo "  3) Branch containers only"
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
        echo -e "${YELLOW}No lab-managed containers found in the configured ranges.${NC}"
        echo "Ensure HQ_RANGE/BRANCH_RANGE are set and containers are deployed and running."
        echo "Use the custom selection option to assign profiles manually."
        return 1
      fi
      ;;

    2)
      if [ -z "${HQ_RANGE:-}" ]; then
        read_ctid_range "Data Center CTID range" 6 "HQ_RANGE"
        _build_default_profiles
      else
        echo "  Using Data Center range: ${HQ_RANGE}"
      fi
      echo "Data Center containers (${HQ_RANGE}):"
      for ctid in "${!DEFAULT_PROFILES[@]}"; do
        IFS='-' read -r _hq_s _hq_e <<< "$HQ_RANGE"
        [ "$ctid" -lt "$_hq_s" ] || [ "$ctid" -gt "$_hq_e" ] && continue
        if echo "$RUNNING_CONTAINERS" | grep -q "^${ctid}$"; then
          TARGET_PROFILES[$ctid]="${DEFAULT_PROFILES[$ctid]}"
          echo "  CT ${ctid}: ${DEFAULT_PROFILES[$ctid]}"
        else
          echo -e "  ${YELLOW}CT ${ctid}: not running (skipped)${NC}"
        fi
      done
      ;;

    3)
      if [ -z "${BRANCH_RANGE:-}" ]; then
        read_ctid_range "Branch CTID range" 5 "BRANCH_RANGE"
        _build_default_profiles
      else
        echo "  Using Branch range: ${BRANCH_RANGE}"
      fi
      echo "Branch containers (${BRANCH_RANGE}):"
      for ctid in "${!DEFAULT_PROFILES[@]}"; do
        IFS='-' read -r _br_s _br_e <<< "$BRANCH_RANGE"
        [ "$ctid" -lt "$_br_s" ] || [ "$ctid" -gt "$_br_e" ] && continue
        if echo "$RUNNING_CONTAINERS" | grep -q "^${ctid}$"; then
          TARGET_PROFILES[$ctid]="${DEFAULT_PROFILES[$ctid]}"
          echo "  CT ${ctid}: ${DEFAULT_PROFILES[$ctid]}"
        else
          echo -e "  ${YELLOW}CT ${ctid}: not running (skipped)${NC}"
        fi
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

  # Look up which node each target container lives on.
  # _CT_NODE is already populated by _load_ct_data() above — no extra query needed.
  declare -A CT_NODES=()
  LOCAL_NODE=$(get_local_node)
  for CTID in "${!TARGET_PROFILES[@]}"; do
    CT_NODES[$CTID]="${_CT_NODE[$CTID]:-$LOCAL_NODE}"
  done

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
      read_with_default "Server cron schedule" "${CRON_SERVER:-*/15 * * * *}" "CRON_SERVER"
      read_with_default "Office cron schedule" "${CRON_OFFICE:-*/5 8-18 * * 1-5}" "CRON_OFFICE"
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

  # 4. Security Test Configuration
  echo ""
  echo -e "${BLUE}4. Security Test Configuration${NC}"
  echo "Security tests run alongside normal traffic on a separate cron schedule."
  echo "They generate targeted security events detectable by your security stack."
  echo ""
  printf "  %-22s %s\n" "eicar"             "AV — EICAR test file download"
  printf "  %-22s %s\n" "dlp-network"       "DLP — POST fake SSN/CCN to HTTPS endpoint"
  printf "  %-22s %s\n" "dlp-genai-prompt"  "DLP — Prompt with embedded PII to AI API (OpenAI/Anthropic/Google)"
  printf "  %-22s %s\n" "dlp-genai-file"    "DLP — Document upload with PII to AI file API"
  printf "  %-22s %s\n" "dlp-genai-image"   "DLP — Image with PII to AI vision API (OCR, installs imagemagick)"
  printf "  %-22s %s\n" "policy-violation"  "Policy — Access blocked apps (Dropbox, WeTransfer, Mega)"
  printf "  %-22s %s\n" "ueba"              "UEBA — After-hours access simulation"
  echo ""
  echo "  1) Recommended defaults (matched to container profiles)"
  echo "  2) All tests on all selected containers"
  echo "  3) Custom selection"
  echo "  4) No security tests"
  read -p "Select [1-4] (default: 4): " sec_choice

  declare -A SECURITY_TESTS=()
  ENABLE_SECURITY_TESTS=false
  CRON_SECURITY="${CRON_SECURITY:-*/30 * * * *}"

  case "${sec_choice:-4}" in
    1)
      ENABLE_SECURITY_TESTS=true
      for CTID in "${!TARGET_PROFILES[@]}"; do
        PROFILE="${TARGET_PROFILES[$CTID]}"
        TESTS=$(_default_security_tests_for_profile "$PROFILE")
        [ -n "$TESTS" ] && SECURITY_TESTS[$CTID]="$TESTS"
      done
      echo ""
      echo -e "${CYAN}Recommended security tests per container:${NC}"
      for CTID in $(echo "${!SECURITY_TESTS[@]}" | tr ' ' '\n' | sort -n); do
        echo "  CT ${CTID} (${TARGET_PROFILES[$CTID]}): ${SECURITY_TESTS[$CTID]}"
      done
      ;;

    2)
      ENABLE_SECURITY_TESTS=true
      ALL_TESTS="eicar dlp-network dlp-genai-prompt dlp-genai-file dlp-genai-image policy-violation ueba"
      for CTID in "${!TARGET_PROFILES[@]}"; do
        SECURITY_TESTS[$CTID]="$ALL_TESTS"
      done
      echo ""
      echo "All security tests will be installed on all selected containers."
      echo -e "${YELLOW}Note: imagemagick will be installed on all containers for the OCR test.${NC}"
      ;;

    3)
      ENABLE_SECURITY_TESTS=true
      echo ""
      echo "For each test, enter CTIDs to enable it on (space-separated), 'all', or Enter to skip."
      echo ""
      for test_name in eicar dlp-network dlp-genai-prompt dlp-genai-file dlp-genai-image policy-violation ueba; do
        case "$test_name" in
          eicar)             desc="AV — EICAR test file download" ;;
          dlp-network)       desc="DLP — POST fake SSN/CCN to HTTPS endpoint" ;;
          dlp-genai-prompt)  desc="DLP — Prompt with embedded PII to AI API" ;;
          dlp-genai-file)    desc="DLP — Document upload with PII to AI file API" ;;
          dlp-genai-image)   desc="DLP — Image with PII to AI vision API (OCR, installs imagemagick)" ;;
          policy-violation)  desc="Policy — Access blocked apps" ;;
          ueba)              desc="UEBA — After-hours access simulation" ;;
        esac
        echo -e "  ${CYAN}${test_name}${NC} — ${desc}"
        read -p "  Enable on CTIDs (or 'all', Enter to skip): " ctid_input
        if [ "$ctid_input" = "all" ]; then
          for CTID in "${!TARGET_PROFILES[@]}"; do
            SECURITY_TESTS[$CTID]="${SECURITY_TESTS[$CTID]:-} ${test_name}"
          done
        elif [ -n "$ctid_input" ]; then
          for ctid in $ctid_input; do
            if [ -n "${TARGET_PROFILES[$ctid]:-}" ]; then
              SECURITY_TESTS[$ctid]="${SECURITY_TESTS[$ctid]:-} ${test_name}"
            else
              echo -e "    ${YELLOW}CT ${ctid} not in target set, skipped${NC}"
            fi
          done
        fi
      done
      ;;

    4|*)
      ENABLE_SECURITY_TESTS=false
      echo "No security tests will be installed."
      ;;
  esac

  if $ENABLE_SECURITY_TESTS && [ ${#SECURITY_TESTS[@]} -gt 0 ]; then
    echo ""
    read_with_default "Security test cron schedule" "${CRON_SECURITY:-*/30 * * * *}" "CRON_SECURITY"
  fi

  # Summary
  section_header "Installation Summary"
  echo "Containers:      ${#TARGET_PROFILES[@]}"
  echo "Intensity:       ${INTENSITY}"
  echo "Server Schedule: ${CRON_SERVER}"
  echo "Office Schedule: ${CRON_OFFICE}"
  echo ""
  echo "Installation mode:"
  [ "$INSTALL_FRAMEWORK" = true ] && echo "  ✓ Install framework (includes genai.sh, run-security-tests.sh)"
  [ "$INSTALL_PROFILES" = true ] && echo "  ✓ Install profiles"
  [ "$ENABLE_CRON" = true ] && echo "  ✓ Enable automatic traffic generation"
  [ "$ENABLE_CRON" = false ] && echo "  ○ Manual start only (no cron)"
  if $ENABLE_SECURITY_TESTS && [ ${#SECURITY_TESTS[@]} -gt 0 ]; then
    echo "  ✓ Security tests (${CRON_SECURITY})"
  else
    echo "  ○ No security tests"
  fi

  echo ""
  echo -e "${CYAN}Container assignments:${NC}"
  for CTID in $(echo "${!TARGET_PROFILES[@]}" | tr ' ' '\n' | sort -n); do
    PROFILE="${TARGET_PROFILES[$CTID]}"
    echo "  CT ${CTID}: ${PROFILE}"
    echo "    → ${PROFILE_DESC[$PROFILE]}"
    if $ENABLE_SECURITY_TESTS && [ -n "${SECURITY_TESTS[$CTID]:-}" ]; then
      echo "    → Security tests: ${SECURITY_TESTS[$CTID]}"
    fi
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
    CT_NODE="${CT_NODES[$CTID]:-$LOCAL_NODE}"

    echo ""
    echo -e "${CYAN}Configuring CT ${CTID} (${PROFILE}) on ${CT_NODE}...${NC}"

    if ! run_on_node "$CT_NODE" pct status "$CTID" 2>/dev/null | grep -q "running"; then
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
        run_on_node "$CT_NODE" pct exec $CTID -- bash -c "echo '${CRON_OFFICE} /opt/traffic-gen/traffic-gen.sh ${PROFILE}' | crontab -"
      else
        run_on_node "$CT_NODE" pct exec $CTID -- bash -c "echo '${CRON_SERVER} /opt/traffic-gen/traffic-gen.sh ${PROFILE}' | crontab -"
      fi
    fi

    if $ENABLE_SECURITY_TESTS && [ -n "${SECURITY_TESTS[$CTID]:-}" ]; then
      echo "  → Installing security tests..."
      for test in ${SECURITY_TESTS[$CTID]}; do
        echo "    • ${test}"
        _install_security_test $CTID $test
      done
      _add_security_test_cron $CTID "$CRON_SECURITY"
    fi

    echo -e "${GREEN}  ✓ CT ${CTID} configured successfully${NC}"
  done

  section_header "✓ Installation Complete"
  echo "Configured containers: ${#TARGET_PROFILES[@]}"
  echo "Traffic intensity: ${INTENSITY}"
  if $ENABLE_SECURITY_TESTS && [ ${#SECURITY_TESTS[@]} -gt 0 ]; then
    echo "Security test schedule: ${CRON_SECURITY}"
  fi

  if $ENABLE_CRON; then
    echo ""
    echo "Traffic generation is ENABLED and will run automatically"
    echo ""
    echo "Useful commands:"
    echo "  View cron:         pct exec <CTID> -- crontab -l"
    echo "  View logs:         pct exec <CTID> -- tail -f /var/log/messages"
    echo "  Run profile:       pct exec <CTID> -- /opt/traffic-gen/traffic-gen.sh <profile>"
    echo "  Run security test: pct exec <CTID> -- /opt/traffic-gen/run-security-tests.sh"
    echo "  Run single test:   pct exec <CTID> -- bash /opt/traffic-gen/security-tests/<test>.sh"
    echo "  Disable cron:      pct exec <CTID> -- crontab -r"
  else
    echo ""
    echo "Traffic generation is DISABLED (manual mode)"
    echo ""
    echo "To start manually:"
    echo "  pct exec <CTID> -- /opt/traffic-gen/traffic-gen.sh <profile>"
    echo ""
    echo "To run security tests manually:"
    echo "  pct exec <CTID> -- /opt/traffic-gen/run-security-tests.sh"
    echo ""
    echo "To enable automatic traffic:"
    echo "  Re-run install (option 4) and choose 'Full install' mode"
  fi
  _maybe_save_config
}

# ============================================================
# MODULE: Show Status
# ============================================================

cmd_show_status() {
  _load_config
  section_header "Lab Status"

  _load_ct_data

  if [ ${#_CT_NODE[@]} -eq 0 ]; then
    echo -e "${RED}No containers found${NC}"
    return 0
  fi

  # Build sorted list: node<TAB>ctid (so we can group by node)
  local sorted_pairs
  sorted_pairs=$(for ctid in "${!_CT_NODE[@]}"; do
    echo "${_CT_NODE[$ctid]}"$'\t'"$ctid"
  done | sort -k1,1 -k2,2n)

  RUNNING=0
  STOPPED=0
  local current_node=""

  # Read from fd 3 (not stdin) so SSH calls inside the loop via run_on_node
  # cannot consume the here-string by reading from stdin.
  while IFS=$'\t' read -r node ctid <&3; do
    local name="${_CT_HOSTNAME[$ctid]:-}"
    local status="${_CT_STATUS[$ctid]:-stopped}"
    local tags="${_CT_TAGS[$ctid]:-}"

    # Filter to lab-managed containers only
    if [[ "$tags" != *"lab-managed"* ]]; then
      continue
    fi

    if [ "$node" != "$current_node" ]; then
      [ -n "$current_node" ] && echo ""
      echo -e "${BLUE}=== Node: ${node} ===${NC}"
      printf "  %-8s %-24s %-12s %-14s\n" "CTID" "Hostname" "Status" "Traffic Gen"
      echo "  --------------------------------------------------------"
      current_node="$node"
    fi

    if [ "$status" = "running" ]; then
      if run_on_node "$node" pct exec "$ctid" -- crontab -l 2>/dev/null | grep -q "traffic-gen"; then
        TRAFFIC="${GREEN}enabled${NC}"
      else
        TRAFFIC="${YELLOW}not set${NC}"
      fi
      printf "  %-8s %-24s ${GREEN}%-12s${NC} " "$ctid" "$name" "Running"
      RUNNING=$((RUNNING + 1))
    else
      TRAFFIC="-"
      printf "  %-8s %-24s ${YELLOW}%-12s${NC} " "$ctid" "$name" "Stopped"
      STOPPED=$((STOPPED + 1))
    fi
    echo -e "$TRAFFIC"
  done 3<<< "$sorted_pairs"

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

  WIZARD_MODE=true

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

  WIZARD_MODE=false

  section_header "✓ Full Lab Setup Complete"
  echo "Your Proxmox lab is ready!"
  echo ""
  save_config
  echo ""
  echo "Run with 'status' or choose option 6 to check the current state."
}

# ============================================================
# MODULE: Container Maintenance
# ============================================================

cmd_update_containers() {
  _load_config
  section_header "Update Container Packages"

  echo "Scanning for containers (cluster-wide)..."
  _load_ct_data

  declare -a RUNNING_CTIDS=()
  declare -A CT_NODE_MAP=() CT_HOSTNAME_MAP=()

  for ctid in $(echo "${!_CT_NODE[@]}" | tr ' ' '\n' | sort -n); do
    tags="${_CT_TAGS[$ctid]:-}"
    name="${_CT_HOSTNAME[$ctid]:-}"
    if [[ "$tags" != *"lab-managed"* ]]; then
      continue
    fi
    if [ "${_CT_STATUS[$ctid]:-stopped}" = "running" ]; then
      RUNNING_CTIDS+=("$ctid")
      CT_NODE_MAP[$ctid]="${_CT_NODE[$ctid]}"
      CT_HOSTNAME_MAP[$ctid]="${_CT_HOSTNAME[$ctid]:-unknown}"
    fi
  done

  if [ ${#RUNNING_CTIDS[@]} -eq 0 ]; then
    echo -e "${YELLOW}No running lab-managed containers found.${NC}"
    return 0
  fi

  echo ""
  echo "Found ${#RUNNING_CTIDS[@]} running container(s):"
  for ctid in "${RUNNING_CTIDS[@]}"; do
    printf "  %-8s %-24s %s\n" "$ctid" "${CT_HOSTNAME_MAP[$ctid]}" "${CT_NODE_MAP[$ctid]}"
  done
  echo ""
  read -p "Update packages on all containers? [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    return 0
  fi

  echo ""
  echo "Updating packages (parallel)..."
  echo ""

  declare -a PIDS=() CTID_ORDER=()
  declare -A TMPFILES=()

  for ctid in "${RUNNING_CTIDS[@]}"; do
    local_tmpf=$(mktemp)
    CTID_ORDER+=("$ctid")
    TMPFILES[$ctid]="$local_tmpf"
    run_on_node "${CT_NODE_MAP[$ctid]}" pct exec "$ctid" -- \
      sh -c 'apk update -q 2>&1 && apk upgrade -y 2>&1' > "$local_tmpf" 2>&1 &
    PIDS+=($!)
  done

  SUCCESS=0; FAILED=0
  for i in "${!PIDS[@]}"; do
    ctid="${CTID_ORDER[$i]}"
    name="${CT_HOSTNAME_MAP[$ctid]}"
    tmpf="${TMPFILES[$ctid]}"
    if wait "${PIDS[$i]}" 2>/dev/null; then
      echo -e "${GREEN}✓ CT ${ctid} (${name})${NC}"
      ((++SUCCESS))
    else
      echo -e "${RED}✗ CT ${ctid} (${name})${NC}"
      sed 's/^/    /' "$tmpf"
      ((++FAILED))
    fi
    rm -f "$tmpf"
  done

  echo ""
  echo -e "${GREEN}Updated: ${SUCCESS}${NC}"
  [ $FAILED -gt 0 ] && echo -e "${RED}Failed: ${FAILED}${NC}"
}

# ============================================================
# MODULE: Update
# ============================================================

_startup_version_check() {
  local remote_version remote_changelog changelog_section

  remote_version=$(curl -fsSL --connect-timeout 5 --max-time 5 \
    "https://api.github.com/repos/mpreissner/proxmox-lab-scripts/releases/latest" \
    2>/dev/null | grep '"tag_name"' | head -1 | cut -d'"' -f4 | sed 's/^v//')
  [ -z "$remote_version" ] && return 0
  version_gt "$remote_version" "$VERSION" || return 0

  echo ""
  echo -e "${YELLOW}══════════════════════════════════════════${NC}"
  echo -e "${YELLOW}  Update available: v${VERSION} → v${remote_version}${NC}"
  echo -e "${YELLOW}══════════════════════════════════════════${NC}"

  remote_changelog=$(curl -fsSL --connect-timeout 10 \
    "https://raw.githubusercontent.com/mpreissner/proxmox-lab-scripts/main/CHANGELOG.md" \
    2>/dev/null) || true
  if [ -n "$remote_changelog" ]; then
    changelog_section=$(echo "$remote_changelog" | awk \
      "/^## \[${remote_version}\]/{found=1; next} found && /^## \[/{exit} found{print}")
    if [ -n "$changelog_section" ]; then
      echo ""
      echo "  What's new in v${remote_version}:"
      echo "$changelog_section" | while IFS= read -r line; do
        echo "  $line"
      done
    fi
  fi

  echo ""
  read -p "Update now? [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo ""
    return 0
  fi

  cmd_update true
  echo ""
  echo "The script will now exit. Re-launch proxmox-lab.sh to run the new version."
  exit 0
}

cmd_update() {
  local skip_confirm="${1:-false}"

  $skip_confirm || section_header "Update proxmox-lab.sh"

  REMOTE_RAW="https://raw.githubusercontent.com/mpreissner/proxmox-lab-scripts/main/proxmox-lab.sh"
  CHANGELOG_RAW="https://raw.githubusercontent.com/mpreissner/proxmox-lab-scripts/main/CHANGELOG.md"

  $skip_confirm || echo "Checking for updates..."
  remote_script=$(curl -fsSL --connect-timeout 10 "$REMOTE_RAW") || {
    echo -e "${RED}Error: Could not reach GitHub. Check network connectivity.${NC}"
    return 1
  }

  REMOTE_VERSION=$(echo "$remote_script" | grep '^VERSION=' | head -1 | cut -d'"' -f2)

  if [ -z "$REMOTE_VERSION" ]; then
    echo -e "${RED}Error: Could not determine remote version.${NC}"
    return 1
  fi

  if ! $skip_confirm; then
    if [ "$REMOTE_VERSION" = "$VERSION" ]; then
      echo -e "${GREEN}Already up to date (v${VERSION})${NC}"
      return 0
    fi

    if ! version_gt "$REMOTE_VERSION" "$VERSION"; then
      echo -e "${YELLOW}Warning: Remote version (v${REMOTE_VERSION}) is older than local (v${VERSION}). No update needed.${NC}"
      return 0
    fi

    echo ""
    echo -e "${CYAN}Update available: v${VERSION} → v${REMOTE_VERSION}${NC}"
    echo ""

    remote_changelog=$(curl -fsSL --connect-timeout 10 "$CHANGELOG_RAW") || true

    if [ -n "$remote_changelog" ]; then
      changelog_section=$(echo "$remote_changelog" | awk \
        "/^## \[${REMOTE_VERSION}\]/{found=1; next} found && /^## \[/{exit} found{print}")
      if [ -n "$changelog_section" ]; then
        echo "  What's new in v${REMOTE_VERSION}:"
        echo "$changelog_section" | while IFS= read -r line; do
          echo "  $line"
        done
        echo ""
      fi
    fi

    read -p "Update proxmox-lab.sh? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Update cancelled."
      return 0
    fi
  fi

  SCRIPT_PATH="$(realpath "$0")"
  TEMP=$(mktemp /tmp/proxmox-lab-update.XXXXXX)

  echo "$remote_script" > "$TEMP"

  bash -n "$TEMP" || {
    echo -e "${RED}Downloaded script failed syntax check. Aborting.${NC}"
    rm -f "$TEMP"
    return 1
  }

  cp "$TEMP" "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
  rm -f "$TEMP"

  echo -e "${GREEN}✓ Updated to v${REMOTE_VERSION}${NC}"
  if ! $skip_confirm; then
    echo ""
    echo "Exiting — relaunch proxmox-lab.sh to run the new version."
    echo "To push updated traffic profiles to containers, run option 4 (Install Traffic Generator) after relaunching."
    exit 0
  fi
}

cmd_system_cleanup() {
  _load_config
  section_header "System Cleanup"

  # Discover lab-managed containers cluster-wide
  echo "Scanning for containers (cluster-wide)..."
  _load_ct_data

  LAB_CTIDS=()
  declare -A LAB_CT_NODE=() LAB_CT_STATUS=() LAB_CT_HOSTNAME=()
  for ctid in $(echo "${!_CT_NODE[@]}" | tr ' ' '\n' | sort -n); do
    name="${_CT_HOSTNAME[$ctid]:-}"
    tags="${_CT_TAGS[$ctid]:-}"
    if [[ "$tags" == *"lab-managed"* ]]; then
      LAB_CTIDS+=($ctid)
      LAB_CT_NODE[$ctid]="${_CT_NODE[$ctid]}"
      LAB_CT_STATUS[$ctid]="${_CT_STATUS[$ctid]}"
      LAB_CT_HOSTNAME[$ctid]="$name"
    fi
  done

  # Template identified by saved TEMPLATE_ID — search cluster-wide
  TEMPLATE_CTID=""
  TEMPLATE_NODE=""
  if [ -n "${TEMPLATE_ID:-}" ]; then
    TEMPLATE_NODE=$(_find_template_node "$TEMPLATE_ID")
    [ -n "$TEMPLATE_NODE" ] && TEMPLATE_CTID="$TEMPLATE_ID"
  fi

  # Alpine images — check every cluster node via pveam
  local _img_store="${IMAGE_STORAGE:-local}"
  declare -a ALPINE_IMAGE_NODES=() ALPINE_IMAGE_PATHS=()
  local _nodes _node
  _nodes=$(get_cluster_nodes 2>/dev/null)
  [ -z "$_nodes" ] && _nodes=$(get_local_node)
  for _node in $_nodes; do
    while IFS= read -r _tmpl; do
      [ -n "$_tmpl" ] && { ALPINE_IMAGE_NODES+=("$_node"); ALPINE_IMAGE_PATHS+=("$_tmpl"); }
    done < <(run_on_node "$_node" pveam list "${_img_store}" 2>/dev/null | \
      awk '/^alpine-.*\.tar\.xz/{print $1}' 2>/dev/null)
  done

  if [ ${#LAB_CTIDS[@]} -eq 0 ] && [ -z "$TEMPLATE_CTID" ] && [ ${#ALPINE_IMAGE_PATHS[@]} -eq 0 ]; then
    echo "Nothing to clean up."
    return 0
  fi

  echo ""
  echo "The following will be PERMANENTLY DESTROYED:"
  echo ""
  if [ -n "$TEMPLATE_CTID" ]; then
    echo "Template:"
    echo "  CT ${TEMPLATE_CTID} — template (on ${TEMPLATE_NODE})"
  fi
  if [ ${#LAB_CTIDS[@]} -gt 0 ]; then
    echo "Containers:"
    for ctid in "${LAB_CTIDS[@]}"; do
      echo "  CT ${ctid} (${LAB_CT_HOSTNAME[$ctid]:-unknown})" \
           "— ${LAB_CT_STATUS[$ctid]:-?} (on ${LAB_CT_NODE[$ctid]:-?})"
    done
  fi
  if [ ${#ALPINE_IMAGE_PATHS[@]} -gt 0 ]; then
    echo ""
    echo "Alpine template images (${_img_store}):"
    for i in "${!ALPINE_IMAGE_PATHS[@]}"; do
      echo "  ${ALPINE_IMAGE_PATHS[$i]} (on ${ALPINE_IMAGE_NODES[$i]})"
    done
  fi

  echo ""
  echo -e "${RED}WARNING: This cannot be undone.${NC}"
  echo ""
  read -p "Type CONFIRM to proceed: " confirm_text

  if [ "$confirm_text" != "CONFIRM" ]; then
    echo "Aborted."
    return 0
  fi

  echo ""
  echo "Cleaning up..."

  # Destroy deployed containers first (stop if running), cluster-wide
  for ctid in "${LAB_CTIDS[@]}"; do
    CT_NODE="${LAB_CT_NODE[$ctid]:-$(get_local_node)}"
    HOSTNAME="${LAB_CT_HOSTNAME[$ctid]:-unknown}"
    STATUS="${LAB_CT_STATUS[$ctid]:-}"
    if [ "$STATUS" = "running" ]; then
      echo "Stopping CT ${ctid} (${HOSTNAME}) on ${CT_NODE}..."
      run_on_node "$CT_NODE" pct stop $ctid 2>/dev/null || true
      sleep 2
    fi
    echo "Destroying CT ${ctid} (${HOSTNAME}) on ${CT_NODE}..."
    if run_on_node "$CT_NODE" pct destroy $ctid 2>/dev/null; then
      echo -e "${GREEN}✓ CT ${ctid} destroyed${NC}"
    else
      echo -e "${RED}✗ CT ${ctid} failed to destroy${NC}"
    fi
  done

  # Confirm all containers are fully gone before destroying the template.
  # pct destroy is asynchronous — the dataset removal can still be in flight
  # when the command returns, and Proxmox may refuse to destroy the template
  # while any volume operations from the clones are still pending.
  if [ ${#LAB_CTIDS[@]} -gt 0 ] && [ -n "$TEMPLATE_CTID" ]; then
    echo "Waiting for containers to be fully removed..."
    local max_wait=30 waited=0 all_gone
    while [ $waited -lt $max_wait ]; do
      all_gone=true
      for ctid in "${LAB_CTIDS[@]}"; do
        CT_NODE="${LAB_CT_NODE[$ctid]:-$(get_local_node)}"
        if run_on_node "$CT_NODE" pct status "$ctid" &>/dev/null; then
          all_gone=false
          break
        fi
      done
      $all_gone && break
      sleep 2
      waited=$((waited + 2))
    done
    if ! $all_gone; then
      echo -e "${YELLOW}Warning: some containers may not be fully gone — template destroy may fail${NC}"
    fi
  fi

  # Destroy template
  if [ -n "$TEMPLATE_CTID" ]; then
    echo "Destroying template CT ${TEMPLATE_CTID} on ${TEMPLATE_NODE}..."
    if run_on_node "$TEMPLATE_NODE" pct destroy $TEMPLATE_CTID 2>/dev/null; then
      echo -e "${GREEN}✓ Template CT ${TEMPLATE_CTID} destroyed${NC}"
    else
      echo -e "${RED}✗ Template CT ${TEMPLATE_CTID} failed to destroy${NC}"
    fi
  fi

  if [ ${#ALPINE_IMAGE_PATHS[@]} -gt 0 ]; then
    echo ""
    echo "Removing Alpine template images..."
    for i in "${!ALPINE_IMAGE_PATHS[@]}"; do
      _node="${ALPINE_IMAGE_NODES[$i]}"
      _tmpl="${ALPINE_IMAGE_PATHS[$i]}"
      if run_on_node "$_node" pveam remove "${_img_store}" "${_tmpl}" 2>/dev/null; then
        echo -e "${GREEN}✓ Removed ${_tmpl} from ${_node}${NC}"
      else
        echo -e "${RED}✗ Failed to remove ${_tmpl} from ${_node}${NC}"
      fi
    done
  fi

  section_header "Cleanup Complete"
}

# ============================================================
# Write a local file into a Windows VM via QEMU guest agent.
# Uses base64 chunking + PowerShell to avoid command-line length limits
# and bypass the non-existent 'qm guest file-write' subcommand.
# Each chunk is written synchronously so ordering is guaranteed.
# Args: <node> <vmid> <local_path> <windows_dest_path>
_win_vm_write_file() {
  local node="$1" vmid="$2" local_path="$3" win_path="$4"
  local b64 chunk offset=0 chunk_size=6000 first=true
  b64=$(base64 < "$local_path" | tr -d '\n')
  local total=${#b64}
  while [ $offset -lt $total ]; do
    chunk="${b64:$offset:$chunk_size}"
    offset=$((offset + chunk_size))
    if $first; then
      run_on_node "$node" qm guest exec --synchronous 1 "$vmid" -- \
        powershell.exe -ExecutionPolicy Bypass -NonInteractive -Command \
        "[System.IO.File]::WriteAllBytes('${win_path}',[Convert]::FromBase64String('${chunk}'))" \
        2>/dev/null
      first=false
    else
      run_on_node "$node" qm guest exec --synchronous 1 "$vmid" -- \
        powershell.exe -ExecutionPolicy Bypass -NonInteractive -Command \
        "\$b=[Convert]::FromBase64String('${chunk}');\$f=[System.IO.File]::Open('${win_path}',[System.IO.FileMode]::Append);\$f.Write(\$b,0,\$b.Length);\$f.Dispose()" \
        2>/dev/null
    fi
  done
}

# ============================================================
# MODULE: Install Windows VM Certificate
# ============================================================

cmd_install_windows_cert() {
  _load_config
  section_header "Install Windows VM Certificate"

  # --- Show running VMs across cluster ---
  echo ""
  echo "Running VMs on cluster:"
  local _nodes _node
  _nodes=$(get_cluster_nodes 2>/dev/null)
  [ -z "$_nodes" ] && _nodes=$(get_local_node)
  printf "  %-8s %-24s %s\n" "VMID" "Name" "Node"
  printf "  %-8s %-24s %s\n" "--------" "------------------------" "--------"
  for _node in $_nodes; do
    pvesh get /nodes/"$_node"/qemu --output-format json 2>/dev/null | python3 -c "
import sys,json
node='$_node'
for r in json.load(sys.stdin):
    if r.get('status') == 'running':
        print('  {:<8} {:<24} {}'.format(r.get('vmid',''), r.get('name','-')[:24], node))
" 2>/dev/null
  done
  echo ""

  # --- VM ID ---
  if [ -n "${WIN_VMID:-}" ]; then
    read -p "  Windows VM ID [${WIN_VMID}]: " _input
    WIN_VMID="${_input:-$WIN_VMID}"
  else
    while [ -z "${WIN_VMID:-}" ]; do
      read -p "  Windows VM ID: " WIN_VMID
    done
  fi

  # --- Locate VM on cluster ---
  echo "  Locating VM ${WIN_VMID} on cluster..."
  local _vm_node
  _vm_node=$(_find_vm_node "$WIN_VMID")
  if [ -z "$_vm_node" ]; then
    echo -e "${RED}  Error: VM ${WIN_VMID} not found on any cluster node.${NC}"
    return 1
  fi
  echo -e "  ${GREEN}Found VM ${WIN_VMID} on node: ${_vm_node}${NC}"

  # --- Check VM is running ---
  if ! run_on_node "$_vm_node" qm status "$WIN_VMID" 2>/dev/null | grep -q "running"; then
    echo -e "${RED}  Error: VM ${WIN_VMID} is not running. Start it and try again.${NC}"
    return 1
  fi

  # --- Check QEMU guest agent ---
  echo "  Checking QEMU guest agent..."
  if ! run_on_node "$_vm_node" qm agent "$WIN_VMID" ping 2>/dev/null; then
    echo -e "${RED}  Error: QEMU guest agent is not responding on VM ${WIN_VMID}.${NC}"
    echo "  Install the QEMU guest agent in Windows and ensure the service is running."
    return 1
  fi
  echo -e "  ${GREEN}Guest agent is available.${NC}"

  # --- Certificate path ---
  echo ""
  if [ -n "${CERT_PATH:-}" ]; then
    read -p "  Certificate path [${CERT_PATH}]: " _input
    CERT_PATH="${_input:-$CERT_PATH}"
  else
    read -p "  Certificate path on this host: " CERT_PATH
  fi
  if [ -z "$CERT_PATH" ] || [ ! -f "$CERT_PATH" ]; then
    echo -e "${RED}  Error: Certificate file not found: ${CERT_PATH}${NC}"
    return 1
  fi

  local CERT_FILENAME
  CERT_FILENAME=$(basename "$CERT_PATH")
  local WIN_TEMP_PATH="C:\\Windows\\Temp\\${CERT_FILENAME}"

  # --- Copy certificate to VM via base64+PowerShell ---
  echo ""
  echo "  Copying certificate to VM ${WIN_VMID}..."
  if ! _win_vm_write_file "$_vm_node" "$WIN_VMID" "$CERT_PATH" "$WIN_TEMP_PATH"; then
    echo -e "${RED}  Error: Failed to copy certificate to VM.${NC}"
    return 1
  fi
  echo -e "  ${GREEN}Certificate copied to ${WIN_TEMP_PATH}${NC}"

  # --- Install certificate to Trusted Root CA store ---
  echo "  Installing certificate to Trusted Root Certification Authorities..."
  run_on_node "$_vm_node" qm guest exec "$WIN_VMID" -- \
    powershell.exe -ExecutionPolicy Bypass -NonInteractive -Command \
    "\$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2('${WIN_TEMP_PATH}'); \$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine'); \$store.Open('ReadWrite'); \$store.Add(\$cert); \$store.Close()" \
    2>/dev/null
  echo -e "  ${GREEN}Certificate install command sent.${NC}"

  # --- Clean up temp file ---
  run_on_node "$_vm_node" qm guest exec "$WIN_VMID" -- \
    cmd.exe /c "del \"${WIN_TEMP_PATH}\"" 2>/dev/null || true

  echo ""
  echo -e "${GREEN}✓ Done. To verify in Windows:${NC}"
  echo "    Run certmgr.msc → Trusted Root Certification Authorities → Certificates"
  echo "    Look for: $(basename "${CERT_FILENAME%.*}")"

  _maybe_save_config
}

# ============================================================
# MODULE: Setup Windows VM Traffic Generator
# ============================================================

cmd_setup_windows_vm() {
  _load_config
  section_header "Setup Windows VM Traffic Generator"

  # --- Show running VMs across cluster ---
  echo ""
  echo "Running VMs on cluster:"
  local _nodes _node
  _nodes=$(get_cluster_nodes 2>/dev/null)
  [ -z "$_nodes" ] && _nodes=$(get_local_node)
  printf "  %-8s %-24s %s\n" "VMID" "Name" "Node"
  printf "  %-8s %-24s %s\n" "--------" "------------------------" "--------"
  for _node in $_nodes; do
    pvesh get /nodes/"$_node"/qemu --output-format json 2>/dev/null | python3 -c "
import sys,json
node='$_node'
for r in json.load(sys.stdin):
    if r.get('status') == 'running':
        print('  {:<8} {:<24} {}'.format(r.get('vmid',''), r.get('name','-')[:24], node))
" 2>/dev/null
  done
  echo ""

  # --- VM ID ---
  if [ -n "${WIN_VMID:-}" ]; then
    read -p "  Windows VM ID [${WIN_VMID}]: " _input
    WIN_VMID="${_input:-$WIN_VMID}"
  else
    while [ -z "${WIN_VMID:-}" ]; do
      read -p "  Windows VM ID: " WIN_VMID
    done
  fi

  # --- Locate VM on cluster ---
  echo "  Locating VM ${WIN_VMID} on cluster..."
  local _vm_node
  _vm_node=$(_find_vm_node "$WIN_VMID")
  if [ -z "$_vm_node" ]; then
    echo -e "${RED}  Error: VM ${WIN_VMID} not found on any cluster node.${NC}"
    return 1
  fi
  echo -e "  ${GREEN}Found VM ${WIN_VMID} on node: ${_vm_node}${NC}"

  # --- Check VM is running ---
  if ! run_on_node "$_vm_node" qm status "$WIN_VMID" 2>/dev/null | grep -q "running"; then
    echo -e "${RED}  Error: VM ${WIN_VMID} is not running. Start it and try again.${NC}"
    return 1
  fi

  # --- Check QEMU guest agent ---
  echo "  Checking QEMU guest agent..."
  if ! run_on_node "$_vm_node" qm agent "$WIN_VMID" ping 2>/dev/null; then
    echo -e "${RED}  Error: QEMU guest agent is not responding on VM ${WIN_VMID}.${NC}"
    echo "  Install the QEMU guest agent in Windows and ensure the service is running."
    return 1
  fi
  echo -e "  ${GREEN}Guest agent is available.${NC}"

  # --- Script paths on Proxmox host ---
  echo ""
  echo -e "${BLUE}Script Paths (on this Proxmox host)${NC}"
  read_with_default "win-traffic.ps1 path" "${WIN_TRAFFIC_PS1:-/root/win-traffic.ps1}" "WIN_TRAFFIC_PS1"
  read_with_default "setup-scheduled-tasks.ps1 path" "${WIN_SETUP_PS1:-/root/setup-scheduled-tasks.ps1}" "WIN_SETUP_PS1"
  for f in "$WIN_TRAFFIC_PS1" "$WIN_SETUP_PS1"; do
    if [ ! -f "$f" ]; then
      echo -e "${RED}  Error: File not found: ${f}${NC}"
      return 1
    fi
  done

  # --- Create destination directory ---
  local WIN_DEST_DIR='C:\ProgramData\proxmox-lab'
  echo ""
  echo "  Creating ${WIN_DEST_DIR} on VM ${WIN_VMID}..."
  run_on_node "$_vm_node" qm guest exec "$WIN_VMID" -- \
    powershell.exe -ExecutionPolicy Bypass -NonInteractive -Command \
    "New-Item -ItemType Directory -Force -Path 'C:\ProgramData\proxmox-lab' | Out-Null" \
    2>/dev/null

  # --- Copy scripts ---
  echo "  Copying win-traffic.ps1..."
  _win_vm_write_file "$_vm_node" "$WIN_VMID" "$WIN_TRAFFIC_PS1" 'C:\ProgramData\proxmox-lab\win-traffic.ps1'
  echo -e "  ${GREEN}✓ win-traffic.ps1 copied${NC}"

  echo "  Copying setup-scheduled-tasks.ps1..."
  _win_vm_write_file "$_vm_node" "$WIN_VMID" "$WIN_SETUP_PS1" 'C:\ProgramData\proxmox-lab\setup-scheduled-tasks.ps1'
  echo -e "  ${GREEN}✓ setup-scheduled-tasks.ps1 copied${NC}"

  # --- Run setup-scheduled-tasks.ps1 ---
  echo ""
  echo "  Running setup-scheduled-tasks.ps1..."
  run_on_node "$_vm_node" qm guest exec "$WIN_VMID" -- \
    powershell.exe -ExecutionPolicy Bypass -NonInteractive \
    -File 'C:\ProgramData\proxmox-lab\setup-scheduled-tasks.ps1' \
    2>/dev/null
  echo -e "  ${GREEN}✓ Scheduled tasks configured${NC}"

  echo ""
  echo -e "${GREEN}✓ Windows VM traffic generator setup complete.${NC}"
  echo "  Scripts installed to: ${WIN_DEST_DIR}"
  echo "  Verify in Windows: open Task Scheduler and check for scheduled lab tasks."

  _maybe_save_config
}

# ============================================================
# MAIN MENU
# ============================================================

main_menu() {
  while true; do
    echo ""
    echo -e "${BLUE}=========================================="
    echo "  Proxmox Lab Manager v${VERSION}"
    echo -e "==========================================${NC}"
    echo ""
    echo "  1) Create Template"
    echo "  2) Deploy Containers"
    echo "  3) Start Containers"
    echo "  4) Install Traffic Generator"
    echo "  5) Full Setup Wizard  (steps 1 → 2 → 3 → 4)"
    echo "  6) Install Windows VM Certificate"
    echo "  7) Setup Windows VM Traffic Generator"
    echo "  8) Show Status"
    echo "  9) Update Container Packages"
    echo " 10) Update Lab Script"
    echo " 11) Stop Containers"
    echo " 12) Exit"
    echo ""
    read -p "Select option [1-12]: " choice

    case "$choice" in
      1) ( cmd_create_template ) || echo -e "${RED}Operation failed or was aborted.${NC}" ;;
      2) ( cmd_deploy_containers ) || echo -e "${RED}Operation failed or was aborted.${NC}" ;;
      3) ( cmd_start_containers ) || echo -e "${RED}Operation failed or was aborted.${NC}" ;;
      4) ( cmd_install_traffic_gen ) || echo -e "${RED}Operation failed or was aborted.${NC}" ;;
      5) ( cmd_full_wizard ) || echo -e "${RED}Wizard failed or was aborted.${NC}" ;;
      6) ( cmd_install_windows_cert ) || echo -e "${RED}Operation failed or was aborted.${NC}" ;;
      7) ( cmd_setup_windows_vm ) || echo -e "${RED}Operation failed or was aborted.${NC}" ;;
      8) ( cmd_show_status ) || echo -e "${RED}Operation failed or was aborted.${NC}" ;;
      9) ( cmd_update_containers ) || echo -e "${RED}Operation failed or was aborted.${NC}" ;;
      10) cmd_update || echo -e "${RED}Operation failed or was aborted.${NC}" ;;
      11) ( cmd_stop_containers ) || echo -e "${RED}Operation failed or was aborted.${NC}" ;;
      12|q|Q)
        echo "Goodbye!"
        exit 0
        ;;
      *)
        echo -e "${RED}Invalid option. Please select 1-12.${NC}"
        ;;
    esac
  done
}

# ============================================================
# ENTRY POINT
# Support direct invocation: ./proxmox-lab.sh <command>
# ============================================================

_migrate_config
case "${1:-}" in
  create-template)  cmd_create_template ;;
  deploy)           cmd_deploy_containers ;;
  start)            cmd_start_containers ;;
  stop)             cmd_stop_containers ;;
  install-traffic)  cmd_install_traffic_gen ;;
  status)           cmd_show_status ;;
  wizard)           cmd_full_wizard ;;
  update)              cmd_update ;;
  update-containers)   cmd_update_containers ;;
  windows-cert)        cmd_install_windows_cert ;;
  windows-setup)       cmd_setup_windows_vm ;;
  _cleanup)            cmd_system_cleanup ;;
  --version|-v)        echo "proxmox-lab.sh v${VERSION}" ;;
  "")                  _startup_version_check; main_menu ;;
  *)
    echo -e "${RED}Unknown command: $1${NC}"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  create-template      Create Alpine LXC template"
    echo "  deploy               Deploy lab containers"
    echo "  start                Start containers"
    echo "  stop                 Stop all running containers"
    echo "  install-traffic      Install traffic generators"
    echo "  status               Show container status"
    echo "  wizard               Full setup wizard"
    echo "  update-containers    Update packages on all running lab containers"
    echo "  update               Check for updates and self-patch"
    echo "  windows-cert         Install TLS cert on a Windows VM"
    echo "  windows-setup        Push traffic scripts to a Windows VM and configure scheduled tasks"
    echo "  --version            Show version"
    echo ""
    echo "Run without arguments for the interactive menu."
    exit 1
    ;;
esac
