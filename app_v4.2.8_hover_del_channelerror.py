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


# HTML 仪表盘模板 - v4.5
HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>RAM Screening Control Center v4.5</title>
    <meta http-equiv="refresh" content="120">
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
        h2 { color: #00d2ff; margin-top: 0; font-size: 18px; margin-bottom: 15px; }
        h4 { color: #00d2ff; margin: 8px 0; font-size: 0.95em; }
        .stats { font-size: 0.9em; color: #888da8; }
        
        /* 标签页与全局按钮容器 */
        .controls-container {
            display: flex;
            justify-content: space-between;
            align-items: flex-end;
            border-bottom: 2px solid #3d4465;
            margin-bottom: 20px;
        }
        .tabs {
            display: flex;
            gap: 10px;
            flex-wrap: wrap;
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
            white-space: nowrap;
            margin-bottom: -2px;
        }
        .tab-button.active {
            color: #00d2ff;
            border-bottom-color: #00d2ff;
        }
        .tab-button:hover {
            color: #00d2ff;
        }
        
        .action-btn {
            background: #2d324a;
            border: 1px solid #00d2ff;
            color: #00d2ff;
            padding: 6px 15px;
            border-radius: 4px;
            cursor: pointer;
            font-size: 0.85em;
            margin-left: 10px;
            transition: all 0.3s;
            margin-bottom: 10px;
        }
        .action-btn:hover {
            background: #00d2ff;
            color: #1a1c2c;
            font-weight: bold;
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

        /* 状态标签与提示 */
        .badge { 
            padding: 4px 10px; 
            border-radius: 4px; 
            font-weight: bold; 
            font-size: 0.85em; 
            cursor: help; /* 鼠标样式提示有悬停内容 */
        }
        .PASS { background: #1e3a2a; color: #2ecc71; border: 1px solid #2ecc71; }
        .FAIL { background: #3a1e1e; color: #e74c3c; border: 1px solid #e74c3c; }
        .WARNING { background: #3a321e; color: #f1c40f; border: 1px solid #f1c40f; }

        .hover-cell {
            cursor: help;
            text-decoration: underline dotted #5d6d7e;
        }

        /* 折叠面板样式 */
        .node-container {
            border: 1px solid #3d4465;
            border-radius: 8px;
            margin-bottom: 12px;
            background: #252839;
            overflow: hidden;
            box-shadow: 0 2px 8px rgba(0,0,0,0.2);
        }
        .node-header {
            background: #2d324a;
            padding: 12px 20px;
            cursor: pointer;
            display: flex;
            justify-content: space-between;
            align-items: center;
            transition: background 0.3s;
            user-select: none;
        }
        .node-header:hover {
            background: #3d4465;
        }
        .node-header-info {
            display: flex;
            gap: 20px;
            align-items: center;
            flex-wrap: wrap;
        }
        .node-summary-item {
            font-size: 0.85em;
            color: #888da8;
        }
        .node-summary-item span {
            color: #e0e0e0;
            font-weight: bold;
        }
        .node-content {
            display: none;
            padding: 20px;
            border-top: 1px solid #3d4465;
            background: #1a1c2c;
        }
        .node-content.active {
            display: block;
        }
        .arrow {
            border: solid #00d2ff;
            border-width: 0 2px 2px 0;
            display: inline-block;
            padding: 4px;
            transform: rotate(45deg);
            transition: transform 0.3s;
            margin-right: 10px;
        }
        .node-header.active-header .arrow {
            transform: rotate(-135deg);
        }

        .detail-card {
            background: #2d324a;
            padding: 12px;
            margin: 10px 0;
            border-radius: 3px;
            border-left: 3px solid #00d2ff;
        }
        .detail-row {
            display: flex;
            justify-content: space-between;
            margin: 6px 0;
            padding: 6px 0;
        }
        .detail-label {
            font-weight: bold;
            color: #00d2ff;
            min-width: 200px;
        }
        .detail-value {
            color: #e0e0e0;
        }

        .memory-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
            gap: 10px;
            margin: 15px 0;
        }
        .dimm-card {
            padding: 12px;
            border-radius: 6px;
            background: #252839;
            border: 2px solid #3d4465;
            text-align: center;
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
        .dimm-name {
            font-weight: bold;
            color: #00d2ff;
            margin-bottom: 8px;
            font-size: 0.95em;
        }
        .dimm-info {
            font-size: 0.85em;
            color: #888da8;
            line-height: 1.4;
        }

        .gsat-card {
            background: #2d324a;
            border: 1px solid #3d4465;
            border-radius: 6px;
            padding: 15px;
            margin: 10px 0;
        }
        .gsat-title {
            color: #00d2ff;
            font-weight: bold;
            font-size: 0.95em;
            margin-bottom: 10px;
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
            <h1>RAM SCREENING DASHBOARD v4.5</h1>
            <div class="stats">
                Last Update: {{ current_time }}<br>
                Total Detected Nodes: {{ nodes|length }}
            </div>
        </header>

        <div class="controls-container">
            <div class="tabs">
                <button class="tab-button active" onclick="switchTab(event, 'overview')">Overview</button>
                <button class="tab-button" onclick="switchTab(event, 'gsat-details')">GSAT Details</button>
                <button class="tab-button" onclick="switchTab(event, 'memory-map')">Memory Map</button>
                <button class="tab-button" onclick="switchTab(event, 'errors')">EDAC Error Detail</button>
            </div>
            <div id="global-actions" style="display: none;">
                <button class="action-btn" onclick="expandAll()">Expand All</button>
                <button class="action-btn" onclick="collapseAll()">Collapse All</button>
            </div>
        </div>

        <div id="overview" class="tab-content active">
            <table>
                <thead>
                    <tr>
                        <th>IP Address</th>
                        <th>Verdict</th>
                        <th>GSAT Status</th>
                        <th>GSAT Errors</th>
                        <th>EDAC Errors</th>
                        <th>Last Seen</th>
                    </tr>
                </thead>
                <tbody>
                    {% if not nodes %}
                    <tr>
                        <td colspan="6" style="text-align: center; padding: 40px; color: #5d6d7e;">
                            No reports received yet. Waiting for nodes...
                        </td>
                    </tr>
                    {% endif %}
                    {% for node in nodes %}
                    <tr>
                        <td><strong style="color: #00d2ff;">{{ node.ip }}</strong></td>
                        <td>
                            <span class="badge {{ node.verdict }}" title="{{ node.verdict_summary }}">
                                {{ node.verdict }}
                            </span>
                        </td>
                        
                        <td class="hover-cell" title="GSAT Status: {{ node.gsat_results.status if node.gsat_results else 'N/A' }} - {{ node.gsat_results.summary if node.gsat_results else 'No summary' }}">
                            {% if node.gsat_results %}
                            <span class="badge {{ node.gsat_results.status }}">
                                {{ node.gsat_results.status }}
                            </span>
                            {% else %}
                                N/A
                            {% endif %}
                        </td>
                        
                        <td>
                            {% if node.gsat_results %}
                            {{ node.gsat_results.errors_found }}
                            {% else %}
                                N/A
                            {% endif %}
                        </td>
                        
                        <td>
                            {% if node.edac_results %}
                            CE: {{ node.edac_results.ce_delta }} / UE: {{ node.edac_results.ue_delta }}
                            {% else %}
                                N/A
                            {% endif %}
                        </td>
                        
                        <td style="font-size: 0.85em; color: #888da8;">{{ node.timestamp }}</td>
                    </tr>
                    {% endfor %}
                </tbody>
            </table>
        </div>

        <div id="gsat-details" class="tab-content">
            <h2>GSAT Test Results</h2>
            {% for node in nodes %}
            {% if node.gsat_results %}
            <div class="node-container">
                <div class="node-header" onclick="toggleNode(this)">
                    <div class="node-header-info">
                        <strong style="color: #00d2ff; font-size: 1.1em;">{{ node.ip }}</strong>
                        <span class="badge {{ node.gsat_results.status }}">{{ node.gsat_results.status }}</span>
                        <div class="node-summary-item">Errors Found: <span>{{ node.gsat_results.errors_found }}</span></div>
                        <div class="node-summary-item">Duration: <span>{{ node.gsat_results.test_time_seconds }}s</span></div>
                        <div class="node-summary-item">Memory: <span>{{ node.gsat_results.memory_tested_mb }}MB</span></div>
                    </div>
                    <div class="arrow"></div>
                </div>
                
                <div class="node-content">
                    <div class="gsat-card">
                        <div class="gsat-title">Test Summary</div>
                        <div class="detail-row">
                            <div class="detail-label">Status:</div>
                            <div class="detail-value">
                                <span class="badge {{ node.gsat_results.status }}">
                                    {{ node.gsat_results.status }}
                                </span>
                            </div>
                        </div>
                        <div class="detail-row">
                            <div class="detail-label">Test Duration:</div>
                            <div class="detail-value">{{ node.gsat_results.test_time_seconds }}s</div>
                        </div>
                        <div class="detail-row">
                            <div class="detail-label">Memory Tested:</div>
                            <div class="detail-value">{{ node.gsat_results.memory_tested_mb }}MB</div>
                        </div>
                        <div class="detail-row">
                            <div class="detail-label">Cores Used:</div>
                            <div class="detail-value">{{ node.gsat_results.cores_used }}</div>
                        </div>
                        <div class="detail-row">
                            <div class="detail-label">Exit Code:</div>
                            <div class="detail-value">{{ node.gsat_results.exit_code }}</div>
                        </div>
                        <div class="detail-row">
                            <div class="detail-label">Errors Found:</div>
                            <div class="detail-value">{{ node.gsat_results.errors_found }}</div>
                        </div>
                        <div class="detail-row">
                            <div class="detail-label">Test Summary:</div>
                            <div class="detail-value">{{ node.gsat_results.summary }}</div>
                        </div>
                    </div>
                </div>
            </div>
            {% endif %}
            {% endfor %}
        </div>

        <div id="memory-map" class="tab-content">
            <h2>Memory DIMM Status Map</h2>
            {% for node in nodes %}
            {% if node.memory_slots and node.memory_slots|length > 0 %}
            <div class="node-container">
                <div class="node-header" onclick="toggleNode(this)">
                    <div class="node-header-info">
                        <strong style="color: #00d2ff; font-size: 1.1em;">{{ node.ip }}</strong>
                        <span class="badge {{ node.verdict }}">{{ node.verdict }}</span>
                        {% if node.memory_stats %}
                        <div class="node-summary-item">Slots: <span>{{ node.memory_stats.installed_slots }}/{{ node.memory_stats.total_slots }}</span></div>
                        <div class="node-summary-item">Empty: <span>{{ node.memory_stats.empty_slots }}</span></div>
                        {% endif %}
                    </div>
                    <div class="arrow"></div>
                </div>

                <div class="node-content">
                    <div class="memory-grid">
                        {% for slot in node.memory_slots %}
                        {% set is_failed = false %}
                        {% if node.memory_errors and node.memory_errors.failed_dimms %}
                            {% for failed_dimm in node.memory_errors.failed_dimms %}
                                {% if slot.slot in failed_dimm or failed_dimm in slot.slot %}
                                    {% set is_failed = true %}
                                {% endif %}
                            {% endfor %}
                        {% endif %}
                        
                        <div class="dimm-card {% if is_failed %}failed{% else %}healthy{% endif %}">
                            <div class="dimm-name">{{ slot.slot }}</div>
                            <div style="font-size: 0.85em; color: #a8b2d1; margin-bottom: 8px;word-break: break-all; line-height: 1.2; white-space: normal;">
                                [{{ slot.bank_locator }}]
                            </div>                    
                            
                            {% if slot.size == 'EMPTY' %}
                            <div class="dimm-info" style="color: #f1c40f;">
                                🔲 EMPTY
                                {% if slot.type and slot.type != 'Unknown' %}
                                <br>{{ slot.type }}
                                {% endif %}
                            </div>
                            {% else %}
                            <div class="dimm-info">
                                <strong style="color: #00d2ff;">{{ slot.size }}</strong><br>
                                {{ slot.type }}<br>
                                {{ slot.speed }}<br>
                                <small style="color: #888da8;">{{ slot.manufacturer }}</small>
                            </div>
                            {% endif %}
                        </div>
                        {% endfor %}
                    </div>
                    
                    {% if node.memory_stats %}
                    <div style="background: #2d324a; padding: 10px; margin-top: 15px; border-radius: 3px;">
                        <p style="margin: 4px 0; color: #e0e0e0;">
                            <strong>Memory Summary:</strong>
                            Total: {{ node.memory_stats.total_slots }} slots,
                            Installed: {{ node.memory_stats.installed_slots }} slots,
                            Empty: {{ node.memory_stats.empty_slots }} slots
                        </p>
                    </div>
                    {% endif %}
                </div>
            </div>
            {% endif %}
            {% endfor %}
        </div>

        <div id="errors" class="tab-content">
            <h2>Detailed EDAC Error Report</h2>
            {% for node in nodes %}
            {% if node.memory_errors or node.edac_results %}
            <div class="node-container">
                <div class="node-header" onclick="toggleNode(this)">
                    <div class="node-header-info">
                        <strong style="color: #00d2ff; font-size: 1.1em;">{{ node.ip }}</strong>
                        {% if node.edac_results %}
                        <div class="node-summary-item">EDAC CE Δ: <span>{{ node.edac_results.ce_delta }}</span></div>
                        <div class="node-summary-item" style="{% if node.edac_results.ue_delta > 0 %}color: #e74c3c;{% endif %}">EDAC UE Δ: <span>{{ node.edac_results.ue_delta }}</span></div>
                        {% endif %}
                    </div>
                    <div class="arrow"></div>
                </div>

                <div class="node-content">
                    {% if node.edac_results %}
                    <div class="detail-card">
                        <h4>EDAC Error Statistics</h4>
                        <div class="detail-row">
                            <div class="detail-label">CE (Correctable):</div>
                            <div class="detail-value">
                                {{ node.edac_results.initial_ce_count }} → {{ node.edac_results.final_ce_count }}
                                (Δ {{ node.edac_results.ce_delta }})
                            </div>
                        </div>
                        <div class="detail-row">
                            <div class="detail-label">UE (Uncorrectable):</div>
                            <div class="detail-value" style="{% if node.edac_results.ue_delta > 0 %}color: #e74c3c;{% endif %}">
                                {{ node.edac_results.initial_ue_count }} → {{ node.edac_results.final_ue_count }}
                                (Δ {{ node.edac_results.ue_delta }})
                            </div>
                        </div>               
                    </div>
                    {% endif %}
                    
                    {% if node.memory_errors and node.memory_errors.error_details %}
                    <div class="detail-card">
                        <h4>EDAC Error Details</h4>
                        <pre style="margin: 0; overflow-x: auto; font-size: 0.8em; color: #888da8;">{{ node.memory_errors.error_details }}</pre>
                    </div>
                    {% endif %}
                </div>
            </div>
            {% endif %}
            {% endfor %}
        </div>

        <div class="footer">
            Storage: {{latest_path}} | Auto-Refresh: 120s | Version: v4.5 (Optimized Hover & Detail View)
        </div>
    </div>

    <script>
    function switchTab(event, tabName) {
        const contents = document.querySelectorAll('.tab-content');
        contents.forEach(content => content.classList.remove('active'));
        
        const buttons = document.querySelectorAll('.tab-button');
        buttons.forEach(button => button.classList.remove('active'));
        
        document.getElementById(tabName).classList.add('active');
        event.target.classList.add('active');

        const globalActions = document.getElementById('global-actions');
        if (tabName === 'overview') {
            globalActions.style.display = 'none';
        } else {
            globalActions.style.display = 'block';
        }
    }

    function toggleNode(headerElement) {
        headerElement.classList.toggle('active-header');
        const content = headerElement.nextElementSibling;
        content.classList.toggle('active');
    }

    function expandAll() {
        const activeTab = document.querySelector('.tab-content.active');
        if (!activeTab) return;

        const headers = activeTab.querySelectorAll('.node-header');
        headers.forEach(header => {
            if (!header.classList.contains('active-header')) {
                header.classList.add('active-header');
                header.nextElementSibling.classList.add('active');
            }
        });
    }

    function collapseAll() {
        const activeTab = document.querySelector('.tab-content.active');
        if (!activeTab) return;

        const headers = activeTab.querySelectorAll('.node-header');
        headers.forEach(header => {
            if (header.classList.contains('active-header')) {
                header.classList.remove('active-header');
                header.nextElementSibling.classList.remove('active');
            }
        });
    }
    </script>
</body>
</html>
"""



# --- 数据判断逻辑 ---
def determine_verdict_and_summary(report):
    """
    更新后的逻辑：返回值严格匹配前端 Hover 显示需求
    """
    gsat_results = report.get("gsat_results", {})
    edac_results = report.get("edac_results", {})
    memory_stats = report.get("memory_stats", {})
    
    # 提取关键数据
    gsat_errors = gsat_results.get("errors_found", 0) if gsat_results else 0
    edac_ue = edac_results.get("ue_delta", 0) if edac_results else 0
    empty_slots = memory_stats.get("empty_slots", 0) if memory_stats else 0
    total_slots = memory_stats.get("total_slots", 0) if memory_stats else 0
    installed_slots = memory_stats.get("installed_slots", 0) if memory_stats else 0
    
    # 1. FAIL 逻辑
    if gsat_errors > 0 or edac_ue > 0:
        verdict = "FAIL"
        if gsat_errors > 0 and edac_ue > 0:
            summary = f"FAIL - GSAT & EDAC Errors: GSAT {gsat_errors}, EDAC UE {edac_ue}"
        elif gsat_errors > 0:
            summary = f"FAIL - GSAT Errors: {gsat_errors} errors found"
        else:
            summary = f"FAIL - EDAC Errors: {edac_ue} uncorrectable errors"
    
    # 2. WARNING 逻辑
    elif empty_slots > 0:
        verdict = "WARNING"
        summary = f"WARNING - Memory Summary: Total: {total_slots} slots, Installed: {installed_slots} slots, Empty: {empty_slots} slots"
    
    # 3. PASS 逻辑
    else:
        verdict = "PASS"
        summary = "PASS - All tests passed - No errors detected"
    
    return verdict, summary


# --- 路由逻辑 ---
@app.route('/api/upload', methods=['POST'])
def upload_data():
    """接收测试数据"""
    try:
        data = request.get_json()
        if not data: 
            return jsonify({"status": "error"}), 400
        
        hostname = data.get("hostname", "unknown_host").replace(".", "_")
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

        return jsonify({"status": "success"}), 200
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
                
                # 数据规范化
                if "ip" not in report:
                    report["ip"] = report.get("hostname", "Unknown")
                
                if "timestamp" not in report:
                    report["timestamp"] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                
                # 计算最新的 verdict 和 summary
                verdict, verdict_summary = determine_verdict_and_summary(report)
                report["verdict"] = verdict
                report["verdict_summary"] = verdict_summary
                
                # 兼容旧数据/补齐字段
                if "gsat_results" not in report: report["gsat_results"] = None
                if "edac_results" not in report: report["edac_results"] = None
                if "memory_errors" not in report: report["memory_errors"] = {"failed_channels": [], "failed_dimms": [], "error_details": ""}
                if "memory_stats" not in report: report["memory_stats"] = {"total_slots": 0, "installed_slots": 0, "empty_slots": 0}
                if "memory_slots" not in report: report["memory_slots"] = []
                
                node_reports.append(report)
        except Exception as e: 
            print(f"Error reading {file_path}: {e}")

    node_reports.sort(key=lambda x: x.get('timestamp', ''), reverse=True)
    current_time = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    
    return render_template_string(
        HTML_TEMPLATE, 
        nodes=node_reports, 
        current_time=current_time, 
        latest_path=LATEST_DIR
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
                verdict, _ = determine_verdict_and_summary(data)
                if verdict == "PASS": pass_count += 1
                elif verdict == "FAIL": fail_count += 1
                elif verdict == "WARNING": warning_count += 1
        except:
            pass
    
    return jsonify({
        "total_active_hosts": total_hosts,
        "pass_count": pass_count,
        "fail_count": fail_count,
        "warning_count": warning_count,
        "version": "4.5"
    }), 200


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)