# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest release | ✅ |
| Previous minor release | ✅ (critical fixes only) |
| Older versions | ❌ |

## Scope

This project consists of shell scripts and PowerShell scripts for deploying Proxmox LXC-based lab environments. The scripts are intended for **isolated lab environments only** and are not designed for production use. Please keep this context in mind when evaluating potential issues.

### In Scope

- Privilege escalation risks in `proxmox-lab.sh` or `win-traffic.ps1`
- Unintended command injection via user-supplied configuration values
- Insecure defaults that could expose lab traffic to unintended networks
- Credentials, tokens, or sensitive data inadvertently committed to the repository
- Logic errors that could cause unintended traffic to external systems beyond the documented scope

### Out of Scope

- Issues that require physical access to the Proxmox host
- Findings in third-party tools or software installed by the scripts (Alpine Linux, ImageMagick, etc.)
- Traffic interception by the Zscaler cloud or other inspection proxies — this is intentional by design
- The EICAR test file and simulated DLP payloads — these are intentional test artifacts, not vulnerabilities

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for potential security concerns.

To report a vulnerability, open a [GitHub Security Advisory](../../security/advisories/new) using the private reporting feature. This allows us to discuss and address the issue before any public disclosure.

Please include:

- A description of the issue and its potential impact
- Steps to reproduce or a proof-of-concept (if applicable)
- The version(s) of the script affected
- Any suggested remediation

## Response Timeline

- **Acknowledgment:** Within 3 business days
- **Initial assessment:** Within 7 days
- **Resolution target:** Within 30 days for confirmed issues (critical issues prioritized)

You will be credited in the release notes if you'd like recognition for your report.

## Additional Notes

Because this project is designed for security testing labs, many behaviors that might appear suspicious in other contexts (DLP test payloads, EICAR downloads, policy-violation traffic) are intentional and documented. If you're unsure whether something is a bug or a feature, feel free to ask in a [Discussion](../../discussions) first.
