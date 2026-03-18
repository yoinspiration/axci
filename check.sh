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
FILTER_TARGETS=""
CRATE_NAME=""
COMPONENT_DIR=""

# =============================================================================
# Helper Functions
# =============================================================================

usage() {
    cat << 'EOF'
组件代码质量检查脚本

用法:
  check.sh [选项] [crate|all]

参数:
  crate     组件名称，如 axvcpu、axaddrspace 等
  all       检查所有组件

选项:
  -c, --component-dir DIR    组件目录 (直接检查指定目录，无需 crate 名称)
  --targets TRIPLE[,TRIPLE,...]  编译目标三元组 (如: aarch64-unknown-none-softfloat)
                             优先级: CLI > config.json targets > 默认值
  -h, --help                 显示此帮助

可用的目标架构:
  aarch64-unknown-none-softfloat  (默认)
  x86_64-unknown-none
  riscv64gc-unknown-none-elf

示例:
  check.sh axvcpu                                  # 使用默认目标
  check.sh axvcpu --targets x86_64-unknown-none   # 指定目标
  check.sh all                                     # 检查所有组件
  check.sh --component-dir /path/to/crate          # 直接检查指定目录
  check.sh -c /path/to/crate --targets aarch64-unknown-none-softfloat
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

# 解析参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--component-dir)
                COMPONENT_DIR="$2"
                shift 2
                ;;
            --targets)
                FILTER_TARGETS="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            all)
                CRATE_NAME="all"
                shift
                ;;
            -*)
                die "未知选项: $1"
                ;;
            *)
                # 位置参数作为 crate 名称
                if [[ -z "${CRATE_NAME}" ]]; then
                    CRATE_NAME="$1"
                else
                    die "只能指定一个 crate 名称"
                fi
                shift
                ;;
        esac
    done
}

# 解析目标
# 优先级: CLI --targets > config.json targets > 默认值
resolve_targets() {
    local targets_input="$FILTER_TARGETS"
    local config_file=""

    # 确定配置文件路径
    if [[ -n "${COMPONENT_DIR}" ]]; then
        config_file="${COMPONENT_DIR}/.github/config.json"
    else
        config_file="${ROOT_DIR}/.github/config.json"
    fi

    # CLI 未指定，尝试 config.json 的 targets 字段
    if [[ -z "${targets_input}" ]] && [[ -f "${config_file}" ]]; then
        local config_targets=$(cat "${config_file}" | jq -r '.targets // [] | join(",")' 2>/dev/null)
        if [[ -n "${config_targets}" ]]; then
            targets_input="${config_targets}"
        fi
    fi

    # 仍为空，使用默认值
    if [[ -z "${targets_input}" ]]; then
        targets_input="${DEFAULT_TARGET}"
    fi

    # 返回解析后的目标列表
    echo "${targets_input}"
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

# 检查指定目录的组件 (通过 --component-dir 指定)
check_component_dir() {
    local target="$1"
    local crate_name=$(basename "${COMPONENT_DIR}")
    
    [[ -d "${COMPONENT_DIR}" ]] || die "组件目录不存在: ${COMPONENT_DIR}"
    [[ -f "${COMPONENT_DIR}/Cargo.toml" ]] || die "不是 Rust 项目: ${COMPONENT_DIR}"
    
    printf '\n%b========== %s ==========%b\n' "${BLUE}" "${crate_name}" "${NC}"
    
    pushd "${COMPONENT_DIR}" >/dev/null
    check_fmt "${crate_name}" || { popd >/dev/null; return 1; }
    check_build "${crate_name}" "${target}"
    check_clippy "${crate_name}" "${target}"
    check_doc "${crate_name}" "${target}"
    popd >/dev/null
    
    success "[${crate_name}] 所有检查通过"
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
    parse_args "$@"
    
    # 如果指定了 --component-dir，直接检查该目录
    if [[ -n "${COMPONENT_DIR}" ]]; then
        # 解析目标
        local targets=$(resolve_targets)
        local targets_array=()
        IFS=',' read -ra targets_array <<< "${targets}"
        
        info "组件目录: ${COMPONENT_DIR}"
        info "检查目标: ${targets_array[*]}"
        
        # 为每个目标运行检查
        local all_passed=true
        for target in "${targets_array[@]}"; do
            target=$(echo "$target" | xargs) # trim
            [[ -z "${target}" ]] && continue
            
            printf '\n%b========== 目标: %s ==========%b\n' "${BLUE}" "${target}" "${NC}"
            
            if ! check_component_dir "${target}"; then
                all_passed=false
            fi
        done
        
        if [[ "${all_passed}" == true ]]; then
            success "所有检查通过!"
            exit 0
        else
            die "部分检查失败"
        fi
        return
    fi
    
    # 如果没有指定 crate，显示帮助
    if [[ -z "${CRATE_NAME}" ]]; then
        usage
        exit 0
    fi
    
    # 解析目标
    local targets=$(resolve_targets)
    local targets_array=()
    IFS=',' read -ra targets_array <<< "${targets}"
    
    info "检查目标: ${targets_array[*]}"
    cd "${ROOT_DIR}"
    
    # 为每个目标运行检查
    local all_passed=true
    for target in "${targets_array[@]}"; do
        target=$(echo "$target" | xargs) # trim
        [[ -z "${target}" ]] && continue
        
        printf '\n%b========== 目标: %s ==========%b\n' "${BLUE}" "${target}" "${NC}"
        
        if [[ "${CRATE_NAME}" == "all" ]]; then
            if ! check_all "${target}"; then
                all_passed=false
            fi
        else
            if ! check_crate "${CRATE_NAME}" "${target}"; then
                all_passed=false
            fi
        fi
    done
    
    if [[ "${all_passed}" == true ]]; then
        success "所有检查通过!"
        exit 0
    else
        die "部分检查失败"
    fi
}

main "$@"
