# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/mpreissner/proxmox-lab-scripts/releases/tag/v1.0.0
