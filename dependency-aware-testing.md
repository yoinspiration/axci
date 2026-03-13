# axci 通用：依赖感知测试选择设计

> 本文档聚焦 **axci 的通用设计**（配置驱动、可复用）。  
> 如需看来源案例（AxVisor 的具体规则和验证场景），见 [`axvisor-case-study.md`](./axvisor-case-study.md)。

## 1. 目标

在 CI 中根据“实际受影响范围”自动选择测试目标，减少不必要的全量测试，同时保持风险可控。

axci 的定位是通用测试编排框架，不绑定某个业务仓库。项目只需要提供规则文件，即可复用同一套检测逻辑。

## 2. 整体架构

axci 的依赖感知由三层组成：

1. **规则层（配置）**
   - 文件：`configs/test-target-rules.json`
   - 负责描述：哪些路径/哪些 crate 变化会触发哪些目标。

2. **分析层（引擎/脚本）**
   - Rust 引擎：`axci-affected/`（推荐，语义集中且可测试）
   - Bash 回退：`scripts/affected_crates.sh` + `tests.sh` 中的兼容逻辑
   - 负责计算：`changed_crates`、`affected_crates`、`skip_all`、`targets`

3. **编排层（执行入口）**
   - 本地入口：`tests.sh --auto-target`
   - CI 入口：`.github/workflows/test.yml` detect job
   - 负责将分析结果转成测试矩阵并执行。

## 3. 分析流程（通用）

分析流程与具体项目无关，核心是三步：

1. **变更检测**
   - `git diff --name-only <base_ref>`
   - 得到变更文件列表，先应用 non-code/skip 规则。

2. **依赖传播**
   - `cargo metadata` 获取 workspace 与依赖关系
   - 从直接修改 crate（`changed_crates`）出发，按反向依赖 BFS 计算 `affected_crates`。

3. **目标映射**
   - 路径规则（`run_all_patterns`/`selection_rules`）
   - crate 规则（`run_all_crates`/`crate_rules`/`crate_path_rules`）
   - 取并集得到最终测试目标；如命中全量规则则直接全量。

## 4. 规则模型（test-target-rules.json）

以下字段是依赖感知的关键扩展：

- `run_all_patterns`
  - 路径匹配触发全量（例如根构建文件、关键目录）。

- `run_all_exclude_patterns`（可选）
  - 与 `run_all_patterns` 联用：命中 run_all 后再排除特定子路径。
  - 常用于“目录整体全量，但某些子目录走精确匹配”。

- `selection_rules`
  - 路径到目标的映射（精确触发）。

- `run_all_crates`
  - 若 `changed_crates` 与其有交集，触发全量。
  - 适合核心基础 crate（直接改动即全量）。

- `crate_rules`
  - 按 crate 命中目标。
  - 支持 `direct_only`：
    - `true`：看 `changed_crates`
    - `false`：看 `affected_crates`

- `crate_path_rules`（可选）
  - “crate + 路径”联合规则，用于同一 crate 内按目录进一步细分目标。
  - 字段：`crates`、`path_patterns`、`targets`、`direct_only`
  - 行为：规则按顺序匹配，同一文件命中第一条后停止。

## 5. 引擎与回退策略

### 5.1 Rust 引擎（优先）

- 可执行文件：`axci-affected/target/release/axci-affected`
- 用法：
  - `axci-affected <repo_dir> <base_ref> [rules_path]`
- 输出：
  - `{"skip_all": bool, "targets": ["target_key", ...]}`

优点：规则语义集中、行为稳定、易做一致性验证。

### 5.2 Bash 兼容回退

当 Rust 引擎不可用时：

- `tests.sh` 回退到 Bash 逻辑
- `scripts/affected_crates.sh` 负责输出：
  - `changed_crates`
  - `affected_crates`
  - `file_to_crate`

这样可以在无预编译引擎时保持功能可用。

## 6. 本地与 CI 使用

### 6.1 本地验证引擎

```bash
cd /path/to/axci
./scripts/verify_affected.sh [组件目录] [base_ref]
```

示例：

```bash
./scripts/verify_affected.sh . HEAD~1
./scripts/verify_affected.sh /path/to/component origin/main
```

### 6.2 本地仅解析目标（不跑测试）

```bash
/path/to/axci/tests.sh --auto-target --base-ref HEAD~1 -n
```

`-n` 用于演示和调试：只看自动选目标结果，不执行实际测试。

### 6.3 CI detect job 行为

detect job 会：

1. 准备环境（必要时安装 Rust）
2. 尝试运行 `axci-affected`
3. 失败或不可用时回退到 Bash 逻辑
4. 输出 `skip_all` 与目标列表，构造测试矩阵
5. 若矩阵为空则测试 job 自动跳过

## 7. 为什么这是“通用设计”

axci 的依赖感知不把业务规则写死在代码里，而是把“项目差异”收敛到规则配置：

- 换仓库主要改 `test-target-rules.json`
- 分析与编排逻辑保持不变
- 同一套机制可复用于 AxVisor、Starry 等项目

这使得规则演进（新增板子、调整路径、细化 crate）更低成本。

## 8. 迁移建议（新项目接入）

1. 先定义目标 key（QEMU/板级等）
2. 先配路径规则（`run_all_patterns` + `selection_rules`）
3. 再逐步加 `run_all_crates` / `crate_rules`
4. 需要细粒度时再引入 `crate_path_rules`
5. 用 `verify_affected.sh` 做样例回归

## 9. 新项目接入模板（最小可用）

下面是一个可直接复制的最小模板。先跑通，再按项目逐步细化。

```json
{
  "non_code": {
    "dirs": ["doc/", "docs/"],
    "exts": [".md", ".txt", ".png", ".jpg", ".svg"],
    "files": ["LICENSE", ".gitignore", ".gitattributes"]
  },
  "run_all_patterns": ["Cargo.toml", "Cargo.lock", "rust-toolchain.toml", ".github/workflows/*"],
  "run_all_exclude_patterns": [],
  "selection_rules": [
    {
      "id": "qemu_path",
      "patterns": ["platform/qemu/*", "configs/board/*qemu*"],
      "targets": ["qemu-aarch64", "qemu-x86_64"]
    },
    {
      "id": "board_a_path",
      "patterns": ["*board-a*", "*soc-a*"],
      "targets": ["board-a"]
    }
  ],
  "target_order": ["qemu-aarch64", "qemu-x86_64", "board-a"],
  "run_all_crates": ["runtime-core", "config-core"],
  "crate_rules": [
    {
      "id": "crate_fs",
      "crates": ["fs"],
      "targets": ["qemu-aarch64", "board-a"],
      "direct_only": false
    }
  ],
  "crate_path_rules": [
    {
      "id": "driver_board_a",
      "crates": ["driver"],
      "path_patterns": ["*board-a*", "*soc-a*"],
      "targets": ["board-a"],
      "direct_only": false
    }
  ]
}
```

接入步骤（推荐顺序）：

1. 先只配置 `non_code`、`run_all_patterns`、`selection_rules`、`target_order`
2. 确认路径规则命中符合预期后，再加入 `run_all_crates`
3. 最后加 `crate_rules` 与 `crate_path_rules` 做依赖感知增强
4. 每次改规则后执行：
   - `./scripts/verify_affected.sh /path/to/component <base_ref>`
   - `/path/to/axci/tests.sh --auto-target --base-ref <base_ref> -n`

## 10. 相关文档

- 通用设计（本文）：`dependency-aware-testing.md`
- 案例说明（AxVisor）：`axvisor-case-study.md`
