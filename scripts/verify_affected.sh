#!/usr/bin/env bash
# 验证 axci-affected 引擎：构建并运行，输出 JSON 与 stderr 分析信息。
# 用法: ./scripts/verify_affected.sh [组件目录] [base_ref]
#  组件目录: 要分析变更的仓库路径，默认 axci 仓库根（脚本所在目录的上一级）
#  base_ref: git diff 的基准，默认 HEAD~1
# 示例:
#   ./scripts/verify_affected.sh . HEAD~1
#   ./scripts/verify_affected.sh /path/to/axvisor origin/main

set -e

AXCI_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPONENT_DIR="${1:-$AXCI_ROOT}"
BASE_REF="${2:-HEAD~1}"
RULES_FILE="$AXCI_ROOT/configs/test-target-rules.json"
for BIN in "$AXCI_ROOT/axci-affected/target/release/axci-affected" "$AXCI_ROOT/axci-affected/target/debug/axci-affected"; do
  [ -x "$BIN" ] && break
done

echo "=== axci-affected 验证 ==="
echo "组件目录: $COMPONENT_DIR"
echo "base_ref: $BASE_REF"
echo "规则文件: $RULES_FILE"
echo ""

if [ ! -x "$BIN" ]; then
  echo "构建 axci-affected (release)..."
  (cd "$AXCI_ROOT/axci-affected" && cargo build --release) || { echo "构建失败"; exit 1; }
  BIN="$AXCI_ROOT/axci-affected/target/release/axci-affected"
fi

if [ ! -x "$BIN" ]; then
  echo "尝试 debug 构建..."
  (cd "$AXCI_ROOT/axci-affected" && cargo build) || true
  BIN="$AXCI_ROOT/axci-affected/target/debug/axci-affected"
fi

if [ ! -x "$BIN" ]; then
  echo "错误: 未找到可执行文件，请确认 axci-affected/target/release/axci-affected 或 target/debug/axci-affected 存在"
  exit 1
fi
echo "使用: $BIN"
echo ""

echo "--- 运行引擎（下方为 stderr 分析，最后为 stdout JSON）---"
TMP_JSON="$(mktemp)"
trap 'rm -f "$TMP_JSON"' EXIT
"$BIN" "$COMPONENT_DIR" "$BASE_REF" "$RULES_FILE" 2>/dev/stderr >"$TMP_JSON"
echo ""
echo "--- 解析后的 JSON ---"
jq . <"$TMP_JSON" 2>/dev/null || cat "$TMP_JSON"
echo ""
echo "--- 单行 JSON（便于脚本消费）---"
jq -c . <"$TMP_JSON" 2>/dev/null || cat "$TMP_JSON"
