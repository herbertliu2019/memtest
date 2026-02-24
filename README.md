# 专业内存故障定位系统 - 完整实施指南

## 概述

这是一套**生产级别的内存故障定位系统**，采用"锤子+显微镜"的专业方法：

- **锤子（Stress）:** `stressapptest` - 产生内存故障
- **显微镜（Detection）:** `edac-util` - 定位故障位置
- **中枢（Control）:** Flask Web 服务器 - 集中管理和显示

---

## 工作原理

### 完整工作流程

```
测试客户端                           中控服务器
     ↓                               ↓
1. 启动 stressapptest              监听上传端口
   （压力测试）                     :5000
     ↓
2. 并行运行 edac-util
   （监控 ECC 错误）
     ↓
3. 采集数据
   - 压力测试结果
   - EDAC 错误计数
   - 故障内存条位置
     ↓
4. 生成 JSON 报告              ←→  接收数据
     ↓                         上传到服务器
5. 上传到服务器                     ↓
                              6. 保存数据
                                 处理分析
                                 ↓
                              7. 网页显示
                                 - 故障统计
                                 - DIMM 位置图
                                 - 详细错误日志
                                 - 建议处理
```

---

## 文件说明

### 1. **memtest_professional.sh** - 客户端脚本

**功能：**
- ✅ 加载 EDAC 驱动（自动处理）
- ✅ 运行 stressapptest 压力测试
- ✅ 实时监控 EDAC 错误
- ✅ 定位故障 DIMM 位置
- ✅ 生成专业报告
- ✅ 上传到中控服务器

**关键参数：**
```bash
STRESS_DURATION=600          # 测试时长 10 分钟
STRESS_MEMORY_PERCENT=90     # 测试 90% 的内存
EDAC_CHECK_INTERVAL=1        # 每秒检查一次错误
SERVER_IP=192.168.1.200      # 中控服务器 IP
SERVER_PORT=5000             # 中控服务器端口
```

**使用方法：**
```bash
# 基本使用
sudo bash memtest_professional.sh

# 指定服务器
sudo bash memtest_professional.sh 192.168.1.200 5000

# 后台运行
sudo bash memtest_professional.sh > test.log 2>&1 &
```

### 2. **app_v4_professional_memory_test.py** - 中控服务器

**功能：**
- 接收客户端上传的测试数据
- 存储历史数据（按日期分层）
- 显示故障内存位置图
- 详细错误分析报告
- 多标签页界面

**启动方法：**
```bash
# 安装依赖（如需要）
pip install flask

# 启动服务器
python3 app_v4_professional_memory_test.py

# 访问 Web 界面
http://localhost:5000
```

---

## 安装和准备

### 步骤 1：在测试客户端上安装工具

```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y stressapptest edac-utils dmidecode curl

# CentOS/RHEL
sudo yum install stressapptest edac-utils dmidecode curl
```

### 步骤 2：验证 EDAC 驱动是否可用

```bash
# 查看 EDAC 驱动
lsmod | grep edac

# 查看 ECC 信息
dmidecode -t memory | grep -i ecc

# 查看当前错误计数
edac-util -v
```

**如果 EDAC 驱动未加载：**
```bash
# 自动加载
sudo modprobe edac_core

# 对于 AMD 系统
sudo modprobe edac_mce_amd

# 对于 Intel 系统
sudo modprobe ie31200_edac

# 验证加载
lsmod | grep edac
```

### 步骤 3：部署中控服务器

```bash
# 创建工作目录
mkdir -p ~/pxe-server
cd ~/pxe-server

# 复制应用文件
cp app_v4_professional_memory_test.py .

# 创建数据目录
mkdir -p data/{history,latest}

# 启动服务器
python3 app_v4_professional_memory_test.py
```

### 步骤 4：部署客户端脚本

```bash
# 在测试客户端上
mkdir -p ~/memtest
cd ~/memtest

# 复制脚本
cp memtest_professional.sh .
chmod +x memtest_professional.sh

# 配置服务器 IP（编辑脚本或作为参数）
# 或者在脚本第一行修改 SERVER_IP
```

---

## 使用场景

### 场景 1：单机测试

```bash
# 在测试机器上
cd ~/memtest
sudo bash memtest_professional.sh 192.168.1.200 5000

# 输出示例
========================================
内存测试完成报告
==========================================
测试 ID: server-01_20240115_143000
测试时长: 603 秒

EDAC 错误统计：
  初始 CE: 0 → 最终 CE: 450 (增加: 450)
  初始 UE: 0 → 最终 UE: 5 (增加: 5)

故障通道列表:
  - mc0_ch1

故障 DIMM 列表:
  - DIMM_0_1

测试结果: FAIL
建议: 检测到不可纠正错误（UE），内存故障，需要立即更换
```

### 场景 2：批量测试多台服务器

```bash
# 编写脚本来批量运行
#!/bin/bash
for server in 192.168.1.100 192.168.1.101 192.168.1.102; do
    ssh root@$server "bash ~/memtest/memtest_professional.sh 192.168.1.200 5000 &"
done

# 然后在 Web 界面查看结果汇总
```

### 场景 3：长期监控

```bash
# 定期运行测试
0 2 * * 0 /root/memtest/memtest_professional.sh 192.168.1.200 5000 >> /var/log/memtest.log 2>&1
# 每周日凌晨 2 点运行测试

0 3 * * 0 curl -s http://localhost:5000/ > /tmp/memtest_report.html
# 保存报告
```

---

## 理解错误类型

### EDAC 错误

| 错误类型 | 符号 | 说明 | 严重程度 |
|---------|------|------|--------|
| **可纠正错误** | CE | 单比特翻转，被 ECC 自动修正，不影响数据 | 🟡 警告 |
| **不可纠正错误** | UE | 多比特翻转，无法修正，导致数据损坏 | 🔴 严重 |

### 判定规则

```
CE = 0, UE = 0  →  PASS  ✓ 内存健康
CE > 10, UE = 0  →  WARNING  ⚠️ 有轻微故障迹象
CE > 0, UE > 0  →  FAIL  ✗ 内存故障，需要更换
```

---

## 从 EDAC 输出找出物理内存条

### 例子 1：EDAC 输出

```
mc0 ch0: 0 CE, 0 UE
mc0 ch1: 450 CE, 5 UE  ← 这个通道有故障
```

### 映射到物理 DIMM

使用 `dmidecode` 查看映射：

```bash
sudo dmidecode -t memory | grep -A 2 "Locator"

# 输出示例
Locator: DIMM A1
Size: 16 GB

Locator: DIMM B1  ← 这对应 mc0_ch1
Size: 16 GB
```

### 完整映射规则

| EDAC 通道 | 常见 DIMM 位置 |
|----------|----------------|
| mc0_ch0 | DIMM A1, DIMM_0_0 |
| mc0_ch1 | DIMM B1, DIMM_0_1 |
| mc1_ch0 | DIMM A2, DIMM_1_0 |
| mc1_ch1 | DIMM B2, DIMM_1_1 |

**注意：** 具体映射因主板而异，需要用 `dmidecode` 验证

---

## 生成的报告格式

### JSON 结构

```json
{
  "test_metadata": {
    "hostname": "server-01",
    "timestamp": "2024-01-15T14:30:00+00:00",
    "test_id": "server-01_20240115_143000"
  },
  "system_info": {
    "cpu_count": 16,
    "cpu_model": "Intel(R) Xeon(R) CPU E5-2680 v4",
    "memory_total_bytes": 68719476736,
    "memory_available_bytes": 62914560000
  },
  "stress_test": {
    "duration_seconds": 600,
    "actual_duration_seconds": 603,
    "memory_percent": 90,
    "exit_code": 0,
    "status": "SUCCESS"
  },
  "edac_results": {
    "initial_ce_count": 0,
    "initial_ue_count": 0,
    "final_ce_count": 450,
    "final_ue_count": 5,
    "ce_delta": 450,
    "ue_delta": 5
  },
  "memory_errors": {
    "failed_channels": ["mc0_ch1"],
    "failed_dimms": ["DIMM_0_1"],
    "error_details": "mc0 ch1: 450 CE, 5 UE"
  },
  "verdict": "FAIL",
  "recommendation": "检测到不可纠正错误（UE），内存故障，需要立即更换"
}
```

---

## Web 界面功能

### 标签页 1：Overview

显示所有测试节点的汇总信息：
- IP 地址
- 测试结果（PASS/FAIL/WARNING）
- EDAC 错误计数（CE/UE）
- 故障 DIMM 数量
- 测试时间

### 标签页 2：Memory Map

物理内存位置可视化：
```
DIMM_0_0  DIMM_0_1  DIMM_0_2  DIMM_0_3
✓ Healthy ❌ Failed  ✓ Healthy ✓ Healthy

DIMM_1_0  DIMM_1_1  DIMM_1_2  DIMM_1_3
✓ Healthy ✓ Healthy ✓ Healthy ✓ Healthy
```

### 标签页 3：Errors Detail

详细的错误日志和建议：
- EDAC 原始输出
- 故障通道列表
- 详细统计表格
- 处理建议

---

## 常见问题排查

### Q1：`stressapptest` 找不到命令

**解决：**
```bash
sudo apt-get install stressapptest
which stressapptest
```

### Q2：`edac-util` 显示"EDAC is not loaded"

**解决：**
```bash
# 加载 EDAC 驱动
sudo modprobe edac_core

# 对于 AMD 系统
sudo modprobe edac_mce_amd

# 验证
lsmod | grep edac
edac-util -v
```

### Q3：脚本无法上传到服务器

**检查：**
```bash
# 1. 服务器是否运行
curl http://192.168.1.200:5000/

# 2. 防火墙是否开放
sudo ufw allow 5000/tcp

# 3. IP 地址是否正确
ping 192.168.1.200
```

### Q4：Web 界面无法显示 DIMM 位置

**原因：** DIMM 映射需要自定义

**解决：**
1. 运行 `sudo dmidecode -t memory` 查看实际映射
2. 编辑脚本中的 DIMM 映射逻辑
3. 或在 Web 界面中手动配置

### Q5：测试后立即关机（检测到 FAIL）

**正常行为。** 脚本在检测到严重故障（UE > 0）时会：
1. 显示警告（30 秒倒计时）
2. 自动关闭系统

**取消方法：**
```bash
# 在倒计时时按 Ctrl+C
# 或修改脚本移除自动关闭

# 取消自动关闭（注释最后几行）
# shutdown -h now
```

---

## 调优建议

### 1. 调整测试强度

```bash
# 更长的测试（2 小时）
stressapptest -s 7200 -M 95%

# 更短的快速测试（5 分钟）
stressapptest -s 300 -M 80%
```

### 2. 监控选项

```bash
# 在另一个终端实时监控
watch -n 1 "edac-util -v"

# 或使用 tail 监控日志
tail -f /tmp/memtest_logs/stressapptest_*.log
```

### 3. 服务器端优化

```python
# 编辑 app_v4_professional_memory_test.py
# 调整自动刷新频率
<meta http-equiv="refresh" content="30">  # 改为 60 秒

# 调整表格刷新
window.location.reload()  # 改为自动 AJAX 刷新
```

---

## 部署清单

### 在客户端

- [ ] 安装 stressapptest
- [ ] 安装 edac-utils
- [ ] 安装 dmidecode
- [ ] 安装 curl
- [ ] 复制 memtest_professional.sh
- [ ] 标记为可执行文件 (`chmod +x`)
- [ ] 配置服务器 IP 地址
- [ ] 测试能否连接到服务器

### 在中控服务器

- [ ] 安装 Python 3 和 Flask
- [ ] 创建工作目录和子目录
- [ ] 复制应用文件
- [ ] 创建 data/{history,latest} 目录
- [ ] 启动 Flask 应用
- [ ] 验证 Web 界面可访问
- [ ] 设置防火墙允许 5000 端口
- [ ] 配置日志和备份

---

## 总结

这套系统提供了：

✅ **专业的内存故障定位**
- 使用行业标准工具
- 高精度的故障识别
- 明确的 DIMM 位置定位

✅ **完整的管理界面**
- 汇总各服务器的测试结果
- 物理内存位置图
- 详细的错误日志

✅ **自动化的工作流程**
- 一键运行测试
- 自动上传数据
- 自动处理结果

✅ **生产级别的可靠性**
- 错误处理完善
- 日志记录详细
- 异常检测和通知

---

**现在你拥有了一套专业级别的内存故障定位系统！** 🚀
