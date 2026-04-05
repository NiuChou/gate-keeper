# Gate Keeper

**Three-layer automated deployment gatekeeper** — static checks before build, cluster validation before deploy, runtime verification after deploy. Config-driven, audit-logged, fail-to-block.

三层自动化部署闸门 — 构建前静态检查、部署前集群校验、部署后运行时验证。配置驱动、审计留痕、失败即阻止。

---

English | [中文文档](README.zh.md)

---

## Quick Start

```bash
# Install
curl -sL https://raw.githubusercontent.com/NiuChou/gate-keeper/main/install.sh | bash

# Initialize (auto-detects project type)
gate-keeper init

# Run checks
gate-keeper run --layer=1      # Static checks only
gate-keeper run                # All three layers

# Smart recommendations
gate-keeper suggest
```

## Three Layers

| Layer | When | What | Requires |
|---|---|---|---|
| **Layer 1: Static** | Before build | go.work, Dockerfile, secretRef, port chain, namespace + custom checks | Nothing |
| **Layer 2: Cluster** | Before deploy | Deployment name, image name, Secret key matching | kubectl |
| **Layer 3: Runtime** | After deploy | Health check, Pod status, load test | kubectl |

Each layer must pass before the next runs. Failure behavior depends on severity and `--fail-on` threshold.

## Four Severity Levels

| Level | Status | Display | Behavior |
|---|---|---|---|
| `critical` (default) | FAIL | ✗ red | Blocks deployment |
| `high` | HIGH | ! red | Blocks when `--fail-on=high` |
| `warning` | WARN | ⚠ yellow | Warns only, exit 2 |
| `info` | INFO | ℹ blue | Informational, no effect on exit code |

### Exit Codes

| Code | Meaning | Scenario |
|---|---|---|
| 0 | All passed | No failures or warnings |
| 1 | Blocked | Failures at or above `--fail-on` threshold |
| 2 | Warnings only | Warnings present but below threshold |

## Commands

```bash
gate-keeper init                # Detect project type, generate .gatekeeper.yaml
gate-keeper run                 # Run checks (default: all layers)
gate-keeper run --layer=1       # Layer 1 only
gate-keeper run --ci            # CI mode (no color, JSON output)
gate-keeper suggest             # Analyze project, recommend checks
gate-keeper audit               # View audit logs
gate-keeper audit --diff        # Compare last two runs
gate-keeper audit --trend       # Pass rate trend chart
gate-keeper audit --export=csv  # Export history as CSV
gate-keeper audit --heatmap     # Check duration heatmap
gate-keeper plugin install URL  # Install rule pack from Git
gate-keeper plugin list         # List installed plugins
gate-keeper plugin remove NAME  # Remove plugin
gate-keeper doctor              # Self-check
gate-keeper add                 # Add custom check to config
gate-keeper stamp               # Generate SHA256 hash baseline
gate-keeper stamp --verify      # Verify file integrity
```

### Run Options

| Option | Default | Description |
|---|---|---|
| `--layer=1\|2\|3\|all` | all | Layer to run |
| `--format=text\|json\|sarif\|junit\|html` | text | Output format |
| `--fail-on=critical\|high\|warning\|none` | critical | Failure threshold |
| `--parallel=N` | auto | Max parallel checks |
| `--dry-run` | — | Preview without executing |
| `--quiet` | — | Suppress PASS/INFO output |
| `--tags=TAG` | — | Filter checks by tag |
| `--ci` | — | CI mode |

## Output Formats

| Format | Use Case |
|---|---|
| `text` | Terminal viewing |
| `json` | Audit log |
| `sarif` | GitHub Security Alerts / VS Code |
| `junit` | Jenkins / GitLab test reports |
| `html` | Standalone shareable report |

```bash
gate-keeper run --format=sarif > results.sarif   # GitHub Security
gate-keeper run --format=junit > results.xml     # Jenkins/GitLab
gate-keeper run --format=html > report.html      # Shareable report
```

## Custom Checks

Four modes covering violation detection and compliance validation:

### pattern — Found = Violation

```yaml
custom_checks:
  - id: no_debug_production
    pattern: "DEBUG.*True"
    paths: "."
    severity: critical
    fix_hint: "Remove DEBUG=True. Use LOG_LEVEL=INFO."
    exclude_dirs: "dist,node_modules"
    tags: "security"
```

### must_match — Found = Compliance

```yaml
custom_checks:
  - id: port_decision_app
    must_match: "PORT.*8000"
    paths: "docker-compose.prod.yml"
    severity: warning

  - id: all_services_healthcheck
    must_match: "healthcheck:"
    must_match_count: 5
    paths: "docker-compose.prod.yml"
    severity: critical
```

### command — Arbitrary Command

```yaml
custom_checks:
  - id: ruff_check
    command: "ruff check apps/ --quiet"
    severity: warning
```

### drift — Drift Detection

```yaml
custom_checks:
  # Global: A exists → B must also exist
  - id: rls_activation
    pattern: "DefineRLSPolicy"
    requires: "ActivateRLS"
    severity: critical

  # Per-file: each file with A must also contain B
  - id: handler_auth
    pattern: "func Handle"
    requires: "ParseAccessToken"
    drift_mode: per_file

  # Commented: pattern only in comments = disabled code
  - id: frontend_auth
    pattern: "useAuth"
    drift_mode: commented
```

## Plugin System

```bash
gate-keeper plugin install https://github.com/org/gk-rules-k8s-security
gate-keeper run --tags=security
```

Plugin structure:

```
gk-rules-k8s-security/
├── metadata.yaml          # name, version, description
├── checks/
│   ├── no-privileged/
│   │   ├── check.sh       # Check script (exit 0 = PASS)
│   │   └── metadata.yaml  # id, severity, tags, compliance, fix_hint
│   └── resource-limits/
└── README.md
```

## Configuration

```yaml
version: 1
project: my-project
namespace: production

layer1:
  secretref_ban:
    severity: critical
    exclude_pattern: "secretKeyRef"
  port_chain:
    severity: critical
  namespace_consistency:
    severity: critical
    expect: "production"

  custom_checks:
    - id: no_console_log
      pattern: "console.log"
      paths: "src"
      severity: warning
      tags: "quality"
      fix_hint: "Remove console.log before production."
```

### Templates

| Template | For |
|---|---|
| k8s-go | K8s + Go |
| k8s-python | K8s + Python |
| nextjs | Next.js |
| monorepo | Monorepo |
| docker-compose | Docker Compose |
| minimal | Minimal config |

### .gatekeeperignore

```
dist/
node_modules/
__pycache__/
*.min.js
```

## Audit & Observability

```bash
$ gate-keeper audit --trend
Pass Rate Trend (last 10 runs):

2026-04-01  ████████████████████  100%
2026-04-02  ██████████████░░░░░░   70%
2026-04-03  ████████████████████  100%
```

```bash
$ gate-keeper audit --heatmap
Check Duration Heatmap:

[H ] Port chain consistency       ██████████  450ms
[A ] go.work validation           ████        120ms
[B ] Shell script syntax           ██           45ms
```

## GitHub Action

```yaml
jobs:
  gate-keeper:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: curl -sL https://raw.githubusercontent.com/NiuChou/gate-keeper/main/install.sh | bash
      - run: gate-keeper run --layer=1 --format=sarif --fail-on=high > results.sarif
      - uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: results.sarif
```

## Supervision

| Mechanism | Description |
|---|---|
| **Tamper detection** | `gate-keeper stamp` generates SHA256 hashes; `stamp --verify` in CI |
| **Bypass detection** | Deployments auto-annotated with `gate-keeper-run-id` after pass |
| **Self-check** | `gate-keeper doctor` verifies config, deps, integrity |
| **Audit trail** | Every run generates JSON audit log |

## Origin

Born from 30 deployment errors during Perseworks v1.6.4 rollout. After 14 rounds of fixes, all lessons were systematized into a three-layer automated check system.

## License

MIT
