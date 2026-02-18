---
name: Bug Report
about: Something isn't working as expected
title: '[Bug] '
labels: bug
assignees: ''
---

## Describe the Bug

A clear description of what's happening and what you expected to happen.

## Steps to Reproduce

1. Run `./proxmox-lab.sh ...`
2. Select option ...
3. See error

## Environment

- **Proxmox VE version:** (e.g., 8.2.4)
- **Cluster topology:** Single node / Multi-node (how many nodes?)
- **Storage type(s):** (e.g., local-lvm, ZFS, NFS, Ceph RBD)
- **Clone type:** Linked / Full
- **Script version:** (check top of `proxmox-lab.sh` for `SCRIPT_VERSION`)

## Relevant Output

```
# Paste relevant terminal output here
# For container issues, include: pct status <CTID> and pct config <CTID>
```

## Status Output

```
# Run: ./proxmox-lab.sh status
# Paste output here
```

## Additional Context

Any other relevant details — network topology, Zscaler configuration, custom CTID ranges, etc.
