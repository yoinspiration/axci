#!/bin/bash
#
# repo.sh - 仓库克隆与更新
#

SCRIPT_DIR_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR_REPO/lib/common.sh"

# 克隆或更新仓库
# 参数: target_name, repo_url, repo_branch, test_dir, log_file, status_file
clone_or_update_repo() {
    local target_name=$1
    local repo_url=$2
    local repo_branch=$3
    local test_dir=$4
    local log_file=$5
    local status_file=$6

    if [ ! -d "$test_dir" ]; then
        # 判断是否为 axvisor 目标，且未使用 --git 选项时，使用 cargo clone 从 crates.io 下载
        if [[ "$target_name" == axvisor-* ]] && [ "$USE_GIT" == false ]; then
            log "  从 crates.io 下载 axvisor..."
            if [ "$DRY_RUN" == true ]; then
                echo "[DRY-RUN] cargo clone axvisor -- $test_dir"
            else
                if ! cargo clone axvisor -- "$test_dir" >> "$log_file" 2>&1; then
                    log_error "  下载 axvisor 失败"
                    echo "failed" > "$status_file"
                    return 1
                fi
            fi
        else
            log "  克隆仓库..."
            if [ "$DRY_RUN" == true ]; then
                echo "[DRY-RUN] git clone --depth 1 -b $repo_branch $repo_url $test_dir"
            else
                if ! git clone --depth 1 -b $repo_branch "$repo_url" "$test_dir" >> "$log_file" 2>&1; then
                    log_error "  克隆仓库失败: $repo_url"
                    echo "failed" > "$status_file"
                    return 1
                fi
                # 初始化子模块
                if [ -f "$test_dir/.gitmodules" ]; then
                    log "  初始化子模块..."
                    (cd "$test_dir" && git submodule update --init --recursive) >> "$log_file" 2>&1 || true
                fi
            fi
        fi
    else
        log "  更新仓库..."
        if [ "$DRY_RUN" != true ]; then
            if [[ "$target_name" == axvisor-* ]] && [ "$USE_GIT" == false ]; then
                # axvisor 使用 cargo clone，不进行 git pull
                log "  axvisor 从 crates.io 下载，跳过更新"
            else
                (cd "$test_dir" && git pull) >> "$log_file" 2>&1 || true
            fi
        fi
    fi
}
