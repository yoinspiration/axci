#!/usr/bin/env bash
# 自动回归 tests.sh --auto-target 选择逻辑（10 条最小用例）
# 用法:
#   bash scripts/regress_auto_target.sh
#   bash scripts/regress_auto_target.sh --explain
#
# 特点:
# - 使用 git worktree 在临时目录执行，不污染当前工作区
# - 全程 dry-run，不执行真实集成测试
# - 输出每条用例 PASS/FAIL 与最终汇总

set -euo pipefail

AXCI_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
WORKTREE_DIR="$TMP_ROOT/axci-regress"
LOG_DIR="$TMP_ROOT/logs"
mkdir -p "$LOG_DIR"
KEEP_TMP="${KEEP_TMP:-0}"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0
EXPLAIN=0

show_help() {
  cat << 'EOF'
用法:
  bash scripts/regress_auto_target.sh [--explain]

选项:
  --explain   每条用例后打印关键决策日志（命中规则/选中目标）
  -h, --help  显示帮助

环境变量:
  KEEP_TMP=1  保留临时目录与日志（默认成功后清理）
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --explain)
        EXPLAIN=1
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        echo "[FATAL] 未知参数: $1"
        show_help
        exit 1
        ;;
    esac
  done
}

cleanup() {
  if git -C "$AXCI_ROOT" worktree list --porcelain 2>/dev/null | grep -Fq "worktree $WORKTREE_DIR"; then
    git -C "$AXCI_ROOT" worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1 || true
  fi
  if [ "$KEEP_TMP" = "1" ] || [ "$FAIL_COUNT" -gt 0 ]; then
    return
  fi
  rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[FATAL] 缺少命令: $cmd"
    exit 1
  fi
}

reset_case_state() {
  git -C "$WORKTREE_DIR" reset --hard HEAD >/dev/null
  git -C "$WORKTREE_DIR" clean -fd >/dev/null
}

print_case_explain() {
  local log_file="$1"
  local change_desc="$2"
  local expected_desc="$3"
  if [ "$EXPLAIN" != "1" ]; then
    return
  fi

  local target_line
  local rule_line
  local lines
  target_line="$(awk '
    /自动目标选择: / { line=$0 }
    END { print line }
  ' "$log_file" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' || true)"
  rule_line="$(awk '
    /rules:/ { line=$0 }
    END { print line }
  ' "$log_file" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' || true)"
  lines="$(awk '
    /自动目标选择:|命中全量规则|跳过所有测试|保守回退 all|rules:/ { print }
  ' "$log_file" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' | awk '!seen[$0]++' | sed -n '1,6p' || true)"

  echo "  说明:"
  echo "    - 改动: $change_desc"
  echo "    - 预期: $expected_desc"
  if [ -n "$target_line" ]; then
    echo "    - 实际: $target_line"
  fi
  if [ -n "$rule_line" ]; then
    echo "    - 规则: $rule_line"
  fi
  if [ -n "$lines" ]; then
    echo "    - 关键日志:"
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      echo "      $line"
    done <<< "$lines"
  else
    echo "    （未提取到关键决策行，可查看完整日志）"
  fi
}

run_tests_sh_case() {
  local case_id="$1"
  local title="$2"
  local change_desc="$3"
  local expected_desc="$4"
  local setup_cmd="$5"
  shift 5
  local expected_patterns=("$@")
  local log_file="$LOG_DIR/${case_id}.log"

  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  echo ""
  echo "[$case_id] $title"

  reset_case_state
  (cd "$WORKTREE_DIR" && eval "$setup_cmd")

  if ! (cd "$WORKTREE_DIR" && bash tests.sh --auto-target --base-ref HEAD --dry-run -v >"$log_file" 2>&1); then
    echo "  FAIL - tests.sh 执行失败"
    echo "  日志: $log_file"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return
  fi

  print_case_explain "$log_file" "$change_desc" "$expected_desc"

  local matched=true
  local pat
  for pat in "${expected_patterns[@]}"; do
    if ! grep -Eq "$pat" "$log_file"; then
      matched=false
      break
    fi
  done

  if [ "$matched" = true ]; then
    echo "  PASS"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  FAIL"
    echo "  日志: $log_file"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

echo "=== auto-target 回归开始 ==="
echo "仓库: $AXCI_ROOT"
echo "临时目录: $TMP_ROOT"

parse_args "$@"

require_cmd git
require_cmd jq
require_cmd bash

if ! git -C "$AXCI_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[FATAL] 当前目录不是 git 仓库: $AXCI_ROOT"
  exit 1
fi

git -C "$AXCI_ROOT" worktree add --detach "$WORKTREE_DIR" HEAD >/dev/null

run_tests_sh_case \
  "01" \
  "文档改动 -> skip all" \
  "新增 docs/_tmp_auto_target.md（文档文件）" \
  "识别为 non_code_only，跳过所有测试" \
  "mkdir -p docs && echo 'tmp' >> docs/_tmp_auto_target.md && git add -N docs/_tmp_auto_target.md" \
  "跳过所有测试"

run_tests_sh_case \
  "02" \
  "无变更 -> skip all" \
  "不制造任何改动" \
  "识别 no_changes，跳过所有测试" \
  ":" \
  "未检测到变更，跳过所有测试"

run_tests_sh_case \
  "03" \
  "aarch64 路径 -> aarch64 + board 子集" \
  "新增 kernel/src/hal/arch/aarch64/_tmp.rs" \
  "命中 aarch64_path，选择 aarch64+board 子集目标" \
  "mkdir -p kernel/src/hal/arch/aarch64 && echo '// tmp' >> kernel/src/hal/arch/aarch64/_tmp.rs && git add -N kernel/src/hal/arch/aarch64/_tmp.rs" \
  "自动目标选择: .*axvisor-qemu-aarch64-arceos" \
  "自动目标选择: .*axvisor-board-phytiumpi-arceos"

run_tests_sh_case \
  "04" \
  "x86_64 路径 -> nimbos 目标" \
  "新增 kernel/src/hal/arch/x86_64/_tmp.rs" \
  "命中 x86_64_path，选择 axvisor-qemu-x86_64-nimbos" \
  "mkdir -p kernel/src/hal/arch/x86_64 && echo '// tmp' >> kernel/src/hal/arch/x86_64/_tmp.rs && git add -N kernel/src/hal/arch/x86_64/_tmp.rs" \
  "自动目标选择: .*axvisor-qemu-x86_64-nimbos"

run_tests_sh_case \
  "05" \
  "phytium 关键词路径 -> phytiumpi 两目标" \
  "新增 tmp/phytium/_tmp.rs（路径含 phytium）" \
  "命中 phytium_path，选择 phytiumpi 两目标" \
  "mkdir -p tmp/phytium && echo 'x' >> tmp/phytium/_tmp.rs && git add -N tmp/phytium/_tmp.rs" \
  "自动目标选择: .*axvisor-board-phytiumpi-arceos" \
  "自动目标选择: .*axvisor-board-phytiumpi-linux"

run_tests_sh_case \
  "06" \
  "rk3568 关键词路径 -> rk3568 两目标" \
  "新增 tmp/rk3568/_tmp.rs（路径含 rk3568）" \
  "命中 rk3568_path，选择 rk3568 两目标" \
  "mkdir -p tmp/rk3568 && echo 'x' >> tmp/rk3568/_tmp.rs && git add -N tmp/rk3568/_tmp.rs" \
  "自动目标选择: .*axvisor-board-roc-rk3568-pc-arceos" \
  "自动目标选择: .*axvisor-board-roc-rk3568-pc-linux"

run_tests_sh_case \
  "07" \
  "tests.sh 改动 -> all" \
  "修改 tests.sh" \
  "命中 run_all_patterns，执行 all" \
  "echo '' >> tests.sh" \
  "命中全量规则，运行 all"

run_tests_sh_case \
  "08" \
  "workflow 改动 -> all" \
  "修改 .github/workflows/test.yml" \
  "命中 run_all_patterns(.github/workflows/*)，执行 all" \
  "echo '' >> .github/workflows/test.yml" \
  "命中全量规则，运行 all"

run_tests_sh_case \
  "09" \
  "未匹配代码路径 -> 保守回退 all" \
  "新增 src/misc/_tmp.rs（不命中任何细分规则）" \
  "无法精确匹配，保守回退 all" \
  "mkdir -p src/misc && echo '// tmp' >> src/misc/_tmp.rs && git add -N src/misc/_tmp.rs" \
  "保守回退 all"

run_tests_sh_case \
  "10" \
  "workflow + 文档混合改动 -> all（全量优先）" \
  "同时修改 .github/workflows/test.yml 与 README.md" \
  "即使含文档改动，仍由 run_all 规则优先触发 all" \
  "echo '' >> .github/workflows/test.yml && echo 'tmp' >> README.md" \
  "命中全量规则，运行 all"

echo ""
echo "=== 汇总 ==="
echo "总数: $TOTAL_COUNT"
echo "通过: $PASS_COUNT"
echo "失败: $FAIL_COUNT"
if [ "$KEEP_TMP" = "1" ] || [ "$FAIL_COUNT" -gt 0 ]; then
  echo "日志目录: $LOG_DIR"
else
  echo "日志目录: 已清理（如需保留请用 KEEP_TMP=1）"
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi

echo "全部用例通过。"
