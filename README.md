# Gate Keeper

三层自动化部署守门员——构建前静态检查、部署前集群校验、部署后运行时验证，配置驱动、审计留痕、失败即阻止。

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
```

---

## 三层守门员 / Three Layers

| 层级 / Layer | 时机 / When | 检查内容 / What | 依赖 / Requires |
|---|---|---|---|
| **Layer 1: 静态检查** | 构建前 / Before build | go.work、Dockerfile、secretRef 禁用、端口链、namespace 一致性 + 自定义检查 | 无 / Nothing |
| **Layer 2: 集群校验** | 部署前 / Before deploy | Deployment 名匹配、镜像名匹配、Secret key 匹配 | kubectl |
| **Layer 3: 运行时验证** | 部署后 / After deploy | 健康检查、Pod 状态、负载测试 | kubectl |

每层全部通过才放行下一层。任一 critical 失败即阻止部署，warning 仅告警不阻止。

Each layer must pass before the next runs. Any critical failure blocks deployment; warnings alert but don't block.

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
| F | secretRef 禁用 | 禁止 secretRef 注入全部 key，必须逐个 secretKeyRef（支持 `exclude_pattern`） |
| G | 废弃组件引用 | 检测已废弃的组件名（可自定义 patterns） |
| H | 端口链一致性 | containerPort = probePort = targetPort（支持命名端口 / supports named ports） |
| I | namespace 一致性 | 所有 YAML 的 namespace 必须一致（支持 `expect` 配置） |
| * | 自定义检查 | 通过 `custom_checks` 配置 pattern 或 command |

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

## 命令 / Commands

```bash
gate-keeper init                # 检测项目类型，生成 .gatekeeper.yaml
gate-keeper run                 # 运行检查（默认全部三层）
gate-keeper run --layer=1       # 仅 Layer 1
gate-keeper run --layer=2       # Layer 1 + 2 (累积 / cumulative)
gate-keeper run --ci            # CI 模式（无颜色，JSON 输出）
gate-keeper audit               # 查看审计日志
gate-keeper audit --last=10     # 最近 10 条
gate-keeper audit --diff        # 对比最近两次运行的变化
gate-keeper doctor              # 自检：配置、依赖、完整性、hash 验证
gate-keeper add                 # 添加自定义检查项到配置
gate-keeper stamp               # 生成 SHA256 hash 文件（篡改检测基线）
gate-keeper stamp --verify      # 验证文件完整性
gate-keeper version             # 版本号
gate-keeper help                # 帮助
```

### gate-keeper add

动态添加自定义 grep 检查项到 `.gatekeeper.yaml`：

Dynamically add custom grep-based checks to `.gatekeeper.yaml`:

```bash
gate-keeper add \
  --id=no_console_log \
  --pattern="console.log" \
  --paths="src/**/*.ts" \
  --severity=warning \
  --description="Ban console.log in source"
```

### gate-keeper stamp

生成 gate-keeper 脚本文件的 SHA256 hash 基线，用于 CI 中检测篡改：

Generate SHA256 hash baseline for tamper detection in CI:

```bash
gate-keeper stamp               # 生成 .gate-keeper.sha256
gate-keeper stamp --verify      # 验证完整性
```

---

## Severity 分级 / Severity Levels

每个检查项可配置 `severity`：

Each check can be configured with `severity`:

| 级别 / Level | 行为 / Behavior |
|---|---|
| `critical`（默认） | 失败 → 阻止部署 (BLOCKED) |
| `warning` | 失败 → 仅警告 (WARNED)，不阻止 |

```yaml
layer1:
  secretref_ban:
    enabled: true
    severity: critical       # 失败即阻止
  shell_syntax:
    enabled: true
    severity: warning        # 失败仅警告
```

---

## GitHub Action

```yaml
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: NiuChou/gate-keeper@v1
        with:
          layer: 1

  deploy:
    needs: validate
    runs-on: [self-hosted, linux]
    steps:
      - uses: NiuChou/gate-keeper@v1
        with:
          layer: 2
```

Action 内置完整性验证：若仓库包含 `.gate-keeper.sha256`，会在运行前自动验证文件未被篡改。

Built-in integrity check: if `.gate-keeper.sha256` exists, files are verified before execution.

---

## Claude Code Skill

```
/gate          # 运行全部检查 / Run all checks
/gate init     # 生成配置 / Generate config
/gate audit    # 查看审计日志 / View audit logs
```

---

## 配置文件 / Configuration

运行 `gate-keeper init` 自动生成，或手动创建 `.gatekeeper.yaml`：

Run `gate-keeper init` to auto-generate, or create `.gatekeeper.yaml` manually:

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
    enabled: true
    severity: critical
  namespace_consistency:
    enabled: true
    severity: critical
    expect: "production"
  deprecated_refs:
    enabled: true
    severity: warning
    patterns: ["minio", "kafka"]

  # 自定义检查 / Custom checks
  custom_checks:
    - id: no_console_log
      pattern: "console.log"
      paths: "src/**/*.ts"
      severity: warning
      description: "Ban console.log"
      exclude_dirs: "dist,node_modules"    # 排除目录 / Exclude directories
      fix_hint: "Remove console.log before production."  # 修复建议 / Fix suggestion
    - id: lint_check
      command: "npm run lint --silent"
      description: "Run linter"

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

类似 `.gitignore`，全局排除目录和文件，避免每条规则重复配置：

Like `.gitignore`, globally exclude directories/files from all pattern checks:

```
# .gatekeeperignore
dist/
node_modules/
__pycache__/
*.min.js
```

---

## 审计日志 / Audit Logs

每次运行自动生成 JSON 审计日志到 `.gate-audit/`：

Every run generates a JSON audit log in `.gate-audit/`:

```json
{
  "timestamp": "2026-04-04T18:30:00Z",
  "git_sha": "13c652a",
  "project": "perseworks",
  "passed": 9,
  "failed": 0,
  "warnings": 2,
  "verdict": "WARNED"
}
```

Verdict 取值 / Verdict values: `PASSED` | `WARNED` | `BLOCKED`

---

## 输出示例 / Output Example

```
============================================
  Gate Keeper v1.2.0 · perseworks
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
  Audit: .gate-audit/2026-04-04T18-30-00Z-13c652a.json
============================================
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

## 起源 / Origin

Gate Keeper 诞生于 Perseworks v1.6.4 部署过程中的 30 个错误。经 14 轮纠错后，将所有教训系统化为三层自动化检查体系。

Born from 30 deployment errors during Perseworks v1.6.4 rollout. After 14 rounds of fixes, all lessons were systematized into a three-layer automated check system.

---

## 许可证 / License

MIT
