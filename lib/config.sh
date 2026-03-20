#!/bin/bash
#
# config.sh - 配置加载、目标检测、依赖检查
#

SCRIPT_DIR_CONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR_CONFIG/lib/common.sh"

# 从 rust-toolchain.toml 中提取 targets 并映射到架构
detect_targets_from_toolchain() {
    local toolchain_file="$COMPONENT_DIR/rust-toolchain.toml"
    local detected_archs=()

    if [ ! -f "$toolchain_file" ]; then
        log_warn "未找到 rust-toolchain.toml，使用所有架构"
        echo "all"
        return
    fi

    # 提取 targets 数组
    local targets=$(grep -A 20 '^targets' "$toolchain_file" 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' || true)

    if [ -z "$targets" ]; then
        log_warn "rust-toolchain.toml 中未找到 targets，使用所有架构"
        echo "all"
        return
    fi

    log_debug "从 rust-toolchain.toml 检测到 targets:"

    # 解析每个 target 并映射到架构
    while IFS= read -r target; do
        [ -z "$target" ] && continue
        log_debug "  - $target"

        case "$target" in
            *aarch64*)
                if [[ " ${detected_archs[*]} " != *" aarch64 "* ]]; then
                    detected_archs+=("aarch64")
                fi
                ;;
            *x86_64*)
                if [[ " ${detected_archs[*]} " != *" x86_64 "* ]]; then
                    detected_archs+=("x86_64")
                fi
                ;;
            *riscv64*)
                if [[ " ${detected_archs[*]} " != *" riscv64 "* ]]; then
                    detected_archs+=("riscv64")
                fi
                ;;
            *loongarch64*)
                if [[ " ${detected_archs[*]} " != *" loongarch64 "* ]]; then
                    detected_archs+=("loongarch64")
                fi
                ;;
        esac
    done <<< "$targets"

    if [ ${#detected_archs[@]} -eq 0 ]; then
        log_warn "无法从 targets 识别架构，使用所有架构"
        echo "all"
        return
    fi

    log "检测到的架构: ${detected_archs[*]}"
    echo "${detected_archs[*]}"
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

    if [ ${#missing[@]} -gt 0 ]; then
        error "缺少依赖: ${missing[*]}\n请安装后重试。"
    fi

    # 检查并安装 cargo-clone
    if ! command -v cargo-clone &> /dev/null && ! cargo clone --help &> /dev/null; then
        log "安装 cargo-clone..."
        cargo install cargo-clone
    fi

    log_success "依赖检查通过"
}

# 默认测试目标
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
      "vmimage_name": "qemu_aarch64_arceos"
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
    "build": {"command": "make build", "timeout_minutes": 15},
    "test": {},
    "patch": {"path_template": "../component"}
  },
  {
    "name": "starry-loongarch64",
    "type": "qemu",
    "arch": "loongarch64",
    "repo": {"url": "https://github.com/Starry-OS/StarryOS", "branch": "main"},
    "build": {"command": "make build", "timeout_minutes": 15},
    "test": {},
    "patch": {"path_template": "../component"}
  },
  {
    "name": "starry-aarch64",
    "type": "qemu",
    "arch": "aarch64",
    "repo": {"url": "https://github.com/Starry-OS/StarryOS", "branch": "main"},
    "build": {"command": "make build", "timeout_minutes": 15},
    "test": {},
    "patch": {"path_template": "../component"}
  },
  {
    "name": "starry-x86_64",
    "type": "qemu",
    "arch": "x86_64",
    "repo": {"url": "https://github.com/Starry-OS/StarryOS", "branch": "main"},
    "build": {"command": "make build", "timeout_minutes": 15},
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
      "vmimage_name": "phytiumpi_arceos,phytiumpi_linux",
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
      "vmimage_name": "roc-rk3568-pc_arceos,roc-rk3568-pc_linux",
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
            local original_targets=$(echo "$CONFIG" | jq -c '{targets}')
            CONFIG=$(echo "$original_targets" | jq -c '. + {"component":{"name":"'"$COMPONENT_NAME"'","crate_name":"'"$COMPONENT_CRATE"'"},"test_targets":'"$DEFAULT_TARGETS"'}')
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

    sudo mkdir -p "$OUTPUT_DIR/logs"
    sudo chmod -R 777 "$OUTPUT_DIR"
    log_debug "输出目录: $OUTPUT_DIR"
}
