#!/bin/bash
#
# qemu.sh - QEMU 测试专用：镜像配置和命令准备
#

SCRIPT_DIR_QEMU="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR_QEMU/lib/common.sh"

# 设置 QEMU 镜像配置（kernel_path、rootfs 处理）
# 参数: target_config, target_name, test_dir, log_file, status_file
setup_qemu_images() {
    local target_config=$1
    local target_name=$2
    local test_dir=$3
    local log_file=$4
    local status_file=$5

    local arch=$(echo "$target_config" | jq -r '.arch')
    local vmconfigs=$(echo "$target_config" | jq -r '.test.vmconfigs')
    local vmimage_name=$(echo "$target_config" | jq -r '.test.vmimage_name // empty')

    if [ -z "$vmimage_name" ]; then
        return 0
    fi

    # 安装 ostool
    ensure_ostool

    # 下载镜像
    if ! download_images "$vmconfigs" "$vmimage_name" "$test_dir" "$log_file" "$status_file"; then
        return 1
    fi

    local IMAGE_DIR="/tmp/.axvisor-images"

    # 配置镜像路径和 rootfs
    IFS=',' read -ra CONFIGS <<< "$vmconfigs"
    IFS=',' read -ra IMAGES <<< "$vmimage_name"

    for i in "${!CONFIGS[@]}"; do
        local img="${IMAGES[$i]}"
        img=$(echo "$img" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        local config="${CONFIGS[$i]}"
        config=$(echo "$config" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

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
    return 0
}

# 准备 QEMU 测试命令
# 参数: target_config
# 输出: 完整的测试命令到 stdout
prepare_qemu_command() {
    local target_config=$1

    local target_name=$(echo "$target_config" | jq -r '.name')
    local test_cmd=$(echo "$target_config" | jq -r '.test.command')
    local build_config=$(echo "$target_config" | jq -r '.test.build_config')
    local qemu_config=$(echo "$target_config" | jq -r '.test.qemu_config')
    local vmconfigs=$(echo "$target_config" | jq -r '.test.vmconfigs')

    # NimbOS 需要使用 Python 包装器自动发送 usertests 命令
    if [[ "$target_name" == *nimbos* ]]; then
        echo "python3 scripts/ci_run_qemu_nimbos.py -- $test_cmd --build-config $build_config --qemu-config $qemu_config --vmconfigs $vmconfigs"
    else
        echo "$test_cmd --build-config $build_config --qemu-config $qemu_config --vmconfigs $vmconfigs"
    fi
}
