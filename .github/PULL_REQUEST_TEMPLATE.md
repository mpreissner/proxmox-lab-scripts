## Summary

<!-- What does this PR do? One or two sentences. -->

## Type of Change

- [ ] Bug fix
- [ ] New traffic profile
- [ ] New security test
- [ ] Documentation update
- [ ] Refactor / cleanup
- [ ] Other (describe below)

## Changes Made

<!-- List the specific files and what changed in each -->

## Testing

<!-- Describe how you tested this. Proxmox VE version, storage type, cluster topology, etc. -->

- [ ] Tested on a live Proxmox VE host
- [ ] `proxmox-lab.sh wizard` completes without errors
- [ ] `proxmox-lab.sh status` shows expected containers
- [ ] Traffic generation confirmed via `pct exec <CTID> -- tail -f /var/log/messages`

## Checklist

- [ ] `VERSION` updated in `proxmox-lab.sh` (if applicable)
- [ ] `CHANGELOG.md` updated
- [ ] `README.md` updated (if behavior changed)
- [ ] `lab-traffic.tsv` updated (if adding/modifying a profile)

## Related Issues

<!-- Closes #, Fixes #, or Related to # -->
