#!/bin/bash
#
# report.sh - 测试报告生成
#

SCRIPT_DIR_REPORT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR_REPORT/lib/common.sh"

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

    # 添加单元测试结果
    local unit_status_file="$OUTPUT_DIR/unit_tests.status"
    if [ -f "$unit_status_file" ]; then
        local unit_status=$(cat "$unit_status_file")
        echo "### 单元测试" >> "$report_file"
        if [ "$unit_status" == "passed" ]; then
            echo "- ✅ 通过" >> "$report_file"
        elif [ "$unit_status" == "skipped" ]; then
            echo "- ⏭️ 跳过" >> "$report_file"
        else
            echo "- ❌ 失败" >> "$report_file"
        fi
        echo "" >> "$report_file"
    fi

    # 添加集成测试结果
    local has_integration=false
    for status_file in "$OUTPUT_DIR"/*.status; do
        if [ -f "$status_file" ] && [ "$(basename "$status_file")" != "unit_tests.status" ]; then
            has_integration=true
            break
        fi
    done

    if [ "$has_integration" == true ]; then
        echo "### 集成测试" >> "$report_file"
        for status_file in "$OUTPUT_DIR"/*.status; do
            if [ -f "$status_file" ] && [ "$(basename "$status_file")" != "unit_tests.status" ]; then
                local name=$(basename "$status_file" .status)
                local status=$(cat "$status_file")
                if [ "$status" == "passed" ]; then
                    echo "- $name: ✅ 通过" >> "$report_file"
                elif [ "$status" == "skipped" ]; then
                    echo "- $name: ⏭️ 跳过 (需要硬件)" >> "$report_file"
                else
                    echo "- $name: ❌ 失败" >> "$report_file"
                fi
            fi
        done
    fi

    log_debug "报告已生成: $report_file"
}
