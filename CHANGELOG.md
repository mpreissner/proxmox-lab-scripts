# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.2] - 2026-02-13

### Changed
- "HQ ServerNet" renamed to "Data Center" throughout all UI labels, prompts, and documentation; internal variable names and container hostnames are unchanged

## [1.2.1] - 2026-02-13

### Fixed
- Node enumeration in `create-template` always fell back to "(Unable to detect nodes)" because `jq` is not installed on Proxmox hosts; replaced with `python3` JSON parsing, which is always available on PVE

## [1.2.0] - 2026-02-13

### Added
- TLS inspection certificate support in `create-template`: optional prompt for a root CA certificate path on the Proxmox host; if provided, the certificate is installed into the template via Alpine's `update-ca-certificates` so all cloned containers inherit it automatically; `CERT_PATH` persisted to `~/.proxmox-lab.conf`
- Security test framework: dedicated scripts in `/opt/traffic-gen/security-tests/` on each container, dispatched by `run-security-tests.sh` on its own cron schedule (`CRON_SECURITY`, default `*/30 * * * *`)
- Seven security test types: `eicar` (AV), `dlp-network` (POST fake SSN/CCN), `dlp-genai-prompt` (PII embedded in AI API prompt), `dlp-genai-file` (document upload with PII to AI file API), `dlp-genai-image` (PNG with PII rendered via ImageMagick to AI vision API, tests OCR DLP), `policy-violation` (access to blocked personal cloud apps), `ueba` (after-hours access simulation)
- Security test submenu in Install Traffic Generator (step 4): recommended defaults per profile, all tests, custom per-test selection, or skip
- GenAI traffic in `executive`, `sales`, `developer`, and `devops` profiles: `genai_browse()` visits public ChatGPT/Claude/Gemini/HuggingFace/Perplexity/Poe pages; `genai_api_call()` submits business-context prompts to HuggingFace anonymous inference API
- `genai.sh` utility installed to `/opt/traffic-gen/utils/` on all containers; includes 12 realistic business prompts
- `CRON_SECURITY` persisted to `~/.proxmox-lab.conf`
- ImageMagick auto-installed on containers when `dlp-genai-image` test is selected
- DLP tests target real AI API endpoints (OpenAI, Anthropic, Google Gemini) — requests are inspected by Zscaler regardless of 401 response; no valid API keys are used or required

### Changed
- Embedded security violations removed from profile scripts; profiles now generate clean traffic only — all security events are controlled via the security test framework
- `executive` profile: UEBA after-hours behaviour moved to `security-tests/ueba.sh`; `executive.sh` now exits cleanly outside business hours
- `fileserver` profile: network DLP POST moved to `security-tests/dlp-network.sh`
- `devops` profile: EICAR download moved to `security-tests/eicar.sh`
- `office-worker` profile: Dropbox policy violation moved to `security-tests/policy-violation.sh`
- GenAI browsing avoids Microsoft Copilot (uses WebSockets, incompatible with standard TLS inspection)

### Fixed
- `dlp-genai-file.sh` and `dlp-genai-image.sh` used `mktemp` with file extension suffixes (e.g. `XXXXXX.txt`), which Alpine busybox `mktemp` does not support; `dlp-genai-file` now uses a plain `mktemp` template, `dlp-genai-image` uses PID-based filenames to preserve the `.png` extension ImageMagick requires

### Removed
- `create-template.sh`, `deploy-container.sh`, `start-containers.sh`, and `install-traffic-gen.sh` — standalone scripts that duplicated functionality already in `proxmox-lab.sh`; `proxmox-lab.sh` is now the sole entry point

## [1.1.1] - 2026-02-12

### Fixed
- Menu options 4 and 5 were swapped: Install Traffic Generator moved to option 4, Stop Containers moved to option 5, so the Full Setup Wizard's "steps 1 → 2 → 3 → 4" reference is accurate

## [1.1.0] - 2026-02-12

### Added
- Config persistence via `~/.proxmox-lab.conf`: saved on first successful run, silently pre-populates all prompts on subsequent runs; user can override any value or skip saving
- `save_config()` / `_maybe_save_config()`: full wizard auto-saves once at the end; individual commands prompt once after completion
- `pick_storage()` short-circuits when STORAGE is already saved, showing current value with a change prompt
- `lab-managed` tag applied to every container deployed by `cmd_deploy_containers` via `pct set --tags lab-managed`
- `cmd_stop_containers`: stops all running `lab-managed` tagged containers in parallel; respects tag scope (ignores template and unmanaged containers); menu option 4, CLI command `stop`

### Fixed
- `((var++))` with `set -e` exits the script when the counter starts at 0 (arithmetic expansion returns the old value, which is 0/false); changed `SUCCESS_COUNT`, `FAILED_COUNT`, and two `offset` counters in `cmd_start_containers` and `cmd_install_traffic_gen` to use pre-increment `((++var))`
- `mkdir -p /opt/traffic-gen/{profiles,domains,utils}` inside Alpine `sh` (busybox ash) created one directory literally named `{profiles,domains,utils}` instead of three, because ash does not support brace expansion; expanded to three explicit `mkdir -p` calls

### Changed
- Menu renumbered: Stop Containers added as option 4; Install Traffic Generator → 5; Show Status → 6; Full Setup Wizard → 7; Update → 8; Exit → 9
- `cmd_start_containers` now filters the container list to `lab-managed` tagged containers only, preventing attempts to start the template or unmanaged containers
- All prompts in `cmd_create_template`, `cmd_deploy_containers`, `cmd_start_containers`, and `cmd_install_traffic_gen` now use saved config values as defaults

## [1.0.0] - 2026-02-12

### Added
- `proxmox-lab.sh` consolidated interactive tool combining all four original scripts into a single entry point
- Interactive main menu with numbered options
- Full Setup Wizard running steps 1 → 2 → 3 → 4 in sequence
- Show Status command displaying container state and traffic generator status at a glance
- Direct command invocation support (`./proxmox-lab.sh <command>`) for scripting and re-running individual steps
- Domain lists for `office-worker` and `executive` traffic profiles (20 URLs each, written to `/opt/traffic-gen/domains/` on containers)
- `browse_random()` integrated into `office-worker` profile: 2 requests during morning routine, 3 during lunch, 2 during regular work hours
- `browse_random()` integrated into `executive` profile: 1 request on after-hours UEBA trigger, 3 during business hours browsing

### Fixed
- `browse_random()` invalid test operator (`-file` → `-f`) in `random-timing.sh`
- `RUNNING_CONTAINERS` in `cmd_install_traffic_gen` now correctly filters to running containers only (`pct list` filtered by status field)

[Unreleased]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v1.2.2...HEAD
[1.2.2]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/mpreissner/proxmox-lab-scripts/releases/tag/v1.0.0
