#!/bin/bash
#
# runner.sh - 命令执行引擎：成功/失败检测、端口清理
#

SCRIPT_DIR_RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR_RUNNER/lib/common.sh"

# 检查并关闭占用端口5555的程序
kill_port_5555_processes() {
    local pids=$(sudo lsof -ti :5555 2>/dev/null)

    if [ -n "$pids" ]; then
        for pid in $pids; do
            log_debug "    关闭进程: PID=$pid"
            sudo kill -9 $pid 2>/dev/null || true
        done
        # 等待端口释放
        sleep 1
    fi
}

# 运行命令并监控输出，检测成功/失败标识符
run_with_success_detection() {
    local cmd="$1"
    local timeout_minutes="$2"
    local log_file="$3"
    local board_name="${4:-}"
    local test_dir="${5:-}"
    local success_patterns=()
    local error_patterns=()

    # 定义成功标识符模式（支持通配符）
    success_patterns+=("Welcome to")
    success_patterns+=("test pass!")
    success_patterns+=("All tests passed!")
    success_patterns+=("simple_sleep passed!")
    success_patterns+=("Hello, world!")
    success_patterns+=("root@firefly:~#")
    success_patterns+=("root@phytium-Ubuntu:~#")
    success_patterns+=("Set hostname to")
    success_patterns+=("starry:~#")
    success_patterns+=("Last login:")
    success_patterns+=("Booting kernel with command")
    # 定义错误标识符模式
    error_patterns+=("error[")
    error_patterns+=("FAILED")
    error_patterns+=("panicked")
    error_patterns+=("segmentation fault")
    error_patterns+=("core dumped")

    # 特殊模式：等待开发板上电
    local power_on_done=false
    local power_on_time=""

    # 创建临时文件来存储状态
    local status_file=$(mktemp)
    local power_flag_file=$(mktemp)
    echo "running" > "$status_file"
    echo "false" > "$power_flag_file"

    # 使用 timeout 运行命令，同时监控输出
    local pid=""
    local fifo=$(mktemp -u)
    mkfifo "$fifo"

    # 启动命令并将输出重定向到管道（添加全局超时）
    timeout "${timeout_minutes}m" sh -c "$cmd" < /dev/null > "$fifo" 2>&1 &
    pid=$!

    # 在后台读取管道并检测成功/错误标识符
    (
        while IFS= read -r line; do
            # 输出到日志
            echo "$line" >> "$log_file"

            # 根据 --print 选项决定是否输出到标准输出
            [[ "$PRINT_OUTPUT" == true ]] && echo "$line"

            # 检测是否等待开发板上电
            if [[ "$line" == *"Waiting for board on power or reset"* ]]; then
                if [ "$power_on_done" == false ] && [ -n "$board_name" ]; then
                    power_on_done=true
                    echo "true" > "$power_flag_file"
                    echo "$(date +%s)" >> "$power_flag_file"
                    # 提示用户上电
                    log "  准备就绪，请给开发板上电…"
                    # 执行上电命令
                    control_board_power "$board_name" "on"
                fi
            fi

            # 检测是否匹配任何错误标识符（优先检测错误）
            for pattern in "${error_patterns[@]}"; do
                if [[ "$line" == *"$pattern"* ]]; then
                    echo "error:$pattern" > "$status_file"
                    kill $pid 2>/dev/null || true
                    exit 0
                fi
            done

            # 检测是否匹配任何成功标识符
            for pattern in "${success_patterns[@]}"; do
                if [[ "$line" == *"$pattern"* ]]; then
                    echo "success" > "$status_file"
                    kill $pid 2>/dev/null || true
                    exit 0
                fi
            done
        done < "$fifo"
    ) &
    local monitor_pid=$!

    # 等待主命令完成
    wait $pid 2>/dev/null || true
    local main_exit_code=$?

    # 对于开发板测试，主命令可能在 U-Boot 启动后就退出了
    # 此时应该继续监控串口输出，等待内核启动完成
    local is_powered_on=$(head -1 "$power_flag_file")
    if [ "$is_powered_on" == "true" ] && [ -n "$board_name" ]; then
        local power_on_timestamp=$(tail -1 "$power_flag_file")
        local current_time=$(date +%s)
        local elapsed=$((current_time - power_on_timestamp))
        local remaining_time=$((timeout_minutes * 60 - elapsed))

        if [ $remaining_time -gt 0 ]; then
            log "  U-Boot 阶段完成，继续监控串口输出 (剩余 ${remaining_time}s)..."

            # 从 .uboot.json 获取串口设备
            local uboot_json_file="$COMPONENT_DIR/.uboot.json"
            # 回退: 框架自带的 uboot.json
            if [ ! -f "$uboot_json_file" ] && [ -f "$SCRIPT_DIR_RUNNER/json/uboot.json" ]; then
                uboot_json_file="$SCRIPT_DIR_RUNNER/json/uboot.json"
            fi
            local serial_port=""
            if [ -f "$uboot_json_file" ]; then
                serial_port=$(jq -r ".boards[\"$board_name\"].serial // empty" "$uboot_json_file" 2>/dev/null)
            fi

            # 如果找到了串口设备，继续读取串口输出
            if [ -n "$serial_port" ] && [ -e "$serial_port" ]; then

                # 等待串口设备可用（cargo osrun 退出后释放串口）
                local wait_count=0
                while [ $wait_count -lt 10 ]; do
                    if ! lsof "$serial_port" &>/dev/null; then
                        break
                    fi
                    sleep 1
                    ((wait_count++))
                done

                # 保存当前终端设置
                local saved_stty=$(stty -g 2>/dev/null) || true

                # 根据 --print 选项决定是否打印到标准输出
                if [[ "$PRINT_OUTPUT" == true ]]; then
                    timeout $remaining_time cat "$serial_port" 2>/dev/null | tee -a "$log_file" &
                else
                    timeout $remaining_time cat "$serial_port" 2>/dev/null >> "$log_file" &
                fi
                local serial_pid=$!

                # 监控日志文件检测成功/失败标识符
                local extra_wait=$remaining_time
                while [ $extra_wait -gt 0 ]; do
                    if grep -qE "Welcome to|test pass!|All tests passed!|Hello, world!|root@firefly:~#|Set hostname to" "$log_file" 2>/dev/null; then
                        echo -ne "\r\033[K"  # 清除当前行
                        log "  检测到成功标识符!"
                        echo "success" > "$status_file"
                        break
                    fi
                    if grep -qE "FAILED|panicked|segmentation fault|core dumped" "$log_file" 2>/dev/null; then
                        echo -ne "\r\033[K"  # 清除当前行
                        log "  检测到错误标识符!"
                        echo "error:detected" > "$status_file"
                        break
                    fi
                    sleep 1
                    ((extra_wait--))
                done

                # 终止串口读取进程
                kill $serial_pid 2>/dev/null || true
                sleep 0.5
                pkill -9 -P $serial_pid 2>/dev/null || true
                kill -9 $serial_pid 2>/dev/null || true

                # 恢复终端设置
                if [ -n "$saved_stty" ]; then
                    stty "$saved_stty" 2>/dev/null || true
                fi
                echo -ne "\r\033[K"  # 清除当前行，确保后续输出整齐
            else
                # 没有串口设备，只能等待
                log_warn "  未找到串口设备配置"
            fi
        fi
    fi

    # 等待监控进程完成
    wait $monitor_pid 2>/dev/null || true

    # 确保终端恢复正常（双重保险）
    stty sane 2>/dev/null || true

    # 读取状态
    local status=$(cat "$status_file")

    # 清理
    rm -f "$fifo" "$status_file" "$power_flag_file"

    # 如果是开发板测试，清理资源（关闭电源、释放串口等）
    if [ -n "$board_name" ] && [ -n "$test_dir" ]; then
        cleanup_board_resources "$board_name" "$test_dir"
    fi

    # 根据状态返回结果
    if [[ "$status" == error:* ]]; then
        local pattern=${status#error:}
        return 1
    elif [ "$status" = "success" ]; then
        return 0
    elif [ $main_exit_code -eq 124 ]; then
        return 124
    else
        # 检查是否是因为检测到成功标识符而结束
        if [ "$status" = "success" ]; then
            return 0
        fi
        # 进程退出但没有检测到成功标识符，视为失败
        return 1
    fi
}
