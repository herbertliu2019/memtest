#!/bin/bash
############################################################
# Industrial RAM Test Script - v4.2 (Ultimate Version)
# 
# 终极版本：融合 v3 和 v4 所有优点
#   1. ✅ 完整的内存扫描 + 备用方案（来自v3）
#   2. ✅ 详细的 GSAT 结果分析（来自v3）
#   3. ✅ 优化的 JSON 结构（gsat_results 字段）（来自v3）
#   4. ✅ 完整的 EDAC 故障定位（来自v4）
#   5. ✅ 故障通道检测和 DIMM 映射（来自v4）
#   6. ✅ CE/UE 增量统计（来自v4）
#   7. ✅ 新增：提取 Bank Locator 辅助精准定位槽位
############################################################

# --- 1. 配置区 ---
TEST_TIME=900                                           # 压力测试时长（秒）
LOG_DIR="/root/test_logs"                               # 日志路径
UPLOAD_URL="http://192.168.30.18:8080/mem/api/upload"  # 中控服务器IP
UPLOAD_TOKEN=""                                         # 可选：Bearer Token
AUTO_MODE=1                                             # 1=无人值守, 0=交互模式
AUTO_POWEROFF=1                                         # 1=自动关机, 0=保留现场

mkdir -p "$LOG_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
GSAT_LOG="$LOG_DIR/gsat_${TIMESTAMP}.log"
MEM_DETAIL_LOG="$LOG_DIR/mem_detail_${TIMESTAMP}.log"
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
echo -e "${RES_BOLD}>>> Industrial RAM Test Pipeline v4.2 (Ultimate) Starting...${RES_NONE}"
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

# 检查 edac-util（可选）
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
# 3. EDAC 驱动初始化
############################################################
if [ "$EDAC_AVAILABLE" -eq 1 ]; then
    log_info "Step 0.5: Initializing EDAC drivers..."
    
    if ! lsmod | grep -q edac_core; then
        sudo modprobe edac_core 2>/dev/null || log_warn "Could not load edac_core"
    fi
    
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
# 4. 内存插槽扫描（提取 Bank Locator）
############################################################
log_info "Step 1: Scanning memory hardware (detailed)..."
HW_DROP_DETECTED=0

sudo dmidecode -t memory 2>/dev/null | awk '
/^Memory Device/ {
    if (slot != "") {
        printf "%s|%s|%s|%s|%s|%s\n", slot, bank, size, type, speed, manufacturer
    }
    slot = ""
    bank = "Unknown"
    size = ""
    type = "Unknown"
    speed = "Unknown"
    manufacturer = "Unknown"
}
/^\s+Locator:/ && !/Bank Locator/ {
    sub(/^\s+Locator:\s+/, "")
    slot = $0
}
/^\s+Bank Locator:/ {
    sub(/^\s+Bank Locator:\s+/, "")
    bank = $0
}
/^\s+Size:/ {
    sub(/^\s+Size:\s+/, "")
    size = $0
    if (size == "" || size ~ /No Module Installed/ || size ~ /^0 *B?$/) {
        size = "EMPTY"
    }
}
/^\s+Type:/ {
    sub(/^\s+Type:\s+/, "")
    type = $0
}
/^\s+Speed:/ {
    sub(/^\s+Speed:\s+/, "")
    speed = $0
}
/^\s+Manufacturer:/ {
    sub(/^\s+Manufacturer:\s+/, "")
    manufacturer = $0
}
END {
    if (slot != "") {
        printf "%s|%s|%s|%s|%s|%s\n", slot, bank, size, type, speed, manufacturer
    }
}' > "$MEM_DETAIL_LOG"

if [ ! -s "$MEM_DETAIL_LOG" ]; then
    log_warn "dmidecode returned no memory slot info. Attempting alternative method..."
    
    dmidecode -t memory 2>/dev/null | awk '
    /^Memory Device/ {
        if (slot != "") {
            printf "%s|%s|%s|%s|%s|%s\n", slot, bank, size, type, speed, manufacturer
        }
        slot = ""; bank = "Unknown"; size = ""; type = "Unknown"; speed = "Unknown"; manufacturer = "Unknown"
    }
    /^\s+Locator:/ && !/Bank Locator/ {
        sub(/^\s+Locator:\s+/, ""); slot = $0
    }
    /^\s+Bank Locator:/ {
        sub(/^\s+Bank Locator:\s+/, ""); bank = $0
    }
    /^\s+Size:/ {
        sub(/^\s+Size:\s+/, ""); size = $0
        if (size == "" || size ~ /No Module Installed/ || size ~ /^0 *B?$/) {
            size = "EMPTY"
        }
    }
    /^\s+Type:/ {
        sub(/^\s+Type:\s+/, ""); type = $0
    }
    /^\s+Speed:/ {
        sub(/^\s+Speed:\s+/, ""); speed = $0
    }
    /^\s+Manufacturer:/ {
        sub(/^\s+Manufacturer:\s+/, ""); manufacturer = $0
    }
    END {
        if (slot != "") {
            printf "%s|%s|%s|%s|%s|%s\n", slot, bank, size, type, speed, manufacturer
        }
    }' > "$MEM_DETAIL_LOG"
fi

# 分析内存信息
if [ -s "$MEM_DETAIL_LOG" ]; then
    TOTAL_SLOTS=$(wc -l < "$MEM_DETAIL_LOG")
    EMPTY_SLOTS=$(grep "|EMPTY|" "$MEM_DETAIL_LOG" | wc -l)
    INSTALLED_SLOTS=$((TOTAL_SLOTS - EMPTY_SLOTS))
    
    log_info "Memory Inventory:"
    log_info "  Total slots: $TOTAL_SLOTS | Installed: $INSTALLED_SLOTS | Empty: $EMPTY_SLOTS"
    
    while IFS='|' read -r slot bank size type speed manufacturer; do
        if [ "$size" = "EMPTY" ]; then
            log_warn "  Slot $slot ($bank): EMPTY"
            HW_DROP_DETECTED=1
        else
            log_info "  Slot $slot ($bank): $size | Type: $type | Speed: $speed | Mfg: $manufacturer"
        fi
    done < "$MEM_DETAIL_LOG"
else
    log_warn "Unable to get memory inventory from dmidecode"
    TOTAL_SLOTS=0
    EMPTY_SLOTS=0
    INSTALLED_SLOTS=0
fi

############################################################
# 5. 采集测试前的 EDAC 状态
############################################################
INITIAL_CE_COUNT=0
INITIAL_UE_COUNT=0

if [ "$EDAC_AVAILABLE" -eq 1 ]; then
    log_info "Recording initial EDAC state..."
    dmesg | grep -iE "ECC|EDAC" | grep -v "Corrected" > "$EDAC_PRE_LOG" 2>/dev/null || true
    
    if edac-util -v &>/dev/null; then
        INITIAL_CE_COUNT=$(edac-util -v 2>/dev/null | grep "CE: " | awk '{sum+=$NF} END {print sum+0}')
        INITIAL_UE_COUNT=$(edac-util -v 2>/dev/null | grep "UE: " | awk '{sum+=$NF} END {print sum+0}')
        log_info "Initial EDAC counters: CE=$INITIAL_CE_COUNT, UE=$INITIAL_UE_COUNT"
    fi
fi

############################################################
# 6. 压力测试 (stressapptest)
############################################################
TOTAL_CORES=$(nproc)
FREE_KB=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
if [ "$FREE_KB" -gt 67108864 ]; then
    PERCENT=95
else
    PERCENT=90
fi

TEST_MB=$((FREE_KB * PERCENT / 100 / 1024))
log_info "Capacity detected. Using $PERCENT% of available memory for testing."

#TEST_MB=$((FREE_KB * 90 / 100 / 1024))

if [ "$FREE_KB" -lt $((512 * 1024)) ]; then
    log_error "Available memory too low (${FREE_KB}KB). Aborting to prevent OOM."
    safe_exit 3
fi
[ "$TEST_MB" -lt 256 ] && TEST_MB=256

log_info "Step 2: Running stressapptest..."
log_info "  Cores: $TOTAL_CORES | Memory to test: ${TEST_MB}MB | Duration: ${TEST_TIME}s"

stressapptest -M "${TEST_MB}" -s "${TEST_TIME}" -W --cc_test > "$GSAT_LOG" 2>&1
GSAT_EXIT=$?

############################################################
# 7. 详细的 GSAT 结果分析
############################################################
log_info "Analyzing GSAT results..."

GSAT_ERRORS=$(grep -i "error" "$GSAT_LOG" | grep -vc "^$" || true)
GSAT_MESSAGES=$(tail -20 "$GSAT_LOG" | head -1)
GSAT_SUMMARY=$(grep -i "summary\|result\|pass\|fail" "$GSAT_LOG" | tail -1 || echo "No summary available")

if [ "$GSAT_EXIT" -eq 0 ]; then
    GSAT_STATUS="PASS"
    GSAT_REAL_ERRORS=0
else
    GSAT_STATUS="FAIL"
    GSAT_REAL_ERRORS=$(grep -oP '\d+ error' "$GSAT_LOG" | head -1 | grep -oP '\d+' || echo "Unknown")
    if [ "$GSAT_REAL_ERRORS" = "Unknown" ]; then
        GSAT_REAL_ERRORS=-1
    fi
fi

log_info "GSAT Exit Code: $GSAT_EXIT | Status: $GSAT_STATUS | Errors: $GSAT_REAL_ERRORS"
log_info "GSAT Summary: $GSAT_SUMMARY"

############################################################
# 8. 采集测试后的 EDAC 状态
############################################################
FINAL_CE_COUNT=$INITIAL_CE_COUNT
FINAL_UE_COUNT=$INITIAL_UE_COUNT
CE_DELTA=0
UE_DELTA=0
FAILED_CHANNELS=""
EDAC_ERROR_DETAILS=""

if [ "$EDAC_AVAILABLE" -eq 1 ]; then
    log_info "Analyzing EDAC results..."
    
    dmesg | grep -iE "ECC|EDAC" | grep -v "Corrected" > "$EDAC_POST_LOG" 2>/dev/null || true
    
    if edac-util -v &>/dev/null; then
        FINAL_CE_COUNT=$(edac-util -v 2>/dev/null | grep "CE: " | awk '{sum+=$NF} END {print sum+0}')
        FINAL_UE_COUNT=$(edac-util -v 2>/dev/null | grep "UE: " | awk '{sum+=$NF} END {print sum+0}')
    fi
    
    CE_DELTA=$((FINAL_CE_COUNT - INITIAL_CE_COUNT))
    UE_DELTA=$((FINAL_UE_COUNT - INITIAL_UE_COUNT))
    
    log_info "Final EDAC counters: CE=$FINAL_CE_COUNT (delta: $CE_DELTA), UE=$FINAL_UE_COUNT (delta: $UE_DELTA)"
    
    EDAC_ERROR_DETAILS=$(diff "$EDAC_PRE_LOG" "$EDAC_POST_LOG" 2>/dev/null | grep '^>' | sed 's/^> //' || true)
    
    if [ -n "$EDAC_ERROR_DETAILS" ]; then
        FAILED_CHANNELS=$(echo "$EDAC_ERROR_DETAILS" | grep -oE "mc[0-9]+[[:space:]]+ch[0-9]+" | sort -u | tr '\n' ',' | sed 's/,$//')
        log_info "Failed channels detected: $FAILED_CHANNELS"
    fi
fi

############################################################
# 9. 最终判定
############################################################
if [ "$GSAT_EXIT" -ne 0 ] || [ "$GSAT_REAL_ERRORS" -gt 0 ] 2>/dev/null || [ "$UE_DELTA" -gt 0 ]; then
    FINAL_STATUS="FAIL"
elif [ "$CE_DELTA" -gt 10 ] || [ "$HW_DROP_DETECTED" -eq 1 ]; then
    FINAL_STATUS="WARNING"
else
    FINAL_STATUS="PASS"
fi

log_info "Final verdict: $FINAL_STATUS"

############################################################
# 10. 映射故障通道到物理 DIMM
############################################################
FAILED_DIMMS=""

if [ -n "$FAILED_CHANNELS" ]; then
    log_info "Mapping failed channels to physical DIMMs..."
    
    FAILED_DIMMS=$(echo "$FAILED_CHANNELS" | tr ',' '\n' | while read channel; do
        mc=$(echo "$channel" | grep -oE 'mc[0-9]+' | grep -oE '[0-9]+')
        ch=$(echo "$channel" | grep -oE 'ch[0-9]+' | grep -oE '[0-9]+')
        echo "DIMM_${mc}_${ch}"
    done | tr '\n' ',' | sed 's/,$//')
    
    log_info "Failed DIMMs: $FAILED_DIMMS"
fi

############################################################
# 11. 构造优化的 JSON 结构（包含 Bank Locator）
############################################################
log_info "Step 3: Packaging report..."
IP_ADDR=$(hostname -I | awk '{print $1}')
HOSTNAME_VAL="$IP_ADDR"

if [ -s "$MEM_DETAIL_LOG" ]; then
    SLOTS_JSON=$(awk -F'|' '{
        printf "{\"slot\": \"%s\", \"bank_locator\": \"%s\", \"size\": \"%s\", \"type\": \"%s\", \"speed\": \"%s\", \"manufacturer\": \"%s\"}\n", $1, $2, $3, $4, $5, $6
    }' "$MEM_DETAIL_LOG" | jq -s '.')
else
    SLOTS_JSON="[]"
fi

GSAT_DETAILS=$(cat <<EOF
{
  "test_time_seconds": $TEST_TIME,
  "memory_tested_mb": $TEST_MB,
  "cores_used": $TOTAL_CORES,
  "exit_code": $GSAT_EXIT,
  "status": "$GSAT_STATUS",
  "errors_found": $GSAT_REAL_ERRORS,
  "summary": "$GSAT_SUMMARY"
}
EOF
)

FAILED_CHANNELS_JSON=$(echo "$FAILED_CHANNELS" | jq -Rn 'input | split(",") | map(select(length > 0))' 2>/dev/null || echo "[]")
FAILED_DIMMS_JSON=$(echo "$FAILED_DIMMS" | jq -Rn 'input | split(",") | map(select(length > 0))' 2>/dev/null || echo "[]")

jq -n \
    --arg hostname "$HOSTNAME_VAL" \
    --arg ip       "$IP_ADDR" \
    --arg verdict  "$FINAL_STATUS" \
    --arg ts       "$(date '+%Y-%m-%d %H:%M:%S')" \
    --argjson gsat_errors  "$GSAT_REAL_ERRORS" \
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
    --argjson memory_stats "{\"total_slots\": $TOTAL_SLOTS, \"installed_slots\": $INSTALLED_SLOTS, \"empty_slots\": $EMPTY_SLOTS}" \
    --argjson gsat_details "$GSAT_DETAILS" \
    '{
        hostname:       $hostname,
        ip:             $ip,
        verdict:        $verdict,
        timestamp:      $ts,
        errors: {
            gsat: $gsat_errors
        },
        metrics: {
            test_time:      $test_time,
            mem_tested_mb:  $mem_mb,
            cores_used:     ('$TOTAL_CORES')
        },
        gsat_results:   $gsat_details,
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
        memory_stats:   $memory_stats,
        memory_slots:   $slots
    }' > "$JSON_FILE"

log_info "Report saved to $JSON_FILE"

############################################################
# 12. 上传
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
# 13. 结果展示
############################################################
echo ""
echo "############################################################"
case "$FINAL_STATUS" in
    PASS)    echo -e "        TEST VERDICT: ${RES_GREEN}${RES_BOLD}PASS${RES_NONE}" ;;
    WARNING) echo -e "        TEST VERDICT: ${RES_YELLOW}${RES_BOLD}WARNING${RES_NONE}" ;;
    FAIL)    echo -e "        TEST VERDICT: ${RES_RED}${RES_BOLD}FAIL${RES_NONE}" ;;
esac
echo "############################################################"
printf "  %-20s %s\n" "HOSTNAME(IP):" "$IP_ADDR"
printf "  %-20s %s\n" "GSAT STATUS:" "$GSAT_STATUS"
printf "  %-20s %s\n" "GSAT ERRORS:" "$GSAT_REAL_ERRORS"
printf "  %-20s %s\n" "GSAT SUMMARY:" "$GSAT_SUMMARY"
printf "  %-20s %s\n" "TEST DURATION:" "${TEST_TIME}s"
printf "  %-20s %s\n" "MEMORY TESTED:" "${TEST_MB}MB"
printf "  %-20s %s\n" "CORES USED:" "$TOTAL_CORES"
printf "  %-20s %s\n" "TOTAL MEM SLOTS:" "$TOTAL_SLOTS"
printf "  %-20s %s\n" "INSTALLED SLOTS:" "$INSTALLED_SLOTS"
printf "  %-20s %s\n" "EMPTY SLOTS:" "$EMPTY_SLOTS"

if [ "$EDAC_AVAILABLE" -eq 1 ]; then
    printf "  %-20s CE: $FINAL_CE_COUNT (+$CE_DELTA) | UE: $FINAL_UE_COUNT (+$UE_DELTA)\n" "EDAC ERRORS:"
    if [ -n "$FAILED_CHANNELS" ]; then
        printf "  %-20s %s\n" "FAILED CHANNELS:" "$FAILED_CHANNELS"
        printf "  %-20s %s\n" "FAILED DIMMs:" "$FAILED_DIMMS"
    fi
fi

printf "  %-20s %s\n" "UPLOAD:" "$( [ "$UPLOAD_OK" -eq 1 ] && echo "OK" || echo "FAILED" )"
printf "  %-20s %s\n" "LOG DIR:" "$LOG_DIR"
echo "############################################################"

############################################################
# 14. 自动关机
############################################################
if [ "$AUTO_POWEROFF" -eq 1 ]; then
    case "$FINAL_STATUS" in

        FAIL)
            echo "======================================"
            echo " MEMORY TEST FAILED - DO NOT POWER OFF"
            echo " Waiting for technician inspection..."
            echo "======================================"

            touch /var/log/memtest_fail.flag

            # 无限等待，不占CPU
            while true; do
                sleep 300
            done
            ;;

        WARNING)
            echo "WARNING detected. Powering off in 30 seconds..."
            sleep 30
            poweroff
            ;;

        PASS)
            echo "PASS. Powering off in 10 seconds..."
            sleep 10
            poweroff
            ;;

    esac

	else
		if [ "$AUTO_MODE" -eq 1 ]; then
			log_info "Auto mode: exiting without poweroff."
		else
			echo ""
			echo -e "[DONE] Press any key to exit (auto-exit in 60s)..."
			read -t 60 -n 1 -s || true
		fi
fi

if [ "$FINAL_STATUS" = "FAIL" ]; then
    safe_exit 1
elif [ "$UPLOAD_OK" -eq 0 ]; then
    safe_exit 4
else
    safe_exit 0
fi
