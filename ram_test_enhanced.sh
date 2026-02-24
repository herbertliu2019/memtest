#!/bin/bash
############################################################
# Industrial RAM Test Script - Enhanced with EDAC Memory Fault Localization
# 基于原 ram_test.sh 的改进版本
# 
# 新增功能：
#   1. EDAC 驱动自动加载和初始化
#   2. 故障内存条精确定位（到DIMM插槽）
#   3. CE/UE 错误计数和增量统计
#   4. 故障通道映射到物理 DIMM 位置
#   5. 改进的 JSON 报告（包含EDAC数据和故障位置）
#
# 保持原有特性：
#   ✓ Kernel error 仅捕捉 Memory + CPU（ECC/EDAC/MCE）
#   ✓ 测试完成后自动上传 + 自动关机
#   ✓ 完整的依赖检查、错误处理
############################################################

# --- 1. 配置区 (请根据实际情况修改) ---
TEST_TIME=300                                           # 压力测试时长（秒）
LOG_DIR="/root/test_logs"                               # 日志路径
UPLOAD_URL="http://192.168.30.100:5000/api/upload"      # 【重要】改成你中控服务器的IP
UPLOAD_TOKEN=""                                         # 可选：Bearer Token，留空则不启用
AUTO_MODE=1                                             # 1=无人值守模式(自动关机), 0=交互模式(按键退出)
AUTO_POWEROFF=1                                         # 1=测试完成后自动关机, 0=保留现场

mkdir -p "$LOG_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
GSAT_LOG="$LOG_DIR/gsat_${TIMESTAMP}.log"
MEM_INV_LOG="$LOG_DIR/mem_inv_${TIMESTAMP}.log"
EDAC_PRE_LOG="/tmp/edac_pre_${TIMESTAMP}.log"
EDAC_POST_LOG="/tmp/edac_post_${TIMESTAMP}.log"
JSON_FILE="/tmp/report_${TIMESTAMP}.json"

# 颜色定义
RES_BOLD='\033[1m'
RES_GREEN='\033[1;32m'
RES_YELLOW='\033[1;33m'
RES_RED='\033[1;31m'
RES_NONE='\033[0m'

############################################################
# 工具函数
############################################################
log_info()  { echo -e "${RES_GREEN}[INFO]${RES_NONE}  $*"; }
log_warn()  { echo -e "${RES_YELLOW}[WARN]${RES_NONE}  $*"; }
log_error() { echo -e "${RES_RED}[ERROR]${RES_NONE} $*" >&2; }

safe_exit() {
    local code=${1:-0}
    log_info "Exiting with code $code"
    exit "$code"
}

############################################################
# 2. 依赖检查
############################################################
clear
echo -e "${RES_BOLD}>>> Industrial RAM Test Pipeline Starting (Enhanced with EDAC)...${RES_NONE}"
echo "Timestamp: $TIMESTAMP"
echo ""

log_info "Step 0: Checking dependencies..."
MISSING_DEPS=0
for cmd in dmidecode stressapptest curl jq awk; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Required command not found: $cmd"
        MISSING_DEPS=1
    fi
done

# 检查 edac-util（新增）
if ! command -v edac-util &>/dev/null; then
    log_warn "edac-util not found. Memory fault localization will be limited."
    EDAC_AVAILABLE=0
else
    EDAC_AVAILABLE=1
fi

if [ "$MISSING_DEPS" -eq 1 ]; then
    log_error "Please install missing dependencies before running."
    log_error "  Ubuntu/Debian: apt-get install -y dmidecode stressapptest curl jq edac-utils"
    safe_exit 2
fi
log_info "All dependencies OK."

############################################################
# 3. EDAC 驱动初始化（新增）
############################################################
if [ "$EDAC_AVAILABLE" -eq 1 ]; then
    log_info "Step 0.5: Initializing EDAC drivers..."
    
    # 加载 EDAC 核心模块
    if ! lsmod | grep -q edac_core; then
        log_info "Loading edac_core module..."
        sudo modprobe edac_core 2>/dev/null || log_warn "Could not load edac_core"
    fi
    
    # 尝试加载特定的 EDAC 驱动
    for driver in edac_mce_amd ie31200_edac i7core_edac ghes; do
        if modprobe -l "$driver" &>/dev/null; then
            if ! lsmod | grep -q "$driver"; then
                sudo modprobe "$driver" 2>/dev/null || true
            fi
        fi
    done
    
    log_info "EDAC drivers initialized."
fi

############################################################
# 4. 内存插槽扫描（保持原有逻辑）
############################################################
log_info "Step 1: Scanning memory hardware..."
HW_DROP_DETECTED=0

sudo dmidecode -t memory 2>/dev/null | awk '
/Memory Device$/ {
    slot = ""; size = ""
}
/^\s+Locator:/ && !/Bank Locator/ {
    sub(/^\s+Locator:\s+/, ""); slot = $0
}
/^\s+Size:/ {
    sub(/^\s+Size:\s+/, ""); size = $0
    if (slot != "") {
        if (size ~ /No Module Installed/ || size ~ /^0$/) {
            printf "%s|EMPTY\n", slot
        } else {
            printf "%s|%s\n", slot, size
        }
    }
}' > "$MEM_INV_LOG"

if [ ! -s "$MEM_INV_LOG" ]; then
    log_warn "dmidecode returned no memory slot info. Skipping slot check."
else
    TOTAL_SLOTS=$(wc -l < "$MEM_INV_LOG")
    EMPTY_SLOTS=$(grep -c "EMPTY" "$MEM_INV_LOG" || true)
    log_info "Total slots: $TOTAL_SLOTS | Empty slots: $EMPTY_SLOTS"
    if [ "$EMPTY_SLOTS" -gt 0 ]; then
        HW_DROP_DETECTED=1
        log_warn "Empty memory slot(s) detected!"
        grep "EMPTY" "$MEM_INV_LOG" | awk -F'|' '{print "  -> Slot: " $1}'
    fi
fi

############################################################
# 5. 采集测试前的 EDAC 状态（新增）
############################################################
INITIAL_CE_COUNT=0
INITIAL_UE_COUNT=0

if [ "$EDAC_AVAILABLE" -eq 1 ]; then
    log_info "Recording initial EDAC state..."
    
    # 保存当前 dmesg 中的 EDAC 错误（用于增量检测）
    dmesg | grep -iE "ECC|EDAC" | grep -v "Corrected" > "$EDAC_PRE_LOG" 2>/dev/null || true
    
    # 尝试从 edac-util 获取初始错误计数
    if edac-util -v &>/dev/null; then
        INITIAL_CE_COUNT=$(edac-util -v 2>/dev/null | grep "CE: " | awk '{sum+=$NF} END {print sum+0}')
        INITIAL_UE_COUNT=$(edac-util -v 2>/dev/null | grep "UE: " | awk '{sum+=$NF} END {print sum+0}')
        log_info "Initial EDAC counters: CE=$INITIAL_CE_COUNT, UE=$INITIAL_UE_COUNT"
    fi
fi

############################################################
# 6. 压力测试 (stressapptest) - 保持原有逻辑
############################################################
TOTAL_CORES=$(nproc)
FREE_KB=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
TEST_MB=$((FREE_KB * 90 / 100 / 1024))

if [ "$FREE_KB" -lt $((512 * 1024)) ]; then
    log_error "Available memory too low (${FREE_KB}KB). Aborting to prevent OOM."
    safe_exit 3
fi
[ "$TEST_MB" -lt 256 ] && TEST_MB=256

log_info "Step 2: Running stressapptest..."
log_info "  Cores: $TOTAL_CORES | Memory to test: ${TEST_MB}MB | Duration: ${TEST_TIME}s"

dmesg | grep -iE "ECC|EDAC" | grep -v "Corrected" > /tmp/pre_mem_err_${TIMESTAMP}.log 2>/dev/null || true
dmesg | grep -iE "MCE" | grep -v "Corrected" > /tmp/pre_cpu_err_${TIMESTAMP}.log 2>/dev/null || true

stressapptest -M "${TEST_MB}" -s "${TEST_TIME}" -W --cc_test > "$GSAT_LOG" 2>&1
GSAT_EXIT=$?

dmesg | grep -iE "ECC|EDAC" | grep -v "Corrected" > /tmp/post_mem_err_${TIMESTAMP}.log 2>/dev/null || true
dmesg | grep -iE "MCE" | grep -v "Corrected" > /tmp/post_cpu_err_${TIMESTAMP}.log 2>/dev/null || true

MEM_KERNEL_ERRORS=$(diff "/tmp/pre_mem_err_${TIMESTAMP}.log" "/tmp/post_mem_err_${TIMESTAMP}.log" 2>/dev/null | grep -c '^>' || true)
CPU_KERNEL_ERRORS=$(diff "/tmp/pre_cpu_err_${TIMESTAMP}.log" "/tmp/post_cpu_err_${TIMESTAMP}.log" 2>/dev/null | grep -c '^>' || true)

GSAT_REAL_ERRORS=0
if grep -qiE "Error|FAIL" "$GSAT_LOG" 2>/dev/null; then
    _parsed=$(grep -oP '\d+ error' "$GSAT_LOG" | tail -1 | grep -oP '\d+' || true)
    [ -n "$_parsed" ] && GSAT_REAL_ERRORS=$_parsed
fi
if [ "$GSAT_EXIT" -ne 0 ] && [ "$GSAT_REAL_ERRORS" -eq 0 ]; then
    GSAT_REAL_ERRORS=-1
fi

log_info "stressapptest exit code: $GSAT_EXIT | Parsed errors: $GSAT_REAL_ERRORS | Mem kernel errors: $MEM_KERNEL_ERRORS | CPU kernel errors: $CPU_KERNEL_ERRORS"

############################################################
# 7. 采集测试后的 EDAC 状态并计算增量（新增）
############################################################
FINAL_CE_COUNT=$INITIAL_CE_COUNT
FINAL_UE_COUNT=$INITIAL_UE_COUNT
CE_DELTA=0
UE_DELTA=0
FAILED_CHANNELS=""
EDAC_ERROR_DETAILS=""

if [ "$EDAC_AVAILABLE" -eq 1 ]; then
    log_info "Analyzing EDAC results..."
    
    # 保存当前 dmesg 中的 EDAC 错误
    dmesg | grep -iE "ECC|EDAC" | grep -v "Corrected" > "$EDAC_POST_LOG" 2>/dev/null || true
    
    # 获取最终错误计数
    if edac-util -v &>/dev/null; then
        FINAL_CE_COUNT=$(edac-util -v 2>/dev/null | grep "CE: " | awk '{sum+=$NF} END {print sum+0}')
        FINAL_UE_COUNT=$(edac-util -v 2>/dev/null | grep "UE: " | awk '{sum+=$NF} END {print sum+0}')
    fi
    
    CE_DELTA=$((FINAL_CE_COUNT - INITIAL_CE_COUNT))
    UE_DELTA=$((FINAL_UE_COUNT - INITIAL_UE_COUNT))
    
    log_info "Final EDAC counters: CE=$FINAL_CE_COUNT (delta: $CE_DELTA), UE=$FINAL_UE_COUNT (delta: $UE_DELTA)"
    
    # 检测故障通道（从 dmesg 中提取）
    EDAC_ERROR_DETAILS=$(diff "$EDAC_PRE_LOG" "$EDAC_POST_LOG" 2>/dev/null | grep '^>' | sed 's/^> //' || true)
    
    if [ -n "$EDAC_ERROR_DETAILS" ]; then
        # 提取 mc# 和 ch# 信息
        FAILED_CHANNELS=$(echo "$EDAC_ERROR_DETAILS" | grep -oE "mc[0-9]+[[:space:]]+ch[0-9]+" | sort -u | tr '\n' ',' | sed 's/,$//')
        log_info "Failed channels detected: $FAILED_CHANNELS"
    fi
fi

############################################################
# 8. 最终判定 - 增加 UE 错误的严重性（新增逻辑）
############################################################
if [ "$GSAT_EXIT" -ne 0 ] || [ "$GSAT_REAL_ERRORS" -gt 0 ] || [ "$MEM_KERNEL_ERRORS" -gt 0 ] || [ "$CPU_KERNEL_ERRORS" -gt 0 ] || [ "$UE_DELTA" -gt 0 ]; then
    FINAL_STATUS="FAIL"
elif [ "$CE_DELTA" -gt 10 ] || [ "$HW_DROP_DETECTED" -eq 1 ]; then
    FINAL_STATUS="WARNING"
else
    FINAL_STATUS="PASS"
fi

log_info "Final verdict: $FINAL_STATUS"

############################################################
# 9. 映射故障通道到物理 DIMM（新增）
############################################################
FAILED_DIMMS=""

if [ -n "$FAILED_CHANNELS" ]; then
    log_info "Mapping failed channels to physical DIMMs..."
    
    # 简单映射规则（可根据实际主板修改）
    # mc0_ch0 -> DIMM_0_0, mc0_ch1 -> DIMM_0_1, etc.
    FAILED_DIMMS=$(echo "$FAILED_CHANNELS" | tr ',' '\n' | while read channel; do
        # 提取 mc 和 ch 数字
        mc=$(echo "$channel" | grep -oE 'mc[0-9]+' | grep -oE '[0-9]+')
        ch=$(echo "$channel" | grep -oE 'ch[0-9]+' | grep -oE '[0-9]+')
        echo "DIMM_${mc}_${ch}"
    done | tr '\n' ',' | sed 's/,$//')
    
    log_info "Failed DIMMs: $FAILED_DIMMS"
fi

############################################################
# 10. 构造改进的 JSON（新增 EDAC 字段）
############################################################
log_info "Step 3: Packaging report..."
HOSTNAME_VAL=$(hostname)
IP_ADDR=$(hostname -I | awk '{print $1}')

# 构建 slots JSON 数组
SLOTS_JSON=$(awk -F'|' '{print $1, $2}' "$MEM_INV_LOG" 2>/dev/null | \
    jq -Rn '[inputs | split(" ") | {"slot": .[0], "size": (.[1:] | join(" "))}]' 2>/dev/null || echo "[]")

# 构建故障通道数组
FAILED_CHANNELS_JSON=$(echo "$FAILED_CHANNELS" | jq -Rn 'input | split(",") | map(select(length > 0))' 2>/dev/null || echo "[]")

# 构建故障 DIMM 数组
FAILED_DIMMS_JSON=$(echo "$FAILED_DIMMS" | jq -Rn 'input | split(",") | map(select(length > 0))' 2>/dev/null || echo "[]")

# 使用 jq 安全构造整个 JSON（新增 EDAC 部分）
jq -n \
    --arg hostname "$IP_ADDR" \
    --arg ip       "$IP_ADDR" \
    --arg verdict  "$FINAL_STATUS" \
    --arg ts       "$(date '+%Y-%m-%d %H:%M:%S')" \
    --argjson gsat_errors  "$GSAT_REAL_ERRORS" \
    --argjson mem_kernel_errors  "$MEM_KERNEL_ERRORS" \
    --argjson cpu_kernel_errors  "$CPU_KERNEL_ERRORS" \
    --argjson test_time    "$TEST_TIME" \
    --argjson mem_mb       "$TEST_MB" \
    --argjson slots        "$SLOTS_JSON" \
    --argjson initial_ce   "$INITIAL_CE_COUNT" \
    --argjson final_ce     "$FINAL_CE_COUNT" \
    --argjson ce_delta     "$CE_DELTA" \
    --argjson initial_ue   "$INITIAL_UE_COUNT" \
    --argjson final_ue     "$FINAL_UE_COUNT" \
    --argjson ue_delta     "$UE_DELTA" \
    --argjson failed_channels "$FAILED_CHANNELS_JSON" \
    --argjson failed_dimms    "$FAILED_DIMMS_JSON" \
    --arg edac_details     "$EDAC_ERROR_DETAILS" \
    '{
        hostname:       $hostname,
        ip:             $ip,
        verdict:        $verdict,
        timestamp:      $ts,
        errors: {
            gsat:           $gsat_errors,
            mem_kernel:     $mem_kernel_errors,
            cpu_kernel:     $cpu_kernel_errors
        },
        edac_results: {
            initial_ce_count: $initial_ce,
            final_ce_count:   $final_ce,
            ce_delta:         $ce_delta,
            initial_ue_count: $initial_ue,
            final_ue_count:   $final_ue,
            ue_delta:         $ue_delta
        },
        memory_errors: {
            failed_channels: $failed_channels,
            failed_dimms:    $failed_dimms,
            error_details:   $edac_details
        },
        metrics: {
            test_time:      $test_time,
            mem_tested_mb:  $mem_mb
        },
        memory_slots: $slots
    }' > "$JSON_FILE"

log_info "Report saved to $JSON_FILE"

############################################################
# 11. 上传（保持原有逻辑）
############################################################
log_info "Step 4: Uploading report to $UPLOAD_URL ..."
UPLOAD_OK=0

CURL_AUTH=()
if [ -n "$UPLOAD_TOKEN" ]; then
    CURL_AUTH=(-H "Authorization: Bearer $UPLOAD_TOKEN")
fi

for i in 1 2 3; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        --fail \
        --connect-timeout 10 \
        --max-time 30 \
        -X POST "$UPLOAD_URL" \
        -H "Content-Type: application/json" \
        "${CURL_AUTH[@]}" \
        -d @"$JSON_FILE" 2>/dev/null || true)

    if [[ "$HTTP_CODE" =~ ^2 ]]; then
        log_info "Upload success (HTTP $HTTP_CODE) on attempt $i."
        UPLOAD_OK=1
        break
    else
        log_warn "Upload attempt $i/3 failed (HTTP $HTTP_CODE). Retrying in 5s..."
        sleep 5
    fi
done

if [ "$UPLOAD_OK" -eq 0 ]; then
    log_error "All upload attempts failed. Report retained locally: $JSON_FILE"
fi

############################################################
# 12. 结果展示（增强版，显示故障位置）
############################################################
echo ""
echo "############################################################"
case "$FINAL_STATUS" in
    PASS)    echo -e "        TEST VERDICT: ${RES_GREEN}${RES_BOLD}PASS${RES_NONE}" ;;
    WARNING) echo -e "        TEST VERDICT: ${RES_YELLOW}${RES_BOLD}WARNING${RES_NONE}" ;;
    FAIL)    echo -e "        TEST VERDICT: ${RES_RED}${RES_BOLD}FAIL${RES_NONE}" ;;
esac
echo "############################################################"
printf "  %-18s %s\n" "HOSTNAME(IP):"  "$IP_ADDR"
printf "  %-18s %s\n" "GSAT ERRORS:"   "$GSAT_REAL_ERRORS"
printf "  %-18s %s\n" "MEM KERNEL ERR:" "$MEM_KERNEL_ERRORS"
printf "  %-18s %s\n" "CPU KERNEL ERR:" "$CPU_KERNEL_ERRORS"

# 新增：显示 EDAC 结果
if [ "$EDAC_AVAILABLE" -eq 1 ]; then
    printf "  %-18s CE: $FINAL_CE_COUNT (+$CE_DELTA) | UE: $FINAL_UE_COUNT (+$UE_DELTA)\n" "EDAC ERRORS:"
    
    if [ -n "$FAILED_CHANNELS" ]; then
        printf "  %-18s %s\n" "FAILED CHANNELS:" "$FAILED_CHANNELS"
        printf "  %-18s %s\n" "FAILED DIMMs:" "$FAILED_DIMMS"
    fi
fi

printf "  %-18s %s\n" "MISSING SLOTS:" "$( [ "$HW_DROP_DETECTED" -eq 1 ] && echo "YES ($EMPTY_SLOTS slot(s))" || echo "NONE" )"
printf "  %-18s %s\n" "UPLOAD:"        "$( [ "$UPLOAD_OK" -eq 1 ] && echo "OK" || echo "FAILED (local copy kept)" )"
printf "  %-18s %s\n" "LOG DIR:"       "$LOG_DIR"
echo "############################################################"

############################################################
# 13. 自动关机逻辑（保持原有）
############################################################
if [ "$AUTO_POWEROFF" -eq 1 ]; then
    if [ "$FINAL_STATUS" = "FAIL" ]; then
        log_warn "Test failed. Machine will power off in 30 seconds..."
        log_warn "Press Ctrl+C to cancel auto-poweroff."
        sleep 30
    else
        log_info "Test completed. Machine will power off in 10 seconds..."
        sleep 10
    fi
    log_info "Shutting down..."
    sudo poweroff
else
    if [ "$AUTO_MODE" -eq 1 ]; then
        log_info "Auto mode: exiting without poweroff."
    else
        echo ""
        echo -e "[DONE] Press any key to exit (auto-exit in 60s)..."
        read -t 60 -n 1 -s || true
    fi
fi

# 退出码逻辑
if [ "$FINAL_STATUS" = "FAIL" ]; then
    safe_exit 1
elif [ "$UPLOAD_OK" -eq 0 ]; then
    safe_exit 4
else
    safe_exit 0
fi
