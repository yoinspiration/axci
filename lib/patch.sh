#!/bin/bash
#
# patch.sh - 组件依赖检查和 Cargo patch 应用
#

SCRIPT_DIR_PATCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR_PATCH/lib/common.sh"

# 检查组件是否被目标项目使用（从 Cargo.lock 或 Cargo.toml 中检索）
# 返回 0 表示使用（或无法确定），1 表示确认未使用
check_component_used() {
    local target_name=$1
    local test_dir=$2

    # 如果不是 axvisor 或 starry 相关的测试，直接返回使用
    if [[ "$target_name" != axvisor-* ]] && [[ "$target_name" != starry-* ]]; then
        return 0
    fi

    log_debug "  检查组件 '$COMPONENT_CRATE' 是否被 $target_name 使用 (搜索目录: $test_dir)"

    # 生成 hyphen 变体 (Cargo 视 _ 和 - 为等价)
    local crate_hyphen="${COMPONENT_CRATE//_/-}"

    local cargo_lock="$test_dir/Cargo.lock"

    # 1. 首选: 从 Cargo.lock 检查（包含所有传递依赖，最可靠）
    if [ -f "$cargo_lock" ]; then
        if grep -q "name = \"$COMPONENT_CRATE\"" "$cargo_lock" 2>/dev/null || \
           grep -q "name = \"$crate_hyphen\"" "$cargo_lock" 2>/dev/null; then
            log_debug "  在 Cargo.lock 中找到组件: $COMPONENT_CRATE"
            return 0
        fi
        # Cargo.lock 存在但未找到，可以确认不使用
        log_debug "  Cargo.lock 中未找到组件: $COMPONENT_CRATE"
        return 1
    fi

    # 2. 无 Cargo.lock: 尝试生成（解析完整依赖树，包括传递依赖）
    log_debug "  未找到 Cargo.lock，尝试 cargo generate-lockfile..."
    if (cd "$test_dir" && cargo generate-lockfile 2>/dev/null); then
        if [ -f "$cargo_lock" ]; then
            if grep -q "name = \"$COMPONENT_CRATE\"" "$cargo_lock" 2>/dev/null || \
               grep -q "name = \"$crate_hyphen\"" "$cargo_lock" 2>/dev/null; then
                log_debug "  在生成的 Cargo.lock 中找到组件: $COMPONENT_CRATE"
                return 0
            fi
            log_debug "  生成的 Cargo.lock 中未找到组件: $COMPONENT_CRATE"
            return 1
        fi
    fi

    # 3. generate-lockfile 失败: 递归搜索所有 Cargo.toml
    log_debug "  cargo generate-lockfile 失败，回退到 Cargo.toml 搜索"
    if find "$test_dir" -name "Cargo.toml" -exec grep -l "$COMPONENT_CRATE" {} + 2>/dev/null | grep -q .; then
        log_debug "  在 Cargo.toml 中找到组件: $COMPONENT_CRATE"
        return 0
    fi

    if [ "$crate_hyphen" != "$COMPONENT_CRATE" ]; then
        if find "$test_dir" -name "Cargo.toml" -exec grep -l "$crate_hyphen" {} + 2>/dev/null | grep -q .; then
            log_debug "  在 Cargo.toml 中找到组件 (hyphen 变体): $crate_hyphen"
            return 0
        fi
    fi

    # 4. 无法确定时默认继续测试（避免误跳过）
    log_warn "  无法确认组件 '$COMPONENT_CRATE' 是否被使用，继续测试"
    return 0
}

# 应用组件 patch 到目标项目的 Cargo.toml
# 参数: target_config, test_dir
apply_component_patch() {
    local target_config=$1
    local test_dir=$2

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
            patch_path="$COMPONENT_DIR"
        fi
    fi

    log "  应用组件 patch (section: $patch_section, path: $patch_path)..."
    if [ "$DRY_RUN" == true ]; then
        echo "[DRY-RUN] 添加 patch 到 $test_dir/Cargo.toml"
    else
        cd "$test_dir"

        # 检查是否已添加该组件的 patch（只在 [patch.*] section 中检查）
        if grep -E "^\[patch\." Cargo.toml >/dev/null 2>&1 && \
           grep -A 100 "^\[patch\." Cargo.toml | grep -q "^$COMPONENT_CRATE\s*="; then
            log "  组件 $COMPONENT_CRATE 已在 patch 中"
        else
            # 检查是否已存在 [patch.$patch_section] section
            if grep -q "^\[patch\.$patch_section\]" Cargo.toml 2>/dev/null; then
                # 在现有的 section 后添加
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
}
