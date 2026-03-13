# AxVisor 案例：依赖感知测试选择

> 本文是 **AxVisor 的落地案例**。  
> 若你关心可复用框架与配置抽象，请优先看 `dependency-aware-testing.md`。

## 1. 背景

AxVisor 的测试覆盖 QEMU 与多块开发板。过去每次 push/PR 都跑全量，导致：

- 稀缺硬件 Runner 被不必要任务占用
- 开发反馈变慢

同时仓库是 Cargo workspace，crate 间有明显依赖关系，因此适合做依赖传播后再选测试目标。

## 2. 案例中的关键规则

在 AxVisor 的实践里，典型规则包括：

- 核心构建文件变化（如 `Cargo.toml` / `Cargo.lock`）=> 全量
- 核心基础 crate（如 `axruntime`、`axconfig`）直接变更 => 全量
- 架构路径变化（如 `kernel/src/hal/arch/x86_64/`）=> x86 相关目标
- 驱动路径变化按 SoC 细分 => 对应板级目标
- 文档/图片等非代码变更 => `skip_all=true`

这些规则本质上都可映射到 axci 的配置字段：

- 路径全量：`run_all_patterns`
- 路径精确：`selection_rules`
- crate 全量：`run_all_crates`
- crate 精确：`crate_rules`
- crate+路径细分：`crate_path_rules`

## 3. 典型场景（示例）

- 只改文档：跳过所有测试
- 改 aarch64 HAL：触发 aarch64/QEMU/相关板子
- 改 x86 平台 crate：只触发 x86_64 QEMU
- 改核心 runtime：触发全量

## 4. 与 axci 的关系

AxVisor 的原始实践证明了“依赖感知 + 路径规则”的有效性，axci 在此基础上做了两件事：

1. **配置化**：把项目差异从代码迁到 `test-target-rules.json`
2. **通用化**：统一入口（`tests.sh` / CI detect）和统一引擎（`axci-affected`）

因此：

- AxVisor 是案例来源（how it started）
- axci 是通用实现（how to reuse）

## 5. 演示建议（面向评审）

演示时建议用三段结论：

1. 文档改动 -> 跳过
2. 平台局部改动 -> 精确命中
3. 核心 crate 改动 -> 全量兜底

这样能清晰体现“效率提升”和“风险控制”并存。
