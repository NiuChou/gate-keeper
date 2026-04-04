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
| **Layer 1: 静态检查** | 构建前 / Before build | go.work、Dockerfile、secretRef 禁用、端口链、namespace 一致性 | 无 / Nothing |
| **Layer 2: 集群校验** | 部署前 / Before deploy | Deployment 名匹配、镜像名匹配、Secret key 匹配 | kubectl |
| **Layer 3: 运行时验证** | 部署后 / After deploy | 健康检查、Pod 状态、负载测试 | kubectl |

每层全部通过才放行下一层。任一失败即阻止部署。

Each layer must pass before the next runs. Any failure blocks deployment.

---

## 检查项清单 / Check List

### Layer 1: 静态检查（9 项）

| ID | 检查 / Check | 说明 / Description |
|---|---|---|
| A | go.work 验证 | use 路径指向存在的目录且含 go.mod |
| B | Shell 语法 | bash -n 语法检查 |
| C | Python 打包 | 无重复 setup.py + pyproject.toml |
| D | Dockerfile COPY | COPY 源路径存在 |
| E | Dockerfile 反模式 | 无 -e 安装、无 -dev 包 |
| F | secretRef 禁用 | 禁止 secretRef 注入全部 key，必须逐个 secretKeyRef |
| G | 废弃组件引用 | 检测已废弃的组件名（可自定义） |
| H | 端口链一致性 | containerPort = probePort = targetPort |
| I | namespace 一致性 | 所有 YAML 的 namespace 必须一致 |

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
gate-keeper doctor              # 自检：配置、依赖、完整性
gate-keeper version             # 版本号
gate-keeper help                # 帮助
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
  secretref_ban: true
  port_chain: true
  namespace_consistency: true
  deprecated_refs:
    enabled: true
    patterns: ["minio", "kafka"]

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
| minimal | 最小配置 |

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
  "verdict": "PASSED"
}
```

---

## 输出示例 / Output Example

```
============================================
  Gate Keeper v1.0.0 · perseworks
============================================

── Layer 1: Static Checks ──

  ✓ [A] go.work validation              PASS  (12ms)
  ✓ [B] Shell script syntax              PASS  (45ms)
  ✓ [C] Python packaging                 PASS  (8ms)
  ✓ [D] Dockerfile COPY paths            PASS  (23ms)
  ✓ [E] Dockerfile anti-patterns         PASS  (15ms)
  ✓ [F] secretRef ban                    PASS  (6ms)
  ✓ [G] Deprecated component refs        PASS  (8ms)
  ✓ [H] Port chain consistency           PASS  (31ms)
  ✓ [I] Namespace consistency            PASS  (5ms)

============================================
  PASSED: 9/9 checks (153ms)
  Audit: .gate-audit/2026-04-04T18-30-00Z-13c652a.json
============================================
```

---

## 起源 / Origin

Gate Keeper 诞生于 Perseworks v1.6.4 部署过程中的 30 个错误。经 14 轮纠错后，将所有教训系统化为三层自动化检查体系。

Born from 30 deployment errors during Perseworks v1.6.4 rollout. After 14 rounds of fixes, all lessons were systematized into a three-layer automated check system.

---

## 许可证 / License

MIT
