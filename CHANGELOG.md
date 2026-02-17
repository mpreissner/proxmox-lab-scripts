# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.1.3] - 2026-02-17

### Fixed
- `cmd_update`: replaced non-atomic `cp`+`rm` replacement pattern (temp file in `/tmp`, then `cp` to script path) with a truly atomic `chmod`+`mv` pattern — temp file is created in the same directory as the script, ensuring same-filesystem rename. Eliminates the window where a crash mid-copy could leave the script partially written.
- `_startup_version_check`: replaced fragile grep-based GitHub releases API JSON parsing (`grep '"tag_name"' | cut | sed`) with `python3 -c "import sys,json; ..."`, consistent with all other JSON parsing in the script.

## [3.1.2] - 2026-02-17

### Added
- **Linked clone support** in `cmd_deploy_containers`: `CLONE_TYPE` config variable (`linked`|`full`, default `full`); prompted at deploy time after node and storage decisions are final. Linked clones share the template's base disk — faster deployment and smaller disk footprint. Eligibility is validated at runtime: (1) single-node deployment on snapshot-capable storage (`lvmthin`, `zfspool`, `rbd`, `btrfs`) where the target node matches the template node; (2) multi-node deployment on shared snapshot-capable storage (Ceph RBD). Multi-node deployments with local storage fall back to full clones with an explanatory warning. `CLONE_TYPE` persisted to `~/.proxmox-lab.conf`.
- `_storage_type()`: queries `pvesh get /storage/{pool}` and returns the storage type string (`lvmthin`, `zfspool`, `nfs`, `dir`, etc.).
- `_storage_supports_linked_clone()`: returns true if the pool type is snapshot-capable (`lvmthin`, `zfspool`, `rbd`, `btrfs`).
- `_configure_clone_type()`: full decision tree for clone type — validates storage capability, checks deployment topology, and optionally migrates the template disk from a non-snapshot-capable pool (e.g. NFS) to a snapshot-capable local pool via `pct move-volume` before proceeding. Updates `STORAGE`, `TMPL_POOL`, `TMPL_TYPE`, and `TMPL_SHARED` on successful move.
- **Deployment requirements summary**: aggregate container count, total RAM, and node count shown as a header line in the Resource Feasibility Check before the per-node RAM table.
- **Disk space check** in `cmd_deploy_containers`: queries `pvesh get /nodes/{node}/storage/{pool}/status` for available and total disk per target node after clone type is determined; estimates 300 MB/container for full clones and 100 MB/container for linked clone deltas; warns at >80% utilization after deployment, aborts if available disk is less than the estimated need. Shared storage (Ceph) is queried once from the template node; local storage is checked independently per target node.
- **`STORAGE` vs. template pool validation**: detects and auto-corrects a mismatch between `STORAGE` in config and the template's actual storage pool (e.g. after manual config edits). Proxmox requires clones to use the same pool as their template; mismatches would otherwise cause a hard failure mid-deploy.

### Fixed
- `pick_storage()` listed all storage pools including those without the `rootdir` content type (e.g. `local`, which carries only `iso,vztmpl,backup` by default). These pools cannot hold CT or VM disk volumes. Now filters to pools with `rootdir` enabled, consistent with the `vztmpl` filter already applied by `pick_image_storage()`.
- `pct clone` for linked clones incorrectly passed `--storage`; Proxmox rejects this flag for linked clones because the clone must reside on the same pool as the template. The flag is now omitted when `CLONE_TYPE=linked`.
- Disk space check used `pvesh get /nodes/{node}/storage/{pool}` (returns storage config metadata) instead of `.../storage/{pool}/status` (returns live usage data including `avail` and `total`); the wrong endpoint returned no usable data, causing every node to show "could not query".

---

## [3.0.5] - 2026-02-15

### Fixed
- `_ensure_win_scripts`: existing PS1 files that predate `$SCRIPT_VERSION` (v2.x copies on the host) were silently kept because the function only checked for file presence, not version. Added `$SCRIPT_VERSION` presence check — files without it are treated as stale and re-fetched from GitHub, ensuring the host always has a versioned copy before Windows Tools operations run.
- `cmd_windows_install_traffic`: install/update message showed `vunknown` when the local PS1 had no `$SCRIPT_VERSION` line. Changed to omit the version suffix if `local_ver` is empty rather than printing `unknown`.

---

## [3.0.4] - 2026-02-15

### Fixed
- `cmd_windows_configure_tasks`: scheduled task verification query ran immediately after the setup script exited. `Register-ScheduledTask` returns synchronously in PowerShell, but the Task Scheduler service commits the task to its internal store with a brief delay, causing `Get-ScheduledTask` to return null even for tasks that were successfully registered. Added a 3-second sleep between script execution and the verification query.

---

## [3.0.3] - 2026-02-15

### Fixed
- `cmd_windows_configure_tasks`: success detection always showed "Warning: check output above" even when tasks were created correctly. Root cause: `setup-scheduled-tasks.ps1` uses `Write-Host` throughout, which writes to PowerShell's host/console stream (not stdout). `qm guest exec` only captures fd1 (stdout), so `out-data` is always empty for Write-Host output. Replaced stdout-capture approach with a post-run `Get-ScheduledTask` query via `_win_exec_ps_capture` (which uses `Write-Output`) to verify the first selected task was registered; shows green tick or warning based on the query result.

---

## [3.0.2] - 2026-02-15

### Fixed
- `cmd_windows_configure_tasks`: `setup-scheduled-tasks.ps1` was copied to the VM on every run regardless of remote version. Added version check via `_win_script_version`; copy is now skipped when the remote version matches local. The script is always executed (profile selection may differ across runs).
- `setup-scheduled-tasks.ps1`: `-Profiles` parameter received as a single comma-separated string when invoked via `qm guest exec -File`; PowerShell treated it as a one-element array, causing all `$Profiles -contains "profile-name"` checks to fail and every task to be skipped. Added normalization block to split on commas when a single-element comma-containing string is detected.
- `cmd_windows_configure_tasks`: directory creation `qm guest exec` call was missing stdout suppression (leaked JSON). Changed `2>/dev/null` to `>/dev/null 2>&1`.
- `cmd_windows_configure_tasks`: task execution now uses `--synchronous 1` and parses output via Python to display PowerShell output cleanly instead of raw JSON; success detection based on `registered successfully` in output rather than unconditional green tick.

---

## [3.0.1] - 2026-02-15

### Fixed
- `$SCRIPT_VERSION` in `win-traffic.ps1` and `setup-scheduled-tasks.ps1` was placed before `param()`, causing a PowerShell parse error (`The assignment expression is not valid`) when parameters were passed. Moved to immediately after the closing `)` of the `param()` block.
- `_win_vm_write_file` JSON output from `qm guest exec --synchronous 1` leaked to the terminal during file transfers. Changed `2>/dev/null` to `>/dev/null 2>&1` on all non-capture `qm guest exec` calls.
- `_win_script_version` always returned `"none"` because the `Select-String` regex pattern did not reliably match across line endings. Replaced with `Get-Content | Where-Object { $_ -like '*SCRIPT_VERSION*' } | Select-Object -First 1` and string split on `"` to extract the version value.
- Certificate install cleanup used `cmd.exe /c del` which failed with `The filename, directory name, or volume label syntax is incorrect`. Replaced with `powershell.exe Remove-Item -Force -ErrorAction SilentlyContinue`.
- VM selection in `_select_win_vms` and `cmd_tag_windows_vms` accepted list position numbers; changed to accept VMIDs directly.

---

## [3.0.0] - 2026-02-15

### Added
- Windows Tools submenu (menu option 6 / `./proxmox-lab.sh windows`) consolidating all Windows VM management with tag-based multi-VM discovery
- `cmd_tag_windows_vms`: bulk-tags VMs with `lab-windows`; highlights VMs with 'win' in the name as candidates; marks already-tagged VMs; comma-separated multi-select or `all`
- `_win_exec_ps_capture()`: runs a PowerShell one-liner via `qm guest exec --synchronous 1` and returns trimmed stdout from the JSON response; foundation for all idempotency checks
- `_win_cert_installed()`: queries the Windows Trusted Root store for a SHA1 thumbprint; returns true if the cert is already installed
- `_win_script_version()`: reads `$SCRIPT_VERSION` from a PS1 file on a remote Windows VM; enables version-aware script push
- `_select_win_vms()`: discovers all VMs tagged `lab-windows` cluster-wide; numbered table with status; comma-separated multi-select or `all`
- `_ensure_win_scripts()`: silently fetches `win-traffic.ps1` and `setup-scheduled-tasks.ps1` from GitHub when entering the Windows Tools submenu if they are not present on the host; saves alongside `proxmox-lab.sh`; no prompt required
- `cmd_update` now also downloads `win-traffic.ps1` and `setup-scheduled-tasks.ps1` after updating the main script; uses the same immutable tag ref when a target version is specified
- `$SCRIPT_VERSION = "3.0.0"` added to `win-traffic.ps1` and `setup-scheduled-tasks.ps1` for remote version comparison during idempotency checks
- `setup-scheduled-tasks.ps1`: `-Profiles` parameter (default: all five) for selective task creation; each task registration block wrapped in `if ($Profiles -contains "profile-name")`; existing tasks always removed before recreation (orphan-safe)

### Changed
- `cmd_install_windows_cert` replaced by `cmd_windows_install_cert`: operates on all `lab-windows`-tagged VMs; skips VMs where the certificate thumbprint is already present in the Trusted Root store
- `cmd_setup_windows_vm` split into `cmd_windows_install_traffic` (version-aware — skips if `$SCRIPT_VERSION` matches remote) and `cmd_windows_configure_tasks` (always re-runs; passes selected profiles via `-Profiles`)
- Main menu: items 6 (Install Windows VM Certificate) and 7 (Setup Windows VM Traffic Generator) replaced by single item 6 (Windows Tools); items 8–12 renumbered to 7–11
- CLI: `windows-cert` and `windows-setup` commands removed; `windows` added (opens the submenu)
- `_load_ct_data` QEMU section now captures the `tags` field (previously emitted an empty fifth column, unused)

### Removed
- `WIN_VMID` config key: removed from `save_config()`; `_migrate_config()` strips it from existing configs on first v3.0.0 launch

---

## [2.6.6] - 2026-02-14

### Fixed
- Startup version check update path installed the wrong version. `_startup_version_check` discovered the target version via the GitHub releases API, but then delegated to `cmd_update` which always downloaded from the main branch raw URL. GitHub's CDN can serve a stale version of the main branch for a short time after a push, causing the installed script to report the previous version number. `_startup_version_check` now passes the target version to `cmd_update`, which downloads from the immutable tag ref (`/v{version}/proxmox-lab.sh`) instead of `/main/`. The interactive update path (menu option 10) is unchanged and continues to download from main.

---

## [2.6.5] - 2026-02-14

### Fixed
- `cmd_update_containers` printed "Operation failed or was aborted." even when all containers updated successfully. The final line `[ $FAILED -gt 0 ] && echo ...` left exit code 1 (from the false `[` test) as the function's return value when no failures occurred. Replaced with an `if` block that only returns 1 when there are actual failures.

---

## [2.6.4] - 2026-02-14

### Fixed
- `cmd_update_containers`: removed `-y` flag from `apk upgrade`. Alpine's `apk` does not recognize `-y` (an `apt` flag) and was erroring with `unrecognized option 'y'`. `apk` is non-interactive by default and requires no flag to suppress prompts.

---

## [2.6.3] - 2026-02-14

### Fixed
- `cmd_show_status` only displayed one container on multi-node clusters. The `while read` loop iterated `$sorted_pairs` via a here-string on stdin. When `run_on_node` used SSH to check crontab on a remote-node container, SSH consumed the remaining here-string data from stdin, terminating the loop early. Fixed by redirecting the here-string to fd 3 (`3<<<`) and reading from it explicitly (`read <&3`), so SSH cannot touch the loop's data stream.

---

## [2.6.2] - 2026-02-14

### Changed
- `cmd_update` (menu option 10) now exits the script with a notice after a successful update instead of returning to the menu. This is consistent with the startup version check flow and prevents the user from continuing on the old version without relaunching.

---

## [2.6.1] - 2026-02-14

### Fixed
- `cmd_start_containers`, `cmd_stop_containers`, `cmd_show_status`, and `cmd_update_containers` all filtered lab containers by `lab-managed` tag **or** hostname patterns `hq-*` / `branch-*`. The hostname fallback has been removed from all four functions; the `lab-managed` tag is now the sole filter, consistent with `cmd_system_cleanup` (fixed in v2.5.2).

---

## [2.6.0] - 2026-02-14

### Added
- `IMAGE_STORAGE` config variable: the storage pool where the Alpine `.tar.xz` template image is downloaded. Prompted during template creation (step 3b) with the list filtered to pools that have the `vztmpl` content type enabled. Saved to `~/.proxmox-lab.conf` and pre-populated on subsequent runs. Defaults to `local` when not set, preserving existing behavior for users upgrading.

### Fixed
- Template creation no longer hardcodes `local` for the Alpine image download (`pveam download`), existence check (`pveam list`), or container creation (`pct create … local:vztmpl/…`). All three now use the configured `IMAGE_STORAGE`.
- System cleanup (`_cleanup`) now discovers Alpine images via `pveam list <IMAGE_STORAGE>` instead of scanning `/var/lib/vz/template/cache/` directly, and removes them via `pveam remove` instead of `rm -f`. This correctly handles non-`local` image storage pools.
- Summary display during template creation now shows `CT Disk Storage` and `Image Storage` as separate labeled fields.

---

## [2.5.2] - 2026-02-14

### Fixed
- `_load_ct_data()` now also queries `/nodes/{node}/qemu` on each cluster node and adds VM IDs to the shared ID map. Proxmox uses a unified CTID/VMID namespace, so LXC containers and QEMU VMs cannot share IDs. Previously, `_next_free_ctid_in_range()` was unaware of VM IDs, causing deploy failures when a calculated CTID was already in use by a VM.
- System cleanup (`cmd_system_cleanup`) now matches containers exclusively by the `lab-managed` tag. The previous hostname-pattern fallback (`hq-*` / `branch-*`) caused non-lab containers with matching hostnames to be erroneously included in the cleanup target list.

---

## [2.5.1] - 2026-02-14

### Added
- Shared storage recommendation during template creation: if local storage is chosen in a multi-node cluster and shared storage pools are available on the selected node, prompts the user to switch. Supports both single-node and multi-node shared storage deployments.
- Pre-deploy shared storage validation: when the template is on shared storage, verifies that the storage pool is accessible on every target node before any cloning begins. Aborts with a clear error if any node is missing the pool.

### Fixed
- Removed incorrect "Note: This script only supports local storage options" warning from template creation. Shared storage is fully supported.

---

## [2.5.0] - 2026-02-14

### Added
- `cmd_update_containers()` (menu option 9 / `update-containers` CLI): updates packages on all running lab-managed containers in parallel via `apk update && apk upgrade`. Reports per-container success/failure; shows error output for any that fail.

### Changed
- Main menu reordered: wizard moved to option 5 (immediately after the four setup steps); Windows cert (6) and Windows traffic gen (7) grouped together; Show Status (8), Update Container Packages (9), Update Lab Script (10), Stop Containers (11), Exit (12).

---

## [2.4.0] - 2026-02-14

### Added
- **Startup version check:** on every interactive launch, queries the GitHub releases API before showing the main menu. If a newer release is available, displays the version banner and changelog for that release, then prompts `Update now? [y/N]:`. Accepting downloads and applies the update, then exits so the user relaunches the new version. Declining proceeds to the main menu. Uses a 5-second timeout; fails silently if GitHub is unreachable. Direct CLI invocations (`deploy`, `start`, `update`, etc.) are unaffected.
- **Config migration routine (`_migrate_config`):** runs at startup before any command. If `SAVED_VERSION` in `~/.proxmox-lab.conf` is older than the running script version, applies pending migration steps and updates `SAVED_VERSION`. Current migration (v2.2.x → v2.3.0): removes stale `HQ_START`/`BRANCH_START` keys and notifies the user if `HQ_RANGE`/`BRANCH_RANGE` are also unset. Silent if no migration is needed.
- `SAVED_VERSION` written to `~/.proxmox-lab.conf` by `save_config()`, recording the version that last wrote the config.

### Changed
- `cmd_update()` accepts an optional `skip_confirm` flag (used internally by the startup version check to avoid double-prompting). Behavior when invoked from menu option 8 or CLI is unchanged.

---

## [2.3.0] - 2026-02-14

### Added
- `read_ctid_range()`: interactive prompt for `START-END` CTID ranges with format validation, start-less-than-end check, and minimum capacity enforcement; used by deploy, start, stop, and install-traffic
- `_next_free_ctid_in_range()`: bounded variant of `_next_free_ctid`; scans only within the specified range and returns an error if the range cannot fit the required number of containers, allowing deploy to fail cleanly rather than silently under-deploying
- `_build_default_profiles()`: dynamically builds the CTID-to-profile map by scanning `HQ_RANGE`/`BRANCH_RANGE` for `lab-managed` containers in CTID order and mapping them positionally to the profile order; branch always reserves the first two slots for `office-worker` (`br_ow_min=2`) before assigning remaining profiles in order; replaces the hardcoded `DEFAULT_PROFILES` array

### Changed
- CTID configuration now uses explicit ranges (`HQ_RANGE`, `BRANCH_RANGE`, e.g. `200-210`) instead of start points (`HQ_START`, `BRANCH_START`); both the start and end of each group's range are specified explicitly, eliminating the implicit assumption that the DC range ends before the branch range begins
- `VLAN_HQ` and `VLAN_BRANCH` no longer have built-in defaults (previously `200` and `201`); users must supply their own values matching their network topology
- Deploy, start, stop, and install-traffic scope options all parse the explicit `HQ_RANGE`/`BRANCH_RANGE` values rather than computing `START + N` offsets
- `DEFAULT_PROFILES` static array removed; replaced by `_build_default_profiles()` called after `_load_ct_data` in `cmd_install_traffic_gen`

### Notes
- **Config migration:** existing `~/.proxmox-lab.conf` files with `HQ_START`/`BRANCH_START` entries will not break on load, but those values are no longer used. On the next config save the new `HQ_RANGE`/`BRANCH_RANGE` keys will be written and the old keys will be dropped. Users will be prompted for range values on first run after upgrading.

## [2.2.1] - 2026-02-14

### Fixed
- `win-traffic.ps1`: replaced all em-dashes and en-dashes with ASCII hyphens; same PowerShell 5.x / Windows-1252 encoding issue as `setup-scheduled-tasks.ps1` in v2.2.0

## [2.2.0] - 2026-02-13

### Added
- `_win_vm_write_file()`: writes a file from the Proxmox host into a Windows VM via QEMU guest agent using base64 chunking through PowerShell; handles files of any size in 6 KB chunks with `--synchronous 1` to guarantee write ordering; replaces the non-existent `qm guest file-write` subcommand
- `cmd_setup_windows_vm`: pushes `win-traffic.ps1` and `setup-scheduled-tasks.ps1` to a Windows VM at `C:\ProgramData\proxmox-lab\`, then runs `setup-scheduled-tasks.ps1` to register scheduled tasks; cluster-aware via `_find_vm_node`; validates QEMU guest agent before proceeding
- Menu option 10: Setup Windows VM Traffic Generator; Exit moved to option 11
- `windows-setup` direct CLI command: `./proxmox-lab.sh windows-setup`
- `WIN_TRAFFIC_PS1` and `WIN_SETUP_PS1` persisted to `~/.proxmox-lab.conf` (default `/root/win-traffic.ps1` and `/root/setup-scheduled-tasks.ps1`)
- Deploy containers now uses dynamic CTID allocation: scans the cluster for occupied CTIDs before building the deployment list, then assigns the next free ID starting from the configured `HQ_START`/`BRANCH_START`, skipping any in use; guarantees all containers in the full stack are deployed even when part of the configured range is already occupied

### Changed
- `cmd_install_windows_cert` now uses `_win_vm_write_file` to copy the certificate into the VM instead of the non-existent `qm guest file-write` subcommand
- Deploy config preview no longer shows fixed CTID offsets; shows "assigned from X, skipping any in use" since actual IDs are determined after scanning
- Deploy summary and post-deployment output now show actual assigned CTIDs derived from the deploy list rather than computed `START + OFFSET` values

### Fixed
- `setup-scheduled-tasks.ps1`: replaced all em-dashes and en-dashes with ASCII hyphens; PowerShell 5.x on Windows reads files without a UTF-8 BOM using the system default encoding (Windows-1252), which mangled the UTF-8 multibyte sequences into characters that broke the parser

## [2.1.0] - 2026-02-13

### Added
- `win-traffic.ps1`: PowerShell traffic generator for Windows VMs; five profiles (office-worker, sales, developer, executive, threat); duration-controlled loop with inter-session delays; logs to `C:\ProgramData\proxmox-lab\traffic-gen.log`; threat profile covers EICAR download, network DLP POST, GenAI DLP prompts to OpenAI/Anthropic/Gemini, and policy violations
- `setup-scheduled-tasks.ps1`: creates Windows Task Scheduler entries for all five traffic profiles with M–F weekday schedules matching each persona's usage pattern; elevation check at startup; post-registration verification confirms each task was created; `-ScriptPath` parameter for non-default install paths
- `cmd_install_windows_cert`: installs a Zscaler TLS root certificate on a Windows VM via QEMU guest agent; cluster-aware via `run_on_node` and `_find_vm_node`; displays running VM table across all cluster nodes; prompts for VM ID (saved to config as `WIN_VMID`); reuses `CERT_PATH` from existing config; copies cert to `C:\Windows\Temp` via stdin pipe; installs to Windows Trusted Root CA store via PowerShell; cleans up temp file on completion
- `_find_vm_node()`: cluster-wide QEMU VM lookup using per-node `pvesh get /nodes/{node}/qemu` queries; mirrors `_find_template_node()` for LXC containers
- Menu option 9: Install Windows VM Certificate; Exit moved to option 10
- `windows-cert` direct CLI command: `./proxmox-lab.sh windows-cert`
- `WIN_VMID` persisted to `~/.proxmox-lab.conf`

### Changed
- `qm guest file-write` uses stdin pipe (`< cert_file`) instead of shell-expanding file content as a positional argument; safer for base64-encoded PEM certificates
- `C:\Windows\Temp` used as cert staging path instead of `C:\temp`; always present on Windows, eliminates the `mkdir C:\temp` pre-step

## [2.0.0] - 2026-02-13

### Added
- Multi-node Proxmox cluster support: containers can be distributed across multiple cluster nodes with auto-balanced or manual placement
- Node resource table during deployment showing RAM total/used/free, CPU count and utilization, and running container count per node
- Auto-balance algorithm distributes containers by available RAM, placing higher-memory containers first on nodes with the most headroom
- Resource feasibility check before deployment: warns at >80% projected node utilization, aborts at >95%
- Container assignment preview before deployment showing CTID, hostname, profile, and target node for each container
- `node_to_ip()`: resolves Proxmox node names to IP addresses via `/etc/hosts` then `/etc/pve/corosync.conf`; used by `run_on_node` to avoid SSH failures when cluster node hostnames are not in DNS
- `_find_template_node()`: cluster-wide CTID lookup using per-node API queries; used for template validation, deploy, and cleanup
- `_load_config()`: re-sources `~/.proxmox-lab.conf` at the entry point of each command function so values saved during one command are immediately available to subsequent commands in the same session

### Changed
- `_load_ct_data()` rewritten to query each cluster node individually via `pvesh get /nodes/{node}/lxc` instead of `pvesh get /cluster/resources`; correctly discovers containers on all nodes in both clustered and standalone (non-clustered) Proxmox environments
- `run_on_node()` routes commands to remote nodes via SSH with transparent stdin passthrough, enabling heredoc-based profile installation to containers on any cluster node
- `pick_storage()` now queries `pvesh get /nodes/{node}/storage` for the actual target node rather than the global storage list, showing only pools available on the relevant node
- `cmd_create_template` fully cluster-aware: all operations (`pveam download`, `pct create`, `pct start`, `pct exec`, `pct stop`, `pct template`) route through `run_on_node` to the selected node; TLS certificate streamed into container via stdin rather than `pct push` to support remote nodes
- `cmd_deploy_containers` cluster-aware: locates template cluster-wide, derives clone strategy based on template storage type (shared → clone on target node; local → clone on template node, migrate if target differs)
- `cmd_start_containers` cluster-aware: discovers containers on all nodes, routes start commands via `run_on_node`; options 2/3 (Data Center/Branch only) no longer prompt for CTID range when values are already saved to config
- `cmd_stop_containers` restructured to match Start Containers: full status table showing Running/Stopped across all nodes, 5-option selection menu (all running, DC only, branch only, specific CTIDs, CTID range), stop commands routed via `run_on_node`
- `cmd_install_traffic_gen` cluster-aware: all `pct exec` calls routed via `run_on_node` to the correct node per container
- `cmd_show_status` cluster-aware: containers grouped by node in output
- `cmd_system_cleanup` cluster-aware: discovers lab containers and template across all nodes via per-node queries; stop and destroy operations routed via `run_on_node`; detects and removes Alpine images on all cluster nodes
- `ctid_to_node()` rewritten to use per-node queries instead of `pvesh get /cluster/resources`
- `NODE` config variable promoted to `NODES` (space-separated list) for multi-node deployments; existing single-node configs with `NODE=` are automatically promoted on load
- `devops` default security tests updated to include `dlp-genai-image` in addition to `eicar`, `dlp-genai-prompt`, and `dlp-genai-file`

### Fixed
- Template creation always used the local node even when a different node was specified in the prompt
- Container discovery only returned containers on the primary (local) node in multi-node deployments, causing Start Containers, Stop Containers, Install Traffic, Status, and Cleanup to miss remote containers entirely
- System cleanup failed to detect or destroy the template when it resided on a non-local cluster node
- System cleanup failed to detect or remove Alpine images downloaded to remote nodes during template creation
- Template validation in deployment used local-only `pct status`, failing when the template was on a different cluster node
- Config values (e.g., `HQ_START`, `BRANCH_START`) saved during a wizard run were unavailable to subsequent standalone commands in the same session due to subshell variable isolation; each command now re-sources the config file on entry
- Stop Containers prompted for CTID range even when `HQ_START`/`BRANCH_START` were already saved to config

## [1.2.4] - 2026-02-12

### Changed
- README Traffic Profiles table updated to document role-appropriate user agents per profile (SDK/tool strings for server profiles, persona-specific browser pools for user profiles)

## [1.2.3] - 2026-02-12

### Changed
- `random_user_agent()` updated with 10 complete, realistic browser user agent strings (previously 3 truncated placeholders)
- Server profiles now send role-appropriate SDK and tool user agents: OneDrive Sync, Dropbox, aws-cli (fileserver); Stripe-Node, OpenSSL (webapp); Exchange Server, Postfix, SpamAssassin, ClamAV (email); Datadog Agent, NewRelic, Docker, GitHub Actions, Debian APT (monitoring); npm, pip, git, GitHub Actions, Docker (devops); aws-sdk-java, Boto3, azsdk-python (database)
- User profiles now pick from persona-specific browser UA pools per run: Windows/Mac mix (office-worker), Mac-heavy Safari/Chrome (sales), Mac/Linux with CLI alternation for package managers (developer), Mac Safari (executive)
- `security-tests/policy-violation.sh` updated to send a browser UA with each request
- `security-tests/ueba.sh` updated with Mac/iOS UA pool (Mac Safari, iPhone Safari, iPad Safari) to simulate exec accessing O365 after hours from a personal device

### Fixed
- `read_with_default()` prompt displayed garbled output when the default value contained `*` characters (e.g., cron expressions like `*/30 * * * *`); unquoted `${default}` inside the `$(echo -e ...)` command substitution caused glob expansion against the current directory; fixed by double-quoting the echo argument

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

[3.1.2]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v3.0.5...v3.1.2
[3.0.5]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v3.0.4...v3.0.5
[3.0.4]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v3.0.3...v3.0.4
[3.0.3]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v3.0.2...v3.0.3
[3.0.2]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v3.0.1...v3.0.2
[3.0.1]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v3.0.0...v3.0.1
[3.0.0]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v2.6.6...v3.0.0
[2.2.1]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v2.2.0...v2.2.1
[2.2.0]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v2.1.0...v2.2.0
[2.1.0]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v1.2.4...v2.0.0
[1.2.4]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v1.2.3...v1.2.4
[1.2.3]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/mpreissner/proxmox-lab-scripts/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/mpreissner/proxmox-lab-scripts/releases/tag/v1.0.0
