# Proxmox Lab Scripts

Interactive shell scripts for deploying and managing Proxmox LXC container-based security testing labs. These scripts automate the creation of realistic network environments with simulated traffic patterns for testing security solutions like Zscaler, CASB, DLP, and UEBA systems.

## Lab Architecture

**Important:** This lab was developed with a specific network topology in mind:

- **Router Configuration:** The lab router has existing IPsec/GRE tunnels to two separate Zscaler data centers
- **Location Simulation:** HQ and Branch subnets are treated as separate physical locations in Zscaler
- **DNS Resolution:** DNS for both subnets is handled by Zscaler Trusted Resolver, specified to containers via DHCP
- **Traffic Flow:** All container traffic egresses through the Zscaler cloud via the appropriate tunnel

This architecture allows realistic simulation of a multi-site enterprise environment with cloud security controls.

## Overview

This collection provides a complete workflow for building a multi-container lab environment that generates realistic web traffic patterns mimicking real-world enterprise scenarios.

### What It Does

- **Creates Alpine LXC templates** with pre-configured utilities
- **Deploys HQ and Branch network containers** with appropriate configurations
- **Generates realistic traffic patterns** for different user/server profiles
- **Simulates security events** (DLP triggers, malware downloads, policy violations, UEBA anomalies)

## Scripts

### 1. `create-template.sh`
Creates a base Alpine Linux LXC template with traffic generation framework.

**Features:**
- Interactive configuration wizard
- Auto-detects latest Alpine version
- Installs essential packages (curl, wget, python3, jq, cron)
- Supports local storage options (local-lvm, local-zfs, custom)

**Usage:**
```bash
./create-template.sh
```

---

### 2. `deploy-container.sh`
Clones and deploys lab containers from the template.

**Features:**
- Deploys 11 total containers (6 HQ servers, 5 Branch users)
- Flexible CTID and VLAN configuration
- Selective deployment (all, HQ only, Branch only)
- Auto-detects and validates templates
- Skips existing containers

**Container Types:**

**HQ ServerNet (6 containers):**
- `hq-fileserver` - File server with cloud sync
- `hq-webapp` - Web application server
- `hq-email` - Email relay server
- `hq-monitoring` - Monitoring and package updates (512MB)
- `hq-devops` - DevOps build server (512MB)
- `hq-database` - Database server

**Branch UserNet (5 containers):**
- `branch-worker1/2` - Office workers
- `branch-sales` - Sales representative
- `branch-dev` - Developer workstation (512MB)
- `branch-exec` - Executive (UEBA target)

**Usage:**
```bash
./deploy-container.sh
```

---

### 3. `install-traffic-gen.sh`
Installs traffic generation profiles on containers.

**Features:**
- Auto-detect running containers
- Multiple installation scopes (all, HQ, Branch, custom)
- Traffic intensity levels (light, normal, heavy, custom)
- Installation modes (full, framework only, update profiles)
- Displays domain information for each profile

**Traffic Profiles:**

| Profile | Domains/Services | Security Tests |
|---------|-----------------|----------------|
| **fileserver** | OneDrive, Dropbox, S3 | DLP (SSN/CCN exfiltration) |
| **webapp** | Stripe API, CDN services | Certificate validation |
| **email** | Office 365, Gmail, SpamHaus | Email security |
| **monitoring** | Ubuntu repos, Datadog, Docker Hub | Package management |
| **devops** | npm, PyPI, GitHub, Docker | EICAR malware test |
| **database** | AWS RDS, Azure SQL, S3 | Cloud backup |
| **office-worker** | Salesforce, Slack, Google Docs, social media | Policy violations |
| **sales** | LinkedIn, Salesforce, Zoom, travel sites | SaaS heavy usage |
| **developer** | GitHub, StackOverflow, AWS Console | Developer tools |
| **executive** | Office 365, WSJ, Bloomberg | UEBA (after-hours email) |

**Traffic Intensity:**
- **Light:** Servers every 30 min, Office every 10 min
- **Normal:** Servers every 15 min, Office every 5 min (default)
- **Heavy:** Servers every 5 min, Office every 2 min

**Usage:**
```bash
./install-traffic-gen.sh
```

---

### 4. `start-containers.sh`
Manages container startup with intelligent status tracking.

**Features:**
- Shows current status of all containers
- Multiple selection methods (all, HQ, Branch, specific, range)
- Parallel or sequential startup modes
- Optional boot wait period
- Post-startup verification

**Usage:**
```bash
./start-containers.sh
```

## Quick Start

### Prerequisites
- Proxmox VE 8.x or higher
- Root or sudo access
- Network bridge configured (default: vmbr0)
- Local storage available (local-lvm or local-zfs)

### Installation Workflow

1. **Create the template:**
   ```bash
   ./create-template.sh
   ```
   - Choose template ID (e.g., 150)
   - Select storage and network settings
   - Wait for template creation (~2-3 minutes)

2. **Deploy containers:**
   ```bash
   ./deploy-container.sh
   ```
   - Select source template
   - Configure VLANs and CTID ranges
   - Deploy HQ and/or Branch containers

3. **Start containers:**
   ```bash
   ./start-containers.sh
   ```
   - Select containers to start
   - Choose parallel startup for speed

4. **Install traffic generators:**
   ```bash
   ./install-traffic-gen.sh
   ```
   - Select traffic intensity
   - Choose installation mode
   - Profiles auto-assigned based on container role

### Verification

View traffic generation logs:
```bash
pct exec 200 -- tail -f /var/log/messages
pct exec 220 -- tail -f /var/log/messages
```

Check cron schedules:
```bash
pct exec 200 -- crontab -l
```

Manual traffic generation:
```bash
pct exec 200 -- /opt/traffic-gen/traffic-gen.sh fileserver
```

## Default Configuration

### Network Layout

| Network | VLAN | CTID Range | Container Count |
|---------|------|------------|-----------------|
| HQServerNet | 200 | 200-205 | 6 servers |
| BranchNet | 201 | 220-224 | 5 users |

### Resource Allocation

| Container Type | Memory | CPU Cores |
|---------------|--------|-----------|
| Standard | 256 MB | 1 |
| Heavy (monitoring, devops, dev) | 512 MB | 1 |

### Traffic Schedules

| Profile Type | Schedule | Active Hours |
|-------------|----------|--------------|
| Server profiles | Every 15 min | 24/7 |
| Office profiles | Every 5 min | M-F 8am-6pm |

## Traffic Patterns

### Business Hours Simulation
- **Morning (8-10am):** Email checks, news browsing
- **Work hours (10am-12pm, 1pm-6pm):** SaaS applications, collaboration tools
- **Lunch (12-1pm):** Personal browsing, shopping, social media attempts
- **After hours:** Minimal activity, UEBA anomalies (executive profile)

### Security Event Simulation
- **DLP Triggers:** 10% chance of sensitive data upload (fileserver)
- **Malware Download:** EICAR test file every ~30 runs (devops)
- **Policy Violations:** Social media, unauthorized file sharing (office-worker)
- **UEBA Anomalies:** After-hours access patterns (executive)

### Traffic Volume
- ~20-40 requests per day per domain
- Randomized delays (5-60 seconds)
- Realistic user agent rotation
- Business hours enforcement for user profiles

## Customization

### Custom CTID Ranges
All scripts support custom CTID ranges:
```bash
# Deploy HQ starting at CTID 300
./deploy-container.sh
# Select HQ only, enter 300 as starting CTID
```

### Custom Traffic Intensity
```bash
./install-traffic-gen.sh
# Select "Custom" intensity
# Enter custom cron schedules
```

### Custom Profile Assignment
```bash
./install-traffic-gen.sh
# Select "Custom selection"
# Example: 300:fileserver,301:webapp,320:developer
```

## Troubleshooting

### Container won't start
```bash
# Check container status
pct status <CTID>

# View container config
pct config <CTID>

# Check logs
pct exec <CTID> -- dmesg
```

### Traffic not generating
```bash
# Verify cron is running
pct exec <CTID> -- rc-status

# Check cron schedule
pct exec <CTID> -- crontab -l

# Test profile manually
pct exec <CTID> -- /opt/traffic-gen/traffic-gen.sh <profile>
```

### Network issues
```bash
# Check network configuration
pct config <CTID> | grep net0

# Test connectivity from container
pct exec <CTID> -- ping -c 3 8.8.8.8
pct exec <CTID> -- curl -I https://google.com
```

## Safety Notes

### Traffic Generation
- Volume is intentionally low (~1-2 requests/hour per domain)
- Will NOT trigger rate limits or blocklists
- Safe for production internet connections
- EICAR test file is industry-standard, non-malicious test payload

### Storage Requirements
- Each container: ~100-200 MB
- Template: ~50 MB
- Total for 11 containers + template: ~2-3 GB

### Network Impact
- Minimal bandwidth usage (<1 Mbps aggregate)
- No broadcast/multicast traffic
- VLAN isolation supported

## Use Cases

- **Security Product Testing:** CASB, SWG, DLP, UEBA validation
- **Policy Development:** Test URL filtering, application control rules
- **Training Labs:** Demonstrate security product capabilities
- **Integration Testing:** Validate logging, alerting, blocking mechanisms
- **Compliance Validation:** Verify data protection controls

## Contributing

Contributions welcome! Areas for enhancement:
- Additional traffic profiles (VoIP, streaming, gaming)
- More security test scenarios
- Support for VMs in addition to LXC containers
- Integration with external traffic generators
- Automated testing frameworks

## License

MIT License - Feel free to use, modify, and distribute.

## Author

Created for building realistic security testing labs on Proxmox VE.

## Acknowledgments

- Traffic patterns based on real-world enterprise usage
- Security scenarios aligned with common compliance frameworks
- Built with feedback from security engineering teams
