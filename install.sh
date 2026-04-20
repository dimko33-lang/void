```bash
#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "run as root"
    exit 1
fi

KEY="$1"
if [ -z "$KEY" ]; then
    echo "Usage: curl -s URL | sudo bash -s -- \"API_KEY\""
    exit 1
fi

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
/opt/void/venv/bin/pip install --upgrade pip
/opt/void/venv/bin/pip install flask requests python-dotenv

cat > void.py << 'EOF'
#!/usr/bin/env python3
import json, os, re, subprocess
from pathlib import Path
from datetime import datetime
import requests
from dotenv import load_dotenv
from flask import Flask, Response, request, stream_with_context

load_dotenv()

BASE = Path(__file__).parent
VOIDS = BASE / "voids"
CSS = VOIDS / "current.css"
MEM = BASE / "memory.json"
LOG = BASE / "void.log"

VOIDS.mkdir(exist_ok=True)

memory = []
if MEM.exists():
    try:
        memory = json.loads(MEM.read_text(encoding="utf-8"))
    except:
        pass

def save():
    MEM.write_text(json.dumps(memory, ensure_ascii=False), encoding="utf-8")

def log(x):
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(x + "\n***\n")

class Agent:
    def __init__(self):
        self.key = os.getenv("KIMI_API_KEY")
        self.url = "https://api.moonshot.ai/v1/chat/completions"

    def stream(self, messages):
        r = requests.post(self.url,
            headers={"Authorization": f"Bearer {self.key}"},
            json={"model":"kimi-k2.5","messages":messages,"stream":True},
            stream=True)
        r.raise_for_status()
        for l in r.iter_lines(decode_unicode=True):
            if not l or not l.startswith("data: "): continue
            d = l[6:]
            if d == "[DONE]": break
            try:
                j = json.loads(d)
                c = j["choices"][0]["delta"].get("content","")
                if c: yield c
            except: pass

agent = Agent()
app = Flask(__name__)

HTML = f"""<!DOCTYPE html>
<html><head><meta charset="UTF-8">
<style>
body {{background:#000;color:#e0e0e0;font-family:monospace;margin:0;padding:6px}}
#screen {{white-space:pre-wrap;outline:none;caret-color:#aaa}}
.header {{color:#555}}
</style></head>
<body>

<pre id="screen" contenteditable="true">
<span class="header">VOID · kimi-k2.5 · Moonshot · {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</span>
***
> 
</pre>

<script>
const s = document.getElementById('screen');
let busy = false;

function last() {{
    let L = s.innerText.split('\\n');
    for (let i=L.length-1;i>=0;i--)
        if (L[i].startsWith('> ')) return L[i].slice(2).trim();
    return '';
}}

function add(t) {{
    s.innerText += t;
    window.scrollTo(0,document.body.scrollHeight);
}}

async function send() {{
    if (busy) return;
    let m = last();
    if (!m) return;

    busy = true;
    add("\\n~ ");

    try {{
        let r = await fetch('/chat', {{
            method:'POST',
            headers:{{'Content-Type':'application/json'}},
            body:JSON.stringify({{message:m}})
        }});

        let rd = r.body.getReader();
        let dec = new TextDecoder();

        while(true) {{
            let {{done,value}} = await rd.read();
            if (done) break;
            add(dec.decode(value,{{stream:true}}));
        }}

        add("\\n***\\n> ");
    }} catch {{
        add("[error]");
    }}

    busy = false;
}}

s.addEventListener('keydown', e=>{{
    if (e.key==='Enter') {{
        e.preventDefault();
        send();
    }}
}});
</script>

</body></html>
"""

def tools(t):
    for m in re.findall(r'\[CMD\](.*?)\[/CMD\]', t, re.DOTALL):
        try:
            r = subprocess.run(m, shell=True, capture_output=True, text=True, cwd=VOIDS)
            t = t.replace(f"[CMD]{m}[/CMD]", r.stdout+r.stderr or "(no output)")
        except Exception as e:
            t = t.replace(f"[CMD]{m}[/CMD]", str(e))
    for m in re.findall(r'\[CSS\](.*?)\[/CSS\]', t, re.DOTALL):
        try:
            CSS.write_text(m, encoding="utf-8")
            t = t.replace(f"[CSS]{m}[/CSS]", "[style]")
        except Exception as e:
            t = t.replace(f"[CSS]{m}[/CSS]", str(e))
    return t

@app.route('/')
def i(): return HTML

@app.route('/chat', methods=['POST'])
def c():
    msg = request.json.get('message','').strip()
    if not msg: return ''

    memory.append({"role":"user","content":msg})
    save()
    log(msg)

    def g():
        full=""
        for ch in agent.stream(memory):
            full+=ch
            yield ch
        if "[CMD]" in full or "[CSS]" in full:
            full = tools(full)
        memory.append({"role":"assistant","content":full})
        save()
        log(full)

    return Response(stream_with_context(g()), mimetype='text/plain')

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=42424, threaded=True)
EOF

cat > /etc/systemd/system/void.service << EOF
[Unit]
Description=Void
After=network.target

[Service]
User=root
WorkingDirectory=/opt/void
EnvironmentFile=/opt/void/.env
ExecStart=/opt/void/venv/bin/python3 /opt/void/void.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable void
systemctl restart void

IP=$(hostname -I | awk '{print $1}')
echo "http://$IP:42424"
```
