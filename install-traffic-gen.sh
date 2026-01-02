#!/bin/bash
# install-traffic-gen.sh - Install traffic generation framework (Interactive)

set -e

# Colors for better UX
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}=========================================="
echo "Traffic Generator Installation"
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

# Profile descriptions
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

# Default profile mapping
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

# 1. Container Selection
echo -e "${BLUE}1. Container Selection${NC}"
echo "Detecting running containers..."

# Get list of running containers
RUNNING_CONTAINERS=$(pct list | awk 'NR>1 {print $1}' | sort -n)

if [ -z "$RUNNING_CONTAINERS" ]; then
  echo -e "${RED}No running containers found!${NC}"
  echo "Please start containers first with: ./start-containers.sh"
  exit 1
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
    # Auto-detect based on default mapping
    echo "Auto-detecting containers..."
    for CTID in $RUNNING_CONTAINERS; do
      if [ -n "${DEFAULT_PROFILES[$CTID]}" ]; then
        TARGET_PROFILES[$CTID]="${DEFAULT_PROFILES[$CTID]}"
      fi
    done

    if [ ${#TARGET_PROFILES[@]} -eq 0 ]; then
      echo -e "${YELLOW}No containers match default CTID ranges (200-205, 220-224)${NC}"
      echo "Please use custom selection option"
      exit 1
    fi
    ;;

  2)
    # HQ range
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
    # Branch range
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
    # Custom selection
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
      ctid=$(echo $ctid | xargs)  # trim whitespace
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
  exit 1
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
  1)
    INSTALL_FRAMEWORK=true
    INSTALL_PROFILES=true
    ENABLE_CRON=true
    ;;
  2)
    INSTALL_FRAMEWORK=true
    INSTALL_PROFILES=true
    ENABLE_CRON=false
    ;;
  3)
    INSTALL_FRAMEWORK=false
    INSTALL_PROFILES=true
    ENABLE_CRON=false
    ;;
esac

# Configuration Summary
echo ""
echo -e "${BLUE}=========================================="
echo "Installation Summary"
echo -e "==========================================${NC}"
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
  exit 0
fi

# Installation begins
echo ""
echo -e "${GREEN}Starting installation...${NC}"

# Function to install framework and utilities
install_framework() {
  local ctid=$1

  # Create main traffic generator script
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

  # Create utility: business hours check
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

  # Create utility: random timing
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

# Function to install profile
install_profile() {
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

# Install on each container
for CTID in "${!TARGET_PROFILES[@]}"; do
  PROFILE="${TARGET_PROFILES[$CTID]}"

  echo ""
  echo -e "${CYAN}Configuring CT ${CTID} (${PROFILE})...${NC}"

  # Check if container is running
  if ! pct status $CTID | grep -q "running"; then
    echo -e "${YELLOW}  ⚠ Container not running, skipping${NC}"
    continue
  fi

  # Install framework
  if $INSTALL_FRAMEWORK; then
    echo "  → Installing framework..."
    install_framework $CTID
  fi

  # Install profile
  if $INSTALL_PROFILES; then
    echo "  → Installing ${PROFILE} profile..."
    install_profile $CTID $PROFILE
  fi

  # Set up cron
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

# Final summary
echo ""
echo -e "${GREEN}=========================================="
echo "✓ Installation Complete"
echo -e "==========================================${NC}"
echo ""
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
  echo "  Run this script again and choose 'Full install' mode"
fi
