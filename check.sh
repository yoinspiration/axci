#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd -P)
CRATES_FILE="${SCRIPT_DIR}/crates.txt"

# =============================================================================
# Colors and Output Functions
# =============================================================================

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

die() { printf '%b✗%b %s\n' "${RED}" "${NC}" "$*" >&2; exit 1; }
info() { printf '%b→%b %s\n' "${BLUE}" "${NC}" "$*"; }
success() { printf '%b✓%b %s\n' "${GREEN}" "${NC}" "$*"; }
warn() { printf '%b⚠%b %s\n' "${YELLOW}" "${NC}" "$*"; }

# =============================================================================
# Configuration
# =============================================================================

DEFAULT_TARGET="aarch64-unknown-none-softfloat"
RUSTDOCFLAGS="-D rustdoc::broken_intra_doc_links"

# =============================================================================
# Helper Functions
# =============================================================================

usage() {
    cat << EOF
组件代码质量检查脚本

用法:
  scripts/check.sh <crate|all> [target]

参数:
  crate     组件名称，如 axvcpu、axaddrspace 等
  all       检查所有组件
  target    目标架构（可选）

可用的目标架构:
  aarch64-unknown-none-softfloat  (默认)
  x86_64-unknown-none
  riscv64gc-unknown-none-elf

示例:
  scripts/check.sh axvcpu
  scripts/check.sh axvcpu x86_64-unknown-none
  scripts/check.sh all
  scripts/check.sh all riscv64gc-unknown-none-elf
EOF
}

read_crates() {
    local crates=()
    while IFS= read -r crate || [[ -n "${crate}" ]]; do
        crate="${crate%$'\r'}"
        [[ -z "${crate}" ]] && continue
        crates+=("${crate}")
    done < "${CRATES_FILE}"
    printf '%s\n' "${crates[@]}"
}

# =============================================================================
# Check Functions
# =============================================================================

check_fmt() {
    info "[$1] 检查代码格式"
    if cargo fmt --all -- --check >/dev/null 2>&1; then
        success "[$1] 代码格式检查通过"
    else
        warn "[$1] 代码格式检查失败，运行 'cargo fmt --all' 修复"; return 1
    fi
}

check_build() {
    info "[$1] 构建检查 (target: $2)"
    if cargo build --target "$2" --all-features >/dev/null 2>&1; then
        success "[$1] 构建检查通过"
    else
        die "[$1] 构建检查失败"
    fi
}

check_clippy() {
    info "[$1] Clippy 检查"
    if cargo clippy --target "$2" --all-features -- -D warnings >/dev/null 2>&1; then
        success "[$1] Clippy 检查通过"
    else
        die "[$1] Clippy 检查失败"
    fi
}

check_doc() {
    info "[$1] 文档构建检查"
    if RUSTDOCFLAGS="${RUSTDOCFLAGS}" cargo doc --no-deps --target "$2" --all-features >/dev/null 2>&1; then
        success "[$1] 文档构建检查通过"
    else
        die "[$1] 文档构建检查失败"
    fi
}

check_crate() {
    local crate="$1" target="$2" crate_dir="${ROOT_DIR}/${1}"
    
    [[ -d "${crate_dir}" ]] || die "组件 ${crate} 不存在"
    [[ -f "${crate_dir}/Cargo.toml" ]] || { warn "跳过 ${crate} (不是 Rust 项目)"; return 0; }
    
    printf '\n%b========== %s ==========%b\n' "${BLUE}" "${crate}" "${NC}"
    
    pushd "${crate_dir}" >/dev/null
    check_fmt "${crate}" || { popd >/dev/null; return 1; }
    check_build "${crate}" "${target}"
    check_clippy "${crate}" "${target}"
    check_doc "${crate}" "${target}"
    popd >/dev/null
    
    success "[${crate}] 所有检查通过"
}

check_all() {
    local target="$1"
    local crates passed=() failed=()
    mapfile -t crates < <(read_crates)
    
    info "检查所有组件 (${#crates[@]} 个)..."
    
    for crate in "${crates[@]}"; do
        # 使用子 shell 隔离错误，确保一个组件失败不影响其他组件
        if (check_crate "${crate}" "${target}"); then
            passed+=("${crate}")
        else
            failed+=("${crate}")
        fi
    done
    
    printf '\n%b========================================%b\n' "${BLUE}" "${NC}"
    printf '%b           检查结果汇总%b\n' "${BLUE}" "${NC}"
    printf '%b========================================%b\n\n' "${BLUE}" "${NC}"

    if [[ ${#passed[@]} -gt 0 ]]; then
        success "通过 ${#passed[@]} 个:"
        for crate in "${passed[@]}"; do
            printf '  %b✓%b %s\n' "${GREEN}" "${NC}" "${crate}"
        done
        printf '\n'
    fi

    if [[ ${#failed[@]} -gt 0 ]]; then
        printf '%b失败 %d 个:%b\n' "${RED}" "${#failed[@]}" "${NC}"
        for crate in "${failed[@]}"; do
            printf '  %b✗%b %s\n' "${RED}" "${NC}" "${crate}"
        done
        printf '\n'
        die "检查完成，共 ${#failed[@]} 个组件失败"
    else
        success "所有 ${#passed[@]} 个组件检查通过"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    local crate="${1:-}" target="${2:-${DEFAULT_TARGET}}"
    
    if [[ -z "${crate}" ]] || [[ "${crate}" == "-h" ]] || [[ "${crate}" == "--help" ]]; then
        usage; exit 0
    fi
    
    info "检查目标: ${target}"
    cd "${ROOT_DIR}"
    
    if [[ "${crate}" == "all" ]]; then
        check_all "${target}"
    else
        check_crate "${crate}" "${target}"
    fi
}

main "$@"
