from flask import Flask, request, jsonify, render_template_string
import os
import json
import glob
import datetime

app = Flask(__name__)

# 配置与目录初始化
BASE_DIR = os.path.abspath("data")
HISTORY_DIR = os.path.join(BASE_DIR, "history")
LATEST_DIR = os.path.join(BASE_DIR, "latest")

for path in [HISTORY_DIR, LATEST_DIR]:
    if not os.path.exists(path):
        os.makedirs(path)


def get_date_subdir(base_dir=HISTORY_DIR):
    """获取或创建当前日期的子目录"""
    now = datetime.datetime.now()
    year_dir = os.path.join(base_dir, now.strftime("%Y"))
    month_dir = os.path.join(year_dir, now.strftime("%Y-%m"))
    day_dir = os.path.join(month_dir, now.strftime("%Y-%m-%d"))
    os.makedirs(day_dir, exist_ok=True)
    return day_dir


# HTML 仪表盘模板 - 增强版（包含内存故障显示）
HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>RAM Screening Control Center</title>
    <meta http-equiv="refresh" content="30">
    <style>
        * { box-sizing: border-box; }
        body { 
            font-family: 'Segoe UI', Tahoma, sans-serif; 
            background: #1a1c2c; 
            color: #e0e0e0; 
            margin: 0; 
            padding: 20px; 
        }
        .container { max-width: 1800px; margin: 0 auto; }
        header { 
            display: flex; 
            justify-content: space-between; 
            align-items: center; 
            border-bottom: 2px solid #3d4465; 
            padding-bottom: 10px; 
            margin-bottom: 20px; 
        }
        h1 { margin: 0; color: #00d2ff; font-size: 24px; }
        .stats { font-size: 0.9em; color: #888da8; }
        
        /* 标签页切换 */
        .tabs {
            display: flex;
            gap: 10px;
            margin-bottom: 20px;
            border-bottom: 2px solid #3d4465;
            padding-bottom: 0;
        }
        .tab-button {
            padding: 12px 20px;
            background: transparent;
            border: none;
            color: #888da8;
            cursor: pointer;
            font-size: 1em;
            border-bottom: 3px solid transparent;
            transition: all 0.3s;
        }
        .tab-button.active {
            color: #00d2ff;
            border-bottom-color: #00d2ff;
        }
        .tab-button:hover {
            color: #00d2ff;
        }
        .tab-content {
            display: none;
        }
        .tab-content.active {
            display: block;
        }

        table { 
            width: 100%; 
            border-collapse: collapse; 
            background: #252839; 
            border-radius: 8px; 
            overflow: hidden; 
            box-shadow: 0 4px 15px rgba(0,0,0,0.3); 
            margin-bottom: 20px;
        }
        th { 
            background: #3d4465; 
            color: #fff; 
            text-align: left; 
            padding: 15px; 
            text-transform: uppercase; 
            font-size: 0.85em; 
        }
        td { 
            padding: 12px 15px; 
            border-bottom: 1px solid #3d4465; 
            font-size: 0.95em; 
        }
        tr:hover { background: #2d324a; }

        /* 状态标签 */
        .badge { 
            padding: 4px 10px; 
            border-radius: 4px; 
            font-weight: bold; 
            font-size: 0.85em; 
        }
        .PASS { background: #1e3a2a; color: #2ecc71; border: 1px solid #2ecc71; }
        .FAIL { background: #3a1e1e; color: #e74c3c; border: 1px solid #e74c3c; }
        .WARNING { background: #3a321e; color: #f1c40f; border: 1px solid #f1c40f; }

        /* 故障 DIMM 显示 */
        .memory-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
            gap: 10px;
            margin-bottom: 20px;
        }
        .dimm-card {
            padding: 15px;
            border-radius: 6px;
            background: #252839;
            border: 2px solid #3d4465;
            text-align: center;
            transition: all 0.3s;
        }
        .dimm-card.healthy {
            border-color: #2ecc71;
            background: rgba(46, 204, 113, 0.1);
        }
        .dimm-card.failed {
            border-color: #e74c3c;
            background: rgba(231, 76, 60, 0.1);
            box-shadow: 0 0 10px rgba(231, 76, 60, 0.5);
        }
        .dimm-card.warning {
            border-color: #f1c40f;
            background: rgba(241, 196, 15, 0.1);
        }
        .dimm-name {
            font-weight: bold;
            margin-bottom: 5px;
            font-size: 0.95em;
        }
        .dimm-status {
            font-size: 0.85em;
            padding: 5px 0;
        }
        .dimm-status.healthy { color: #2ecc71; }
        .dimm-status.failed { color: #e74c3c; }
        .dimm-status.warning { color: #f1c40f; }

        /* 错误详情 */
        .error-detail {
            background: #1a1c2c;
            border-left: 4px solid #e74c3c;
            padding: 12px;
            margin: 10px 0;
            border-radius: 3px;
            font-family: monospace;
            font-size: 0.85em;
            max-height: 200px;
            overflow-y: auto;
        }

        .error-num { font-weight: bold; }
        .has-error { color: #e74c3c; }
        .no-error { color: #888da8; }

        /* 拖动 tooltip */
        .tooltip-container {
            position: relative;
            display: inline-block;
            border-bottom: 1px dotted #888da8;
            cursor: pointer;
        }

        .tooltip-text {
            position: fixed;
            background-color: #1a1c2c;
            color: #e0e0e0;
            border-radius: 6px;
            padding: 12px;
            border: 1px solid #3d4465;
            box-shadow: 0 8px 16px rgba(0,0,0,0.5);
            font-size: 0.85em;
            opacity: 0;
            pointer-events: none;
            transition: opacity 0.15s ease;
            z-index: 9999;
            width: auto;
            min-width: 200px;
            max-width: 600px;
            max-height: 500px;
            overflow-y: auto;
            touch-action: none;
        }

        .tooltip-header {
            background: linear-gradient(135deg, #3d4465 0%, #2d3455 100%);
            padding: 8px 12px;
            border-bottom: 1px solid #00d2ff;
            border-radius: 6px 6px 0 0;
            cursor: move;
            display: flex;
            justify-content: space-between;
            align-items: center;
            user-select: none;
            margin: -12px -12px 8px -12px;
        }

        .tooltip-header h4 {
            margin: 0;
            color: #00d2ff;
            font-size: 0.95em;
            flex: 1;
        }

        .tooltip-close-btn {
            background: transparent;
            border: none;
            color: #e0e0e0;
            cursor: pointer;
            font-size: 1.2em;
            padding: 0;
            width: 24px;
            height: 24px;
            border-radius: 3px;
            transition: all 0.2s ease;
        }

        .tooltip-close-btn:hover {
            background: rgba(231, 76, 60, 0.2);
            color: #e74c3c;
        }

        .tooltip-content {
            padding: 0;
        }

        .tooltip-container.active .tooltip-text {
            opacity: 1;
            pointer-events: auto;
        }

        .tooltip-text.dragging {
            box-shadow: 0 12px 24px rgba(0, 210, 255, 0.3);
            border-color: #00d2ff;
        }

        .footer { 
            margin-top: 20px; 
            text-align: center; 
            font-size: 0.8em; 
            color: #5d6d7e; 
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>RAM SCREENING DASHBOARD</h1>
            <div class="stats">
                Last Update: {{ current_time }}<br>
                Total Active Nodes: {{ nodes|length }}
            </div>
        </header>

        <!-- 标签页 -->
        <div class="tabs">
            <button class="tab-button active" onclick="switchTab(event, 'overview')">Overview</button>
            <button class="tab-button" onclick="switchTab(event, 'memory-map')">Memory Map</button>
            <button class="tab-button" onclick="switchTab(event, 'errors')">Errors Detail</button>
        </div>

        <!-- Overview 标签页 -->
        <div id="overview" class="tab-content active">
            <table>
                <thead>
                    <tr>
                        <th>IP Address</th>
                        <th>Verdict</th>
                        <th>Stress Test</th>
                        <th>EDAC Errors</th>
                        <th>Failed DIMMs</th>
                        <th>Last Seen</th>
                    </tr>
                </thead>
                <tbody>
                    {% if not nodes %}
                    <tr>
                        <td colspan="6" style="text-align: center; padding: 40px; color: #5d6d7e;">No reports received yet. Waiting for nodes...</td>
                    </tr>
                    {% endif %}
                    {% for node in nodes %}
                    <tr>
                        <td><strong style="color: #00d2ff;">{{ node.ip }}</strong></td>
                        <td><span class="badge {{ node.verdict }}">{{ node.verdict }}</span></td>
                        
                        <!-- 压力测试状态 -->
                        <td>
                            {% if node.stress_test %}
                            <div class="tooltip-container">
                                {{ node.stress_test.status }}
                                <div class="tooltip-text">
                                    <div class="tooltip-header">
                                        <h4>Stress Test Details</h4>
                                        <button class="tooltip-close-btn" onclick="event.stopPropagation(); this.closest('.tooltip-container').classList.remove('active');">×</button>
                                    </div>
                                    <div class="tooltip-content">
                                        <p><strong>Duration:</strong> {{ node.stress_test.duration_seconds }}s</p>
                                        <p><strong>Memory:</strong> {{ node.stress_test.memory_percent }}%</p>
                                        <p><strong>Exit Code:</strong> {{ node.stress_test.exit_code }}</p>
                                    </div>
                                </div>
                            </div>
                            {% else %}
                                N/A
                            {% endif %}
                        </td>
                        
                        <!-- EDAC 错误 -->
                        <td class="error-num {% if node.edac_results and (node.edac_results.ce_delta > 0 or node.edac_results.ue_delta > 0) %}has-error{% else %}no-error{% endif %}">
                            {% if node.edac_results %}
                                CE: {{ node.edac_results.ce_delta }} / UE: {{ node.edac_results.ue_delta }}
                            {% else %}
                                N/A
                            {% endif %}
                        </td>
                        
                        <!-- 故障 DIMM -->
                        <td>
                            {% if node.memory_errors and node.memory_errors.failed_dimms|length > 0 %}
                            <div class="tooltip-container">
                                <span class="has-error">{{ node.memory_errors.failed_dimms|length }} Failed</span>
                                <div class="tooltip-text">
                                    <div class="tooltip-header">
                                        <h4>Failed DIMMs</h4>
                                        <button class="tooltip-close-btn" onclick="event.stopPropagation(); this.closest('.tooltip-container').classList.remove('active');">×</button>
                                    </div>
                                    <div class="tooltip-content">
                                        {% for dimm in node.memory_errors.failed_dimms %}
                                        <p style="color: #e74c3c;">{{ dimm }}</p>
                                        {% endfor %}
                                    </div>
                                </div>
                            </div>
                            {% else %}
                                <span class="no-error">✓ Healthy</span>
                            {% endif %}
                        </td>
                        
                        <td style="font-size: 0.85em; color: #888da8;">{{ node.timestamp }}</td>
                    </tr>
                    {% endfor %}
                </tbody>
            </table>
        </div>

        <!-- Memory Map 标签页 -->
        <div id="memory-map" class="tab-content">
            <h2 style="color: #00d2ff; margin-bottom: 20px;">Memory DIMM Status Map</h2>
            
            {% for node in nodes %}
            <div style="margin-bottom: 30px; border: 1px solid #3d4465; padding: 15px; border-radius: 6px;">
                <h3 style="color: #00d2ff; margin-top: 0;">{{ node.hostname or node.ip }}</h3>
                
                <div class="memory-grid">
                    {% set dimm_slots = ['DIMM_0_0', 'DIMM_0_1', 'DIMM_0_2', 'DIMM_0_3', 'DIMM_1_0', 'DIMM_1_1', 'DIMM_1_2', 'DIMM_1_3'] %}
                    {% for dimm_slot in dimm_slots %}
                    {% set failed = false %}
                    {% set status_class = 'healthy' %}
                    
                    {% if node.memory_errors and node.memory_errors.failed_dimms %}
                        {% if dimm_slot in node.memory_errors.failed_dimms %}
                            {% set failed = true %}
                            {% set status_class = 'failed' %}
                        {% endif %}
                    {% endif %}
                    
                    <div class="dimm-card {{ status_class }}">
                        <div class="dimm-name">{{ dimm_slot }}</div>
                        <div class="dimm-status {{ status_class }}">
                            {% if failed %}❌ Failed{% else %}✓ Healthy{% endif %}
                        </div>
                    </div>
                    {% endfor %}
                </div>
            </div>
            {% endfor %}
        </div>

        <!-- Errors Detail 标签页 -->
        <div id="errors" class="tab-content">
            <h2 style="color: #00d2ff; margin-bottom: 20px;">Detailed Error Report</h2>
            
            {% for node in nodes %}
            {% if node.memory_errors and node.memory_errors.error_details %}
            <div style="margin-bottom: 30px; border: 1px solid #3d4465; padding: 15px; border-radius: 6px;">
                <h3 style="color: #00d2ff; margin-top: 0;">{{ node.hostname or node.ip }}</h3>
                
                <p><strong>Verdict:</strong> <span class="badge {{ node.verdict }}">{{ node.verdict }}</span></p>
                <p><strong>Recommendation:</strong> {{ node.recommendation or 'N/A' }}</p>
                
                {% if node.memory_errors.failed_channels %}
                <h4 style="color: #f1c40f; margin-top: 15px;">Failed Channels:</h4>
                <div style="background: #1a1c2c; padding: 10px; border-radius: 3px; border-left: 4px solid #f1c40f;">
                    {% for channel in node.memory_errors.failed_channels %}
                    <p style="margin: 5px 0;">{{ channel }}</p>
                    {% endfor %}
                </div>
                {% endif %}
                
                <h4 style="color: #e74c3c; margin-top: 15px;">EDAC Error Details:</h4>
                <div class="error-detail">
                    {% if node.memory_errors.error_details %}
                    {{ node.memory_errors.error_details }}
                    {% else %}
                    No error details available
                    {% endif %}
                </div>
                
                {% if node.edac_results %}
                <h4 style="color: #00d2ff; margin-top: 15px;">EDAC Statistics:</h4>
                <table style="width: 100%; background: #1a1c2c;">
                    <tr>
                        <td><strong>Metric</strong></td>
                        <td><strong>Initial</strong></td>
                        <td><strong>Final</strong></td>
                        <td><strong>Delta</strong></td>
                    </tr>
                    <tr>
                        <td>CE (Correctable Errors)</td>
                        <td>{{ node.edac_results.initial_ce_count }}</td>
                        <td>{{ node.edac_results.final_ce_count }}</td>
                        <td class="{% if node.edac_results.ce_delta > 0 %}has-error{% endif %}">{{ node.edac_results.ce_delta }}</td>
                    </tr>
                    <tr>
                        <td>UE (Uncorrectable Errors)</td>
                        <td>{{ node.edac_results.initial_ue_count }}</td>
                        <td>{{ node.edac_results.final_ue_count }}</td>
                        <td class="{% if node.edac_results.ue_delta > 0 %}has-error{% endif %}">{{ node.edac_results.ue_delta }}</td>
                    </tr>
                </table>
                {% endif %}
            </div>
            {% endif %}
            {% endfor %}
        </div>

        <div class="footer">
            Storage: {{ history_path }} | Auto-Refresh: 30s | Version: v4 (Professional Memory Testing)
        </div>
    </div>

    <script>
    // 标签页切换
    function switchTab(event, tabName) {
        // 隐藏所有标签页
        const contents = document.querySelectorAll('.tab-content');
        contents.forEach(content => content.classList.remove('active'));
        
        // 移除所有标签按钮的 active 类
        const buttons = document.querySelectorAll('.tab-button');
        buttons.forEach(button => button.classList.remove('active'));
        
        // 显示选中的标签页
        document.getElementById(tabName).classList.add('active');
        event.target.classList.add('active');
    }

    // ==================== 拖动 tooltip ====================
    document.addEventListener("DOMContentLoaded", function () {
        const tooltips = document.querySelectorAll(".tooltip-container");
        let draggedElement = null;
        let offsetX = 0;
        let offsetY = 0;

        function makeDraggable(tooltipText) {
            const header = tooltipText.querySelector(".tooltip-header");
            if (!header) return;

            header.addEventListener("mousedown", function (e) {
                e.preventDefault();
                draggedElement = tooltipText;
                tooltipText.classList.add("dragging");
                
                const rect = tooltipText.getBoundingClientRect();
                offsetX = e.clientX - rect.left;
                offsetY = e.clientY - rect.top;
            });
        }

        document.addEventListener("mousemove", function (e) {
            if (!draggedElement) return;

            let x = e.clientX - offsetX;
            let y = e.clientY - offsetY;

            // 边界检测
            if (x < 0) x = 0;
            if (x + draggedElement.offsetWidth > window.innerWidth) {
                x = window.innerWidth - draggedElement.offsetWidth;
            }
            if (y < 0) y = 0;
            if (y + draggedElement.offsetHeight > window.innerHeight) {
                y = window.innerHeight - draggedElement.offsetHeight - 20;
            }

            draggedElement.style.left = x + "px";
            draggedElement.style.top = y + "px";
        });

        document.addEventListener("mouseup", function () {
            if (draggedElement) {
                draggedElement.classList.remove("dragging");
                draggedElement = null;
            }
        });

        tooltips.forEach(container => {
            const tooltip = container.querySelector(".tooltip-text");
            makeDraggable(tooltip);

            container.addEventListener("click", function (e) {
                e.stopPropagation();
                const isActive = container.classList.contains("active");

                tooltips.forEach(t => t.classList.remove("active"));

                if (!isActive) {
                    const rect = container.getBoundingClientRect();
                    const tooltipWidth = tooltip.offsetWidth || 400;
                    const tooltipHeight = tooltip.offsetHeight || 300;

                    let top = rect.bottom + window.scrollY + 10;
                    let left = rect.left + window.scrollX;

                    if (rect.bottom + tooltipHeight + 10 > window.innerHeight) {
                        top = Math.max(0, rect.top + window.scrollY - tooltipHeight - 10);
                    }

                    if (left + tooltipWidth > window.innerWidth) {
                        left = window.innerWidth - tooltipWidth - 20;
                    }

                    if (left < 0) left = 10;

                    tooltip.style.top = top + "px";
                    tooltip.style.left = left + "px";

                    container.classList.add("active");
                }
            });
        });

        document.addEventListener("click", function () {
            tooltips.forEach(t => t.classList.remove("active"));
        });

        document.addEventListener("keydown", function (e) {
            if (e.key === "Escape") {
                tooltips.forEach(t => t.classList.remove("active"));
            }
        });

        document.querySelectorAll(".tooltip-text").forEach(tooltip => {
            tooltip.addEventListener("click", function (e) {
                e.stopPropagation();
            });
        });
    });
    </script>
</body>
</html>
"""


# --- 路由逻辑 ---
@app.route('/api/upload', methods=['POST'])
def upload_data():
    """接收内存测试结果（包括故障定位数据）"""
    try:
        data = request.get_json()
        if not data: 
            return jsonify({"status": "error"}), 400
        
        hostname = data.get("test_metadata", {}).get("hostname", "unknown_host").replace(".", "_")
        timestamp_str = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        
        # 保存到日期分层目录
        date_subdir = get_date_subdir(HISTORY_DIR)
        history_file = os.path.join(date_subdir, f"{hostname}_{timestamp_str}.json")
        with open(history_file, 'w') as f:
            json.dump(data, f, indent=4)
        
        # 保存最新结果
        latest_file = os.path.join(LATEST_DIR, f"{hostname}.json")
        with open(latest_file, 'w') as f:
            json.dump(data, f, indent=4)

        return jsonify({
            "status": "success",
            "message": f"Data saved successfully"
        }), 200
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500


@app.route('/')
def index():
    """显示仪表盘"""
    node_reports = []
    json_files = glob.glob(os.path.join(LATEST_DIR, "*.json"))
    
    for file_path in json_files:
        try:
            with open(file_path, 'r') as f:
                report = json.load(f)
                
                # 提取关键信息
                if "test_metadata" in report:
                    report["hostname"] = report["test_metadata"].get("hostname", "unknown")
                    report["timestamp"] = report["test_metadata"].get("timestamp", "")
                
                # 从 stress_test 中提取 IP（如果有的话）
                if "ip" not in report:
                    report["ip"] = report.get("hostname", "Unknown")
                
                # 数据规范化
                if "verdict" not in report:
                    report["verdict"] = "UNKNOWN"
                if "recommendation" not in report:
                    report["recommendation"] = ""
                if "memory_errors" not in report:
                    report["memory_errors"] = {"failed_channels": [], "failed_dimms": [], "error_details": ""}
                
                node_reports.append(report)
        except Exception as e: 
            print(f"Error reading {file_path}: {e}")

    node_reports.sort(key=lambda x: x.get('timestamp', ''), reverse=True)
    current_time = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    
    return render_template_string(
        HTML_TEMPLATE, 
        nodes=node_reports, 
        current_time=current_time, 
        history_path=HISTORY_DIR
    )


@app.route('/api/stats', methods=['GET'])
def get_stats():
    """获取统计信息"""
    total_hosts = len(glob.glob(os.path.join(LATEST_DIR, "*.json")))
    
    pass_count = 0
    fail_count = 0
    warning_count = 0
    
    for file_path in glob.glob(os.path.join(LATEST_DIR, "*.json")):
        try:
            with open(file_path, 'r') as f:
                data = json.load(f)
                verdict = data.get("verdict", "UNKNOWN")
                if verdict == "PASS":
                    pass_count += 1
                elif verdict == "FAIL":
                    fail_count += 1
                elif verdict == "WARNING":
                    warning_count += 1
        except:
            pass
    
    return jsonify({
        "total_active_hosts": total_hosts,
        "pass_count": pass_count,
        "fail_count": fail_count,
        "warning_count": warning_count
    }), 200


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
