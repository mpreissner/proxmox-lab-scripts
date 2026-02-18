---
name: Security Test Scenario Request
about: Request a new DLP, AV, UEBA, or policy violation test scenario
title: '[Security Test] '
labels: enhancement
assignees: ''
---

## Test Category

- [ ] DLP — data in motion (network POST)
- [ ] DLP — GenAI prompt
- [ ] DLP — file upload
- [ ] DLP — image/OCR
- [ ] AV / malware detection
- [ ] Policy violation (blocked application/category)
- [ ] UEBA anomaly
- [ ] Other (describe below)

## What Should This Test Trigger?

Describe the specific detection or log event you're trying to generate. Be as specific as possible about the signal — e.g., "a Zscaler DLP engine match on IBAN number patterns in a multipart upload", "a UEBA alert for after-hours file download from SharePoint".

## Proposed Implementation

How should the test script generate this traffic? Include the target endpoint, payload structure, or any tooling required (e.g., ImageMagick for rendered images, specific curl flags).

If you have a working prototype, paste it here:

```bash
# Prototype script
```

## Default Profile Assignment

Which traffic profiles should have this test enabled by default? Why does this scenario fit those personas?

| Profile | Enable by default? | Reason |
|---------|-------------------|--------|
| fileserver | | |
| devops | | |
| developer | | |
| office-worker | | |
| sales | | |
| executive | | |

## Additional Context

Relevant Zscaler policy documentation, DLP engine patterns, compliance framework references, or other context that would help implement this.
