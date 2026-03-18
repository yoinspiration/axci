#!/bin/bash
#
# image.sh - 镜像下载和 ostool 安装（QEMU 和 Board 共用）
#

SCRIPT_DIR_IMAGE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR_IMAGE/lib/common.sh"

# 确保 ostool 已安装
ensure_ostool() {
    if ! command -v ostool &> /dev/null; then
        log "  安装 ostool..."
        cargo +stable install ostool --version ^0.8
    fi
}

# 下载镜像
# 参数: vmconfigs, vmimage_name, test_dir, log_file, status_file
# 返回: 0 成功, 1 失败
download_images() {
    local vmconfigs=$1
    local vmimage_name=$2
    local test_dir=$3
    local log_file=$4
    local status_file=$5

    log "  下载测试镜像..."

    # 创建镜像目录
    local IMAGE_DIR="/tmp/.axvisor-images"
    sudo mkdir -p "$IMAGE_DIR"
    sudo chmod 777 "$IMAGE_DIR"

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
                if cargo xtask image download $img >> "$log_file" 2>&1; then
                    log_success "  镜像下载成功: $img"
                else
                    log_error "  镜像下载失败: $img"
                    echo "failed" > "$status_file"
                    cd "$COMPONENT_DIR"
                    return 1
                fi
            else
                log_warn "  配置文件不存在: $config"
            fi
        fi
    done

    cd "$COMPONENT_DIR"
    return 0
}
