# Proxmox Lab Scripts

An interactive shell script for deploying and managing a Proxmox LXC container-based security testing lab. Automates the creation of a realistic multi-site enterprise network with simulated traffic patterns for testing security solutions like Zscaler, CASB, DLP, and UEBA systems.

## Lab Architecture

**Important:** This lab was developed with a specific network topology in mind:

- **Router Configuration:** The lab router has existing IPsec/GRE tunnels to two separate Zscaler data centers
- **Location Simulation:** Data Center and Branch subnets are treated as separate physical locations in Zscaler
- **DNS Resolution:** DNS for both subnets is handled by Zscaler Trusted Resolver, specified to containers via DHCP
- **Traffic Flow:** All container traffic egresses through the Zscaler cloud via the appropriate tunnel

This architecture allows realistic simulation of a multi-site enterprise environment with cloud security controls.

## Overview

Provides a complete workflow for building a multi-container lab environment that generates realistic web traffic patterns mimicking real-world enterprise scenarios.

### What It Does

- **Creates Alpine LXC templates** with pre-configured utilities
- **Deploys Data Center and Branch network containers** with appropriate configurations, distributed across multiple Proxmox cluster nodes with auto-balanced or manual placement
- **Generates realistic traffic patterns** for different user/server profiles, including GenAI platform usage
- **Configures security tests** independently of normal traffic — DLP (network, GenAI prompt/file/image OCR), AV/malware, policy violations, UEBA anomalies
- **Installs TLS inspection certificates on Windows VMs** via QEMU guest agent, cluster-aware across all Proxmox nodes

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
9. **Install Windows VM Certificate** — install a TLS inspection root CA on a Windows VM via QEMU guest agent
10. **Setup Windows VM Traffic Generator** — push `win-traffic.ps1` and `setup-scheduled-tasks.ps1` to a Windows VM and register scheduled tasks
11. **Exit**

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
./proxmox-lab.sh windows-cert
./proxmox-lab.sh windows-setup
```

**Config persistence:**

On first run, the script prompts for all values as usual. After completing any command, it offers to save the answers to `~/.proxmox-lab.conf`. On every subsequent run those values pre-populate all prompts — press Enter to accept, or type a new value to override. The config file survives script updates. The Full Setup Wizard auto-saves once at the end without prompting at each step.

---

## Quick Start

### Prerequisites
- Proxmox VE 8.x or higher
- Root or sudo access
- Network bridge configured (default: vmbr0)
- Local storage available (local-lvm or local-zfs); shared NFS/Ceph storage supported for multi-node clusters
- TLS inspection root CA certificate on the Proxmox host, if your network performs HTTPS inspection (see below)
- Multi-node cluster: node IPs resolvable via `/etc/hosts` or present in `/etc/pve/corosync.conf` (DNS not required)
- Windows VM certificate install: QEMU guest agent installed and running inside the Windows VM

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

### TLS Inspection Certificate

If your network performs TLS inspection (e.g., Zscaler), copy your root CA certificate to the Proxmox host before running `create-template`:

```bash
scp /path/to/ZscalerRootCertificate.crt root@<proxmox-host>:/root/
```

During step 1 (`create-template`), the script prompts for the certificate path on the host. If provided, the certificate is installed into the template via Alpine's `update-ca-certificates`, and every cloned container inherits it automatically. The path is saved to `~/.proxmox-lab.conf` for subsequent runs.

Zscaler offers a choice of using their built-in root certificate or uploading a custom one — either works. If you are not using TLS inspection, press Enter to skip.

To verify the certificate is trusted in a container after deployment:

```bash
pct exec 200 -- curl -sv https://www.google.com 2>&1 | grep -E "SSL|issuer|subject"
```

### Windows VM Certificate

To install the TLS inspection certificate on a Windows VM, ensure the QEMU guest agent is installed and running inside Windows, then run:

```bash
./proxmox-lab.sh windows-cert
```

The script discovers all running VMs across the cluster, prompts for the target VM ID, and installs the certificate to the Windows Trusted Root Certification Authorities store via PowerShell through the QEMU guest agent. The same `CERT_PATH` used for LXC containers is reused — no separate copy is needed. The VM ID is saved to `~/.proxmox-lab.conf` for subsequent runs.

To verify in Windows after installation:
- Run `certmgr.msc` → Trusted Root Certification Authorities → Certificates
- Look for the Zscaler root CA entry

### Windows Traffic Generation

`win-traffic.ps1` and `setup-scheduled-tasks.ps1` are companion scripts for Windows VMs. To deploy them automatically, copy both files to the Proxmox host (e.g., `/root/`) and run:

```bash
./proxmox-lab.sh windows-setup
```

The script pushes both files to `C:\ProgramData\proxmox-lab\` on the target VM via QEMU guest agent and runs `setup-scheduled-tasks.ps1` to register M-F scheduled tasks for all five traffic profiles. The VM ID and script paths are saved to `~/.proxmox-lab.conf` for subsequent runs.

To verify after setup, open Task Scheduler on the Windows VM and check for the registered lab tasks.

### Verification

View traffic generation logs:
```bash
pct exec 200 -- tail -f /var/log/messages
pct exec 220 -- tail -f /var/log/messages
```

Check cron schedules (traffic + security tests):
```bash
pct exec 200 -- crontab -l
```

Manual traffic generation:
```bash
pct exec 200 -- /opt/traffic-gen/traffic-gen.sh fileserver
```

Run all security tests manually:
```bash
pct exec 200 -- /opt/traffic-gen/run-security-tests.sh
```

Run a single security test manually:
```bash
pct exec 224 -- bash /opt/traffic-gen/security-tests/ueba.sh
pct exec 200 -- bash /opt/traffic-gen/security-tests/dlp-network.sh
```

---

## Default Configuration

### Network Layout

| Network | VLAN | CTID Range | Container Count |
|---------|------|------------|-----------------|
| Data Center | 200 | 200-205 | 6 servers |
| BranchNet | 201 | 220-224 | 5 users |

### Resource Allocation

| Container Type | Memory | CPU Cores |
|---------------|--------|-----------|
| Standard | 256 MB | 1 |
| Heavy (monitoring, devops, dev) | 512 MB | 1 |

### Traffic Schedules

| Cron | Default Schedule | Active Hours |
|------|-----------------|--------------|
| Server profiles | Every 15 min | 24/7 |
| Office profiles | Every 5 min | M-F 8am-6pm |
| Security tests | Every 30 min | 24/7 (UEBA script self-limits to after-hours) |

---

## Traffic Patterns

### Business Hours Simulation
- **Morning (8-10am):** Email checks, news browsing
- **Work hours (10am-12pm, 1pm-6pm):** SaaS applications, collaboration tools, GenAI assistants
- **Lunch (12-1pm):** Personal browsing, shopping, social media attempts
- **After hours:** Minimal activity (UEBA test fires independently if enabled)

### Traffic Profiles

| Profile | Domains/Services | User Agent | GenAI |
|---------|-----------------|-----------|-------|
| **fileserver** | OneDrive, Dropbox, S3 | OneDrive Sync, Dropbox, aws-cli | — |
| **webapp** | Stripe API, CDN services, OCSP | Stripe-Node, WebServer, OpenSSL, aws-cli | — |
| **email** | Office 365, Gmail, SpamHaus, ClamAV | Exchange Server, Postfix, SpamAssassin, ClamAV | — |
| **monitoring** | Ubuntu repos, Datadog, New Relic, Docker Hub, GitHub | Debian APT, Datadog Agent, NewRelic, Docker, GitHub Actions | — |
| **devops** | npm, PyPI, GitHub, Docker Hub | npm, pip, git, GitHub Actions, Docker | Browse + API call |
| **database** | AWS RDS, Azure SQL, S3 | aws-sdk-java, Boto3, azsdk-python | — |
| **office-worker** | Salesforce, Slack, Google Docs, news | Windows/Mac browser pool (Chrome, Edge, Firefox) | — |
| **sales** | LinkedIn, Salesforce, Zoom, travel | Mac browser pool (Safari, Chrome) | Browse + API call |
| **developer** | GitHub, StackOverflow, npm, PyPI, AWS Console | Mac/Linux browser pool; git, npm, pip, Docker for tool calls | Browse + API call |
| **executive** | Office 365, WSJ, Bloomberg, Zoom | Mac Safari pool | Browse + API call |

Server profiles send role-appropriate SDK and tool user agents matching the software that would realistically generate each request. User profiles pick from a persona-specific browser UA pool once per run and use it consistently throughout, so all requests within a session appear to come from the same device.

GenAI browsing visits ChatGPT, Claude, Gemini, HuggingFace, Perplexity, and Poe. API calls submit business-context prompts to the HuggingFace anonymous inference API. Microsoft Copilot is excluded (WebSockets, incompatible with standard TLS inspection).

### Security Tests

Security tests are installed separately from normal traffic profiles and run on their own cron. Enabling or disabling a test is done during Install Traffic Generator (step 4) and takes effect immediately — no container restart needed.

| Test | Category | What It Generates |
|------|----------|-------------------|
| `eicar` | AV | EICAR test file download |
| `dlp-network` | DLP | POST with fake SSN + CCN to HTTPS endpoint |
| `dlp-genai-prompt` | DLP | JSON prompt with PII to OpenAI/Anthropic/Google API |
| `dlp-genai-file` | DLP | Multipart document upload with PII to AI file API |
| `dlp-genai-image` | DLP OCR | ImageMagick-rendered PNG with PII to AI vision API |
| `policy-violation` | Policy | HTTP access to Dropbox, WeTransfer, Mega, Box |
| `ueba` | UEBA | After-hours O365, Teams, SharePoint access |

**How GenAI DLP tests work:** The tests POST to real AI API endpoints (OpenAI, Anthropic, Google Gemini) with no valid API key. The server returns 401. Zscaler DLP inspects the outbound request body before the response arrives, so the DLP trigger fires on the request payload regardless. The traffic appears as a real user attempting to use a ChatGPT or Claude API.

**Default test assignments by profile:**

| Profile | Default security tests |
|---------|----------------------|
| fileserver | dlp-network |
| devops | eicar, dlp-genai-prompt, dlp-genai-file, dlp-genai-image |
| developer | eicar, dlp-genai-prompt, dlp-genai-file |
| office-worker | policy-violation, dlp-genai-prompt |
| sales | policy-violation, dlp-genai-prompt, dlp-genai-file |
| executive | ueba, dlp-genai-prompt |
| All others | none |

### Traffic Volume
- ~20-40 requests per day per domain
- Randomized delays (5-60 seconds)
- Role-appropriate user agents: SDK/tool strings for server profiles, persona-specific browser pools for user profiles
- Business hours enforcement for user profiles

---

## Customization

### Custom CTID Ranges
```bash
./proxmox-lab.sh deploy
# Select Data Center only, enter 300 as starting CTID
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

### Custom Security Tests
```bash
./proxmox-lab.sh install-traffic
# Step 4 → Custom selection
# Choose which tests to enable per container
```

To disable a specific test on a container without reinstalling everything:
```bash
pct exec <CTID> -- rm /opt/traffic-gen/security-tests/eicar.sh
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
- Will NOT trigger rate limits or blocklists on normal traffic
- Safe for production internet connections
- EICAR test file is industry-standard, non-malicious test payload
- GenAI DLP tests POST to real AI APIs with no valid key — server returns 401, but the outbound request is inspected by Zscaler as intended
- `dlp-genai-image` installs ImageMagick (~10 MB) on the container when enabled

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
