#!/bin/bash
set -e

[ "$EUID" -ne 0 ] && echo "run as root" && exit 1

KEY="$1"
[ -z "$KEY" ] && echo "Usage: curl -s URL | sudo bash -s -- \"KEY\"" && exit 1

systemctl stop void 2>/dev/null || true
systemctl disable void 2>/dev/null || true
rm -f /etc/systemd/system/void.service
rm -rf /opt/void
systemctl daemon-reload

apt update
apt install -y python3 python3-pip python3-venv

mkdir -p /opt/void/voids
cd /opt/void

echo "KIMI_API_KEY=$KEY" > .env
chmod 600 .env

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install flask requests python-dotenv

cat > void.py << 'PYEOF'
#!/usr/bin/env python3
import json
import os
import re
import subprocess
from pathlib import Path
from datetime import datetime
import requests
from dotenv import load_dotenv
from flask import Flask, Response, jsonify, request, stream_with_context

load_dotenv()

BASE_DIR = Path(__file__).parent
VOIDS_DIR = BASE_DIR / "voids"
CSS_FILE = VOIDS_DIR / "current.css"

VOIDS_DIR.mkdir(exist_ok=True)

conversation_history = []
thinking_enabled = False
memory_enabled = False

class VoidAgent:
    def __init__(self):
        self.api_key = os.getenv("KIMI_API_KEY", "").strip()
        self.model = "kimi-k2.5"
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

    def chat_stream(self, messages):
        yield from self._call_llm_stream(messages)

agent = VoidAgent()
app = Flask(__name__)

MODEL_NAME = "kimi-k2.5"
PROVIDER = "Moonshot"

HTML = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>VOID</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500&display=swap');
* { box-sizing: border-box; margin: 0; padding: 0; }
html, body { background: #0c0c0c; color: #d4d4d4; font-family: 'JetBrains Mono', monospace; font-size: 14px; line-height: 1.5; padding: 6px 12px; min-height: 100vh; }
#header { color: #4a4a4a; font-size: 10px; margin: 0; padding: 0; line-height: 1.3; user-select: text; }
#manuscript { margin: 0; padding: 0; user-select: text; }
.msg { margin: 0; padding: 0; line-height: 1.6; white-space: pre-wrap; word-break: break-word; user-select: text; }
.msg.user { color: #9a9a9a; }
.msg.assistant { color: #d4d4d4; }
.msg.system { color: #6a6a6a; font-style: italic; }
.msg .prefix { color: #5a5a5a; user-select: text; }
.separator { margin: 0; padding: 0; line-height: 1.5; color: transparent; user-select: text; font-size: 12px; }
#input-line { display: flex; align-items: center; margin: 0; padding: 0; color: #6a6a6a; }
.prompt { margin-right: 8px; user-select: none; color: #5a5a5a; }
#editable-input { background: transparent; border: none; color: #d4d4d4; font-family: inherit; font-size: 14px; flex-grow: 1; outline: none; caret-color: #a0a0a0; padding: 0; min-height: 1.5em; user-select: text; }
#editable-input:empty::before { content: attr(data-placeholder); color: #4a4a4a; }
</style>
<link rel="stylesheet" href="/css" id="dynamic-css">
</head>
<body>
<div id="header">VOID · """ + MODEL_NAME + """ (""" + PROVIDER + """) · <span id="thinking-status">thinking: off</span> · <span id="memory-status">memory: off</span> · """ + datetime.now().strftime('%Y-%m-%d %H:%M:%S') + """</div>
<div id="manuscript"><div class="separator">***</div></div>
<div id="input-line"><span class="prompt">></span><div id="editable-input" contenteditable="true" data-placeholder=" "></div></div>
<script>
const manuscript = document.getElementById('manuscript');
const editableInput = document.getElementById('editable-input');
let isSending = false;

async function loadHistory() {
    const res = await fetch('/history');
    const data = await res.json();
    manuscript.innerHTML = '<div class="separator">***</div>';
    data.history.forEach(msg => addMessageToUI(msg.role, msg.content, false));
    document.getElementById('thinking-status').textContent = `thinking: ${data.thinking ? 'on' : 'off'}`;
    document.getElementById('memory-status').textContent = `memory: ${data.memory ? 'on' : 'off'}`;
}

function addMessageToUI(role, content, scroll = true) {
    const msgDiv = document.createElement('div');
    msgDiv.className = `msg ${role}`;
    const prefixSpan = document.createElement('span');
    prefixSpan.className = 'prefix';
    prefixSpan.textContent = role === 'user' ? '> ' : '~ ';
    msgDiv.appendChild(prefixSpan);
    msgDiv.appendChild(document.createTextNode(content));
    manuscript.appendChild(msgDiv);
    const sep = document.createElement('div');
    sep.className = 'separator';
    sep.textContent = '***';
    manuscript.appendChild(sep);
    if (scroll) window.scrollTo(0, document.body.scrollHeight);
}

function refreshCSS() { document.getElementById('dynamic-css').href = '/css?' + Date.now(); }

async function sendMessage() {
    const text = editableInput.innerText.trim();
    if (!text || isSending) return;
    isSending = true;
    editableInput.innerText = '';
    
    if (text.startsWith('/')) {
        const res = await fetch('/command', { 
            method: 'POST', 
            headers: {'Content-Type': 'application/json'}, 
            body: JSON.stringify({command: text}) 
        });
        const data = await res.json();
        if (data.clear) manuscript.innerHTML = '<div class="separator">***</div>';
        else addMessageToUI('system', data.message);
        document.getElementById('thinking-status').textContent = `thinking: ${data.thinking ? 'on' : 'off'}`;
        document.getElementById('memory-status').textContent = `memory: ${data.memory ? 'on' : 'off'}`;
        isSending = false;
        editableInput.focus();
        return;
    }
    
    addMessageToUI('user', text);
    const assistantDiv = document.createElement('div');
    assistantDiv.className = 'msg assistant';
    const prefixSpan = document.createElement('span');
    prefixSpan.className = 'prefix';
    prefixSpan.textContent = '~ ';
    assistantDiv.appendChild(prefixSpan);
    manuscript.appendChild(assistantDiv);
    
    try {
        const res = await fetch('/chat', { 
            method: 'POST', 
            headers: {'Content-Type': 'application/json'}, 
            body: JSON.stringify({message: text}) 
        });
        if (!res.ok) throw new Error('Chat failed');
        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let fullResponse = '';
        while (true) {
            const {done, value} = await reader.read();
            if (done) break;
            const chunk = decoder.decode(value, {stream: true});
            fullResponse += chunk;
            assistantDiv.innerHTML = '<span class="prefix">~ </span>' + fullResponse;
            window.scrollTo(0, document.body.scrollHeight);
        }
        const sep = document.createElement('div');
        sep.className = 'separator';
        sep.textContent = '***';
        manuscript.appendChild(sep);
        refreshCSS();
    } catch (e) {
        assistantDiv.innerHTML = '<span class="prefix">~ </span>[error]';
    } finally {
        isSending = false;
        editableInput.focus();
    }
}

editableInput.addEventListener('keydown', e => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
});

document.addEventListener('click', e => {
    const isTextSelection = window.getSelection().toString().length > 0;
    if (!isTextSelection && !e.target.closest('.msg') && !e.target.closest('#editable-input') && !e.target.closest('#header')) {
        editableInput.focus();
    }
});

document.addEventListener('keydown', e => {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'a') {
        e.preventDefault();
        const selection = window.getSelection();
        const range = document.createRange();
        const header = document.getElementById('header');
        range.setStartBefore(header);
        range.setEndAfter(manuscript.lastChild || manuscript);
        selection.removeAllRanges();
        selection.addRange(range);
    }
});

document.addEventListener('copy', e => {
    const selection = window.getSelection();
    e.clipboardData.setData('text/plain', selection.toString());
    e.preventDefault();
});

loadHistory();
editableInput.focus();
</script>
</body>
</html>
"""

def parse_and_execute_tools(content):
    changed = False
    for match in re.finditer(r'\[CMD\](.*?)\[/CMD\]', content, re.DOTALL):
        cmd = match.group(1).strip()
        try:
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30, cwd=VOIDS_DIR)
            output = result.stdout + result.stderr
            if not output: output = "(no output)"
            content = content.replace(match.group(0), f"[executed: {cmd}]\n{output}")
        except Exception as e:
            content = content.replace(match.group(0), f"[error: {cmd}]\n{str(e)}")
    for match in re.finditer(r'\[CSS\](.*?)\[/CSS\]', content, re.DOTALL):
        css = match.group(1).strip()
        try:
            CSS_FILE.write_text(css, encoding='utf-8')
            content = content.replace(match.group(0), "[style applied]")
            changed = True
        except:
            pass
    return content, changed

@app.route('/')
def index(): return HTML

@app.route('/css')
def get_css():
    if CSS_FILE.exists(): return Response(CSS_FILE.read_text(), mimetype='text/css')
    return '', 200

@app.route('/history')
def get_history():
    return jsonify({
        'history': conversation_history,
        'thinking': thinking_enabled,
        'memory': memory_enabled
    })

@app.route('/command', methods=['POST'])
def handle_command():
    global thinking_enabled, memory_enabled, conversation_history
    data = request.get_json()
    cmd = data.get('command', '').lower().strip()
    
    if cmd == '/t':
        thinking_enabled = not thinking_enabled
        status = 'on' if thinking_enabled else 'off'
        return jsonify({'thinking': thinking_enabled, 'memory': memory_enabled, 'message': f'thinking {status}'})
    elif cmd == '/m':
        memory_enabled = not memory_enabled
        if not memory_enabled:
            conversation_history = []
        status = 'on' if memory_enabled else 'off'
        msg = f'memory {status}' + (' (cleared)' if not memory_enabled else '')
        return jsonify({'thinking': thinking_enabled, 'memory': memory_enabled, 'message': msg})
    elif cmd == '/c':
        conversation_history = []
        return jsonify({'thinking': thinking_enabled, 'memory': memory_enabled, 'clear': True})
    else:
        return jsonify({'thinking': thinking_enabled, 'memory': memory_enabled, 'message': '?'})

@app.route('/chat', methods=['POST'])
def chat():
    global conversation_history
    data = request.get_json()
    user_msg = data.get('message', '').strip()
    if not user_msg: return jsonify({'error': 'empty'}), 400
    
    conversation_history.append({"role": "user", "content": user_msg})
    
    def generate():
        global conversation_history
        full_response = ""
        css_changed = False
        try:
            messages = conversation_history if memory_enabled else [{"role": "user", "content": user_msg}]
            for chunk in agent.chat_stream(messages):
                full_response += chunk
                yield chunk
            if '[CMD]' in full_response or '[CSS]' in full_response:
                full_response, css_changed = parse_and_execute_tools(full_response)
            conversation_history.append({"role": "assistant", "content": full_response})
            if css_changed: yield "\n\n✨ room updated"
        except Exception as e:
            error_msg = f"[error]: {str(e)}"
            conversation_history.append({"role": "assistant", "content": error_msg})
            yield error_msg
    
    return Response(stream_with_context(generate()), mimetype='text/plain; charset=utf-8')

if __name__ == '__main__':
    host = os.getenv('HOST', '0.0.0.0')
    port = int(os.getenv('PORT', 42424))
    app.run(host=host, port=port, debug=False, threaded=True)
PYEOF

cat > /etc/systemd/system/void.service << EOF
[Unit]
Description=Void
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
    journalctl -u void.service -n 10 --no-pager
    exit 1
fi
