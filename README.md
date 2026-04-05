# Gate Keeper

一套三层自动化部署校验系统——构建前静态检查、部署前集群校验、部署后运行时验证，配置驱动、审计留痕、失败即阻止。

A three-layer automated deployment gatekeeper — static checks before build, cluster validation before deploy, runtime verification after deploy — config-driven, audit-logged, fail-to-block.

---

## 快速开始 / Quick Start

```bash
# 安装 / Install
curl -sL https://raw.githubusercontent.com/NiuChou/gate-keeper/main/install.sh | bash

# 初始化配置（自动检测项目类型）/ Initialize config
gate-keeper init

# 运行检查 / Run checks
gate-keeper run --layer=1      # 仅静态检查 / Static only
gate-keeper run --layer=all    # 全部三层 / All layers

# 智能推荐 / Smart recommendations
gate-keeper suggest            # 分析项目，推荐应启用的检查
```

---

## 三层守门员 / Three Layers

| 层级 / Layer | 时机 / When | 检查内容 / What | 依赖 / Requires |
|---|---|---|---|
| **Layer 1: 静态检查** | 构建前 / Before build | go.work、Dockerfile、secretRef 禁用、端口链、namespace 一致性 + 自定义检查 | 无 / Nothing |
| **Layer 2: 集群校验** | 部署前 / Before deploy | Deployment 名匹配、镜像名匹配、Secret key 匹配 | kubectl |
| **Layer 3: 运行时验证** | 部署后 / After deploy | 健康检查、Pod 状态、负载测试 | kubectl |

每层全部通过才放行下一层。失败行为取决于 severity 和 `--fail-on` 阈值。

Each layer must pass before the next runs. Failure behavior depends on severity and `--fail-on` threshold.

---

## Severity 四级分级 / Four Severity Levels

| 级别 / Level | 状态码 / Status | 显示 / Display | 行为 / Behavior |
|---|---|---|---|
| `critical` (默认) | FAIL | ✗ 红色 | 阻止部署 / Blocks deployment |
| `high` | HIGH | ! 红色 | `--fail-on=high` 时阻止 / Blocks when `--fail-on=high` |
| `warning` | WARN | ⚠ 黄色 | 仅警告，exit 2 / Warns only, exit 2 |
| `info` | INFO | ℹ 蓝色 | 信息提示，不影响退出码 / Informational, no effect on exit code |

### 退出码 / Exit Codes

| 退出码 / Code | 含义 / Meaning | 场景 / Scenario |
|---|---|---|
| 0 | 全部通过 / All passed | 无失败或警告 |
| 1 | 阻断 / Blocked | 存在达到 `--fail-on` 阈值的失败 |
| 2 | 仅警告 / Warnings only | 有警告但未达到阻断阈值 |

```yaml
layer1:
  secretref_ban:
    severity: critical       # 失败即阻止 / Blocks on failure
  shell_syntax:
    severity: warning        # 失败仅警告 / Warns on failure
  dockerfile_copy:
    severity: info           # 仅提示 / Informational only
```

---

## 命令 / Commands

```bash
gate-keeper init                # 检测项目类型，生成 .gatekeeper.yaml
gate-keeper run                 # 运行检查（默认全部三层）
gate-keeper run --layer=1       # 仅 Layer 1
gate-keeper run --layer=2       # Layer 1 + 2 (累积 / cumulative)
gate-keeper run --ci            # CI 模式（无颜色，JSON 输出）
gate-keeper suggest             # 分析项目结构，推荐检查项
gate-keeper audit               # 查看审计日志
gate-keeper audit --last=10     # 最近 10 条
gate-keeper audit --diff        # 对比最近两次运行的变化
gate-keeper audit --trend       # 通过率趋势图 / Pass rate trend chart
gate-keeper audit --export=csv  # 导出审计历史为 CSV
gate-keeper audit --heatmap     # 检查耗时热力图 / Duration heatmap
gate-keeper plugin install URL  # 从 Git URL 安装规则包
gate-keeper plugin list         # 列出已安装插件
gate-keeper plugin remove NAME  # 删除插件
gate-keeper doctor              # 自检：配置、依赖、完整性
gate-keeper add                 # 添加自定义检查项到配置
gate-keeper stamp               # 生成 SHA256 hash（篡改检测基线）
gate-keeper stamp --verify      # 验证文件完整性
gate-keeper version             # 版本号
gate-keeper help                # 帮助
```

### run 选项 / Run Options

| 参数 / Option | 默认 / Default | 说明 / Description |
|---|---|---|
| `--layer=1\|2\|3\|all` | all | 运行的层级 / Layer to run |
| `--format=text\|json\|sarif\|junit\|html` | text | 输出格式 / Output format |
| `--fail-on=critical\|high\|warning\|none` | critical | 失败阈值 / Failure threshold |
| `--parallel=N` | auto (nproc) | 最大并发检查数 / Max parallel checks |
| `--dry-run` | — | 预览检查列表，不执行 / Preview, don't execute |
| `--quiet` | — | 仅输出 FAIL/WARN/HIGH / Suppress PASS/INFO |
| `--tags=TAG` | — | 按标签过滤检查 / Filter by tag |
| `--ci` | — | CI 模式 / CI mode |

---

## 输出格式 / Output Formats

| 格式 / Format | 用途 / Use Case |
|---|---|
| `text` (默认) | 终端查看 / Terminal viewing |
| `json` | 审计日志 / Audit log |
| `sarif` | GitHub Security Alert / VS Code 直接消费 |
| `junit` | Jenkins / GitLab 测试报告解析 |
| `html` | 独立 HTML 报告（内联 CSS，可分享）/ Standalone shareable report |

```bash
# GitHub Security Alert 集成
gate-keeper run --format=sarif > results.sarif

# Jenkins/GitLab 测试报告
gate-keeper run --format=junit > results.xml

# 生成可分享的 HTML 报告
gate-keeper run --format=html > report.html
```

---

## 检查项清单 / Check List

### Layer 1: 静态检查（9 项 + 自定义）

| ID | 检查 / Check | 说明 / Description |
|---|---|---|
| A | go.work 验证 | use 路径指向存在的目录且含 go.mod |
| B | Shell 语法 | bash -n 语法检查 |
| C | Python 打包 | 无重复 setup.py + pyproject.toml |
| D | Dockerfile COPY | COPY 源路径存在 |
| E | Dockerfile 反模式 | 无 -e 安装、无 -dev 包 |
| F | secretRef 禁用 | 禁止 secretRef 注入全部 key（支持 `exclude_pattern`） |
| G | 废弃组件引用 | 检测已废弃的组件名（可自定义 patterns） |
| H | 端口链一致性 | containerPort = probePort（支持命名端口） |
| I | namespace 一致性 | 所有 YAML 的 namespace 必须一致（支持 `expect`） |
| * | 自定义检查 | pattern / must_match / command / drift 四种模式 |

### Layer 2: 集群校验（3 项）

| ID | 检查 / Check | 说明 / Description |
|---|---|---|
| J | Deployment 名匹配 | YAML name vs 集群实际 name |
| K | 镜像名匹配 | YAML image vs 构建脚本推送的 image |
| L | Secret key 匹配 | YAML secretKeyRef vs 集群 secret 实际 key |

### Layer 3: 运行时验证（3 项）

| ID | 检查 / Check | 说明 / Description |
|---|---|---|
| M | 健康检查 | 所有 Pod 状态为 Running |
| N | 异常 Pod 检测 | 无 CrashLoopBackOff / ImagePullBackOff |
| O | 负载测试 | k6 轻量级 smoke test（可选） |

### 监督层 / Supervision

| ID | 检查 / Check | 说明 / Description |
|---|---|---|
| S-1 | 篡改检测 | SHA256 hash 验证 gate-keeper 文件完整性 |
| — | 绕过检测 | Deployment 缺少 `gate-keeper-run-id` annotation 即告警 |

---

## 自定义检查 / Custom Checks

四种检查模式，覆盖违规检测和合规验证双向需求：

Four check modes covering both violation detection and compliance validation:

### pattern — 找到即违规 / Found = Violation

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

### must_match — 找到即合规，没找到即违规 / Found = Compliance

```yaml
custom_checks:
  - id: port_decision_app
    must_match: "PORT.*8000"
    paths: "docker-compose.prod.yml"
    severity: warning
    fix_hint: "Ensure decision-app listens on port 8000"

  - id: all_services_healthcheck
    must_match: "healthcheck:"
    must_match_count: 5              # 至少 5 个匹配 / At least 5 matches
    paths: "docker-compose.prod.yml"
    severity: critical
```

### command — 任意命令 / Arbitrary Command

```yaml
custom_checks:
  - id: ruff_check
    command: "ruff check apps/ --quiet"
    severity: warning
    description: "Python linter"
```

### drift — 漂移检测 / Drift Detection

```yaml
custom_checks:
  # 全局漂移：A 存在 → B 也必须存在
  - id: rls_activation
    pattern: "DefineRLSPolicy"
    requires: "ActivateRLS"
    severity: critical
    fix_hint: "Call ActivateRLS() in main.go"

  # 按文件漂移：每个含 A 的文件都必须含 B
  - id: handler_auth
    pattern: "func Handle"
    requires: "ParseAccessToken"
    drift_mode: per_file
    paths: "handlers/"

  # 注释漂移：pattern 只在注释中出现 = 被禁用了
  - id: frontend_auth
    pattern: "useAuth"
    drift_mode: commented
    paths: "src/"
    fix_hint: "Uncomment auth code"
```

---

## 插件系统 / Plugin System

从 Git 仓库安装第三方规则包：

Install third-party rule packs from Git repositories:

```bash
gate-keeper plugin install https://github.com/org/gk-rules-k8s-security
gate-keeper plugin list
gate-keeper run --tags=security    # 仅运行带 security 标签的检查
```

规则包结构 / Plugin structure:

```
gk-rules-k8s-security/
├── metadata.yaml          # name, version, description
├── checks/
│   ├── no-privileged/
│   │   ├── check.sh       # 检查脚本 / Check script
│   │   └── metadata.yaml  # id, severity, tags, compliance, fix_hint
│   └── resource-limits/
└── README.md
```

---

## 配置文件 / Configuration

运行 `gate-keeper init` 自动生成，或手动创建 `.gatekeeper.yaml`：

```yaml
version: 1
project: my-project
namespace: production

layer1:
  secretref_ban:
    enabled: true
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
      exclude_dirs: "dist,node_modules"

    - id: port_check
      must_match: "PORT.*8000"
      paths: "docker-compose.prod.yml"
      severity: warning

layer2:
  deployment_name_match: true
  secret_key_match: true

layer3:
  healthz: true
  pod_status: true
```

### 项目模板 / Templates

| 模板 / Template | 适用 / For |
|---|---|
| k8s-go | K8s + Go 项目 |
| k8s-python | K8s + Python 项目 |
| nextjs | Next.js 项目 |
| monorepo | Monorepo 项目 |
| docker-compose | Docker Compose 项目 |
| minimal | 最小配置 |

### .gatekeeperignore

类似 `.gitignore`，全局排除目录和文件：

Like `.gitignore`, globally exclude directories/files from all pattern checks:

```
dist/
node_modules/
__pycache__/
*.min.js
```

---

## 审计与可观测 / Audit & Observability

每次运行自动生成 JSON 审计日志到 `.gate-audit/`：

Every run generates a JSON audit log in `.gate-audit/`:

```json
{
  "timestamp": "2026-04-05T09:01:36Z",
  "git_sha": "ef928a6",
  "project": "my-project",
  "fail_on": "critical",
  "passed": 9,
  "failed": 0,
  "high": 0,
  "warnings": 2,
  "infos": 0,
  "verdict": "WARNED"
}
```

### 趋势分析 / Trend Analysis

```bash
$ gate-keeper audit --trend
Pass Rate Trend (last 10 runs):

2026-04-01  ████████████████████  100%
2026-04-02  ██████████████░░░░░░   70%
2026-04-03  ████████████████████  100%
```

### 耗时热力图 / Duration Heatmap

```bash
$ gate-keeper audit --heatmap
Check Duration Heatmap:

[H ] Port chain consistency       ██████████  450ms
[A ] go.work validation           ████        120ms
[B ] Shell script syntax           ██           45ms
```

---

## 输出示例 / Output Example

```
============================================
  Gate Keeper v2.0.0 · my-project
============================================

── Layer 1: Static Checks ──

  ✓ [A] go.work validation              PASS  (12ms)
  ✓ [B] Shell script syntax              PASS  (45ms)
  ✓ [C] Python packaging                 PASS  (8ms)
  ✓ [D] Dockerfile COPY paths            PASS  (23ms)
  ✓ [E] Dockerfile anti-patterns         PASS  (15ms)
  ✓ [F] secretRef ban                    PASS  (6ms)
  ⚠ [G] Deprecated component refs        WARN  (8ms)
  ✓ [H] Port chain consistency           PASS  (31ms)
  ✓ [I] Namespace consistency            PASS  (5ms)

============================================
  PASSED: 8/9 checks, 1 warning(s) (153ms)
  Audit: .gate-audit/2026-04-05T09-01-36Z-ef928a6.json
============================================
```

---

## GitHub Action

```yaml
jobs:
  gate-keeper:
    name: Gate Keeper
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install gate-keeper
        run: curl -sL https://raw.githubusercontent.com/NiuChou/gate-keeper/main/install.sh | bash
      - name: Run checks
        run: gate-keeper run --layer=1 --format=sarif --fail-on=high > results.sarif
      - name: Upload SARIF
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: results.sarif
```

---

## 监督流 / Supervision

Gate Keeper 包含自监督机制，防止被绕过或篡改：

Gate Keeper includes self-supervision to prevent bypass or tampering:

| 机制 / Mechanism | 说明 / Description |
|---|---|
| **篡改检测** | `gate-keeper stamp` 生成 SHA256 hash，CI 中 `stamp --verify` 验证 |
| **绕过检测** | 成功运行后自动为 Deployment 打上 `gate-keeper-run-id` annotation |
| **自检** | `gate-keeper doctor` 验证配置、依赖、hash 完整性 |
| **审计留痕** | 每次运行生成 JSON 审计日志，不可回避 |

---

## Claude Code Skill

```
/gate          # 运行全部检查 / Run all checks
/gate init     # 生成配置 / Generate config
/gate audit    # 查看审计日志 / View audit logs
```

---

## 起源 / Origin

Gate Keeper 诞生于 Perseworks v1.6.4 部署过程中的 30 个错误。经 14 轮纠错后，将所有教训系统化为三层自动化检查体系。

Born from 30 deployment errors during Perseworks v1.6.4 rollout. After 14 rounds of fixes, all lessons were systematized into a three-layer automated check system.

---

## 许可证 / License

MIT
