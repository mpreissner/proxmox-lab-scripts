---
name: Traffic Profile Request
about: Request a new user or server traffic profile
title: '[Profile] '
labels: enhancement
assignees: ''
---

## Profile Name and Persona

What role or system should this profile represent? (e.g., "VoIP endpoint", "DevSecOps engineer", "streaming media server")

## Security Testing Use Case

What security product capability or policy would this profile help validate? (e.g., "generates realistic RTP/SIP traffic to test application control rules", "represents a developer persona with access to internal secrets managers")

## Proposed Domains and User Agents

List the domains this profile should browse and the user agents it should use. For server profiles, include the SDK or tool string that would realistically make these requests.

```
# Example
url     voip    zoom.us             yes
url     voip    teams.microsoft.com yes
```

## GenAI Activity (if applicable)

Should this profile include GenAI browsing or prompt submissions? If so, which providers (ChatGPT, Perplexity, Mistral) and what types of prompts fit the persona?

## Security Test Assignments (if applicable)

Should any default security tests be enabled for this profile? Which ones, and why does this persona fit those test scenarios?

## Additional Context

Any relevant references — vendor traffic patterns, protocol documentation, or existing `lab-traffic.tsv` customizations you're already using.
