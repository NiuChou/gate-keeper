---
name: gate
description: "Deployment gatekeeper — run pre-build/deploy checks"
user-invocable: true
---

# /gate

Three-layer automated deployment gatekeeper.

## Usage
- `/gate` — Run all checks
- `/gate init` — Detect project type and generate .gatekeeper.yaml
- `/gate audit` — View recent audit logs

## Execution
1. Check if `gate-keeper` CLI is available
2. If no `.gatekeeper.yaml`, auto-detect project type and generate one
3. Run `gate-keeper run --layer=all`
4. Display results summary
