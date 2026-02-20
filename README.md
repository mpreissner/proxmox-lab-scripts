# Proxmox Lab Scripts

An interactive shell script for deploying and managing a Proxmox LXC container-based security testing lab. Automates the creation of a realistic multi-site enterprise network with simulated traffic patterns for testing security solutions like Zscaler, CASB, DLP, and UEBA systems.

## What's New (v3.4.0)

**Workload selection menu** — the Deploy step now shows an interactive checkbox menu for each deployment group (Data Center and Branch) after the scope choice. Select any subset of profiles rather than always deploying the full fixed stack. Each selected profile gets a quantity prompt so you can deploy multiple instances of the same workload (e.g., three `fileserver` containers, two `developer` containers). Containers are numbered sequentially: `hq1-fileserver1`, `hq1-fileserver2`, `branch1-worker1`, etc.

CTID range minimum-count requirements and resource feasibility checks are now computed dynamically from the actual workload selections, rather than being hardcoded to 6 (HQ) and 5 (Branch).

The `install-traffic` profile-to-container mapping is now hostname-based rather than positional, so it works correctly with any combination of profiles and quantities.

---

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
- **Deploys Data Center and Branch network containers** with appropriate configurations — an interactive checkbox menu lets you select which profiles to deploy and how many of each; containers distribute across multiple Proxmox cluster nodes with auto-balanced or manual placement; supports linked clones (shared base disk, faster deploy) or full clones depending on storage type and topology
- **Generates realistic traffic patterns** driven by `lab-traffic.tsv` — a tab-separated data file that defines URLs, GenAI providers, prompts, and security test assignments per profile. Profile scripts are generated dynamically at install time from this file.
- **Simulates GenAI usage** by POSTing role-appropriate prompts to ChatGPT's web app endpoint — generating prompt capture events visible in Zscaler ZIA logs
- **Configures security tests** independently of normal traffic — DLP (network, GenAI prompt/file/image OCR), AV/malware, policy violations, UEBA anomalies
- **Manages Windows VMs** via a dedicated submenu: bulk-tags VMs for discovery, installs TLS inspection certificates (skip-if-current), pushes and version-checks traffic scripts, and configures scheduled tasks with profile selection

## Script

### `proxmox-lab.sh`

A single interactive menu covering the full lab lifecycle.

**Menu options:**
1. **Create Template** — create an Alpine LXC template
2. **Deploy Containers** — clone and configure lab containers
3. **Start Containers** — start stopped lab-managed containers
4. **Install Traffic Generator** — push traffic profiles to containers; includes an in-script profile viewer and security test toggle (enter `v` at the confirmation prompt)
5. **Full Setup Wizard** — runs steps 1 → 2 → 3 → 4 in sequence
6. **Windows Tools** — submenu for Windows VM management (see below)
7. **Show Status** — view all containers with running state and traffic gen status at a glance
8. **Update Container Packages** — run `apk update && apk upgrade` on all running lab containers in parallel
9. **Update Lab Script** — check GitHub for a newer version, show changelog, prompt to confirm, then self-patch the script in place and exit. Also downloads updated `setup-scheduled-tasks.ps1` and `lab-traffic.tsv` alongside the main script (`win-traffic.ps1` is generated from the TSV at push time and is not downloaded). On every interactive launch, the same check runs automatically before the menu appears.
10. **Stop Containers** — stop all running lab-managed containers
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
./proxmox-lab.sh update-containers
./proxmox-lab.sh update
./proxmox-lab.sh windows
```

**Config persistence:**

On first run, the script prompts for all values as usual. After completing any command, it offers to save the answers to `~/.proxmox-lab.conf`. On every subsequent run those values pre-populate all prompts — press Enter to accept, or type a new value to override. The config file survives script updates. The Full Setup Wizard auto-saves once at the end without prompting at each step.

Key saved values include node selection, network bridge, CT disk storage pool (`STORAGE`), image storage pool (`IMAGE_STORAGE`), VLAN IDs, CTID ranges, template ID, clone type (`CLONE_TYPE`), TLS certificate path, cron schedules, and `lab-traffic.tsv` path.

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
./proxmox-lab.sh deploy            # Step 2 — select workloads and clone containers
./proxmox-lab.sh start             # Step 3 — start containers
./proxmox-lab.sh install-traffic   # Step 4 — install traffic profiles
```

### Image Storage

During `create-template` (step 3b), the script prompts for the storage pool where the Alpine `.tar.xz` template image will be downloaded. Only pools with the `vztmpl` content type are listed. This is separate from the CT disk storage pool (step 3) — on most Proxmox hosts `local` is the correct choice for image storage. The selection is saved to `~/.proxmox-lab.conf` as `IMAGE_STORAGE`.

### TLS Inspection Certificate

If your network performs TLS inspection (e.g., Zscaler), copy your root CA certificate to the Proxmox host before running `create-template`:

```bash
scp /path/to/ZscalerRootCertificate.crt root@<proxmox-host>:/root/
```

During `create-template` (step 7), the script prompts for the certificate path on the host. If provided, the certificate is installed into the template via Alpine's `update-ca-certificates`, and every cloned container inherits it automatically. The path is saved to `~/.proxmox-lab.conf` for subsequent runs.

Zscaler offers a choice of using their built-in root certificate or uploading a custom one — either works. If you are not using TLS inspection, press Enter to skip.

To verify the certificate is trusted in a container after deployment:

```bash
pct exec 200 -- curl -sv https://www.google.com 2>&1 | grep -E "SSL|issuer|subject"
```

### Windows Tools

All Windows VM management is in the Windows Tools submenu (option 6) or via `./proxmox-lab.sh windows`. The submenu has four steps meant to be run in order on first setup:

**Step 1 — Tag Windows VMs**

Tags one or more VMs with `lab-windows` so they appear in all subsequent Windows Tools operations. The script shows all VMs across the cluster, marks VMs with 'win' in the name as candidates, and lets you select by number or `all`.

**Step 2 — Install TLS Certificate**

Installs the TLS inspection root CA (same `CERT_PATH` as for LXC containers) to the Windows Trusted Root store on all selected VMs. Skips VMs where the certificate thumbprint is already present — safe to re-run.

Requires the QEMU guest agent to be installed and running inside each Windows VM.

To verify in Windows: `certmgr.msc` → Trusted Root Certification Authorities → Certificates.

**Step 3 — Install / Update Traffic Generator Script**

Generates `win-traffic.ps1` dynamically from `lab-traffic.tsv` and pushes it to `C:\ProgramData\proxmox-lab\` on each selected VM. The `$SCRIPT_VERSION` field in the generated file encodes both the script version and a short TSV content hash — skips VMs that are already up to date, and re-pushes automatically when the TSV changes even without a script version bump.

`setup-scheduled-tasks.ps1` is downloaded automatically from GitHub the first time you enter the Windows Tools submenu if not already present alongside `proxmox-lab.sh`, and updated whenever you run `Update Lab Script` (option 9).

**Step 4 — Configure Scheduled Tasks**

Pushes `setup-scheduled-tasks.ps1` and runs it on each selected VM. Prompts for which profiles to install (office-worker, sales, developer, executive, threat — default: all). Existing lab tasks are always removed and recreated, so re-running with a different profile set removes orphaned tasks cleanly.

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

CTID ranges and VLAN IDs have no built-in defaults — they are entered at deploy time and saved to `~/.proxmox-lab.conf` for subsequent runs.

| Network | Available profiles | Default qty |
|---------|-------------------|-------------|
| Data Center | fileserver, webapp, email, monitoring, devops, database | 1 each (user-selectable) |
| BranchNet | office-worker, sales, developer, executive | 2 for office-worker, 1 for others (user-selectable) |

Profiles and quantities are chosen interactively at deploy time via the workload selection menu. Containers are named `hq1-<profile><n>` and `branch1-<profile><n>` (e.g., `hq1-fileserver1`, `branch1-worker2`).

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
| **devops** | npm, PyPI, GitHub, Docker Hub | npm, pip, git, GitHub Actions, Docker | ChatGPT |
| **database** | AWS RDS, Azure SQL, S3 | aws-sdk-java, Boto3, azsdk-python | — |
| **office-worker** | Microsoft 365, Slack, Google Docs, news, personal sites | Windows/Mac browser pool (Chrome, Edge, Firefox) | — |
| **sales** | LinkedIn, Salesforce, Zoom, HubSpot, Expedia | Mac browser pool (Safari, Chrome) | ChatGPT |
| **developer** | GitHub, StackOverflow, npm, PyPI, AWS Console | Mac/Linux browser pool (Chrome, Firefox) | ChatGPT |
| **executive** | WSJ, Bloomberg, FT, Reuters, Office 365, travel, Zoom | Mac Safari/Chrome pool | ChatGPT |

Server profiles emit role-appropriate SDK and tool user agents matching the software that would realistically generate each request. User profiles pick from a persona-specific browser UA pool once per run and use it consistently throughout, so all requests within a session appear to come from the same device.

### GenAI Traffic

GenAI-capable profiles (devops, developer, sales, executive) generate two types of GenAI activity:

**Browsing** — periodic GET requests to GenAI platform homepages, simulating a user navigating to an AI tool.

**Prompt submission** — POST requests to ChatGPT's web app endpoint (`chatgpt.com/backend-api/f/conversation`) with role-appropriate business prompts embedded in the request body across all four GenAI-capable profiles (devops, developer, sales, executive).

The server returns 401/403 (no valid session token). Zscaler inspects the outbound request body before the response arrives, so **prompt capture events fire in ZIA logs regardless of the server response**. The traffic appears as a real user interacting with a GenAI service.

Microsoft Copilot is excluded — it uses WebSockets which are incompatible with standard TLS inspection. Claude and Gemini are excluded due to session-authenticated endpoints that cannot produce realistic synthetic traffic without active sessions.

### Security Tests

Security tests are installed separately from normal traffic profiles and run on their own cron schedule. Each test is an independent script — it is "enabled" when its script file is present on the container.

The default test assignments are defined in `lab-traffic.tsv` and can be toggled per profile before deployment using the built-in profile viewer (enter `v` at the "Proceed with installation?" prompt during `install-traffic`).

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

### `lab-traffic.tsv`

All traffic data — URLs, GenAI providers, GenAI prompts, and security test assignments — lives in `lab-traffic.tsv` alongside `proxmox-lab.sh` on the Proxmox host. The file is auto-downloaded from GitHub on first `install-traffic` run if not present, and updated alongside the main script by `Update Lab Script` (option 9).

The file is tab-separated with four columns:

```
type        profile         value                           enabled
url         office-worker   salesforce.com                  yes
genai_provider  devops      chatgpt                         yes
genai_prompt    devops      What are the key differences... yes
security_test   devops      dlp-genai-image                 no
```

To customize traffic data, edit `lab-traffic.tsv` directly on the Proxmox host and re-run `install-traffic`. Changes take effect on the next `install-traffic` run — no container restart needed. The `enabled` column on every row lets you toggle individual URLs, prompts, or security tests on or off without deleting entries.

### In-Script Profile Viewer and Security Test Toggle

At the "Proceed with installation?" prompt during `install-traffic`, enter `v` to open the profile viewer:

- **Browse any profile** — see its URLs, GenAI providers, prompts, and security test on/off state
- **Toggle security tests** — flip individual tests on or off; changes write back to `lab-traffic.tsv` immediately and are reflected in the upcoming install

This is the recommended way to review and adjust security test posture before deploying to a new environment.

### Custom CTID Ranges
```bash
./proxmox-lab.sh deploy
# Select Data Center only, enter 300-310 as CTID range
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

To disable a specific security test on a container without reinstalling everything:
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

# Test profile manually (use bash explicitly — container default shell is ash)
pct exec <CTID> -- bash /opt/traffic-gen/traffic-gen.sh <profile>
```

### Network issues
```bash
# Check network configuration
pct config <CTID> | grep net0

# Test connectivity from container
pct exec <CTID> -- ping -c 3 8.8.8.8
pct exec <CTID> -- curl -I https://google.com
```

### Manually testing inside a container

The default shell inside Alpine containers is BusyBox `ash`. The traffic generator scripts use bash-specific syntax — always enter bash explicitly when sourcing or running scripts manually:

```bash
pct exec <CTID> -- bash
```

---

## Safety Notes

### Traffic Generation
- Volume is intentionally low (~1-2 requests/hour per domain)
- Will NOT trigger rate limits or blocklists on normal traffic
- Safe for production internet connections
- EICAR test file is industry-standard, non-malicious test payload
- GenAI prompt submission uses real web app endpoints with no valid session token — server returns 401/403, but the outbound request body is inspected by Zscaler as intended
- GenAI DLP tests POST to real AI APIs with no valid key — server returns 401, but the outbound request is inspected by Zscaler as intended
- `dlp-genai-image` installs ImageMagick (~10 MB) on the container when enabled

### Storage Requirements
- Template: ~50-100 MB
- Full clone per container: ~200-300 MB (independent copy of template disk)
- Linked clone per container: ~100 MB delta (base disk shared with template)
- Total for 11 containers + template — full clones: ~2.5-3.5 GB; linked clones: ~1.2-1.5 GB
- Storage pool must support `rootdir` content type; must be snapshot-capable (`lvmthin`, `zfspool`, Ceph RBD) to use linked clones

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
