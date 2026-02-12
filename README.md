# Proxmox Lab Scripts

An interactive shell script for deploying and managing a Proxmox LXC container-based security testing lab. Automates the creation of a realistic multi-site enterprise network with simulated traffic patterns for testing security solutions like Zscaler, CASB, DLP, and UEBA systems.

## Lab Architecture

**Important:** This lab was developed with a specific network topology in mind:

- **Router Configuration:** The lab router has existing IPsec/GRE tunnels to two separate Zscaler data centers
- **Location Simulation:** HQ and Branch subnets are treated as separate physical locations in Zscaler
- **DNS Resolution:** DNS for both subnets is handled by Zscaler Trusted Resolver, specified to containers via DHCP
- **Traffic Flow:** All container traffic egresses through the Zscaler cloud via the appropriate tunnel

This architecture allows realistic simulation of a multi-site enterprise environment with cloud security controls.

## Overview

Provides a complete workflow for building a multi-container lab environment that generates realistic web traffic patterns mimicking real-world enterprise scenarios.

### What It Does

- **Creates Alpine LXC templates** with pre-configured utilities
- **Deploys HQ and Branch network containers** with appropriate configurations
- **Generates realistic traffic patterns** for different user/server profiles
- **Simulates security events** (DLP triggers, malware downloads, policy violations, UEBA anomalies)

## Script

### `proxmox-lab.sh`

A single interactive menu covering the full lab lifecycle.

**Menu options:**
1. **Create Template** — create an Alpine LXC template
2. **Deploy Containers** — clone and configure lab containers
3. **Start Containers** — start stopped lab-managed containers
4. **Install Traffic Generator** — push traffic profiles to containers
5. **Stop Containers** — stop all running lab-managed containers
6. **Show Status** — view all containers with running state and traffic gen status at a glance
7. **Full Setup Wizard** — runs steps 1 → 2 → 3 → 4 in sequence
8. **Update** — check GitHub for a newer version, show changelog, and self-patch the script in place
9. **Exit**

**Interactive menu:**
```bash
./proxmox-lab.sh
```

**Direct command invocation** (useful for scripting or re-running a single step):
```bash
./proxmox-lab.sh create-template
./proxmox-lab.sh deploy
./proxmox-lab.sh start
./proxmox-lab.sh stop
./proxmox-lab.sh install-traffic
./proxmox-lab.sh status
./proxmox-lab.sh wizard
./proxmox-lab.sh update
```

**Config persistence:**

On first run, the script prompts for all values as usual. After completing any command, it offers to save the answers to `~/.proxmox-lab.conf`. On every subsequent run those values pre-populate all prompts — press Enter to accept, or type a new value to override. The config file survives script updates. The Full Setup Wizard auto-saves once at the end without prompting at each step.

---

## Quick Start

### Prerequisites
- Proxmox VE 8.x or higher
- Root or sudo access
- Network bridge configured (default: vmbr0)
- Local storage available (local-lvm or local-zfs)

### Full wizard (recommended)

Run all four setup steps in sequence:

```bash
./proxmox-lab.sh wizard
```

The wizard walks through all four steps in sequence, prompting for input at each stage, then saves your settings automatically.

### Step by step

Each step can also be run individually:

```bash
./proxmox-lab.sh create-template   # Step 1 — create Alpine template
./proxmox-lab.sh deploy            # Step 2 — clone 11 containers
./proxmox-lab.sh start             # Step 3 — start containers
./proxmox-lab.sh install-traffic   # Step 4 — install traffic profiles
```

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

---

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

---

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

### Traffic Profiles

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

### Traffic Volume
- ~20-40 requests per day per domain
- Randomized delays (5-60 seconds)
- Realistic user agent rotation
- Business hours enforcement for user profiles

---

## Customization

### Custom CTID Ranges
```bash
./proxmox-lab.sh deploy
# Select HQ only, enter 300 as starting CTID
```

### Custom Traffic Intensity
```bash
./proxmox-lab.sh install-traffic
# Select "Custom" intensity, enter cron schedules
```

### Custom Profile Assignment
```bash
./proxmox-lab.sh install-traffic
# Select "Custom selection"
# Example: 300:fileserver,301:webapp,320:developer
```

---

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

---

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

---

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
