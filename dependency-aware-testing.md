# 依赖感知的测试目标选择

## 背景与动机

AxVisor 是一个运行在多种硬件平台上的 Hypervisor，其集成测试需要在 QEMU 模拟器和真实开发板上执行。在此之前，每次代码提交（push/PR）都会触发**全部**测试配置（QEMU aarch64、QEMU x86_64、飞腾派、RK3568），即使只修改了一行文档或某个板级驱动也是如此。

这带来了两个问题：

1. **硬件资源浪费**：自托管 Runner 连接的开发板是稀缺资源，不必要的测试会阻塞其他任务。
2. **反馈延迟**：全量测试耗时长，开发者等待时间增加。

与此同时，AxVisor 采用 Cargo workspace 组织多个 crate，crate 之间存在依赖关系。当一个底层模块（如 `axruntime`）被修改时，所有依赖它的上层模块都应该被重新测试——这就是**依赖感知测试**的核心需求。

## 设计概述

### 三阶段分析流程

```
┌─────────────────────────────────────────────────────────┐
│  阶段 1：变更检测                                         │
│  git diff --name-only <base_ref>                         │
│  → 获取变更文件列表                                       │
│  → 过滤非代码文件（文档、图片等）                           │
└─────────────────────┬───────────────────────────────────┘
                      ▼
┌─────────────────────────────────────────────────────────┐
│  阶段 2：依赖传播                                         │
│  cargo metadata → 构建 workspace 反向依赖图                │
│  BFS 遍历 → 找出所有间接受影响的 crate                     │
└─────────────────────┬───────────────────────────────────┘
                      ▼
┌─────────────────────────────────────────────────────────┐
│  阶段 3：目标映射                                         │
│  10 条规则将受影响的 crate + 变更文件                      │
│  映射到具体的测试目标（QEMU/开发板）                        │
└─────────────────────────────────────────────────────────┘
```

### Workspace 内部依赖图

通过 `cargo metadata` 自动提取的 workspace 内部反向依赖关系：

```
axconfig     ← axruntime, axvisor
axruntime    ← axvisor
axfs         ← (axruntime 间接依赖)
driver       ← axvisor
axplat-x86-qemu-q35 ← axruntime (仅 x86_64 目标)
```

当某个 crate 被修改时，沿着反向依赖链向上传播。例如：

- 修改 `axconfig` → `axruntime` 受影响 → `axvisor` 受影响
- 修改 `driver` → `axvisor` 受影响
- 修改 `axplat-x86-qemu-q35` → `axruntime` 受影响（但这是条件编译依赖，仅 x86_64）

### 测试目标

| 目标 ID | 说明 | Runner 标签 |
|---------|------|-------------|
| `qemu_aarch64` | QEMU AArch64 模拟测试 | `[self-hosted, linux, intel]` |
| `qemu_x86_64` | QEMU x86_64 模拟测试 | `[self-hosted, linux, intel]` |
| `board_phytiumpi` | 飞腾派开发板测试 | `[self-hosted, linux, phytiumpi]` |
| `board_rk3568` | ROC-RK3568-PC 开发板测试 | `[self-hosted, linux, roc-rk3568-pc]` |

## 映射规则

分析引擎按以下 10 条规则（优先级从高到低）将变更映射到测试目标：

### 全量触发规则（返回所有目标）

| 规则 | 触发条件 | 理由 |
|------|----------|------|
| Rule 1 | 根构建配置变更：`Cargo.toml`、`Cargo.lock`、`rust-toolchain.toml` | 依赖或工具链变更影响所有构建 |
| Rule 2 | `xtask/` 源码被**直接修改** | 构建工具变更可能影响所有构建流程 |
| Rule 3 | `axruntime` 或 `axconfig` 被**直接修改** | 核心基础模块，所有平台都依赖 |
| Rule 4 | `kernel/` 下非架构特定的代码变更（不在 `kernel/src/hal/arch/` 下） | VMM、Shell、调度等通用逻辑 |

### 精确触发规则

| 规则 | 触发条件 | 触发目标 |
|------|----------|----------|
| Rule 5 | `kernel/src/hal/arch/aarch64/` 变更 | `qemu_aarch64` + `board_phytiumpi` + `board_rk3568` |
| Rule 5 | `kernel/src/hal/arch/x86_64/` 变更 | `qemu_x86_64` |
| Rule 6 | `axplat-x86-qemu-q35` crate 受影响 | `qemu_x86_64` |
| Rule 7 | `axfs` crate 受影响 | `qemu_aarch64` + `board_phytiumpi` + `board_rk3568` |
| Rule 8 | `driver` crate 受影响 — 飞腾派相关文件 | `board_phytiumpi` |
| Rule 8 | `driver` crate 受影响 — Rockchip 相关文件 | `board_rk3568` |
| Rule 8 | `driver` crate 受影响 — 通用驱动文件 | `board_phytiumpi` + `board_rk3568` |
| Rule 9 | `.github/workflows/` 下 QEMU 相关配置 | `qemu_aarch64` + `qemu_x86_64` |
| Rule 9 | `.github/workflows/` 下 Board/UBoot 相关配置 | `board_phytiumpi` + `board_rk3568` |
| Rule 10 | `configs/board/` 或 `configs/vms/` 下的配置文件 | 对应的特定目标 |

### 跳过规则

以下文件变更不触发任何测试（`skip_all=true`）：

- `doc/` 目录下的文件
- `*.md`、`*.txt`、`*.png`、`*.jpg`、`*.svg` 等
- `LICENSE`、`.gitignore`、`.gitattributes`

### 关于"直接修改"与"间接受影响"的区分

Rule 2 和 Rule 3 特意使用"直接修改的 crate"（`changed_crates`）而非"所有受影响的 crate"（`affected_crates`）进行判断。这是因为 `cargo metadata` 的依赖解析不区分条件编译依赖（`[target.'cfg(...)'.dependencies]`）。例如 `axruntime` 对 `axplat-x86-qemu-q35` 的依赖仅在 x86_64 目标下生效，但 `cargo metadata` 会无条件地将其包含在依赖图中。如果不区分，修改 x86 平台 crate 就会通过 `axruntime` 间接触发全量测试。

## 文件变更清单

| 文件 | 变更类型 | 说明 |
|------|----------|------|
| `xtask/src/affected.rs` | 新增 | 核心分析引擎（约 400 行） |
| `xtask/src/main.rs` | 修改 | 注册 `Affected` 子命令 |
| `.github/workflows/test-qemu.yml` | 修改 | 添加 `detect` job，动态构建测试矩阵 |
| `.github/workflows/test-board.yml` | 修改 | 添加 `detect` job，动态构建测试矩阵 |

## CI 工作流变更

### 改动前

```
push/PR → test-qemu job (固定 3 个矩阵项) → 全部在 self-hosted Runner 上执行
push/PR → test-board job (固定 4 个矩阵项) → 全部在 self-hosted Runner 上执行
```

### 改动后

```
push/PR → detect job (ubuntu-latest, 轻量级)
              │
              ├─ 分析影响范围
              ├─ 动态构建测试矩阵（仅包含受影响的目标）
              │
              └──→ test job (self-hosted Runner)
                   仅运行矩阵中的配置项
                   如果矩阵为空则整个 job 被跳过
```

`detect` job 运行在 GitHub 提供的标准 `ubuntu-latest` Runner 上，不占用稀缺的硬件 Runner 资源。通过 `actions/cache` 缓存 xtask 的编译产物，后续运行接近零开销。

## 使用方法

### 本地使用

```bash
# 对比 main 分支，查看需要运行哪些测试
cargo xtask affected --base origin/main

# 对比上一个 commit
cargo xtask affected --base HEAD~1

# 对比某个特定 commit
cargo xtask affected --base abc1234
```

输出示例：

```json
{
  "skip_all": false,
  "qemu_aarch64": true,
  "qemu_x86_64": false,
  "board_phytiumpi": false,
  "board_rk3568": false,
  "changed_crates": [
    "axvisor"
  ],
  "affected_crates": [
    "axvisor"
  ]
}
```

同时 `stderr` 会输出详细的分析过程，便于调试：

```
[affected] changed files (1):
  kernel/src/hal/arch/aarch64/api.rs
[affected] workspace crates: ["axvisor", "nop", "axconfig", ...]
[affected] reverse deps:
  axconfig ← {"axruntime", "axvisor"}
  axruntime ← {"axvisor"}
  driver ← {"axvisor"}
[affected] directly changed crates: {"axvisor"}
[affected] all affected crates:     {"axvisor"}
[affected] test scope: qemu_aarch64=true qemu_x86_64=false board_phytiumpi=false board_rk3568=false
```

### CI 中自动执行

无需手动操作。当 push 或创建 PR 时，CI 工作流会自动：

1. 运行 `detect` job 分析影响范围
2. 将分析结果写入 `$GITHUB_OUTPUT`
3. 根据结果动态构建测试矩阵
4. 仅在受影响的硬件 Runner 上执行测试

## 验证结果

以下场景已在本地通过验证：

| 场景 | 变更文件 | 结果 |
|------|----------|------|
| 只改文档 | `doc/shell.md` | `skip_all=true`，跳过所有测试 |
| 改 aarch64 HAL | `kernel/src/hal/arch/aarch64/api.rs` | QEMU aarch64 + 两块 ARM 开发板 |
| 改飞腾派驱动 | `modules/driver/src/blk/phytium.rs` | 仅飞腾派开发板 |
| 改 x86 平台 crate | `platform/x86-qemu-q35/src/lib.rs` | 仅 QEMU x86_64 |
| 改 axruntime | `modules/axruntime/src/lib.rs` | 全部测试（核心模块） |
| 改 kernel 通用代码 | `kernel/src/main.rs` | 全部测试 |
| 改 Rockchip 驱动 | `modules/driver/src/soc/rockchip/pm.rs` | 仅 RK3568 开发板 |

## 扩展指南

### 添加新的开发板

当添加新的开发板支持时，需要：

1. 在 `xtask/src/affected.rs` 的 `TestScope` 结构体中添加新的布尔字段
2. 在 `determine_targets()` 中添加对应的规则
3. 在 `run()` 中将新字段写入 `$GITHUB_OUTPUT`
4. 在 CI 工作流的 `Build board test matrix` 步骤中添加对应的矩阵项

### 添加新的 workspace crate

无需额外操作。`cargo metadata` 会自动发现新的 workspace 成员及其依赖关系。如果新 crate 是平台特定的，需要在 `determine_targets()` 中添加对应的映射规则。

### 修改规则

所有映射规则集中在 `xtask/src/affected.rs` 的 `determine_targets()` 函数中，便于统一维护。

---

## 在 axci 中的实现

上述依赖感知逻辑在 **axci** 仓库中通过「规则文件 + 通用脚本 + CI 接入」实现，可供所有使用 axci 工作流的仓库复用（包括 AxVisor、Starry 等）。

### 实现方式概览

| 层级 | 说明 |
|------|------|
| **规则** | `configs/test-target-rules.json` 增加可选字段 `run_all_crates`、`crate_rules` |
| **脚本** | `scripts/affected_crates.sh`：基于 `git diff` + `cargo metadata` 输出 `changed_crates` / `affected_crates` |
| **CI** | `.github/workflows/test.yml` 的 detect job：安装 Rust 后调用脚本，将结果与路径规则合并得到最终测试矩阵 |

### 规则文件扩展（test-target-rules.json）

- **run_all_crates**（数组）：若**直接修改**的 crate 名在该列表中，则触发全量测试。用于核心基础模块（如 `axruntime`、`axconfig`）。
- **run_all_exclude_patterns**（数组，可选）：与 `run_all_patterns` 配合使用。当某变更文件匹配了某个 `run_all_patterns` 时，若**同时**匹配本列表中的任一模式，则**不**触发全量。用于实现「该路径下除某子路径外均跑全量」，例如 kernel 下非架构特定代码跑全量、但 `kernel/src/hal/arch/*` 仍走精确规则：`run_all_patterns` 含 `kernel/*`，`run_all_exclude_patterns` 含 `kernel/src/hal/arch/*`。
- **crate_rules**（数组）：每条规则形如：
  - `crates`：crate 名列表
  - `targets`：触发的测试目标 key 列表
  - `direct_only`：若为 `true`，仅当该 crate 在 **changed_crates** 中时触发；若为 `false`，在 **affected_crates** 中即触发（含间接受影响）
- **crate_path_rules**（数组，可选，**axci-affected 引擎支持**）：「crate + 路径」联合规则。当某**变更文件**所属 crate 在规则的 `crates` 中、且文件路径匹配规则的 `path_patterns` 之一时，将该规则的 `targets` 加入选中目标。用于同一 crate 内按路径细分（如 driver：phytium 相关 → 仅飞腾派板，rockchip 相关 → 仅 RK3568，其余 → 两块板）。每条规则含：`crates`、`path_patterns`、`targets`、`direct_only`（含义同 crate_rules）。规则按配置顺序匹配，一个文件只命中第一条匹配的规则。

路径规则（`run_all_patterns`、`selection_rules`）与依赖规则**取并集**：路径匹配到的目标 + crate 规则匹配到的目标 + crate_path_rules 匹配到的目标一起作为最终选中的目标；若任一路径规则或 run_all_crates 命中，则跑全量。

### 脚本用法（本地或 CI）

```bash
# 从组件目录执行，对比 origin/main
/path/to/axci/scripts/affected_crates.sh . origin/main

# 输出 JSON
{"changed_crates":["axvisor"],"affected_crates":["axvisor"]}
```

脚本会：`git diff --name-only base_ref` → 用 `cargo metadata` 解析各文件所属 crate → 构建反向依赖图 → BFS 得到 affected。若无 `Cargo.toml` 或无 `cargo`，则输出空数组。

### CI 行为

1. detect job 中增加「Install Rust for dependency-aware detection」步骤（stable，无额外 components）。
2. 若规则文件存在且包含 `run_all_crates` 或 `crate_rules`，则执行 `affected_crates.sh`，得到 `CHANGED_CRATES_JSON`、`AFFECTED_CRATES_JSON`。
3. 路径规则照常计算；在此基础上：
   - 若 `changed_crates` 与 `run_all_crates` 有交集 → `NEEDS_ALL=true`
   - 对每条 `crate_rules`，按 `direct_only` 选用 changed 或 affected，命中则把该规则的 `targets` 加入 `SELECTED`。
4. 最终矩阵 = 路径选中的目标 ∪ 依赖规则选中的目标；若 `NEEDS_ALL` 则全量。

### Rust 引擎 axci-affected（可选）

axci 提供与上述规则和脚本**语义一致**的 Rust 程序 `axci-affected`，用于直接输出「是否跳过 + 有序目标列表」，便于维护与复用。

- **位置**：`axci-affected/`（独立 Cargo 项目，依赖 `serde`、`serde_json`、`cargo_metadata`）。
- **用法**：  
  `axci-affected <repo_dir> <base_ref> [rules_path]`  
  向 stdout 输出 JSON：`{"skip_all": bool, "targets": ["target_key", ...]}`；规则解析、路径匹配、non_code、run_all_patterns/selection_rules、crate 依赖计算（changed/affected）与 run_all_crates/crate_rules 均在引擎内完成。
- **优先级**：  
  - **tests.sh**：若存在可执行文件 `axci-affected/target/release/axci-affected`（相对 tests.sh 所在目录），则自动目标选择时优先调用该二进制，解析其 JSON 后设置 `TEST_TARGET` / `AUTO_DETECTED_TARGETS`；否则回退到原有 bash + `affected_crates.sh` 逻辑。  
  - **CI（test.yml）**：detect job 中会先执行 `cargo build --release` 构建 axci-affected；在 `test_targets: auto` 且规则有效时，若二进制可用且运行成功，则直接使用其输出的 `skip_all` 与 `targets` 生成矩阵，否则使用原有 bash 逻辑。

本地使用前需在 axci 仓库中执行：  
`cargo build --release -C axci-affected`（或 `cd axci-affected && cargo build --release`）。

### 验证

#### 1. 仅验证 axci-affected 引擎（在 axci 仓库内）

```bash
# 构建
cd /path/to/axci/axci-affected && cargo build --release

# 对当前仓库、对比 HEAD~1 跑一次（看变更文件和输出 JSON）
./target/release/axci-affected . HEAD~1 ../configs/test-target-rules.json 2>/dev/null | jq .

# 看 stderr 的变更文件与 changed/affected crates
./target/release/axci-affected . HEAD~1 ../configs/test-target-rules.json 2>&1
```

或用 axci 自带的验证脚本（在 axci 根目录执行）：

```bash
./scripts/verify_affected.sh [组件目录] [base_ref]
# 示例：./scripts/verify_affected.sh . HEAD~1
# 示例：./scripts/verify_affected.sh /path/to/axvisor origin/main
```

#### 2. 验证 tests.sh 自动目标（走引擎）

在**组件仓库**（如 AxVisor）中，用 axci 的 tests.sh，并确保 axci 里已编译好 axci-affected：

```bash
cd /path/to/axvisor
/path/to/axci/tests.sh --auto-target --base-ref HEAD~1 -n
# -n 只解析目标不跑测试；观察日志里是否出现「自动目标选择 (axci-affected): …」
```

可人为制造变更再验证：只改 `doc/readme.md` 期望 skip；只改 `kernel/src/hal/arch/aarch64/` 下文件期望仅 aarch64 目标。

#### 3. 验证 CI（detect job）

在组件仓库 push 分支并打开 PR，或使用 `workflow_dispatch` 调用 test workflow，传入 `test_targets: auto`、`base_ref: origin/main`；查看 detect job 日志中是否出现 `Auto detect reason: engine` 以及矩阵是否与预期一致。

### axci-affected 与 xtask Affected 规则对照

在默认 `configs/test-target-rules.json` 下，使用 **axci-affected** 引擎时与 xtask 的逐条对应关系如下（xtask 目标 ID 与 axci 的 target_key 对应关系：qemu_aarch64 → axvisor-qemu-aarch64-*，qemu_x86_64 → axvisor-qemu-x86_64-nimbos，board_phytiumpi → axvisor-board-phytiumpi-*，board_rk3568 → axvisor-board-roc-rk3568-pc-*）。

| xtask 规则 | 触发条件 | xtask 目标 | axci 实现 | 是否一致 |
|------------|----------|------------|-----------|----------|
| **跳过** | doc/、*.md、LICENSE 等 | skip_all | `non_code` | ✅ 一致 |
| **Rule 1** | Cargo.toml / Cargo.lock / rust-toolchain | 全量 | `run_all_patterns` | ✅ 一致 |
| **Rule 2** | xtask/ 直接修改 | 全量 | `run_all_patterns` 含 `xtask/*` | ✅ 一致 |
| **Rule 3** | axruntime / axconfig 直接修改 | 全量 | `run_all_crates`（仅 changed_crates） | ✅ 一致 |
| **Rule 4** | kernel/ 下且不在 hal/arch/ 下 | 全量 | `run_all_patterns` 含 `kernel/*` + `run_all_exclude_patterns` 含 `kernel/src/hal/arch/*` | ✅ 一致 |
| **Rule 5a** | kernel/…/aarch64/ 变更 | qemu_aarch64 + 两块板 | `selection_rules` 之 aarch64_path → 仅 QEMU aarch64 两个 target_key | ⚠️ 配置差异：默认未把两块板放进 aarch64_path，可改为与 xtask 一致 |
| **Rule 5b** | kernel/…/x86_64/ 变更 | qemu_x86_64 | `selection_rules` 之 x86_64_path | ✅ 一致 |
| **Rule 6** | axplat-x86-qemu-q35 受影响 | qemu_x86_64 | `crate_rules` crate_x86_platform | ✅ 一致 |
| **Rule 7** | axfs 受影响 | qemu_aarch64 + 两块板 | `crate_rules` crate_axfs | ✅ 一致 |
| **Rule 8** | driver + phytium / rockchip / 通用 | 对应板子 | `crate_path_rules` driver_phytium / driver_rockchip / driver_generic | ✅ 一致 |
| **Rule 9** | .github/workflows/ QEMU vs Board 细分 | 对应子集 | 默认 `.github/workflows/*` → 全量；要细分需在规则中拆成多条 path→targets | ⚠️ 可选：规则可配置成与 xtask 一致 |
| **Rule 10** | configs/board、configs/vms | 对应目标 | `selection_rules`（aarch64_path、x86_64_path、phytium_path、rk3568_path） | ✅ 一致 |

**依赖与输出**

- **变更/受影响计算**：两者均为 `git diff` + `cargo metadata` 反向依赖 BFS，且 run_all 类规则仅看**直接修改**（changed_crates），与 xtask 一致。
- **输出形式**：xtask 输出 TestScope 布尔 + changed/affected_crates；axci-affected 输出 `skip_all` + 有序 `targets` 列表，语义等价（CI 用 targets 生成矩阵）。

**小结**：在默认规则下，除 Rule 5a（aarch64 HAL 是否顺带触发两块板）和 Rule 9（workflows 是否按 QEMU/Board 细分）为可配置差异外，其余规则与 xtask 对齐；需要与 xtask 完全一致时，在 `selection_rules` 中为 aarch64_path 增加两块板 target_key、并按需细化 .github/workflows 的 path 规则即可。

### 与本文档前半部分（AxVisor xtask）的关系

- 本文档前半部分描述的是**在 AxVisor 仓库内**用 Rust xtask（`xtask affected`）实现依赖感知，规则写在代码里，适合单仓库深度定制。
- axci 的实现是**通用、配置驱动**：规则写在 `test-target-rules.json`，任何使用 axci 的仓库只要在规则里配置 `run_all_crates` / `crate_rules`（并保证 detect 时能跑 `cargo metadata`），即可获得依赖感知，无需在各自仓库写 xtask。
- 使用 **axci-affected** 引擎并配置 **run_all_exclude_patterns**（如 kernel 下排除 `hal/arch/*`）与 **crate_path_rules**（如 driver 按 phytium/rockchip/通用细分）后，行为可与 xtask 的 Rule 4（kernel 非架构特定→全量）、Rule 8（driver 按路径→对应板）对齐。
- 若 AxVisor 通过 axci 的 workflow_call 跑 CI，并采用 axci 的规则文件，则依赖感知由 axci 的脚本（或 axci-affected 引擎）+ 规则统一提供；AxVisor 本地的 xtask 仍可保留，用于本地 `cargo xtask affected` 调试与一致性验证。
