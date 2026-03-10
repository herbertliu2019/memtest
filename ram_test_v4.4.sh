#!/bin/bash
############################################################
# Industrial RAM Test Script - v4.4 (dmesg ECC Edition)
#
# 修改说明（基于 v4.2）：
#   🔴 移除对 edac-util 的 ECC 计数依赖（edac-util 在
#      MCE HANDLING 模式 + 计数器溢出时读数为0，不可靠）
#   🔴 改用 dmesg -C 清空日志缓冲区作为测试起点
#   🔴 直接解析 dmesg MCE/EDAC 原始日志捕获 CE/UE 错误
#   🟡 从 CPU_SrcID#N_Ha#N_Chan#N_DIMM#N 精确提取槽位
#   🟡 交叉比对 dmidecode 将 EDAC 位置映射到物理标签
#   🟡 JSON 报告新增 ecc_events[] 数组，每条错误独立记录
#   🟡 新增 RAS soft-offline 页面检测
############################################################

# --- 1. 配置区 ---
TEST_TIME=900                                           # 压力测试时长（秒）
LOG_DIR="/root/test_logs"                               # 日志路径
UPLOAD_URL="http://192.168.30.18:8080/mem/api/upload"  # 中控服务器IP
UPLOAD_TOKEN=""                                         # 可选：Bearer Token
AUTO_MODE=1                                             # 1=无人值守, 0=交互模式
AUTO_POWEROFF=0                                         # 1=自动关机, 0=保留现场

mkdir -p "$LOG_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
GSAT_LOG="$LOG_DIR/gsat_${TIMESTAMP}.log"
MEM_DETAIL_LOG="$LOG_DIR/mem_detail_${TIMESTAMP}.log"
DMESG_ECC_LOG="$LOG_DIR/dmesg_ecc_${TIMESTAMP}.log"   # 测试期间捕获的ECC原始日志
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
echo -e "${RES_BOLD}>>> Industrial RAM Test Pipeline v4.4 (dmesg ECC Edition) Starting...${RES_NONE}"
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

# edac-util 完全不再用于ECC错误检测，仅做提示
if ! command -v edac-util &>/dev/null; then
    log_info "edac-util not found (not required - ECC detection uses dmesg directly)."
fi

if [ "$MISSING_DEPS" -eq 1 ]; then
    log_error "Please install missing dependencies before running."
    log_error "  Ubuntu/Debian: apt-get install -y dmidecode stressapptest curl jq"
    safe_exit 2
fi
log_info "All dependencies OK."

############################################################
# 3. EDAC 驱动初始化
#    目的：确保内核 EDAC 驱动已加载，这样 MCE 错误才会
#    出现在 dmesg 中。我们不依赖 edac-util 读数，
#    但需要内核驱动把错误写入日志。
############################################################
log_info "Step 0.5: Initializing EDAC kernel drivers..."

if ! lsmod | grep -q edac_core; then
    modprobe edac_core 2>/dev/null || log_warn "Could not load edac_core"
fi

# 按平台尝试加载对应EDAC驱动（Intel Sandy/Ivy/Haswell Bridge等）
for driver in sb_edac sbridge_edac skx_edac i7core_edac ie31200_edac edac_mce_amd ghes_edac; do
    if modinfo "$driver" &>/dev/null 2>&1; then
        if ! lsmod | grep -q "$driver"; then
            modprobe "$driver" 2>/dev/null || true
        fi
    fi
done

LOADED_EDAC=$(lsmod | grep -iE 'edac|sbridge|skx_edac' | awk '{print $1}' | tr '\n' ' ')
log_info "EDAC drivers active: ${LOADED_EDAC:-none}"

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
# 5. 清空 dmesg 缓冲区作为测试起点
#    遵循 Gemini 建议：dmesg -C 清除旧日志，确保测试后
#    dmesg 中捕获到的全部是本次测试产生的新错误。
############################################################
log_info "Clearing dmesg buffer (test baseline)..."
dmesg -C 2>/dev/null || {
    log_warn "dmesg -C failed (需要 root). 改用行数快照作为基准。"
    DMESG_BASELINE=$(dmesg | wc -l)
}
log_info "dmesg buffer cleared. Test starting from clean slate."

############################################################
# 辅助函数：解析 dmesg ECC 日志，输出结构化错误记录
#
# 解析目标行示例：
#   EDAC MC1: 178 CE memory read error on
#     CPU_SrcID#0_Ha#0_Chan#0_DIMM#0
#     (channel:0 slot:0 page:0x4eb97f offset:0x5c0 grain:32
#      syndrome:0x0 - OVERFLOW area:DRAM err_code:0001:0090
#      socket:0 ha:0 channel_mask:1 rank:1
#      row:0x8af7 col:0x3a8 bank_addr:2 bank_group:3)
#
# 输出格式（每行一条错误）：
#   error_type|mc|ce_count|socket|ha|chan|dimm|page|overflow|raw_slot_label
############################################################
parse_dmesg_ecc() {
    local input="$1"
    echo "$input" | grep -E "EDAC MC[0-9]+: [0-9]+ [CU]E .*error" | \
    awk '
    {
        line = $0

        # 提取 MC 编号
        mc = "?"
        if (match(line, /EDAC MC([0-9]+):/, a)) mc = a[1]
        else if (match(line, /MC([0-9]+)/, a)) mc = a[1]

        # 提取 CE 或 UE 数量和类型
        err_type = "CE"; err_count = "0"
        if (match(line, /([0-9]+) CE/, a)) { err_type="CE"; err_count=a[1] }
        else if (match(line, /([0-9]+) UE/, a)) { err_type="UE"; err_count=a[1] }

        # 从 CPU_SrcID#N_Ha#N_Chan#N_DIMM#N 提取（最精确）
        src_id="?"; ha="?"; chan="?"; dimm="?"
        if (match(line, /SrcID#([0-9]+)/, a)) src_id=a[1]
        if (match(line, /Ha#([0-9]+)/, a))    ha=a[1]
        if (match(line, /Chan#([0-9]+)/, a))  chan=a[1]
        if (match(line, /DIMM#([0-9]+)/, a))  dimm=a[1]

        # 从括号内字段提取（备用）
        socket="?"; page="?"; offset="?"
        if (match(line, /socket:([0-9]+)/, a))  socket=a[1]
        if (match(line, /channel:([0-9]+)/, a) && chan=="?") chan=a[1]
        if (match(line, /slot:([0-9]+)/, a)    && dimm=="?") dimm=a[1]
        if (match(line, /page:(0x[0-9a-f]+)/, a)) page=a[1]
        if (match(line, /offset:(0x[0-9a-f]+)/, a)) offset=a[1]

        # 使用 src_id 作为 socket（SrcID 就是 socket 编号）
        if (src_id != "?") socket=src_id

        # 检测 OVERFLOW 标志
        overflow = (line ~ /OVERFLOW/) ? "YES" : "NO"

        # 提取 EDAC 原始槽位标签（CPU_SrcID#... 整段）
        raw_label = "?"
        if (match(line, /CPU_[^(]+/, a)) {
            raw_label = a[0]
            gsub(/[[:space:]]+$/, "", raw_label)
        }

        printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n",
            err_type, mc, err_count, socket, ha, chan, dimm,
            page, offset, overflow, raw_label
    }'
}

############################################################
# 辅助函数：将 EDAC (socket,mc,chan,dimm) 映射到物理槽位标签
#
# 优先级：
#   1. /sys/devices/system/edac/mc/mcN/csrowX/chY_dimm_label
#   2. /sys/devices/system/edac/mc/mcN/dimmN/dimm_label
#   3. 估算 dmidecode 行号并读取物理 Locator
############################################################
edac_to_physical_slot() {
    local socket="$1" mc="$2" chan="$3" dimm="$4"
    local mem_log="$5"

    # 方法1：从 csrow sysfs 读取 DIMM label（最准确）
    local label=""
    for csrow_dir in /sys/devices/system/edac/mc/mc${mc}/csrow*/; do
        local lf="${csrow_dir}ch${chan}_dimm_label"
        if [ -f "$lf" ]; then
            label=$(cat "$lf" 2>/dev/null | tr -d '\n')
            [ -n "$label" ] && { echo "$label"; return; }
        fi
    done

    # 方法2：新式 dimm sysfs 路径
    local dimm_sysfs="/sys/devices/system/edac/mc/mc${mc}/dimm${dimm}/dimm_label"
    if [ -f "$dimm_sysfs" ]; then
        label=$(cat "$dimm_sysfs" 2>/dev/null | tr -d '\n')
        [ -n "$label" ] && { echo "$label"; return; }
    fi

    # 方法3：根据 socket/mc/chan/dimm 估算 dmidecode 行号
    # Intel Dual-socket, 2 MC per socket, 4 chan per MC, 1-2 DIMM per chan
    local idx=$(( socket * 16 + mc * 4 + chan * 2 + dimm + 1 ))
    if [ -s "$mem_log" ]; then
        local row
        row=$(sed -n "${idx}p" "$mem_log" 2>/dev/null)
        if [ -n "$row" ]; then
            local sl bk
            sl=$(echo "$row" | cut -d'|' -f1)
            bk=$(echo "$row" | cut -d'|' -f2)
            echo "${sl} (${bk}) [estimated]"
            return
        fi
    fi

    echo "UNKNOWN (socket=${socket} mc=${mc} chan=${chan} dimm=${dimm})"
}

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

stressapptest -M "${TEST_MB}" -s "${TEST_TIME}" -W -m 64 -i 16 --stop_on_errors  > "$GSAT_LOG" 2>&1
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
# 8. 测试后：直接从 dmesg 解析 ECC 错误
#    完全不依赖 edac-util，直接读取内核原始日志
############################################################
CE_DELTA=0
UE_DELTA=0
FAILED_CHANNELS=""
ECC_EVENTS_JSON="[]"
SOFT_OFFLINE_PAGES=""

log_info "Analyzing post-test dmesg for ECC/MCE errors..."

# 获取测试期间的全部 dmesg（dmesg -C 已清空旧日志，所以全部都是新的）
DMESG_NOW=$(dmesg 2>/dev/null)

# 如果 dmesg -C 之前失败了，只取新增行
if [ -n "${DMESG_BASELINE:-}" ]; then
    DMESG_NOW=$(dmesg | tail -n +"$((DMESG_BASELINE + 1))")
fi

# 保存原始 ECC 日志供事后检查
echo "$DMESG_NOW" | grep -E "EDAC|MCE|RAS" > "$DMESG_ECC_LOG" 2>/dev/null || true

# --- 检测 RAS soft-offline（页面被隔离，说明错误严重）---
SOFT_OFFLINE_PAGES=$(echo "$DMESG_NOW" | grep "RAS: Soft-offlining pfn" \
    | grep -oE "pfn: 0x[0-9a-f]+" | tr '\n' ' ' || true)
if [ -n "$SOFT_OFFLINE_PAGES" ]; then
    log_error "⚠️  RAS soft-offline detected! Pages isolated: $SOFT_OFFLINE_PAGES"
    log_error "   This means errors were so frequent the kernel quarantined memory pages."
fi

# --- 主解析：提取所有 CE/UE 错误行 ---
RAW_ECC_LINES=$(echo "$DMESG_NOW" | grep -E "EDAC MC[0-9]+: [0-9]+ [CU]E .*error")

if [ -z "$RAW_ECC_LINES" ]; then
    log_info "No ECC errors found in dmesg during test."
else
    log_error "⚠️  ECC errors detected in dmesg!"
    # 去重（同一错误会被多个 CPU 报告，地址相同即为同一次）
    UNIQUE_ECC=$(echo "$RAW_ECC_LINES" | sort -u)

    # 逐行解析，构建结构化数据
    ECC_EVENTS_JSON="["
    FIRST_EVENT=1

    while IFS='|' read -r err_type mc ce_count socket ha chan dimm page offset overflow raw_label; do
        [ -z "$err_type" ] && continue

        # 累计计数
        if [ "$err_type" = "CE" ] && [[ "$ce_count" =~ ^[0-9]+$ ]]; then
            CE_DELTA=$((CE_DELTA + ce_count))
        elif [ "$err_type" = "UE" ] && [[ "$ce_count" =~ ^[0-9]+$ ]]; then
            UE_DELTA=$((UE_DELTA + ce_count))
        fi

        # 映射到物理槽位
        PHYS_SLOT=$(edac_to_physical_slot "$socket" "$mc" "$chan" "$dimm" "$MEM_DETAIL_LOG")

        # 记录到 FAILED_CHANNELS（格式：MC1_Ch0）
        CHAN_KEY="MC${mc}_Ch${chan}"
        if ! echo "$FAILED_CHANNELS" | grep -q "$CHAN_KEY"; then
            FAILED_CHANNELS="${FAILED_CHANNELS}${CHAN_KEY},"
        fi

        # 控制台输出
        log_error "  ● ${err_type} Error | MC=${mc} Socket=${socket} Ha=${ha} Chan=${chan} DIMM=${dimm}"
        log_error "    Count: ${ce_count}$([ "$overflow" = "YES" ] && echo ' ⚠️  OVERFLOW (actual count >> reported)')"
        log_error "    Addr:  page=${page} offset=${offset}"
        log_error "    EDAC:  ${raw_label}"
        log_error "    Slot:  ${PHYS_SLOT}"

        # 追加到 JSON 数组
        [ "$FIRST_EVENT" -eq 1 ] && FIRST_EVENT=0 || ECC_EVENTS_JSON="${ECC_EVENTS_JSON},"
        PHYS_SAFE=$(echo "$PHYS_SLOT" | sed 's/"/\\"/g')
        RAW_SAFE=$(echo "$raw_label" | sed 's/"/\\"/g')
        ECC_EVENTS_JSON="${ECC_EVENTS_JSON}
        {
            \"error_type\": \"${err_type}\",
            \"mc\": ${mc:-0},
            \"socket\": \"${socket}\",
            \"ha\": \"${ha}\",
            \"channel\": \"${chan}\",
            \"dimm\": \"${dimm}\",
            \"count\": ${ce_count:-0},
            \"overflow\": $([ "$overflow" = "YES" ] && echo 'true' || echo 'false'),
            \"phys_address_page\": \"${page}\",
            \"phys_address_offset\": \"${offset}\",
            \"edac_label\": \"${RAW_SAFE}\",
            \"physical_slot\": \"${PHYS_SAFE}\"
        }"

    done < <(parse_dmesg_ecc "$UNIQUE_ECC")

    ECC_EVENTS_JSON="${ECC_EVENTS_JSON}
    ]"

    FAILED_CHANNELS="${FAILED_CHANNELS%,}"   # 去尾部逗号
    log_error "Total CE delta: $CE_DELTA | UE delta: $UE_DELTA"
    log_error "Failed channels: $FAILED_CHANNELS"
fi

############################################################
# 9. 最终判定
#    UE > 0          → FAIL  (不可纠错，数据已损坏)
#    GSAT fail       → FAIL
#    CE > 0          → WARNING (可纠错，但内存需更换)
#    soft-offline    → WARNING (内核主动隔离内存页)
#    HW slot missing → WARNING
############################################################
if [ "$GSAT_EXIT" -ne 0 ] || \
   { [[ "$GSAT_REAL_ERRORS" =~ ^[0-9]+$ ]] && [ "$GSAT_REAL_ERRORS" -gt 0 ]; } || \
   [ "$UE_DELTA" -gt 0 ]; then
    FINAL_STATUS="FAIL"
elif [ "$CE_DELTA" -gt 0 ] || [ -n "$SOFT_OFFLINE_PAGES" ] || [ "$HW_DROP_DETECTED" -eq 1 ]; then
    FINAL_STATUS="WARNING"
else
    FINAL_STATUS="PASS"
fi

log_info "Final verdict: $FINAL_STATUS"

############################################################
# 10. 映射故障通道到物理 DIMM（从已解析数据汇总）
############################################################
FAILED_DIMMS=""
if [ -n "$FAILED_CHANNELS" ]; then
    log_info "Failed channel → physical DIMM summary:"
    # 从 ECC_EVENTS_JSON 中已包含物理映射，这里做终端摘要
    while IFS=',' read -ra ch_arr; do
        for ch_entry in "${ch_arr[@]}"; do
            [ -z "$ch_entry" ] && continue
            log_info "  $ch_entry → see ecc_events in JSON for physical slot"
            FAILED_DIMMS="${FAILED_DIMMS}${ch_entry},"
        done
    done <<< "$FAILED_CHANNELS"
    FAILED_DIMMS="${FAILED_DIMMS%,}"
fi

############################################################
# 11. 构造 JSON 报告（新增 ecc_events[] 每条错误独立记录）
############################################################
log_info "Step 3: Packaging report..."
IP_ADDR=$(hostname -I | awk '{print $1}')
HOSTNAME_VAL="$IP_ADDR"

if [ -s "$MEM_DETAIL_LOG" ]; then
    SLOTS_JSON=$(awk -F'|' '{
        printf "{\"slot\": \"%s\", \"bank_locator\": \"%s\", \"size\": \"%s\", \"type\": \"%s\", \"speed\": \"%s\", \"manufacturer\": \"%s\"}\n",
        $1, $2, $3, $4, $5, $6
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

# 软隔离页面转 JSON 数组
SOFT_OFFLINE_JSON=$(echo "$SOFT_OFFLINE_PAGES" | tr ' ' '\n' | grep -v '^$' | \
    jq -Rn '[inputs]' 2>/dev/null || echo "[]")

# 验证 ECC_EVENTS_JSON 是合法 JSON，否则回退为空数组
if ! echo "$ECC_EVENTS_JSON" | jq '.' >/dev/null 2>&1; then
    log_warn "ECC events JSON malformed, resetting to empty array."
    ECC_EVENTS_JSON="[]"
fi

jq -n \
    --arg  hostname        "$HOSTNAME_VAL" \
    --arg  ip              "$IP_ADDR" \
    --arg  verdict         "$FINAL_STATUS" \
    --arg  ts              "$(date '+%Y-%m-%d %H:%M:%S')" \
    --argjson gsat_errors  "${GSAT_REAL_ERRORS:-0}" \
    --argjson test_time    "$TEST_TIME" \
    --argjson mem_mb       "$TEST_MB" \
    --argjson slots        "$SLOTS_JSON" \
    --argjson ce_delta     "$CE_DELTA" \
    --argjson ue_delta     "$UE_DELTA" \
    --argjson failed_channels "$FAILED_CHANNELS_JSON" \
    --argjson failed_dimms    "$FAILED_DIMMS_JSON" \
    --argjson ecc_events      "$ECC_EVENTS_JSON" \
    --argjson soft_offline    "$SOFT_OFFLINE_JSON" \
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
        ecc_summary: {
            ce_total:         $ce_delta,
            ue_total:         $ue_delta,
            failed_channels:  $failed_channels,
            failed_dimms:     $failed_dimms,
            soft_offline_pfn: $soft_offline,
            detection_source: "dmesg (kernel EDAC/MCE log)",
            edac_util_used:   false
        },
        ecc_events:     $ecc_events,
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
    PASS)    echo -e "        TEST VERDICT: ${RES_GREEN}${RES_BOLD}✅  PASS${RES_NONE}" ;;
    WARNING) echo -e "        TEST VERDICT: ${RES_YELLOW}${RES_BOLD}⚠️   WARNING${RES_NONE}" ;;
    FAIL)    echo -e "        TEST VERDICT: ${RES_RED}${RES_BOLD}❌  FAIL${RES_NONE}" ;;
esac
echo "############################################################"
printf "  %-22s %s\n" "HOSTNAME(IP):"    "$IP_ADDR"
printf "  %-22s %s\n" "GSAT STATUS:"     "$GSAT_STATUS"
printf "  %-22s %s\n" "GSAT ERRORS:"     "$GSAT_REAL_ERRORS"
printf "  %-22s %s\n" "GSAT SUMMARY:"    "$GSAT_SUMMARY"
printf "  %-22s %s\n" "TEST DURATION:"   "${TEST_TIME}s"
printf "  %-22s %s\n" "MEMORY TESTED:"   "${TEST_MB}MB"
printf "  %-22s %s\n" "CORES USED:"      "$TOTAL_CORES"
printf "  %-22s %s\n" "TOTAL MEM SLOTS:" "$TOTAL_SLOTS"
printf "  %-22s %s\n" "INSTALLED SLOTS:" "$INSTALLED_SLOTS"
printf "  %-22s %s\n" "EMPTY SLOTS:"     "$EMPTY_SLOTS"

# ECC 结果（来自 dmesg 直接解析）
echo "  ──────────────────────────────────────────────────────"
printf "  %-22s %s\n" "ECC SOURCE:"      "dmesg (kernel EDAC/MCE log)"
printf "  %-22s CE: %s  |  UE: %s\n"    "ECC ERRORS:" "$CE_DELTA" "$UE_DELTA"
if [ -n "$SOFT_OFFLINE_PAGES" ]; then
    printf "  %-22s %s\n" "SOFT-OFFLINE PFN:" "$SOFT_OFFLINE_PAGES"
fi
if [ -n "$FAILED_CHANNELS" ]; then
    printf "  %-22s %s\n" "FAILED CHANNELS:" "$FAILED_CHANNELS"
    printf "  %-22s %s\n" "FAILED DIMMs:"    "$FAILED_DIMMS"
    echo "  ECC Event Detail:"
    # 从 JSON 中提取每个 event 的物理槽位打印
    if command -v jq &>/dev/null && [ -f "$JSON_FILE" ]; then
        jq -r '.ecc_events[] | "    ● \(.error_type) MC\(.mc) Chan\(.channel) DIMM\(.dimm) | count=\(.count)\(.overflow | if . then " OVERFLOW" else "" end) | slot=\(.physical_slot)"' \
            "$JSON_FILE" 2>/dev/null | sort -u || true
    fi
fi
echo "  ──────────────────────────────────────────────────────"

printf "  %-22s %s\n" "UPLOAD:"   "$( [ "$UPLOAD_OK" -eq 1 ] && echo "OK" || echo "FAILED" )"
printf "  %-22s %s\n" "JSON:"     "$JSON_FILE"
printf "  %-22s %s\n" "ECC LOG:"  "$DMESG_ECC_LOG"
printf "  %-22s %s\n" "LOG DIR:"  "$LOG_DIR"
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
