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
        # === ПРАВИЛЬНЫЙ МЕЖДУНАРОДНЫЙ URL ===
        self.url = "https://api.moonshot.ai/v1/chat/completions"
        self.timeout = 120
    
    def _call_llm_stream(self, messages):
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
    
    def execute_command(self, command: str):
        try:
            result = subprocess.run(shlex.split(command), capture_output=True, text=True, timeout=30, cwd=VOIDS_DIR)
            output = result.stdout + result.stderr
            return {"success": True, "output": output or "(нет вывода)", "exit_code": result.returncode}
        except subprocess.TimeoutExpired:
            return {"success": False, "output": "Timeout 30s", "exit_code": -1}
        except Exception as e:
            return {"success": False, "output": str(e), "exit_code": -1}
    
    def chat_stream(self, messages):
        yield from self._call_llm_stream(messages)

agent = VoidAgent()
app = Flask(__name__)

HTML = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes">
<title>void</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=Inter:ital,wght@0,400;0,500;1,400;1,500&display=swap');
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; height: 100dvh; }
body { background: #000000; color: #fff; font-family: 'Inter', sans-serif; font-weight: 400; overflow: hidden; -webkit-font-smoothing: antialiased; }
::selection { background: rgba(255, 255, 255, 0.08); color: inherit; }
#chatMessages { position: fixed; top: 0; left: 0; right: 0; bottom: 50px; overflow-y: auto; padding: 16px 18px; z-index: 2; }
.msgWrap { margin-bottom: 2px; position: relative; cursor: default; user-select: text; -webkit-user-select: text; }
.msg { margin: 0; letter-spacing: 0.01em; line-height: 1.6; word-break: break-word; white-space: pre-wrap; font-size: 15px; padding: 6px 0; }
.msg.assistant { color: #e8e8e8; }
.msg.user { color: #888888; }
#messageInput { position: fixed; bottom: 16px; left: 18px; right: 18px; width: auto; background: transparent; color: #cccccc; border: none; outline: none; font-family: 'Inter', sans-serif; font-size: 15px; padding: 0; caret-color: rgba(255, 255, 255, 0.3); }
#messageInput::placeholder { content: ""; opacity: 0; }
::-webkit-scrollbar { width: 6px; }
::-webkit-scrollbar-track { background: #000; }
::-webkit-scrollbar-thumb { background: #2a2a2a; border-radius: 3px; }
* { scrollbar-width: thin; scrollbar-color: #2a2a2a #000; }
@media (max-width: 720px) { .msg { font-size: 14px; } #chatMessages { padding: 14px 14px; } #messageInput { left: 14px; right: 14px; font-size: 14px; } }
</style>
<link rel="stylesheet" href="/css" id="dynamic-css">
</head>
<body>
<div id="chatMessages"></div>
<input type="text" id="messageInput" autofocus autocomplete="off" placeholder=" ">
<script>
const chatDiv = document.getElementById('chatMessages');
const input = document.getElementById('messageInput');
let isSending = false;
let currentAssistantMsg = null;
function refreshCSS() { document.getElementById('dynamic-css').href = '/css?' + Date.now(); }
async function loadMemory() {
    try {
        const res = await fetch('/memory');
        const data = await res.json();
        const wasAtBottom = chatDiv.scrollHeight - chatDiv.scrollTop - chatDiv.clientHeight < 10;
        chatDiv.innerHTML = '';
        data.forEach((msg, idx) => { addMessageToUI(msg.role, msg.content, idx); });
        if (wasAtBottom) chatDiv.scrollTop = chatDiv.scrollHeight;
    } catch (e) { console.error('Failed to load memory:', e); }
}
function addMessageToUI(role, content, idx) {
    const wrap = document.createElement('div');
    wrap.className = 'msgWrap';
    wrap.dataset.index = idx;
    wrap.style.userSelect = 'text';
    wrap.style.webkitUserSelect = 'text';
    let lastClick = 0;
    wrap.onclick = (e) => {
        const now = Date.now();
        if (now - lastClick < 200) {
            e.stopPropagation();
            fetch('/delete', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({index: parseInt(wrap.dataset.index)}) }).then(res => res.ok && loadMemory());
        }
        lastClick = now;
    };
    const msgDiv = document.createElement('div');
    msgDiv.className = `msg ${role}`;
    msgDiv.textContent = content;
    msgDiv.style.userSelect = 'text';
    msgDiv.style.webkitUserSelect = 'text';
    wrap.appendChild(msgDiv);
    chatDiv.appendChild(wrap);
}
function updateLastMessage(content) { if (currentAssistantMsg) currentAssistantMsg.querySelector('.msg').textContent = content; }
async function sendMessage() {
    const text = input.value.trim();
    if (!text || isSending) return;
    isSending = true;
    input.value = '';
    input.disabled = true;
    addMessageToUI('user', text, -1);
    const wrap = document.createElement('div');
    wrap.className = 'msgWrap';
    wrap.style.userSelect = 'text';
    wrap.style.webkitUserSelect = 'text';
    const msgDiv = document.createElement('div');
    msgDiv.className = 'msg assistant';
    msgDiv.textContent = '';
    msgDiv.style.userSelect = 'text';
    msgDiv.style.webkitUserSelect = 'text';
    wrap.appendChild(msgDiv);
    chatDiv.appendChild(wrap);
    currentAssistantMsg = wrap;
    chatDiv.scrollTop = chatDiv.scrollHeight;
    try {
        const res = await fetch('/chat', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({message: text}) });
        if (!res.ok) throw new Error('Chat failed');
        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let fullResponse = '';
        while (true) {
            const {done, value} = await reader.read();
            if (done) break;
            const chunk = decoder.decode(value, {stream: true});
            fullResponse += chunk;
            updateLastMessage(fullResponse);
            chatDiv.scrollTop = chatDiv.scrollHeight;
        }
        await loadMemory();
        refreshCSS();
    } catch (e) { console.error(e); } finally {
        isSending = false;
        input.disabled = false;
        input.focus();
        currentAssistantMsg = null;
    }
}
input.addEventListener('keydown', (e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); } });
loadMemory();

// --- ПРОСТЕЙШИЙ UNDO / REDO (ПРОВЕРЕНО) ---
let cssHistory = [];
let cssHistoryIndex = -1;

function saveState(css) {
    if (cssHistoryIndex < cssHistory.length - 1) {
        cssHistory = cssHistory.slice(0, cssHistoryIndex + 1);
    }
    cssHistory.push(css);
    cssHistoryIndex = cssHistory.length - 1;
}

function undo() {
    if (cssHistoryIndex > 0) {
        cssHistoryIndex--;
        fetch('/css', { method: 'POST', body: cssHistory[cssHistoryIndex] }).then(refreshCSS);
    }
}

function redo() {
    if (cssHistoryIndex < cssHistory.length - 1) {
        cssHistoryIndex++;
        fetch('/css', { method: 'POST', body: cssHistory[cssHistoryIndex] }).then(refreshCSS);
    }
}

document.addEventListener('keydown', (e) => {
    const mod = e.ctrlKey || e.metaKey;
    if (mod && e.key === 'z' && !e.shiftKey) {
        e.preventDefault();
        undo();
    } else if ((mod && e.key === 'z' && e.shiftKey) || (e.ctrlKey && e.key === 'y')) {
        e.preventDefault();
        redo();
    }
});

// Перехват CSS от модели
const originalFetch = window.fetch;
window.fetch = async function(...args) {
    const res = await originalFetch.apply(this, args);
    if (args[0] === '/css' && args[1]?.method === 'POST') {
        setTimeout(() => saveState(args[1].body), 50);
    }
    return res;
};

// Инициализация
(async function() {
    try {
        const res = await fetch('/css');
        const css = await res.text();
        if (css) { cssHistory = [css]; cssHistoryIndex = 0; }
    } catch (e) {}
})();
// --- КОНЕЦ ---

input.focus();
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
@app.route('/css', methods=['GET', 'POST'])
def handle_css():
    if request.method == 'POST':
        css_data = request.get_data(as_text=True)
        try:
            CSS_FILE.write_text(css_data, encoding='utf-8')
            return '', 200
        except Exception as e:
            return str(e), 500
    else:
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
