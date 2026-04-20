#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then 
    echo "Error: run as root"
    exit 1
fi

KEY="$1"
if [ -z "$KEY" ]; then
    echo "Usage: curl -s URL | sudo bash -s -- \"YOUR-KEY\""
    exit 1
fi

# Clean
systemctl stop void 2>/dev/null || true
systemctl disable void 2>/dev/null || true
rm -f /etc/systemd/system/void.service
rm -rf /opt/void
systemctl daemon-reload

# Dependencies
apt update
apt install -y python3 python3-pip python3-venv

# Directory
mkdir -p /opt/void/voids
cd /opt/void

# API Key
echo "KIMI_API_KEY=$KEY" > .env
chmod 600 .env

# Python env
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install flask requests python-dotenv

# === void.py ===
cat > void.py << 'EOF'
#!/usr/bin/env python3
"""
VOID — Kimi K2.5 (Moonshot Global)
"""

import json
import os
import re
import subprocess
import shlex
from pathlib import Path
from typing import List, Dict, Optional, Generator
from datetime import datetime

import requests
from dotenv import load_dotenv
from flask import Flask, Response, jsonify, request, stream_with_context

load_dotenv()

BASE_DIR = Path(__file__).parent
VOIDS_DIR = BASE_DIR / "voids"
CSS_FILE = VOIDS_DIR / "current.css"
LOG_FILE = BASE_DIR / "void.log"
MEMORY_FILE = BASE_DIR / "memory.json"
VOIDS_DIR.mkdir(exist_ok=True)

memory = []
if MEMORY_FILE.exists():
    try:
        with open(MEMORY_FILE, 'r', encoding='utf-8') as f:
            memory.extend(json.load(f))
    except:
        pass

def save_memory():
    with open(MEMORY_FILE, 'w', encoding='utf-8') as f:
        json.dump(memory, f, ensure_ascii=False, indent=2)

def log_to_file(role, content):
    with open(LOG_FILE, 'a', encoding='utf-8') as f:
        f.write(f"{content}\n***\n")

class VoidAgent:
    def __init__(self):
        self.api_key = os.getenv("KIMI_API_KEY", "").strip()
        self.model = "kimi-k2.5"
        self.url = "https://api.moonshot.ai/v1/chat/completions"
        self.timeout = 120
    
    def _call_llm_stream(self, messages: List[Dict]) -> Generator[str, None, None]:
        headers = {"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"}
        payload = {"model": self.model, "messages": messages, "stream": True}
        resp = requests.post(self.url, headers=headers, json=payload, timeout=self.timeout, stream=True)
        resp.raise_for_status()
        for line in resp.iter_lines(decode_unicode=True):
            if line and line.startswith("data: "):
                data = line[6:]
                if data == "[DONE]":
                    break
                try:
                    chunk = json.loads(data)
                    delta = chunk.get("choices", [{}])[0].get("delta", {})
                    content = delta.get("content", "")
                    if content:
                        yield content
                except:
                    continue
    
    def execute_command(self, command: str) -> Dict:
        try:
            result = subprocess.run(shlex.split(command), capture_output=True, text=True, timeout=30, cwd=VOIDS_DIR)
            output = result.stdout + result.stderr
            return {"success": True, "output": output or "(нет вывода)", "exit_code": result.returncode}
        except subprocess.TimeoutExpired:
            return {"success": False, "output": "Timeout 30s", "exit_code": -1}
        except Exception as e:
            return {"success": False, "output": str(e), "exit_code": -1}
    
    def chat_stream(self, messages: List[Dict]) -> Generator[str, None, None]:
        yield from self._call_llm_stream(messages)

agent = VoidAgent()
app = Flask(__name__)

# Настройки для гримуара
MODEL_NAME = "kimi-k2.5"
PROVIDER = "Moonshot"
THINKING = "enabled"
MEMORY_STATUS = "on"

HTML = f"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes">
<title>VOID · Гримуар</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500&display=swap');
* {{ box-sizing: border-box; }}
html, body {{ margin: 0; padding: 0; background: #000; color: #e0e0e0; font-family: 'JetBrains Mono', monospace; font-weight: 400; -webkit-font-smoothing: antialiased; }}
body {{ padding: 24px; min-height: 100vh; }}
#manuscript-header {{
    color: #5a5a5a;
    font-size: 11px;
    border-bottom: 1px solid #2a2a2a;
    padding-bottom: 8px;
    margin-bottom: 24px;
    user-select: none;
}}
#manuscript {{
    white-space: pre-wrap;
    word-break: break-word;
    line-height: 1.7;
    font-size: 14px;
}}
.msg {{
    margin-bottom: 16px;
}}
.msg.user {{
    color: #9a9a9a;
}}
.msg.assistant {{
    color: #d0d0d0;
}}
.msg.user::before {{
    content: "> ";
    color: #5a5a5a;
}}
.msg.assistant::before {{
    content: "~ ";
    color: #5a5a5a;
}}
.separator {{
    color: #2a2a2a;
    font-size: 12px;
    margin: 16px 0;
    user-select: text;
}}
#scribe-line {{
    display: flex;
    align-items: center;
    margin-top: 24px;
    color: #5a5a5a;
}}
.prompt {{
    margin-right: 8px;
    user-select: none;
}}
#messageInput {{
    background: transparent;
    border: none;
    color: #e0e0e0;
    font-family: inherit;
    font-size: 14px;
    flex-grow: 1;
    outline: none;
    caret-color: #8a8a8a;
    padding: 0;
}}
#messageInput::placeholder {{ opacity: 0; }}
</style>
<link rel="stylesheet" href="/css" id="dynamic-css">
</head>
<body>
<div id="manuscript-header">VOID · {MODEL_NAME} ({PROVIDER}) · thinking: {THINKING} · memory: {MEMORY_STATUS} · {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</div>
<div id="manuscript">
    <div class="separator">***</div>
</div>
<div id="scribe-line">
    <span class="prompt">></span>
    <input type="text" id="messageInput" autofocus autocomplete="off" placeholder=" ">
</div>
<script>
const manuscript = document.getElementById('manuscript');
const input = document.getElementById('messageInput');
let isSending = false;

function refreshCSS() {{ document.getElementById('dynamic-css').href = '/css?' + Date.now(); }}

function addMessageToUI(role, content) {{
    const msgDiv = document.createElement('div');
    msgDiv.className = `msg ${{role}}`;
    msgDiv.textContent = content;
    msgDiv.style.userSelect = 'text';
    msgDiv.style.webkitUserSelect = 'text';
    manuscript.appendChild(msgDiv);
    
    const sep = document.createElement('div');
    sep.className = 'separator';
    sep.textContent = '***';
    sep.style.userSelect = 'text';
    manuscript.appendChild(sep);
    
    window.scrollTo(0, document.body.scrollHeight);
}}

async function sendMessage() {{
    const text = input.value.trim();
    if (!text || isSending) return;
    isSending = true;
    input.value = '';
    input.disabled = true;
    
    addMessageToUI('user', text);
    
    const assistantDiv = document.createElement('div');
    assistantDiv.className = 'msg assistant';
    assistantDiv.textContent = '';
    assistantDiv.style.userSelect = 'text';
    assistantDiv.style.webkitUserSelect = 'text';
    manuscript.appendChild(assistantDiv);
    
    window.scrollTo(0, document.body.scrollHeight);
    
    try {{
        const res = await fetch('/chat', {{ method: 'POST', headers: {{'Content-Type': 'application/json'}}, body: JSON.stringify({{message: text}}) }});
        if (!res.ok) throw new Error('Chat failed');
        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let fullResponse = '';
        while (true) {{
            const {{done, value}} = await reader.read();
            if (done) break;
            const chunk = decoder.decode(value, {{stream: true}});
            fullResponse += chunk;
            assistantDiv.textContent = fullResponse;
            window.scrollTo(0, document.body.scrollHeight);
        }}
        
        const sep = document.createElement('div');
        sep.className = 'separator';
        sep.textContent = '***';
        sep.style.userSelect = 'text';
        manuscript.appendChild(sep);
        
        refreshCSS();
    }} catch (e) {{ console.error(e); }} finally {{
        isSending = false;
        input.disabled = false;
        input.focus();
    }}
}}

input.addEventListener('keydown', (e) => {{
    if (e.key === 'Enter' && !e.shiftKey) {{
        e.preventDefault();
        sendMessage();
    }}
}});

document.body.addEventListener('click', () => {{
    input.focus();
}});

// Начальный разделитель уже в HTML
</script>
</body>
</html>
"""

def parse_and_execute_tools(content: str):
    changed = False
    cmd_pattern = r'\[CMD\](.*?)\[/CMD\]'
    for match in re.finditer(cmd_pattern, content, re.DOTALL):
        cmd = match.group(1).strip()
        try:
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30, cwd=VOIDS_DIR)
            output = result.stdout + result.stderr
            if not output: output = "(no output)"
            content = content.replace(match.group(0), f"[executed: {cmd}]\n{output}")
        except Exception as e:
            content = content.replace(match.group(0), f"[error: {cmd}]\n{str(e)}")
    css_pattern = r'\[CSS\](.*?)\[/CSS\]'
    for match in re.finditer(css_pattern, content, re.DOTALL):
        css = match.group(1).strip()
        try:
            CSS_FILE.write_text(css, encoding='utf-8')
            content = content.replace(match.group(0), "[style applied]")
            changed = True
        except Exception as e:
            content = content.replace(match.group(0), f"[css error: {str(e)}]")
    return content, changed

@app.route('/')
def index(): return HTML
@app.route('/css')
def get_css():
    if CSS_FILE.exists(): return Response(CSS_FILE.read_text(), mimetype='text/css')
    return '', 200
@app.route('/memory')
def get_memory(): return jsonify(memory)
@app.route('/chat', methods=['POST'])
def chat():
    data = request.get_json()
    user_msg = data.get('message', '').strip()
    if not user_msg: return jsonify({'error': 'empty'}), 400
    memory.append({"role": "user", "content": user_msg})
    save_memory()
    log_to_file('user', user_msg)
    def generate():
        full_response = ""
        css_changed = False
        try:
            for chunk in agent.chat_stream(memory):
                try: clean_chunk = chunk.encode('latin-1').decode('utf-8')
                except: clean_chunk = chunk
                full_response += clean_chunk
                yield clean_chunk
            if '[CMD]' in full_response or '[CSS]' in full_response:
                full_response, css_changed = parse_and_execute_tools(full_response)
            memory.append({"role": "assistant", "content": full_response})
            save_memory()
            log_to_file('assistant', full_response)
            if css_changed: yield "\n\n✨ room updated"
        except Exception as e:
            error_msg = f"[error]: {str(e)}"
            memory.append({"role": "assistant", "content": error_msg})
            save_memory()
            log_to_file('assistant', error_msg)
            yield error_msg
    return Response(stream_with_context(generate()), mimetype='text/plain; charset=utf-8')
@app.route('/delete', methods=['POST'])
def delete_message():
    data = request.get_json()
    idx = data.get('index')
    try:
        idx = int(idx)
        if 0 <= idx < len(memory):
            deleted = memory.pop(idx)
            save_memory()
            log_to_file('system', f"deleted [{idx}]: {deleted.get('content', '')[:50]}...")
            return jsonify({'ok': True})
    except (ValueError, TypeError): pass
    return jsonify({'error': 'bad index'}), 400
if __name__ == '__main__':
    host = os.getenv('HOST', '0.0.0.0')
    port = int(os.getenv('PORT', 42424))
    print(f"VOID :: http://{host}:{port}")
    app.run(host=host, port=port, debug=False, threaded=True)
EOF

# Service
cat > /etc/systemd/system/void.service << EOF
[Unit]
Description=Void AI Agent
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/void
EnvironmentFile=/opt/void/.env
Environment="PORT=42424"
ExecStart=/opt/void/venv/bin/python3 /opt/void/void.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable void.service
systemctl start void.service

sleep 2

if systemctl is-active --quiet void.service; then
    IP=$(hostname -I | awk '{print $1}')
    echo "http://$IP:42424"
else
    journalctl -u void.service -n 30 --no-pager
    exit 1
fi
