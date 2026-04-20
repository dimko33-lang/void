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

systemctl stop void 2>/dev/null || true
systemctl disable void 2>/dev/null || true
rm -f /etc/systemd/system/void.service
rm -rf /opt/void
systemctl daemon-reload

apt-get update -qq
apt-get install -y python3 python3-pip python3-venv

mkdir -p /opt/void/voids
cd /opt/void

echo "KIMI_API_KEY=$KEY" > .env
chmod 600 .env

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip --no-cache-dir
pip install flask requests python-dotenv --no-cache-dir

cat > void.py << 'EOF'
#!/usr/bin/env python3
"""
VOID — Kimi K2.5 (Moonshot Global)
"""
import json
import os
import re
import subprocess
from pathlib import Path
from typing import List, Dict, Generator
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
                    content = chunk.get("choices", [{}])[0].get("delta", {}).get("content", "")
                    if content:
                        yield content
                except:
                    continue

    def chat_stream(self, messages: List[Dict]) -> Generator[str, None, None]:
        yield from self._call_llm_stream(messages)

agent = VoidAgent()
app = Flask(__name__)

MODEL_NAME = "kimi-k2.5"
PROVIDER = "Moonshot"
THINKING = "enabled"
MEMORY_STATUS = "on"

HTML = f"""
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes">
<title>VOID</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500&display=swap');
* {{ box-sizing: border-box; margin: 0; padding: 0; }}
html, body {{ 
    background: #000; 
    color: #e0e0e0; 
    font-family: 'JetBrains Mono', monospace; 
    -webkit-font-smoothing: antialiased; 
}}
body {{ padding: 3px 9px 14px 9px; }}

#manuscript-header {{
    color: #4a4a4a;
    font-size: 10px;
    margin-bottom: 1px;
    user-select: text;
    letter-spacing: 0.3px;
}}
#manuscript {{
    white-space: pre-wrap;
    word-break: break-word;
    line-height: 1.65;
    font-size: 14px;
    margin-top: 0;
    user-select: text;
    cursor: text;
}}
.msg {{ margin-bottom: 0; user-select: text; }}
.separator {{
    color: transparent;
    font-size: 12px;
    margin: 1px 0;
    user-select: text;
}}
#input-line {{
    display: flex;
    align-items: center;
    margin-top: 5px;
    color: #5a5a5a;
}}
.prompt {{ margin-right: 8px; user-select: none; }}
#editable-input {{
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
</style>
<link rel="stylesheet" href="/css" id="dynamic-css">
</head>
<body>
<div id="manuscript-header">VOID · {MODEL_NAME} ({PROVIDER}) · thinking: {THINKING} · memory: {MEMORY_STATUS} · {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</div>
<div id="manuscript">
    <div class="separator">***</div>
</div>
<div id="input-line">
    <span class="prompt">></span>
    <div id="editable-input" contenteditable="true" data-placeholder=" "></div>
</div>

<script>
const manuscript = document.getElementById('manuscript');
const editableInput = document.getElementById('editable-input');
let isSending = false;

function refreshCSS() {{ document.getElementById('dynamic-css').href = '/css?' + Date.now(); }}

function addMessageToUI(role, content) {{
    const msgDiv = document.createElement('div');
    msgDiv.className = `msg ${role}`;
    const prefix = role === 'user' ? '> ' : '~ ';
    msgDiv.textContent = prefix + content;
    manuscript.appendChild(msgDiv);

    const sep = document.createElement('div');
    sep.className = 'separator';
    sep.textContent = '***';
    manuscript.appendChild(sep);

    window.scrollTo(0, document.body.scrollHeight);
}}

async function sendMessage() {{
    const text = editableInput.innerText.trim();
    if (!text || isSending) return;
    isSending = true;
    editableInput.innerText = '';
    editableInput.focus();

    addMessageToUI('user', text);

    const assistantDiv = document.createElement('div');
    assistantDiv.className = 'msg assistant';
    assistantDiv.textContent = '~ ';
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
            assistantDiv.textContent = '~ ' + fullResponse;
            window.scrollTo(0, document.body.scrollHeight);
        }}
        const sep = document.createElement('div');
        sep.className = 'separator';
        sep.textContent = '***';
        manuscript.appendChild(sep);
        refreshCSS();
    }} catch (e) {{ console.error(e); }} finally {{
        isSending = false;
        editableInput.focus();
    }}
}}

editableInput.addEventListener('keydown', (e) => {{
    if (e.key === 'Enter' && !e.shiftKey) {{
        e.preventDefault();
        sendMessage();
    }}
}});

document.addEventListener('mousedown', (e) => {{
    if (e.target.closest('#manuscript') || e.target.closest('#editable-input') || e.target.closest('#input-line')) return;
    setTimeout(() => editableInput.focus(), 10);
}});

document.addEventListener('keydown', (e) => {{
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'a') {{
        e.preventDefault();
        const selection = window.getSelection();
        const range = document.createRange();
        range.setStartBefore(document.getElementById('manuscript-header'));
        range.setEndAfter(manuscript.lastChild || manuscript);
        selection.removeAllRanges();
        selection.addRange(range);
    }}
}});

document.addEventListener('copy', (e) => {{
    const selection = window.getSelection();
    e.clipboardData.setData('text/plain', selection.toString());
    e.preventDefault();
}});
</script>
</body>
</html>
"""

def parse_and_execute_tools(content: str):
    changed = False
    for match in re.finditer(r'\[CMD\](.*?)\[/CMD\]', content, re.DOTALL):
        cmd = match.group(1).strip()
        try:
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30, cwd=VOIDS_DIR)
            output = result.stdout + result.stderr or "(no output)"
            content = content.replace(match.group(0), f"[executed: {cmd}]\n{output}")
        except Exception as e:
            content = content.replace(match.group(0), f"[error: {cmd}]\n{str(e)}")

    for match in re.finditer(r'\[CSS\](.*?)\[/CSS\]', content, re.DOTALL):
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
    if CSS_FILE.exists():
        return Response(CSS_FILE.read_text(encoding='utf-8'), mimetype='text/css')
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
                full_response += chunk
                yield chunk
                if '[CMD]' in full_response or '[CSS]' in full_response:
                    full_response, css_changed = parse_and_execute_tools(full_response)
            memory.append({"role": "assistant", "content": full_response})
            save_memory()
            log_to_file('assistant', full_response)
            if css_changed:
                yield "\n\n✨ room updated"
        except Exception as e:
            error_msg = f"[error]: {str(e)}"
            memory.append({"role": "assistant", "content": error_msg})
            save_memory()
            log_to_file('assistant', error_msg)
            yield error_msg

    return Response(stream_with_context(generate()), mimetype='text/plain; charset=utf-8')

if __name__ == '__main__':
    host = os.getenv('HOST', '0.0.0.0')
    port = int(os.getenv('PORT', 42424))
    print(f"VOID :: http://{host}:{port}")
    app.run(host=host, port=port, debug=False, threaded=True)
EOF

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
RestartSec=8

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now void.service > /dev/null 2>&1

sleep 1.5
if systemctl is-active --quiet void.service; then
    IP=$(hostname -I | awk '{print $1}')
    echo "http://$IP:42424"
else
    echo "Failed to start service"
    journalctl -u void.service -n 30 --no-pager
    exit 1
fi
