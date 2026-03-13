#!/bin/bash
#
# Hypervisor Test Framework - 本地测试脚本
# 此脚本可独立运行，也可被各组件调用
#
# 用法:
#   ./tests.sh                           # 运行所有测试
#   ./tests.sh --target axvisor          # 仅测试指定目标
#   ./tests.sh --config /path/to/.test-config.json
#   ./tests.sh --component-dir /path/to/component
#

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 默认配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_DIR="$SCRIPT_DIR"
COMPONENT_DIR=""
CONFIG_FILE=""
TEST_TARGET="all"
AUTO_TARGET=false
BASE_REF="origin/main"
AUTO_DETECTED_TARGETS=""
VERBOSE=false
CLEANUP=true
DRY_RUN=false
PARALLEL=true
OUTPUT_DIR=""
IMAGE_STORAGE_ROOT="/tmp/.axvisor-images"
DEFAULT_REGISTRY_URL="https://raw.githubusercontent.com/arceos-hypervisor/axvisor-guest/refs/heads/main/registry/default.toml"
FALLBACK_REGISTRY_URL="https://raw.githubusercontent.com/arceos-hypervisor/axvisor-guest/refs/heads/main/registry/v0.0.22.toml"
IMAGE_DOWNLOAD_MAX_ATTEMPTS=2
TEST_TARGET_RULES_FILE="$FRAMEWORK_DIR/configs/test-target-rules.json"
TARGET_RULES_JSON=""

# 帮助信息
show_help() {
    cat << 'EOF'
Hypervisor Test Framework - 本地测试脚本

用法:
  tests.sh [选项]

选项:
  -c, --component-dir DIR    组件目录 (默认: 当前目录)
  -f, --config FILE          配置文件路径 (可选，默认使用内置测试目标)
  -t, --target TARGET        测试目标: all, axvisor-qemu, starry, 或具体目标名 (默认: all)
  -o, --output DIR           输出目录 (默认: COMPONENT_DIR/test-results)
  -v, --verbose              详细输出
  --no-cleanup               不清理临时文件
  --dry-run                  仅显示将要执行的命令
  --sequential               顺序执行测试 (不并行)
  --auto-target              根据 git 变更自动选择测试目标
  --base-ref REF             自动选择目标时用于对比的基线 (默认: origin/main)
  -h, --help                 显示此帮助

测试目标:
  all                        运行所有测试
  axvisor-qemu               运行所有 axvisor QEMU 测试
  axvisor-board              运行所有 axvisor Board 测试
  starry                     运行所有 starry 测试
  axvisor-qemu-aarch64-arceos     测试 axvisor 在 QEMU aarch64 上的 ArceOS 镜像
  axvisor-qemu-aarch64-linux      测试 axvisor 在 QEMU aarch64 上的 Linux 镜像
  axvisor-qemu-x86_64-nimbos      测试 axvisor 在 QEMU x86_64 上的 NimbOS 镜像
  axvisor-board-phytiumpi-arceos  测试 axvisor 在 phytiumpi 开发板上的 ArceOS 镜像
  axvisor-board-phytiumpi-linux   测试 axvisor 在 phytiumpi 开发板上的 Linux 镜像
  axvisor-board-roc-rk3568-pc-arceos  测试 axvisor 在 roc-rk3568-pc 开发板上的 ArceOS 镜像
  axvisor-board-roc-rk3568-pc-linux   测试 axvisor 在 roc-rk3568-pc 开发板上的 Linux 镜像
  starry-riscv64             测试 starry 在 riscv64 架构下
  starry-loongarch64         测试 starry 在 loongarch64 架构下
  starry-aarch64             测试 starry 在 aarch64 架构下
  starry-x86_64              测试 starry 在 x86_64 架构下

镜像下载:
  镜像将从 https://github.com/arceos-hypervisor/axvisor-guest/releases/v0.0.22 自动下载
  存储位置: /tmp/.axvisor-images

示例:
  tests.sh                                    # 在当前目录运行所有测试
  tests.sh -t axvisor-qemu                    # 仅运行 axvisor QEMU 测试
  tests.sh -t axvisor-board                   # 仅运行 axvisor Board 测试
  tests.sh -t starry-aarch64                  # 仅运行 starry aarch64 测试
  tests.sh -t axvisor-board-phytiumpi-arceos  # 仅运行 phytiumpi ArceOS 测试
  tests.sh --dry-run -v                       # 显示将要执行的命令
  tests.sh --auto-target --base-ref origin/main

EOF
}

# 解析参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--component-dir)
                COMPONENT_DIR="$2"
                shift 2
                ;;
            -f|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -t|--target)
                TEST_TARGET="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --no-cleanup)
                CLEANUP=false
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --sequential)
                PARALLEL=false
                shift
                ;;
            --auto-target)
                AUTO_TARGET=true
                shift
                ;;
            --base-ref)
                BASE_REF="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# 日志函数
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { 
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

error() { log_error "$1"; exit 1; }

# 判断当前目标是否会运行 Starry 测试
requires_starry_tooling() {
    case "$TEST_TARGET" in
        all|starry|starry-*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# 判断当前目标是否会运行 Starry aarch64（需要 musl 交叉编译器）
requires_starry_aarch64_tooling() {
    case "$TEST_TARGET" in
        all|starry|starry-aarch64)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# 检查依赖
check_dependencies() {
    log "检查依赖..."
    
    local missing=()
    
    # 检查 jq
    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi
    
    # 检查 git
    if ! command -v git &> /dev/null; then
        missing+=("git")
    fi
    
    # 检查 cargo
    if ! command -v cargo &> /dev/null; then
        missing+=("cargo (Rust)")
    fi

    # 检查 python3（NimbOS 自动输入脚本依赖）
    if ! command -v python3 &> /dev/null; then
        missing+=("python3")
    fi

    # 检查 script（board 测试 PTY 依赖）
    if ! command -v script &> /dev/null; then
        missing+=("script (util-linux)")
    fi

    # 检查 curl（镜像 registry fallback 依赖）
    if ! command -v curl &> /dev/null; then
        missing+=("curl")
    fi

    # Starry 构建依赖（仅在会运行 Starry 目标时检查）
    if requires_starry_tooling; then
        if ! command -v cmake &> /dev/null; then
            missing+=("cmake (Starry rootfs/build 依赖)")
        fi
    fi

    # Starry aarch64 构建依赖（lwext4 依赖 musl 交叉 C 编译器）
    if requires_starry_aarch64_tooling; then
        if ! command -v aarch64-linux-musl-cc &> /dev/null && ! command -v aarch64-linux-musl-gcc &> /dev/null; then
            missing+=("aarch64-linux-musl-cc 或 aarch64-linux-musl-gcc (Starry aarch64 musl 交叉编译器)")
        fi
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        error "缺少依赖: ${missing[*]}\n请安装后重试。若是 Starry aarch64，可参考 setup-musl prebuilt 工具链。"
    fi
    
    log_success "依赖检查通过"
}

# 默认测试目标（与 .github/workflows/test.yml 保持一致）
DEFAULT_TARGETS='[
  {
    "name": "axvisor-qemu-aarch64-arceos",
    "type": "qemu",
    "arch": "aarch64",
    "repo": {"url": "https://github.com/arceos-hypervisor/axvisor", "branch": "master"},
    "build": {"command": "", "timeout_minutes": 15},
    "test": {
      "command": "cargo xtask qemu",
      "build_config": "configs/board/qemu-aarch64.toml",
      "qemu_config": ".github/workflows/qemu-aarch64.toml",
      "vmconfigs": "configs/vms/arceos-aarch64-qemu-smp1.toml",
      "vmimage_name": "qemu_aarch64_arceos,qemu_aarch64_arceos"
    },
    "patch": {"path_template": "../component"}
  },
  {
    "name": "axvisor-qemu-aarch64-linux",
    "type": "qemu",
    "arch": "aarch64",
    "repo": {"url": "https://github.com/arceos-hypervisor/axvisor", "branch": "master"},
    "build": {"command": "", "timeout_minutes": 15},
    "test": {
      "command": "cargo xtask qemu",
      "build_config": "configs/board/qemu-aarch64.toml",
      "qemu_config": ".github/workflows/qemu-aarch64.toml",
      "vmconfigs": "configs/vms/linux-aarch64-qemu-smp1.toml",
      "vmimage_name": "qemu_aarch64_linux"
    },
    "patch": {"path_template": "../component"}
  },
  {
    "name": "axvisor-qemu-x86_64-nimbos",
    "type": "qemu",
    "arch": "x86_64",
    "repo": {"url": "https://github.com/arceos-hypervisor/axvisor", "branch": "master"},
    "build": {"command": "", "timeout_minutes": 15},
    "test": {
      "command": "cargo xtask qemu",
      "build_config": "configs/board/qemu-x86_64.toml",
      "qemu_config": ".github/workflows/qemu-x86_64.toml",
      "vmconfigs": "configs/vms/nimbos-x86_64-qemu-smp1.toml",
      "vmimage_name": "qemu_x86_64_nimbos"
    },
    "patch": {"path_template": "../component"}
  },
  {
    "name": "starry-riscv64",
    "type": "qemu",
    "arch": "riscv64",
    "repo": {"url": "https://github.com/Starry-OS/StarryOS", "branch": "main"},
    "build": {"command": "make build", "timeout_minutes": 30},
    "test": {},
    "patch": {"path_template": "../component"}
  },
  {
    "name": "starry-loongarch64",
    "type": "qemu",
    "arch": "loongarch64",
    "repo": {"url": "https://github.com/Starry-OS/StarryOS", "branch": "main"},
    "build": {"command": "make build", "timeout_minutes": 30},
    "test": {},
    "patch": {"path_template": "../component"}
  },
  {
    "name": "starry-aarch64",
    "type": "qemu",
    "arch": "aarch64",
    "repo": {"url": "https://github.com/Starry-OS/StarryOS", "branch": "main"},
    "build": {"command": "make build", "timeout_minutes": 30},
    "test": {},
    "patch": {"path_template": "../component"}
  },
  {
    "name": "starry-x86_64",
    "type": "qemu",
    "arch": "x86_64",
    "repo": {"url": "https://github.com/Starry-OS/StarryOS", "branch": "main"},
    "build": {"command": "make build", "timeout_minutes": 30},
    "test": {},
    "patch": {"path_template": "../component"}
  },
  {
    "name": "axvisor-board-phytiumpi-arceos",
    "type": "board",
    "arch": "aarch64",
    "board": "phytiumpi",
    "repo": {"url": "https://github.com/arceos-hypervisor/axvisor", "branch": "master"},
    "build": {"command": "", "timeout_minutes": 15},
    "test": {
      "command": "cargo xtask uboot",
      "build_config": "configs/board/phytiumpi.toml",
      "uboot_config": ".github/workflows/uboot.toml",
      "vmconfigs": "configs/vms/arceos-aarch64-e2000-smp1.toml",
      "vmimage_name": "phytiumpi_arceos",
      "bin_dir": "/tmp/tftp"
    },
    "patch": {"path_template": "../component"}
  },
  {
    "name": "axvisor-board-phytiumpi-linux",
    "type": "board",
    "arch": "aarch64",
    "board": "phytiumpi",
    "repo": {"url": "https://github.com/arceos-hypervisor/axvisor", "branch": "master"},
    "build": {"command": "", "timeout_minutes": 15},
    "test": {
      "command": "cargo xtask uboot",
      "build_config": "configs/board/phytiumpi.toml",
      "uboot_config": ".github/workflows/uboot.toml",
      "vmconfigs": "configs/vms/linux-aarch64-e2000-smp1.toml",
      "vmimage_name": "phytiumpi_linux",
      "bin_dir": "/tmp/tftp"
    },
    "patch": {"path_template": "../component"}
  },
  {
    "name": "axvisor-board-roc-rk3568-pc-arceos",
    "type": "board",
    "arch": "aarch64",
    "board": "roc-rk3568-pc",
    "repo": {"url": "https://github.com/arceos-hypervisor/axvisor", "branch": "master"},
    "build": {"command": "", "timeout_minutes": 15},
    "test": {
      "command": "cargo xtask uboot",
      "build_config": "configs/board/roc-rk3568-pc.toml",
      "uboot_config": ".github/workflows/uboot.toml",
      "vmconfigs": "configs/vms/arceos-aarch64-rk3568-smp1.toml",
      "vmimage_name": "roc-rk3568-pc_arceos",
      "bin_dir": "/tmp/tftp"
    },
    "patch": {"path_template": "../component"}
  },
  {
    "name": "axvisor-board-roc-rk3568-pc-linux",
    "type": "board",
    "arch": "aarch64",
    "board": "roc-rk3568-pc",
    "repo": {"url": "https://github.com/arceos-hypervisor/axvisor", "branch": "master"},
    "build": {"command": "", "timeout_minutes": 15},
    "test": {
      "command": "cargo xtask uboot",
      "build_config": "configs/board/roc-rk3568-pc.toml",
      "uboot_config": ".github/workflows/uboot.toml",
      "vmconfigs": "configs/vms/linux-aarch64-rk3568-smp1.toml",
      "vmimage_name": "roc-rk3568-pc_linux",
      "bin_dir": "/tmp/tftp"
    },
    "patch": {"path_template": "../component"}
  }
]'

# 加载配置
load_config() {
    # 确定组件目录
    if [ -z "$COMPONENT_DIR" ]; then
        COMPONENT_DIR="$(pwd)"
    fi
    
    # 尝试查找配置文件（可选）
    if [ -z "$CONFIG_FILE" ]; then
        if [ -f "$COMPONENT_DIR/.github/config.json" ]; then
            CONFIG_FILE="$COMPONENT_DIR/.github/config.json"
        elif [ -f "$COMPONENT_DIR/.test-config.json" ]; then
            CONFIG_FILE="$COMPONENT_DIR/.test-config.json"
        fi
    fi
    
    # 检测 crate 名称（从 Cargo.toml）
    if [ -f "$COMPONENT_DIR/Cargo.toml" ]; then
        COMPONENT_CRATE=$(grep '^name = ' "$COMPONENT_DIR/Cargo.toml" | head -1 | sed 's/name = "\(.*\)"/\1/' || basename "$COMPONENT_DIR")
    else
        COMPONENT_CRATE=$(basename "$COMPONENT_DIR")
    fi
    COMPONENT_NAME="$COMPONENT_CRATE"
    
    # 如果有配置文件，则使用配置文件
    if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
        log "加载配置: $CONFIG_FILE"
        CONFIG=$(cat "$CONFIG_FILE")
        # 从配置文件获取组件信息
        local config_name=$(echo "$CONFIG" | jq -r '.component.name // empty')
        local config_crate=$(echo "$CONFIG" | jq -r '.component.crate_name // empty')
        [ -n "$config_name" ] && COMPONENT_NAME="$config_name"
        [ -n "$config_crate" ] && COMPONENT_CRATE="$config_crate"
        
        # 检查配置文件是否包含 test_targets
        local has_targets=$(echo "$CONFIG" | jq 'has("test_targets")')
        if [ "$has_targets" != "true" ]; then
            log "配置文件不包含 test_targets，使用默认测试目标"
            CONFIG="{\"component\":{\"name\":\"$COMPONENT_NAME\",\"crate_name\":\"$COMPONENT_CRATE\"},\"test_targets\":$DEFAULT_TARGETS}"
        fi
    else
        log "未找到配置文件，使用默认测试目标"
        CONFIG="{\"component\":{\"name\":\"$COMPONENT_NAME\",\"crate_name\":\"$COMPONENT_CRATE\"},\"test_targets\":$DEFAULT_TARGETS}"
    fi
    
    log_debug "组件: $COMPONENT_NAME ($COMPONENT_CRATE)"
}

# 设置输出目录
setup_output() {
    if [ -z "$OUTPUT_DIR" ]; then
        OUTPUT_DIR="$COMPONENT_DIR/test-results"
    fi
    
    mkdir -p "$OUTPUT_DIR/logs"
    log_debug "输出目录: $OUTPUT_DIR"
}

# 初始化本地镜像 registry（当默认下载源异常时用于兜底）
bootstrap_image_registry() {
    local log_file="$1"
    local storage_dir="${IMAGE_STORAGE_ROOT}"
    local default_registry_url="${DEFAULT_REGISTRY_URL}"
    local fallback_registry_url="${FALLBACK_REGISTRY_URL}"
    local default_registry_file include_url source_url source_kind

    mkdir -p "$storage_dir"
    if [ -f "${storage_dir}/images.toml" ]; then
        return 0
    fi

    default_registry_file="$(mktemp)"
    if ! curl -4 --retry 3 --retry-delay 2 -fL "$default_registry_url" -o "$default_registry_file" >> "$log_file" 2>&1; then
        rm -f "$default_registry_file"
        source_kind="fallback registry"
        source_url="$fallback_registry_url"
        registry_fallback_used="yes"
        log_warn "  获取默认 registry 失败，使用 fallback: $source_url"
    else
        include_url="$(sed -n 's/^[[:space:]]*url[[:space:]]*=[[:space:]]*"\([^"]*\)".*$/\1/p' "$default_registry_file" | sed -n '1p')"
        rm -f "$default_registry_file"
        if [ -n "$include_url" ]; then
            source_kind="included registry"
            source_url="$include_url"
        else
            source_kind="default registry"
            source_url="$default_registry_url"
        fi
    fi

    log "  初始化本地镜像 registry: $source_kind"
    if ! curl -4 --retry 3 --retry-delay 2 -fL "$source_url" -o "${storage_dir}/images.toml" >> "$log_file" 2>&1; then
        if [ "$source_url" != "$fallback_registry_url" ]; then
            log_warn "  registry 初始化失败，重试 fallback: $fallback_registry_url"
            registry_fallback_used="yes"
            if ! curl -4 --retry 3 --retry-delay 2 -fL "$fallback_registry_url" -o "${storage_dir}/images.toml" >> "$log_file" 2>&1; then
                return 1
            fi
        else
            return 1
        fi
    fi

    date +%s > "${storage_dir}/.last_sync" 2>/dev/null || true
    return 0
}

# 下载镜像（失败时自动 bootstrap registry 并重试）
download_image_with_retry() {
    local test_dir="$1"
    local image_name="$2"
    local log_file="$3"
    local attempt

    for ((attempt=1; attempt<=IMAGE_DOWNLOAD_MAX_ATTEMPTS; attempt++)); do
        if (cd "$test_dir" && cargo xtask image download "$image_name" >> "$log_file" 2>&1); then
            return 0
        fi

        if [ "$attempt" -lt "$IMAGE_DOWNLOAD_MAX_ATTEMPTS" ]; then
            image_retry_count=$((image_retry_count + 1))
            log_warn "  镜像下载失败（第 ${attempt} 次），尝试初始化 registry 后重试: $image_name"
            bootstrap_image_registry "$log_file" || log_warn "  registry 初始化失败，继续直接重试下载"
        fi
    done

    return 1
}

# 检查组件是否被目标项目使用（避免 patch 成功但未进入依赖图）
# 返回 0 表示已使用，1 表示未使用
check_component_used() {
    local target_name="$1"
    local test_dir="$2"
    local cargo_lock="$test_dir/Cargo.lock"
    local cargo_toml="$test_dir/Cargo.toml"

    # 仅对 axvisor/starry 目标做依赖图检查
    if [[ "$target_name" != axvisor-* ]] && [[ "$target_name" != starry-* ]]; then
        return 0
    fi

    # 优先检查 Cargo.lock 中是否出现组件包名
    if [ -f "$cargo_lock" ]; then
        if awk '/^\[\[package\]\]/{in_pkg=1;next} /^\[/{in_pkg=0} in_pkg && /^name = /{print}' "$cargo_lock" \
            | grep -q "^name = \"$COMPONENT_CRATE\"$"; then
            log_debug "  在 Cargo.lock 中检测到组件依赖: $COMPONENT_CRATE"
            return 0
        fi
    fi

    # 再回退到 Cargo.toml 的直接依赖检查
    if [ -f "$cargo_toml" ] && grep -q "^$COMPONENT_CRATE\\s*=" "$cargo_toml"; then
        log_debug "  在 Cargo.toml 中检测到组件依赖: $COMPONENT_CRATE"
        return 0
    fi

    return 1
}

# 检查 x86_64 KVM 运行能力（NimbOS QEMU 测试依赖）
check_kvm_available() {
    # /dev/kvm 存在且可读写是最直接的可用性判断
    if [ ! -e /dev/kvm ]; then
        log_error "  未检测到 /dev/kvm，当前环境不支持 KVM 加速"
        return 1
    fi

    if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
        log_error "  /dev/kvm 无访问权限，请确认当前用户已加入 kvm 组"
        return 1
    fi

    # 进一步检查 CPU 是否暴露虚拟化能力标志（Intel: vmx, AMD: svm）
    if ! grep -Eq '(vmx|svm)' /proc/cpuinfo; then
        log_error "  未检测到 CPU 虚拟化标志（vmx/svm），NimbOS 测试无法使用 KVM"
        return 1
    fi

    log_debug "  KVM 环境检查通过"
    return 0
}

# 写入单个目标的元信息，供报告聚合使用
write_target_meta() {
    local meta_file="$1"
    local dep_state="$2"
    local kvm_state="$3"
    local retry_count="$4"
    local fallback_used="$5"

    cat > "$meta_file" << EOF
dep_check=$dep_state
kvm_check=$kvm_state
image_retry_count=$retry_count
registry_fallback_used=$fallback_used
EOF
}

# 统一写入目标结果（status + meta）
set_target_result() {
    local status_file="$1"
    local meta_file="$2"
    local result="$3"
    local dep_state="$4"
    local kvm_state="$5"
    local retry_count="$6"
    local fallback_used="$7"

    echo "$result" > "$status_file"
    write_target_meta "$meta_file" "$dep_state" "$kvm_state" "$retry_count" "$fallback_used"
}

# 加载自动目标选择规则
load_test_target_rules() {
    if [ -n "$TARGET_RULES_JSON" ]; then
        return 0
    fi

    # 规则文件优先级：
    # 1) 组件仓库本地规则: $COMPONENT_DIR/.github/axci-test-target-rules.json
    # 2) 默认规则: axci 仓库自身的 configs/test-target-rules.json
    local component_rules=""
    if [ -n "$COMPONENT_DIR" ]; then
        component_rules="$COMPONENT_DIR/.github/axci-test-target-rules.json"
    else
        component_rules=".github/axci-test-target-rules.json"
    fi

    if [ -f "$component_rules" ]; then
        TEST_TARGET_RULES_FILE="$component_rules"
    fi

    if [ ! -f "$TEST_TARGET_RULES_FILE" ]; then
        log_warn "自动目标选择规则文件不存在: $TEST_TARGET_RULES_FILE，回退为 all"
        return 1
    fi

    if ! jq -e '
        .non_code and
        .non_code.dirs and
        .non_code.exts and
        .non_code.files and
        .run_all_patterns and
        .selection_rules and
        .target_order
    ' "$TEST_TARGET_RULES_FILE" > /dev/null 2>&1; then
        log_warn "自动目标选择规则文件格式无效: $TEST_TARGET_RULES_FILE，回退为 all"
        return 1
    fi

    TARGET_RULES_JSON="$(jq -c . "$TEST_TARGET_RULES_FILE")"
    return 0
}

# 判断是否为非代码文件（用于自动目标选择）
is_non_code_file() {
    local path="$1"
    if [ -z "$TARGET_RULES_JSON" ]; then
        return 1
    fi

    echo "$TARGET_RULES_JSON" | jq -e --arg path "$path" '
        (.non_code.dirs  | any(. as $d | $path | startswith($d))) or
        (.non_code.exts  | any(. as $e | $path | endswith($e))) or
        (.non_code.files | any(. as $f | $path == $f))
    ' > /dev/null 2>&1
}

# 获取变更文件列表（自动目标选择）
get_changed_files_for_auto_target() {
    local files=""
    if files=$(git diff --name-only "$BASE_REF" 2>/dev/null); then
        printf '%s\n' "$files"
        return 0
    fi

    log_warn "自动目标选择: base-ref '$BASE_REF' 不可用，回退到 HEAD~1"
    if files=$(git diff --name-only HEAD~1 2>/dev/null); then
        printf '%s\n' "$files"
        return 0
    fi
    return 1
}

# 根据变更路径自动选择测试目标
auto_detect_test_targets() {
    load_test_target_rules || {
        TEST_TARGET="all"
        AUTO_DETECTED_TARGETS=""
        return
    }

    # 优先使用 Rust 引擎 axci-affected（若已编译）
    local axci_root
    axci_root="$(cd "$(dirname "$0")" && pwd)"
    local affected_bin="$axci_root/axci-affected/target/release/axci-affected"
    if [ -x "$affected_bin" ]; then
        local engine_out
        engine_out="$("$affected_bin" "$COMPONENT_DIR" "$BASE_REF" "$TEST_TARGET_RULES_FILE" 2>/dev/null)" || true
        if [ -n "$engine_out" ] && echo "$engine_out" | jq -e '.skip_all != null and .targets != null' >/dev/null 2>&1; then
            local skip_all
            skip_all="$(echo "$engine_out" | jq -r '.skip_all')"
            if [ "$skip_all" = "true" ]; then
                log "自动目标选择 (axci-affected): 跳过所有测试"
                TEST_TARGET="__skip_all__"
                AUTO_DETECTED_TARGETS=""
                return
            fi
            local targets_arr=()
            while IFS= read -r t; do [ -n "$t" ] && targets_arr+=("$t"); done < <(echo "$engine_out" | jq -r '.targets[]?' 2>/dev/null)
            if [ ${#targets_arr[@]} -eq 0 ]; then
                log_warn "自动目标选择 (axci-affected): 无目标，回退 all"
                TEST_TARGET="all"
                AUTO_DETECTED_TARGETS=""
                return
            fi
            log "自动目标选择 (axci-affected): ${targets_arr[*]}"
            TEST_TARGET="__auto__"
            AUTO_DETECTED_TARGETS="${targets_arr[*]}"
            return
        fi
    fi

    # 依赖感知：可选地通过 cargo metadata 计算 changed/affected crates
    local changed_crates_json="[]"
    local affected_crates_json="[]"
    local file_to_crate_json="{}"
    local run_all_crates_json="[]"
    local crate_rules_json="[]"
    local crate_path_rules_json="[]"
    local affected_script=""

    affected_script="$(dirname "$0")/scripts/affected_crates.sh"
    if [ -f "$affected_script" ]; then
        # 解析规则中的 crate 相关配置（无则为空数组）
        run_all_crates_json="$(echo "$TARGET_RULES_JSON" | jq -c '.run_all_crates // []' 2>/dev/null || echo '[]')"
        crate_rules_json="$(echo "$TARGET_RULES_JSON" | jq -c '.crate_rules // []' 2>/dev/null || echo '[]')"
        crate_path_rules_json="$(echo "$TARGET_RULES_JSON" | jq -c '.crate_path_rules // []' 2>/dev/null || echo '[]')"
        if { echo "$run_all_crates_json" | jq -e '. | type == "array"' >/dev/null 2>&1; } || \
           { echo "$crate_rules_json" | jq -e '. | type == "array"' >/dev/null 2>&1; } || \
           { echo "$crate_path_rules_json" | jq -e '. | type == "array"' >/dev/null 2>&1; }; then
            # 若组件仓库是 Rust workspace 且安装了 cargo，则脚本会返回 crate 影响范围；否则返回空数组
            local crates_output
            crates_output="$("$affected_script" "$COMPONENT_DIR" "$BASE_REF" 2>/dev/null || true)"
            if [ -n "$crates_output" ] && echo "$crates_output" | jq -e '.changed_crates != null and .affected_crates != null' >/dev/null 2>&1; then
                changed_crates_json="$(echo "$crates_output" | jq -c '.changed_crates')"
                affected_crates_json="$(echo "$crates_output" | jq -c '.affected_crates')"
                file_to_crate_json="$(echo "$crates_output" | jq -c '.file_to_crate // {}')"
                log_debug "依赖感知: changed_crates=$changed_crates_json affected_crates=$affected_crates_json"
            fi
        fi
    fi

    local changed_files
    changed_files="$(get_changed_files_for_auto_target)" || {
        log_warn "自动目标选择失败，回退为 all"
        TEST_TARGET="all"
        return
    }

    local changed_count=0
    local rule_hits=()
    while IFS= read -r _line; do
        [ -z "$_line" ] && continue
        changed_count=$((changed_count + 1))
    done <<< "$changed_files"

    log "自动目标选择: base_ref=$BASE_REF, changed_files=$changed_count"
    if [[ "$VERBOSE" == true ]]; then
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            log_debug "  changed: $f"
        done <<< "$changed_files"
    fi

    # 无变更时直接跳过
    if [ -z "$changed_files" ]; then
        rule_hits+=("no_changes")
        log "自动目标选择: 未检测到变更，跳过所有测试"
        TEST_TARGET="__skip_all__"
        AUTO_DETECTED_TARGETS=""
        log_debug "  rules: ${rule_hits[*]}"
        return
    fi

    local has_code_change=false
    local needs_all=false
    local -A selected_target_map=()
    local run_all_pattern=""
    local f
    local rule_line
    local rule_id
    local patterns_blob
    local targets_blob
    local pattern
    local target_name

    local run_all_patterns=()
    mapfile -t run_all_patterns < <(echo "$TARGET_RULES_JSON" | jq -r '.run_all_patterns[]')
    local run_all_exclude_patterns=()
    mapfile -t run_all_exclude_patterns < <(echo "$TARGET_RULES_JSON" | jq -r '.run_all_exclude_patterns[]?')

    local selection_rule_rows=()
    mapfile -t selection_rule_rows < <(echo "$TARGET_RULES_JSON" | jq -r '.selection_rules[] | [.id, (.patterns | join("\u001f")), (.targets | join("\u001f"))] | @tsv')

    local target_order=()
    mapfile -t target_order < <(echo "$TARGET_RULES_JSON" | jq -r '.target_order[]')

    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if ! is_non_code_file "$f"; then
            has_code_change=true
        fi

        for run_all_pattern in "${run_all_patterns[@]}"; do
            if [[ "$f" == $run_all_pattern ]]; then
                local excluded=false
                local ex_pattern
                for ex_pattern in "${run_all_exclude_patterns[@]}"; do
                    if [[ "$f" == $ex_pattern ]]; then
                        excluded=true
                        break
                    fi
                done
                if [ "$excluded" = false ]; then
                    needs_all=true
                    rule_hits+=("run_all:$f")
                fi
                break
            fi
        done

        for rule_line in "${selection_rule_rows[@]}"; do
            IFS=$'\t' read -r rule_id patterns_blob targets_blob <<< "$rule_line"
            local matched=false
            local patterns=()
            IFS=$'\x1f' read -r -a patterns <<< "$patterns_blob"
            for pattern in "${patterns[@]}"; do
                if [[ "$f" == $pattern ]]; then
                    matched=true
                    break
                fi
            done
            if [ "$matched" = true ]; then
                rule_hits+=("$rule_id:$f")
                local targets=()
                IFS=$'\x1f' read -r -a targets <<< "$targets_blob"
                for target_name in "${targets[@]}"; do
                    selected_target_map["$target_name"]=1
                done
            fi
        done
    done <<< "$changed_files"

    if [ "$has_code_change" = false ]; then
        rule_hits+=("non_code_only")
        log "自动目标选择: 仅文档/非代码变更，跳过所有测试"
        TEST_TARGET="__skip_all__"
        AUTO_DETECTED_TARGETS=""
        log_debug "  rules: ${rule_hits[*]}"
        return
    fi

    # 依赖感知：run_all_crates 命中则全量
    if [ "$run_all_crates_json" != "[]" ] && [ "$changed_crates_json" != "[]" ]; then
        if echo "$run_all_crates_json" | jq -e --argjson changed "$changed_crates_json" '
          any(.[]; $changed | index(.))' >/dev/null 2>&1; then
            needs_all=true
            rule_hits+=("run_all_crates")
        fi
    fi

    if [ "$needs_all" = true ]; then
        TEST_TARGET="all"
        log "自动目标选择: 命中全量规则，运行 all"
        log_debug "  rules: ${rule_hits[*]}"
        return
    fi

    # 依赖感知：根据 crate_rules 为目标加分（changed_crates / affected_crates）
    if [ "$crate_rules_json" != "[]" ]; then
        while IFS= read -r rule; do
            [ -z "$rule" ] && continue
            local crates_json
            local direct_only
            local targets_json
            local check_json
            crates_json="$(echo "$rule" | jq -c '.crates // []')"
            direct_only="$(echo "$rule" | jq -r '.direct_only // false')"
            targets_json="$(echo "$rule" | jq -c '.targets // []')"
            if [ "$direct_only" = "true" ]; then
                check_json="$changed_crates_json"
            else
                check_json="$affected_crates_json"
            fi
            for crate in $(echo "$crates_json" | jq -r '.[]'); do
                if [ -n "$check_json" ] && echo "$check_json" | jq -e --arg c "$crate" 'index($c) != null' >/dev/null 2>&1; then
                    rule_hits+=("crate_rule:$crate")
                    for t in $(echo "$targets_json" | jq -r '.[]'); do
                        selected_target_map["$t"]=1
                    done
                    break
                fi
            done
        done < <(echo "$crate_rules_json" | jq -c '.[]?')
    fi

    # 依赖感知：crate_path_rules（crate + 路径 联合规则）
    if [ "$crate_path_rules_json" != "[]" ]; then
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            local file_crate
            file_crate="$(echo "$file_to_crate_json" | jq -r --arg f "$f" '.[$f] // empty' 2>/dev/null || true)"
            [ -z "$file_crate" ] && continue

            while IFS= read -r rule; do
                [ -z "$rule" ] && continue
                local crates_json
                local direct_only
                local targets_json
                local path_patterns_json
                local check_json
                crates_json="$(echo "$rule" | jq -c '.crates // []')"
                direct_only="$(echo "$rule" | jq -r '.direct_only // false')"
                targets_json="$(echo "$rule" | jq -c '.targets // []')"
                path_patterns_json="$(echo "$rule" | jq -c '.path_patterns // []')"
                if [ "$direct_only" = "true" ]; then
                    check_json="$changed_crates_json"
                else
                    check_json="$affected_crates_json"
                fi

                if ! echo "$check_json" | jq -e --arg c "$file_crate" 'index($c) != null' >/dev/null 2>&1; then
                    continue
                fi
                if ! echo "$crates_json" | jq -e --arg c "$file_crate" 'index($c) != null' >/dev/null 2>&1; then
                    continue
                fi

                local matched_path=false
                local p
                for p in $(echo "$path_patterns_json" | jq -r '.[]'); do
                    if [[ "$f" == $p ]]; then
                        matched_path=true
                        break
                    fi
                done
                if [ "$matched_path" = true ]; then
                    rule_hits+=("crate_path_rule:$file_crate:$f")
                    for t in $(echo "$targets_json" | jq -r '.[]'); do
                        selected_target_map["$t"]=1
                    done
                    break
                fi
            done < <(echo "$crate_path_rules_json" | jq -c '.[]?')
        done <<< "$changed_files"
    fi

    local targets=()
    for target_name in "${target_order[@]}"; do
        if [ -n "${selected_target_map[$target_name]:-}" ]; then
            targets+=("$target_name")
        fi
    done

    if [ ${#targets[@]} -eq 0 ]; then
        # 保守回退，避免漏测
        TEST_TARGET="all"
        log_warn "自动目标选择: 无法精确匹配，保守回退 all"
        log_debug "  rules: ${rule_hits[*]}"
        return
    fi

    TEST_TARGET="__auto__"
    AUTO_DETECTED_TARGETS="${targets[*]}"
    log "自动目标选择: ${AUTO_DETECTED_TARGETS}"
    log_debug "  rules: ${rule_hits[*]}"
}

# 获取要测试的目标
get_test_targets() {
    local targets=()

    if [ "$TEST_TARGET" == "__skip_all__" ]; then
        echo ""
        return
    elif [ "$TEST_TARGET" == "__auto__" ]; then
        echo "$AUTO_DETECTED_TARGETS"
        return
    elif [ "$TEST_TARGET" == "all" ]; then
        # 从配置获取所有目标
        local count=$(echo "$CONFIG" | jq '.test_targets | length')
        for ((i=0; i<count; i++)); do
            targets+=("$(echo "$CONFIG" | jq -r ".test_targets[$i].name")")
        done
    elif [[ "$TEST_TARGET" == axvisor-qemu ]]; then
        # 运行所有 axvisor QEMU 测试
        local count=$(echo "$CONFIG" | jq '.test_targets | length')
        for ((i=0; i<count; i++)); do
            local name=$(echo "$CONFIG" | jq -r ".test_targets[$i].name")
            if [[ "$name" == axvisor-qemu-* ]]; then
                targets+=("$name")
            fi
        done
    elif [[ "$TEST_TARGET" == axvisor-board ]]; then
        # 运行所有 axvisor 开发板测试
        local count=$(echo "$CONFIG" | jq '.test_targets | length')
        for ((i=0; i<count; i++)); do
            local name=$(echo "$CONFIG" | jq -r ".test_targets[$i].name")
            if [[ "$name" == axvisor-board-* ]]; then
                targets+=("$name")
            fi
        done
    elif [[ "$TEST_TARGET" == starry ]]; then
        # 运行所有 starry 测试
        local count=$(echo "$CONFIG" | jq '.test_targets | length')
        for ((i=0; i<count; i++)); do
            local name=$(echo "$CONFIG" | jq -r ".test_targets[$i].name")
            if [[ "$name" == starry-* ]]; then
                targets+=("$name")
            fi
        done
    else
        # 具体目标名称
        targets+=("$TEST_TARGET")
    fi
    
    echo "${targets[@]}"
}

# 运行单个测试目标
run_test_target() {
    local target_name=$1
    local log_file="$OUTPUT_DIR/logs/${target_name}_$(date +%Y%m%d_%H%M%S).log"
    local status_file="$OUTPUT_DIR/${target_name}.status"
    local meta_file="$OUTPUT_DIR/${target_name}.meta"
    local dependency_check_result="not_checked"
    local kvm_check_result="not_applicable"
    local image_retry_count=0
    local registry_fallback_used="no"
    
    log "测试目标: $target_name"
    
    # 获取目标配置
    local target_config=$(echo "$CONFIG" | jq -e ".test_targets[] | select(.name == \"$target_name\")")
    if [ -z "$target_config" ]; then
        log_error "未找到测试目标配置: $target_name"
        set_target_result "$status_file" "$meta_file" "failed" "$dependency_check_result" "$kvm_check_result" "$image_retry_count" "$registry_fallback_used"
        return 1
    fi
    
    local repo_url=$(echo "$target_config" | jq -r '.repo.url')
    local repo_branch=$(echo "$target_config" | jq -r '.repo.branch // "main"')
    local test_type=$(echo "$target_config" | jq -r '.type // "qemu"')
    local build_cmd=$(echo "$target_config" | jq -r '.build.command')
    local timeout_min=$(echo "$target_config" | jq -r '.build.timeout_minutes // 15')
    
    log_debug "  仓库: $repo_url ($repo_branch)"
    log_debug "  类型: $test_type"
    log_debug "  构建: $build_cmd"
    log_debug "  超时: ${timeout_min}分钟"

    # NimbOS x86_64 测试依赖 KVM，提前失败以减少无意义等待
    if [[ "$target_name" == "axvisor-qemu-x86_64-nimbos" ]] && [ "$DRY_RUN" != true ]; then
        kvm_check_result="checking"
        if ! check_kvm_available; then
            kvm_check_result="failed"
            set_target_result "$status_file" "$meta_file" "failed" "$dependency_check_result" "$kvm_check_result" "$image_retry_count" "$registry_fallback_used"
            return 1
        fi
        kvm_check_result="passed"
    fi
    
    # 测试目录
    local test_dir="$OUTPUT_DIR/repos/$target_name"
    
    # 克隆或更新仓库
    if [ ! -d "$test_dir" ]; then
        log "  克隆仓库..."
        if [ "$DRY_RUN" == true ]; then
            echo "[DRY-RUN] git clone --depth 1 -b $repo_branch $repo_url $test_dir"
        else
            if ! git clone --depth 1 -b $repo_branch "$repo_url" "$test_dir" >> "$log_file" 2>&1; then
                log_error "  克隆仓库失败: $repo_url"
                set_target_result "$status_file" "$meta_file" "failed" "$dependency_check_result" "$kvm_check_result" "$image_retry_count" "$registry_fallback_used"
                return 1
            fi
            # 初始化子模块
            if [ -f "$test_dir/.gitmodules" ]; then
                log "  初始化子模块..."
                (cd "$test_dir" && git submodule update --init --recursive) >> "$log_file" 2>&1 || true
            fi
        fi
    else
        log "  更新仓库..."
        if [ "$DRY_RUN" != true ]; then
            (cd "$test_dir" && git pull) >> "$log_file" 2>&1 || true
        fi
    fi
    
    # 确保仓库目录存在 (dry-run 模式下跳过)
    if [ "$DRY_RUN" != true ] && [ ! -d "$test_dir" ]; then
        log_error "  仓库目录不存在: $test_dir"
        set_target_result "$status_file" "$meta_file" "failed" "$dependency_check_result" "$kvm_check_result" "$image_retry_count" "$registry_fallback_used"
        return 1
    fi
    
    # dry-run 模式下跳过后续操作
    if [ "$DRY_RUN" == true ]; then
        log "  DRY RUN: 跳过 patch、构建和测试"
        set_target_result "$status_file" "$meta_file" "skipped" "$dependency_check_result" "$kvm_check_result" "$image_retry_count" "$registry_fallback_used"
        return 2
    fi
    
    # 应用 patch - 与 CI 逻辑保持一致
    # 优先级: 目标配置 > 全局配置 > 默认值
    local patch_section=$(echo "$target_config" | jq -r '.patch.section // empty')
    [ -z "$patch_section" ] && patch_section=$(echo "$CONFIG" | jq -r '.patch.section // "crates-io"')
    
    local patch_path=$(echo "$target_config" | jq -r '.patch.path_template // empty')
    [ -z "$patch_path" ] && patch_path=$(echo "$CONFIG" | jq -r '.patch.path_template // "../component"')
    
    # 转换为绝对路径
    if [[ "$patch_path" == ".."* ]]; then
        # 尝试从 test_dir 解析相对路径
        local resolved_path="$test_dir/$patch_path"
        if [ -d "$resolved_path" ]; then
            patch_path="$(cd "$resolved_path" && pwd)"
        else
            # 如果相对路径解析失败，直接使用组件目录的绝对路径
            log "  相对路径 $patch_path 不存在，使用组件目录: $COMPONENT_DIR"
            patch_path="$COMPONENT_DIR"
        fi
    fi
    
    log "  应用组件 patch (section: $patch_section, path: $patch_path)..."
    if [ "$DRY_RUN" == true ]; then
        echo "[DRY-RUN] 添加 patch 到 $test_dir/Cargo.toml"
    else
        cd "$test_dir"
        
        # 检查是否已添加该组件的 patch（只在 [patch.*] section 中检查）
        # 使用 awk 提取所有 [patch.*] section 的内容并检查
        local already_patched=$(awk '/^\[patch\./,/^\[/ {print}' Cargo.toml 2>/dev/null | grep -q "^$COMPONENT_CRATE\s*=" && echo "yes" || echo "no")
        if [ "$already_patched" == "yes" ]; then
            log "  组件 $COMPONENT_CRATE 已在 patch 中"
        else
            # 检查是否已存在 [patch.$patch_section] section
            if grep -q "^\[patch\.$patch_section\]" Cargo.toml 2>/dev/null; then
                # 在现有的 section 后添加
                # 使用 sed 在匹配行后插入
                sed -i "/^\[patch\.$patch_section\]/a $COMPONENT_CRATE = { path = \"$patch_path\" }" Cargo.toml
                log_debug "已在现有 patch section 中添加组件"
            else
                # 创建新的 section
                cat >> Cargo.toml << EOF

[patch.$patch_section]
$COMPONENT_CRATE = { path = "$patch_path" }
EOF
                log_debug "已创建新的 patch section 并添加组件"
            fi
        fi
    fi

    # 检查 patch 是否真正进入目标依赖图，避免“测了但没测到组件”
    if [[ "$target_name" == axvisor-* ]] || [[ "$target_name" == starry-* ]]; then
        if ! check_component_used "$target_name" "$test_dir"; then
            dependency_check_result="not_used"
            log_warn "  跳过测试: 组件 '$COMPONENT_CRATE' 未在 $target_name 依赖图中生效"
            set_target_result "$status_file" "$meta_file" "skipped" "$dependency_check_result" "$kvm_check_result" "$image_retry_count" "$registry_fallback_used"
            cd "$COMPONENT_DIR"
            return 2
        fi
        dependency_check_result="used"
    fi
    
    # 执行构建
    if [ -n "$build_cmd" ]; then
        log "  构建... ($build_cmd, timeout: ${timeout_min}m)"
        
        if [ "$DRY_RUN" == true ]; then
            echo "[DRY-RUN] cd $test_dir && timeout ${timeout_min}m $build_cmd"
        else
            cd "$test_dir"
            # 为 starry 测试准备构建命令
            local actual_build_cmd="$build_cmd"
            if [[ "$target_name" == starry-* ]]; then
                local arch=$(echo "$target_config" | jq -r '.arch')
                log "  构建架构: $arch"
                # 将 ARCH 作为 make 参数传递，而不是环境变量
                actual_build_cmd="$build_cmd ARCH=$arch"
            fi
            
            if timeout "${timeout_min}m" sh -c "$actual_build_cmd" >> "$log_file" 2>&1; then
                log_success "  构建成功: $target_name"
                
                # 为 starry 测试准备 rootfs
                if [[ "$target_name" == starry-* ]]; then
                    log "  准备 rootfs..."
                    local arch=$(echo "$target_config" | jq -r '.arch')
                    # 将 ARCH 作为 make 参数传递，而不是环境变量
                    if timeout "${timeout_min}m" sh -c "make rootfs ARCH=$arch" >> "$log_file" 2>&1; then
                        log_success "  Rootfs 准备成功"
                    else
                        log_error "  Rootfs 准备失败: $target_name"
                        set_target_result "$status_file" "$meta_file" "failed" "$dependency_check_result" "$kvm_check_result" "$image_retry_count" "$registry_fallback_used"
                        cd "$COMPONENT_DIR"
                        return 1
                    fi
                fi
            else
                local exit_code=$?
                if [ $exit_code -eq 124 ]; then
                    log_error "  构建超时: $target_name"
                else
                    log_error "  构建失败: $target_name (退出码: $exit_code)"
                fi
                set_target_result "$status_file" "$meta_file" "failed" "$dependency_check_result" "$kvm_check_result" "$image_retry_count" "$registry_fallback_used"
                cd "$COMPONENT_DIR"
                return 1
            fi
        fi
    fi
    
    # 执行测试（如果有测试配置）
    local has_test=$(echo "$target_config" | jq 'has("test")')
    if [ "$has_test" == "true" ]; then
        local test_cmd=$(echo "$target_config" | jq -r '.test.command')
        local test_timeout=$(echo "$target_config" | jq -r '.test.timeout_minutes // 30')
        
        log "  运行测试... ($test_cmd, timeout: ${test_timeout}m)"
        
        # Board 测试前准备
        if [ "$test_type" == "board" ]; then
            # 确保安装 ostool
            if ! command -v ostool &> /dev/null; then
                log "  安装 ostool..."
                cargo +stable install ostool --version ^0.8
            fi
            
            # 创建 TFTP 目录
            local bin_dir=$(echo "$target_config" | jq -r '.test.bin_dir // "/tmp/tftp"')
            mkdir -p "$bin_dir"
            log "  TFTP 目录已准备: $bin_dir"
            
            # 下载镜像和配置（类似 QEMU 测试）
            local vmconfigs=$(echo "$target_config" | jq -r '.test.vmconfigs')
            local vmimage_name=$(echo "$target_config" | jq -r '.test.vmimage_name // empty')
            
            if [ -n "$vmimage_name" ]; then
                log "  下载测试镜像..."
                
                # 创建镜像目录
                local IMAGE_DIR="${IMAGE_STORAGE_ROOT}"
                mkdir -p "$IMAGE_DIR"
                
                # 检查并下载镜像
                IFS=',' read -ra CONFIGS <<< "$vmconfigs"
                IFS=',' read -ra IMAGES <<< "$vmimage_name"
                
                for i in "${!CONFIGS[@]}"; do
                    img="${IMAGES[$i]}"
                    img=$(echo "$img" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                    config="${CONFIGS[$i]}"
                    config=$(echo "$config" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                    
                    # 检查镜像是否存在
                    local img_path="${IMAGE_DIR}/${img}"
                    if [ -d "$img_path" ]; then
                        log "  镜像已存在: $img_path"
                    else
                        log "  镜像不存在，开始下载: $img"
                        if [ -f "$test_dir/$config" ]; then
                            cd "$test_dir"
                            if download_image_with_retry "$test_dir" "$img" "$log_file"; then
                                log_success "  镜像下载成功: $img"
                            else
                                log_error "  镜像下载失败: $img"
                                set_target_result "$status_file" "$meta_file" "failed" "$dependency_check_result" "$kvm_check_result" "$image_retry_count" "$registry_fallback_used"
                                cd "$COMPONENT_DIR"
                                return 1
                            fi
                        else
                            log_warn "  配置文件不存在: $config"
                        fi
                    fi
                    
                    # 更新配置文件
                    if [ -f "$test_dir/$config" ]; then
                        cd "$test_dir"
                        
                        # 获取 image_location
                        local image_location=$(sed -n 's/^image_location[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$config")
                        local board_name=$(echo "$target_config" | jq -r '.board')
                        
                        # Board 测试的内核文件名（与 board 同名，例如 phytiumpi）
                        local kernel_name="${board_name}"
                        
                        case "$image_location" in
                        "fs")
                            log "  将配置从文件系统模式改为内存模式"
                            # 修改 image_location 为 memory
                            sed -i 's|^image_location[[:space:]]*=.*|image_location = "memory"|' "$config"
                            # 更新 kernel_path 指向镜像目录中的内核文件
                            sed -i 's|^kernel_path[[:space:]]*=.*|kernel_path = "'"${IMAGE_DIR}"'/'"$img"'/'"$kernel_name"'"|' "$config"
                            log "  已更新 kernel_path: ${IMAGE_DIR}/${img}/${kernel_name}"
                            ;;
                        "memory")
                            log "  内存存储模式 - 更新 kernel_path"
                            sed -i 's|^kernel_path[[:space:]]*=.*|kernel_path = "'"${IMAGE_DIR}"'/'"$img"'/'"$kernel_name"'"|' "$config"
                            log "  已更新 kernel_path: ${IMAGE_DIR}/${img}/${kernel_name}"
                            ;;
                        *)
                            log "  未知的 image_location: $image_location，修改为 memory"
                            sed -i 's|^image_location[[:space:]]*=.*|image_location = "memory"|' "$config"
                            sed -i 's|^kernel_path[[:space:]]*=.*|kernel_path = "'"${IMAGE_DIR}"'/'"$img"'/'"$kernel_name"'"|' "$config"
                            log "  已更新 kernel_path: ${IMAGE_DIR}/${img}/${kernel_name}"
                            ;;
                        esac
                    else
                        log_warn "  配置文件不存在: $config"
                    fi
                done
                cd "$COMPONENT_DIR"
            fi
        fi
        
        # 下载镜像和配置（仅适用于 axvisor QEMU 测试）
        if [[ "$target_name" == axvisor-qemu-* ]]; then
            local arch=$(echo "$target_config" | jq -r '.arch')
            local vmconfigs=$(echo "$target_config" | jq -r '.test.vmconfigs')
            local vmimage_name=$(echo "$target_config" | jq -r '.test.vmimage_name // empty')
            
            if [ -n "$vmimage_name" ]; then
                log "  下载测试镜像..."
                
                # 创建镜像目录
                local IMAGE_DIR="${IMAGE_STORAGE_ROOT}"
                mkdir -p "$IMAGE_DIR"
                
                # 安装 ostool（如果尚未安装）
                if ! command -v ostool &> /dev/null; then
                    log "  安装 ostool..."
                    cargo +stable install ostool --version ^0.8
                fi
                
                # 检查并下载镜像
                IFS=',' read -ra CONFIGS <<< "$vmconfigs"
                IFS=',' read -ra IMAGES <<< "$vmimage_name"
                
                for i in "${!CONFIGS[@]}"; do
                    img="${IMAGES[$i]}"
                    img=$(echo "$img" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                    config="${CONFIGS[$i]}"
                    config=$(echo "$config" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                    
                    # 检查镜像是否存在
                    local img_path="${IMAGE_DIR}/${img}"
                    if [ -d "$img_path" ]; then
                        log "  镜像已存在: $img_path"
                    else
                        log "  镜像不存在，开始下载: $img"
                        if [ -f "$test_dir/$config" ]; then
                            cd "$test_dir"
                            if download_image_with_retry "$test_dir" "$img" "$log_file"; then
                                log_success "  镜像下载成功: $img"
                            else
                                log_error "  镜像下载失败: $img"
                                set_target_result "$status_file" "$meta_file" "failed" "$dependency_check_result" "$kvm_check_result" "$image_retry_count" "$registry_fallback_used"
                                cd "$COMPONENT_DIR"
                                return 1
                            fi
                        else
                            log_warn "  配置文件不存在: $config"
                        fi
                    fi

                    # NimbOS x86_64 测试需要 BIOS 引导文件，缺失时直接失败并给出明确提示
                    if [[ "$img" == "qemu_x86_64_nimbos" ]]; then
                        local BIOS_IMG_PATH="${IMAGE_DIR}/${img}/axvm-bios.bin"
                        if [ ! -f "${BIOS_IMG_PATH}" ]; then
                            log_error "  缺少 NimbOS BIOS 文件: ${BIOS_IMG_PATH}"
                            log_error "  请重新下载镜像或检查镜像源可用性"
                            set_target_result "$status_file" "$meta_file" "failed" "$dependency_check_result" "$kvm_check_result" "$image_retry_count" "$registry_fallback_used"
                            cd "$COMPONENT_DIR"
                            return 1
                        fi
                    fi
                    
                    if [ -f "$test_dir/$config" ]; then
                        cd "$test_dir"
                        
                        # 获取 image_location
                        local image_location=$(sed -n 's/^image_location[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$config")
                        local img_name="qemu-$arch"
                        
                        case "$image_location" in
                        "fs")
                            log "  文件系统存储模式 - 无需更新配置"
                            ;;
                        "memory")
                            sed -i 's|^kernel_path[[:space:]]*=.*|kernel_path = "'"${IMAGE_DIR}"'/'"$img"'/'"$img_name"'"|' "$config"
                            log "  内存存储模式 - 已更新 kernel_path"
                            ;;
                        *)
                            log "  未知的 image_location: $image_location"
                            ;;
                        esac
                        
                        # 检查并处理 rootfs.img
                        local ROOTFS_IMG_PATH="${IMAGE_DIR}/$img/rootfs.img"
                        local qemu_config="$test_dir/$(echo "$target_config" | jq -r '.test.qemu_config')"
                        
                        if [ -f "${ROOTFS_IMG_PATH}" ]; then
                            log "  找到 rootfs.img，更新 $qemu_config"
                            sed -i 's|file=${workspaceFolder}/tmp/rootfs.img|file='"${ROOTFS_IMG_PATH}"'|' "$qemu_config"
                            log "  Rootfs 配置完成"
                        else
                            log "  未找到 rootfs.img，移除 rootfs 设备配置"
                            sed -i '/-device/,/virtio-blk-device,drive=disk0/d' "$qemu_config"
                            sed -i '/-drive/,/id=disk0,if=none,format=raw,file=${workspaceFolder}\/tmp\/rootfs.img/d' "$qemu_config"
                            sed -i 's/root=\/dev\/vda rw //' "$qemu_config"
                            log "  Rootfs 设备配置已移除"
                        fi
                    else
                        log_warn "  配置文件不存在: $config"
                    fi
                done
                cd "$COMPONENT_DIR"
            fi
        fi
        
        # 准备测试命令
        local full_test_cmd=""
        if [[ "$target_name" == axvisor-qemu-* ]]; then
            # Axvisor QEMU 测试
            local build_config=$(echo "$target_config" | jq -r '.test.build_config')
            local qemu_config=$(echo "$target_config" | jq -r '.test.qemu_config')
            local vmconfigs=$(echo "$target_config" | jq -r '.test.vmconfigs')
            full_test_cmd="$test_cmd --build-config $build_config --qemu-config $qemu_config --vmconfigs $vmconfigs"
            # NimbOS 需要自动输入 usertests，通过 PTY 包装器执行。
            if [[ "$target_name" == "axvisor-qemu-x86_64-nimbos" ]]; then
                full_test_cmd="python3 $FRAMEWORK_DIR/scripts/ci_run_qemu_nimbos.py -- $full_test_cmd"
            fi
        elif [[ "$target_name" == axvisor-board-* ]]; then
            # Axvisor Board 测试
            local build_config=$(echo "$target_config" | jq -r '.test.build_config')
            local uboot_config=$(echo "$target_config" | jq -r '.test.uboot_config')
            local vmconfigs=$(echo "$target_config" | jq -r '.test.vmconfigs')
            local bin_dir=$(echo "$target_config" | jq -r '.test.bin_dir // "/tmp/tftp"')

            cd "$test_dir"

            # 步骤 1: 执行 defconfig 生成 .build.toml
            log "  生成构建配置..."
            local board_name=$(echo "$target_config" | jq -r '.board')

            # 获取客户机配置文件列表
            # vmconfigs 是逗号分隔的列表，例如: "configs/vms/arceos-aarch64-e2000-smp1.toml"
            # 需要解析这些配置文件路径并配置到 vm_configs
            local vm_configs_json="["
            local vm_configs=$(echo "$target_config" | jq -r '.test.vmconfigs')
            IFS=',' read -ra CONFIGS <<< "$vmconfigs"
            for i in "${!CONFIGS[@]}"; do
                config="${CONFIGS[$i]}"
                config=$(echo "$config" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                if [ $i -gt 0 ]; then
                    vm_configs_json+=", "
                fi
                vm_configs_json+='"'"$config"'"'
            done
            vm_configs_json+="]"

            log "  执行 cargo xtask defconfig $board_name..."
            if cargo xtask defconfig "$board_name" >> "$log_file" 2>&1; then
                log_success "  Defconfig 成功"
            else
                log_error "  Defconfig 失败"
                set_target_result "$status_file" "$meta_file" "failed" "$dependency_check_result" "$kvm_check_result" "$image_retry_count" "$registry_fallback_used"
                cd "$COMPONENT_DIR"
                return 1
            fi

            # 步骤 2: 修改 .build.toml 文件
            log "  步骤 2: 更新 .build.toml 配置..."
            local build_toml=".build.toml"

            if [ -f "$build_toml" ]; then
                # 使用 awk 来替换 features 和 vm_configs
                awk -v vm_configs="$vm_configs_json" '
                    /^features = \[/ { in_features=1; print "features = ["; print "    # \"ept-level-4\","; print "    \"dyn-plat\","; print "    \"axstd/bus-mmio\","; print "]"; next }
                    in_features { if(/^\]/) { in_features=0 } next }
                    /^vm_configs = \[/ { in_vm=1; next }
                    in_vm { if(/^\]/) { in_vm=0 } next }
                    /^log = / { print $0 "\nvm_configs = " vm_configs; next }
                    { print }
                ' "$build_toml" > "$build_toml.tmp" && mv "$build_toml.tmp" "$build_toml"

                log_success "  .build.toml 更新完成"
                log_debug "    - Features 已更新"
                log_debug "    - vm_configs: $vm_configs_json"
            else
                log_error "  未找到 .build.toml 文件"
                set_target_result "$status_file" "$meta_file" "failed" "$dependency_check_result" "$kvm_check_result" "$image_retry_count" "$registry_fallback_used"
                cd "$COMPONENT_DIR"
                return 1
            fi

            # 步骤 3: 检查 .uboot.toml 是否存在，不存在则提示用户输入
            log "  步骤 3: 检查 U-Boot 配置..."
            local uboot_config_file=".uboot.toml"

            if [ ! -f "$uboot_config_file" ]; then
                # 生成交互式配置文件
                log ""
                log "  ======== 配置 U-Boot 参数 ======== "
                log ""

                # 提示用户输入 serial
                echo -e "${CYAN}请输入串口设备路径 (例如: /dev/ttyUSB0):${NC}"
                read -p "> " serial_input
                serial_input="${serial_input:-/dev/ttyUSB0}"

                # 提示用户输入 baud_rate
                echo ""
                echo -e "${CYAN}请输入波特率 (例如: 115200):${NC}"
                read -p "> " baud_rate_input
                baud_rate_input="${baud_rate_input:-115200}"

                # 提示用户输入 dtb_file
                echo ""
                echo -e "${CYAN}请输入 DTB 文件路径 (例如: board/orangepi-5-plus.dtb):${NC}"
                read -p "> " dtb_file_input
                dtb_file_input="${dtb_file_input:-board/orangepi-5-plus.dtb}"

                # 生成 .uboot.toml 文件
                cat > "$uboot_config_file" << EOF
serial = "$serial_input"
baud_rate = "$baud_rate_input"
success_regex = []
fail_regex = []
dtb_file = "$dtb_file_input"
EOF

                log ""
                log "  U-Boot 配置已保存到: $uboot_config_file"
                log "  - 串口: $serial_input"
                log "  - 波特率: $baud_rate_input"
                log "  - DTB文件: $dtb_file_input"
                log ""
            else
                log "  使用已存在的配置文件: $uboot_config_file"
            fi

            # 步骤 4: 执行 cargo xtask uboot
            full_test_cmd="$test_cmd"
        elif [[ "$target_name" == starry-* ]]; then
            # Starry 测试
            local arch=$(echo "$target_config" | jq -r '.arch')
            # 使用 Starry 官方 CI 脚本，避免 make run 长驻导致超时
            full_test_cmd="scripts/ci-test.py $arch"
        fi

        if [ "$DRY_RUN" == true ]; then
            echo "[DRY-RUN] cd $test_dir && timeout ${test_timeout}m $full_test_cmd"
        else
            cd "$test_dir"
            export RUST_LOG=debug
            if [[ "$target_name" == starry-* ]] && [ ! -f "$test_dir/disk.img" ]; then
                # 兼容 Starry 新旧 rootfs 命名：disk.img 或 rootfs-<arch>.img
                local starry_arch
                local arch_rootfs
                starry_arch="$(echo "$target_config" | jq -r '.arch // empty')"
                arch_rootfs="$test_dir/rootfs-${starry_arch}.img"
                if [ -n "$starry_arch" ] && [ -f "$arch_rootfs" ]; then
                    ln -sf "rootfs-${starry_arch}.img" "$test_dir/disk.img"
                    log "  检测到 rootfs-${starry_arch}.img，已链接为 disk.img"
                fi
            fi
            if [[ "$target_name" == starry-* ]] && [ ! -f "$test_dir/disk.img" ]; then
                log_error "  缺少 rootfs 镜像: $test_dir/disk.img"
                set_target_result "$status_file" "$meta_file" "failed" "$dependency_check_result" "$kvm_check_result" "$image_retry_count" "$registry_fallback_used"
                cd "$COMPONENT_DIR"
                return 1
            fi
            # Board 测试通过 PTY 运行，避免 crossterm 在非 TTY 环境异常。
            if [[ "$target_name" == axvisor-board-* ]]; then
                timeout "${test_timeout}m" script -q -c "$full_test_cmd" /dev/null 2>&1 | tee -a "$log_file"
            else
                timeout "${test_timeout}m" sh -c "$full_test_cmd" 2>&1 | tee -a "$log_file"
            fi
            local exit_code=${PIPESTATUS[0]}
            if [ $exit_code -eq 0 ]; then
                log_success "  测试成功: $target_name"
                set_target_result "$status_file" "$meta_file" "passed" "$dependency_check_result" "$kvm_check_result" "$image_retry_count" "$registry_fallback_used"
                cd "$COMPONENT_DIR"
                return 0
            else
                if [ $exit_code -eq 124 ]; then
                    log_error "  测试超时: $target_name"
                else
                    log_error "  测试失败: $target_name (退出码: $exit_code)"
                fi
                set_target_result "$status_file" "$meta_file" "failed" "$dependency_check_result" "$kvm_check_result" "$image_retry_count" "$registry_fallback_used"
                cd "$COMPONENT_DIR"
                return 1
            fi
        fi
    else
        # 没有测试配置，仅构建成功就算通过
        log_success "  仅构建，无测试: $target_name"
        set_target_result "$status_file" "$meta_file" "passed" "$dependency_check_result" "$kvm_check_result" "$image_retry_count" "$registry_fallback_used"
        cd "$COMPONENT_DIR"
        return 0
    fi
}

# 运行所有测试
run_all_tests() {
    local targets=$(get_test_targets)
    local failed=0
    local passed=0
    local skipped=0
    local pids=()
    local target_array=()
    
    # 转换为数组
    read -ra target_array <<< "$targets"
    
    log "测试目标: ${target_array[*]}"
    echo ""
    
    if [ "$PARALLEL" == true ] && [ ${#target_array[@]} -gt 1 ]; then
        # 并行执行
        for target in "${target_array[@]}"; do
            run_test_target "$target" &
            pids+=($!)
        done
        
        # 等待所有任务完成
        for i in "${!pids[@]}"; do
            local target="${target_array[$i]}"
            local status_file="$OUTPUT_DIR/${target}.status"
            wait ${pids[$i]} || true

            if [ -f "$status_file" ]; then
                local status=$(cat "$status_file")
                if [ "$status" == "passed" ]; then
                    ((passed++))
                elif [ "$status" == "skipped" ]; then
                    ((skipped++))
                else
                    ((failed++))
                fi
            else
                # 未生成状态文件时按失败处理
                ((failed++))
            fi
        done
    else
        # 顺序执行
        for target in "${target_array[@]}"; do
            run_test_target "$target"
            local exit_code=$?
            if [ $exit_code -eq 0 ]; then
                ((passed++))
            elif [ $exit_code -eq 2 ]; then
                ((skipped++))
            else
                ((failed++))
            fi
        done
    fi
    
    echo ""
    log "测试结果:"
    echo "  - 通过: $passed"
    echo "  - 失败: $failed"
    echo "  - 跳过: $skipped"
    
    # 生成报告
    generate_report "$passed" "$failed" "$skipped"
    
    if [ $failed -gt 0 ]; then
        return 1
    fi
    return 0
}

# 生成报告
generate_report() {
    local passed=$1
    local failed=$2
    local skipped=$3
    local report_file="$OUTPUT_DIR/report.md"
    
    cat > "$report_file" << EOF
# 测试报告

**组件**: $COMPONENT_NAME 
**时间**: $(date '+%Y-%m-%d %H:%M:%S')  
**配置**: $CONFIG_FILE

## 结果汇总

| 状态 | 数量 |
|------|------|
| ✅ 通过 | $passed |
| ❌ 失败 | $failed |
| ⏭️ 跳过 | $skipped |

## 详细结果

EOF
    
    for status_file in "$OUTPUT_DIR"/*.status; do
        if [ -f "$status_file" ]; then
            local name=$(basename "$status_file" .status)
            local status=$(cat "$status_file")
            local meta_file="$OUTPUT_DIR/${name}.meta"
            local dep_check="unknown"
            local kvm_check="unknown"
            local image_retry_count="0"
            local fallback_used="no"

            if [ -f "$meta_file" ]; then
                dep_check=$(sed -n 's/^dep_check=//p' "$meta_file")
                kvm_check=$(sed -n 's/^kvm_check=//p' "$meta_file")
                image_retry_count=$(sed -n 's/^image_retry_count=//p' "$meta_file")
                fallback_used=$(sed -n 's/^registry_fallback_used=//p' "$meta_file")
            fi

            local details="(dep=$dep_check, kvm=$kvm_check, retries=$image_retry_count, fallback=$fallback_used)"
            if [ "$status" == "passed" ]; then
                echo "- $name: ✅ 通过 $details" >> "$report_file"
            elif [ "$status" == "skipped" ]; then
                echo "- $name: ⏭️ 跳过 $details" >> "$report_file"
            else
                echo "- $name: ❌ 失败 $details" >> "$report_file"
            fi
        fi
    done
    
    log_debug "报告已生成: $report_file"
}

# 清理
cleanup() {
    if [ "$CLEANUP" == true ] && [ "$DRY_RUN" != true ]; then
        log_debug "清理临时文件..."
        
        # 恢复 Cargo.toml
        for test_dir in "$OUTPUT_DIR/repos"/*; do
            if [ -d "$test_dir" ]; then
                (cd "$test_dir" && git checkout Cargo.toml 2>/dev/null) || true
            fi
        done
    fi
}

# 主函数
main() {
    parse_args "$@"
    
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Hypervisor Test Framework${NC}"
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo ""
    
    check_dependencies
    load_config

    if [ "$AUTO_TARGET" == true ]; then
        auto_detect_test_targets
    fi
    
    log "配置加载完成"
    log "组件: $COMPONENT_NAME ($COMPONENT_CRATE)"
    
    setup_output
    
    log "输出目录: $OUTPUT_DIR"
    
    if [ "$DRY_RUN" == true ]; then
        log_warn "DRY RUN 模式 - 不会执行实际操作"
    fi
    
    # 临时禁用 set -e 以捕获 run_all_tests 的返回值
    set +e
    run_all_tests
    local result=$?
    set -e
    
    cleanup
    
    echo ""
    if [ $result -eq 0 ]; then
        log_success "所有测试通过!"
    elif [ $result -eq 2 ]; then
        log_warn "部分测试被跳过（需要硬件）"
    else
        log_error "部分测试失败"
    fi
    
    exit $result
}

# 捕获信号
trap cleanup EXIT INT TERM

main "$@"
