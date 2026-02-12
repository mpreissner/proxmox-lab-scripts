# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/mpreissner/proxmox-lab-scripts/releases/tag/v1.0.0
