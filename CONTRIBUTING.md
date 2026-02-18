# Contributing

Thanks for your interest in improving proxmox-lab-scripts! Contributions are welcome — here's how to get started.

## Ways to Contribute

- **New traffic profiles** — additional user or server personas (VoIP, streaming, gaming, etc.)
- **New security test scenarios** — additional DLP, UEBA, or AV test scripts
- **Bug fixes** — especially around edge cases in multi-node cluster deployments or storage type detection
- **Documentation improvements** — clearer setup instructions, troubleshooting tips, or architecture diagrams
- **Windows tooling** — enhancements to `win-traffic.ps1` or `setup-scheduled-tasks.ps1`

## Getting Started

1. Fork the repository and clone your fork locally.
2. Test your changes against a real Proxmox environment if possible. This project is tightly coupled to Proxmox VE APIs and LXC behavior — changes are difficult to validate without a live host.
3. Keep the interactive menu style and config persistence patterns consistent with the existing script.

## Submitting Changes

1. Create a descriptive branch name: `feature/voip-traffic-profile` or `fix/linked-clone-detection`.
2. Make your changes. If modifying `proxmox-lab.sh`, update `VERSION` at the top of the file.
3. Update `CHANGELOG.md` with a brief summary of your changes under an `[Unreleased]` section.
4. Update `README.md` if your change adds or modifies user-facing behavior.
5. Open a pull request targeting the `dev` branch with a clear description of what you changed and why.

## Pull Request Guidelines

- Keep PRs focused — one feature or fix per PR makes review much easier.
- If you're adding a new traffic profile, include example entries in `lab-traffic.tsv` for the new profile.
- If you're adding a new security test, add its script to the appropriate location and document it in the README's security test table.
- PRs that touch `proxmox-lab.sh` should be tested against at least Proxmox VE 8.x.

## `lab-traffic.tsv` Format

The TSV file uses four tab-separated columns:

```
type            profile         value                   enabled
url             office-worker   salesforce.com          yes
genai_provider  devops          chatgpt                 yes
genai_prompt    devops          What are the key...     yes
security_test   devops          dlp-genai-image         no
```

Valid `type` values: `url`, `genai_provider`, `genai_prompt`, `security_test`  
Valid `enabled` values: `yes`, `no`

## Code Style

- Shell scripts: follow the existing style — POSIX-compatible where possible, bash-specific syntax is acceptable since the scripts require bash explicitly
- PowerShell: follow existing conventions in `win-traffic.ps1`
- Comments: explain *why*, not just *what*, especially for anything Zscaler-specific or Proxmox API-specific

## Reporting Bugs

Please open a [GitHub Issue](../../issues/new/choose) using the Bug Report template. Include your Proxmox VE version, storage type, cluster topology (single node vs. multi-node), and the output of `./proxmox-lab.sh status` if relevant.

## Feature Requests

Open a [GitHub Issue](../../issues/new/choose) using the Feature Request template, or start a [Discussion](../../discussions) if you want to float an idea before building it.
