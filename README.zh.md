# Gate Keeper

**三层自动化部署闸门** — 构建前静态检查、部署前集群校验、部署后运行时验证。配置驱动、审计留痕、失败即阻止。

Three-layer automated deployment gatekeeper — static checks before build, cluster validation before deploy, runtime verification after deploy. Config-driven, audit-logged, fail-to-block.

---

[English](README.md) | 中文文档

---

## 快速开始

```bash
# 安装
curl -sL https://raw.githubusercontent.com/NiuChou/gate-keeper/main/install.sh | bash

# 初始化配置（自动检测项目类型）
gate-keeper init

# 运行检查
gate-keeper run --layer=1      # 仅静态检查
gate-keeper run                # 全部三层

# 智能推荐
gate-keeper suggest
```

## 三层守门员

| 层级 | 时机 | 检查内容 | 依赖 |
|---|---|---|---|
| **Layer 1: 静态检查** | 构建前 | go.work、Dockerfile、secretRef 禁用、端口链、namespace 一致性 + 自定义检查 | 无 |
| **Layer 2: 集群校验** | 部署前 | Deployment 名匹配、镜像名匹配、Secret key 匹配 | kubectl |
| **Layer 3: 运行时验证** | 部署后 | 健康检查、Pod 状态、负载测试 | kubectl |

每层全部通过才放行下一层。失败行为取决于 severity 和 `--fail-on` 阈值。

## 四级 Severity

| 级别 | 状态码 | 显示 | 行为 |
|---|---|---|---|
| `critical`（默认） | FAIL | ✗ 红色 | 阻止部署 |
| `high` | HIGH | ! 红色 | `--fail-on=high` 时阻止 |
| `warning` | WARN | ⚠ 黄色 | 仅警告，exit 2 |
| `info` | INFO | ℹ 蓝色 | 信息提示，不影响退出码 |

### 退出码

| 退出码 | 含义 | 场景 |
|---|---|---|
| 0 | 全部通过 | 无失败或警告 |
| 1 | 阻断 | 存在达到 `--fail-on` 阈值的失败 |
| 2 | 仅警告 | 有警告但未达到阻断阈值 |

## 命令

```bash
gate-keeper init                # 检测项目类型，生成 .gatekeeper.yaml
gate-keeper run                 # 运行检查（默认全部三层）
gate-keeper run --layer=1       # 仅 Layer 1
gate-keeper run --ci            # CI 模式（无颜色，JSON 输出）
gate-keeper suggest             # 分析项目结构，推荐检查项
gate-keeper audit               # 查看审计日志
gate-keeper audit --diff        # 对比最近两次运行
gate-keeper audit --trend       # 通过率趋势图
gate-keeper audit --export=csv  # 导出审计历史为 CSV
gate-keeper audit --heatmap     # 检查耗时热力图
gate-keeper plugin install URL  # 从 Git URL 安装规则包
gate-keeper plugin list         # 列出已安装插件
gate-keeper plugin remove NAME  # 删除插件
gate-keeper doctor              # 自检
gate-keeper add                 # 添加自定义检查项
gate-keeper stamp               # 生成 SHA256 hash 基线
gate-keeper stamp --verify      # 验证文件完整性
```

### run 选项

| 参数 | 默认 | 说明 |
|---|---|---|
| `--layer=1\|2\|3\|all` | all | 运行的层级 |
| `--format=text\|json\|sarif\|junit\|html` | text | 输出格式 |
| `--fail-on=critical\|high\|warning\|none` | critical | 失败阈值 |
| `--parallel=N` | auto | 最大并发检查数 |
| `--dry-run` | — | 预览检查列表，不执行 |
| `--quiet` | — | 仅输出 FAIL/WARN/HIGH |
| `--tags=TAG` | — | 按标签过滤检查 |
| `--ci` | — | CI 模式 |

## 输出格式

| 格式 | 用途 |
|---|---|
| `text` | 终端查看 |
| `json` | 审计日志 |
| `sarif` | GitHub Security Alert / VS Code |
| `junit` | Jenkins / GitLab 测试报告 |
| `html` | 独立 HTML 报告（内联 CSS，可分享） |

```bash
gate-keeper run --format=sarif > results.sarif   # GitHub Security
gate-keeper run --format=junit > results.xml     # Jenkins/GitLab
gate-keeper run --format=html > report.html      # 可分享报告
```

## 自定义检查

四种检查模式，覆盖违规检测和合规验证双向需求：

### pattern — 找到即违规

```yaml
custom_checks:
  - id: no_debug_production
    pattern: "DEBUG.*True"
    paths: "."
    severity: critical
    fix_hint: "移除 DEBUG=True，使用 LOG_LEVEL=INFO"
    exclude_dirs: "dist,node_modules"
    tags: "security"
```

### must_match — 找到即合规，没找到即违规

```yaml
custom_checks:
  - id: port_decision_app
    must_match: "PORT.*8000"
    paths: "docker-compose.prod.yml"
    severity: warning

  - id: all_services_healthcheck
    must_match: "healthcheck:"
    must_match_count: 5              # 至少 5 个匹配
    paths: "docker-compose.prod.yml"
    severity: critical
```

### command — 任意命令

```yaml
custom_checks:
  - id: ruff_check
    command: "ruff check apps/ --quiet"
    severity: warning
```

### drift — 漂移检测

```yaml
custom_checks:
  # 全局漂移：A 存在 → B 也必须存在
  - id: rls_activation
    pattern: "DefineRLSPolicy"
    requires: "ActivateRLS"
    severity: critical

  # 按文件漂移：每个含 A 的文件都必须含 B
  - id: handler_auth
    pattern: "func Handle"
    requires: "ParseAccessToken"
    drift_mode: per_file

  # 注释漂移：pattern 只在注释中出现 = 被禁用了
  - id: frontend_auth
    pattern: "useAuth"
    drift_mode: commented
```

## 插件系统

```bash
gate-keeper plugin install https://github.com/org/gk-rules-k8s-security
gate-keeper run --tags=security
```

规则包结构：

```
gk-rules-k8s-security/
├── metadata.yaml          # name, version, description
├── checks/
│   ├── no-privileged/
│   │   ├── check.sh       # 检查脚本（exit 0 = PASS）
│   │   └── metadata.yaml  # id, severity, tags, compliance, fix_hint
│   └── resource-limits/
└── README.md
```

## 配置文件

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
      fix_hint: "生产环境移除 console.log"
```

### 项目模板

| 模板 | 适用 |
|---|---|
| k8s-go | K8s + Go 项目 |
| k8s-python | K8s + Python 项目 |
| nextjs | Next.js 项目 |
| monorepo | Monorepo 项目 |
| docker-compose | Docker Compose 项目 |
| minimal | 最小配置 |

### .gatekeeperignore

```
dist/
node_modules/
__pycache__/
*.min.js
```

## 审计与可观测

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

## 监督流

| 机制 | 说明 |
|---|---|
| **篡改检测** | `gate-keeper stamp` 生成 SHA256 hash，CI 中 `stamp --verify` 验证 |
| **绕过检测** | 成功运行后自动为 Deployment 打上 `gate-keeper-run-id` annotation |
| **自检** | `gate-keeper doctor` 验证配置、依赖、hash 完整性 |
| **审计留痕** | 每次运行生成 JSON 审计日志，不可回避 |

## 起源

Gate Keeper 诞生于 Perseworks v1.6.4 部署过程中的 30 个错误。经 14 轮纠错后，将所有教训系统化为三层自动化检查体系。

## 许可证

MIT
