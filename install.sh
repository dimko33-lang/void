#!/usr/bin/env python3
"""
VOID — Kimi K2.5
"""
import json
import os
import re
import subprocess
from pathlib import Path
from typing import List, Generator
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

    def _call_llm_stream(self, messages: List[dict]) -> Generator[str, None, None]:
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

    def chat_stream(self, messages: List[dict]) -> Generator[str, None, None]:
        yield from self._call_llm_stream(messages)

agent = VoidAgent()
app = Flask(__name__)

MODEL_NAME = "kimi-k2.5"
PROVIDER = "Moonshot"

HTML = f"""<!DOCTYPE html><html lang="ru"><head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>VOID</title>
<style>
* {{ margin:0; padding:0; box-sizing:border-box; }}

html, body {{
    background:#000;
    color:#e0e0e0;
    font-family: monospace;
    font-size:14px;
}}

#manuscript-header {{
    color:#4a4a4a;
    font-size:10px;
    margin:0;
    padding:0;
    line-height:1.2;
}}

#manuscript {{
    white-space:pre-wrap;
    word-break:break-word;
    line-height:1.6;
    margin:0;
    padding:0;
}}

.msg {{
    margin:0;
}}

.separator {{
    margin:0;
    padding:0;
    line-height:1;
}}

#input-line {{
    display:flex;
    margin:0;
}}

.prompt {{
    margin-right:6px;
}}

#editable-input {{
    background:transparent;
    border:none;
    color:#e0e0e0;
    font-family:inherit;
    font-size:14px;
    flex-grow:1;
    outline:none;
}}
</style>
<link rel="stylesheet" href="/css" id="dynamic-css">
</head>
<body>
<div id="manuscript-header">VOID · {MODEL_NAME} ({PROVIDER}) · {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</div>
<div id="manuscript"><div class="separator">***</div></div>
<div id="input-line"><span class="prompt">></span><div id="editable-input" contenteditable="true"></div></div>

<script>
const manuscript = document.getElementById('manuscript');
const editableInput = document.getElementById('editable-input');
let isSending = false;

function refreshCSS() {{
    document.getElementById('dynamic-css').href = '/css?' + Date.now();
}}

function addMessageToUI(role, content) {{
    const msg = document.createElement('div');
    msg.className = 'msg';
    msg.textContent = (role === 'user' ? '> ' : '~ ') + content;
    manuscript.appendChild(msg);

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
    addMessageToUI('user', text);

    const assistant = document.createElement('div');
    assistant.className = 'msg';
    assistant.textContent = '~ ';
    manuscript.appendChild(assistant);

    const res = await fetch('/chat', {{
        method:'POST',
        headers:{{'Content-Type':'application/json'}},
        body:JSON.stringify({{message:text}})
    }});

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let full = '';

    while (true) {{
        const {{done, value}} = await reader.read();
        if (done) break;
        const chunk = decoder.decode(value, {{stream:true}});
        full += chunk;
        assistant.textContent = '~ ' + full;
    }}

    const sep = document.createElement('div');
    sep.className = 'separator';
    sep.textContent = '***';
    manuscript.appendChild(sep);

    refreshCSS();
    isSending = false;
    editableInput.focus();
}}

editableInput.addEventListener('keydown', e => {{
    if (e.key === 'Enter' && !e.shiftKey) {{
        e.preventDefault();
        sendMessage();
    }}
}});
</script>
</body></html>"""

def parse_and_execute_tools(content: str):
    changed = False

    for match in re.finditer(r'\[CMD\](.*?)\[/CMD\]', content, re.DOTALL):
        cmd = match.group(1).strip()
        try:
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30, cwd=VOIDS_DIR)
            out = result.stdout + result.stderr or "(no output)"
            content = content.replace(match.group(0), f"[executed]\n{out}")
        except Exception as e:
            content = content.replace(match.group(0), f"[error]\n{e}")

    for match in re.finditer(r'\[CSS\](.*?)\[/CSS\]', content, re.DOTALL):
        try:
            CSS_FILE.write_text(match.group(1).strip(), encoding='utf-8')
            content = content.replace(match.group(0), "[style applied]")
            changed = True
        except Exception as e:
            content = content.replace(match.group(0), f"[css error] {e}")

    return content, changed

@app.route('/')
def index(): return HTML

@app.route('/css')
def css():
    if CSS_FILE.exists():
        return Response(CSS_FILE.read_text(), mimetype='text/css')
    return '', 200

@app.route('/chat', methods=['POST'])
def chat():
    user_msg = request.get_json().get('message', '').strip()
    if not user_msg:
        return '', 400

    memory.append({"role":"user","content":user_msg})
    save_memory()
    log_to_file('user', user_msg)

    def generate():
        full = ""
        css_changed = False

        for chunk in agent.chat_stream(memory):
            full += chunk
            yield chunk

        if '[CMD]' in full or '[CSS]' in full:
            full, css_changed = parse_and_execute_tools(full)

        memory.append({"role":"assistant","content":full})
        save_memory()
        log_to_file('assistant', full)

        if css_changed:
            yield "\n\nupdated"

    return Response(stream_with_context(generate()), mimetype='text/plain')

app.run("0.0.0.0", 42424)
