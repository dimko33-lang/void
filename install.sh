#!/bin/bash
set -e

[ "$EUID" -ne 0 ] && echo "run as root" && exit 1

KEY="$1"
[ -z "$KEY" ] && echo "usage: curl -s URL | sudo bash -s -- KEY" && exit 1

systemctl stop void 2>/dev/null || true
systemctl disable void 2>/dev/null || true
rm -f /etc/systemd/system/void.service
rm -rf /opt/void
systemctl daemon-reload

apt update
apt install -y python3 python3-venv python3-pip

mkdir -p /opt/void/voids
cd /opt/void

echo "KIMI_API_KEY=$KEY" > .env
chmod 600 .env

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install flask requests python-dotenv

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

VOIDS.mkdir(exist_ok=True)

memory = []
if MEM.exists():
    try: memory = json.loads(MEM.read_text())
    except: pass

def save(): MEM.write_text(json.dumps(memory, ensure_ascii=False))

class Agent:
    def __init__(self):
        self.key = os.getenv("KIMI_API_KEY","").strip()
        self.url = "https://api.moonshot.ai/v1/chat/completions"
        self.model = "kimi-k2.5"

    def stream(self, messages):
        r = requests.post(self.url,
            headers={"Authorization":f"Bearer {self.key}"},
            json={"model":self.model,"messages":messages,"stream":True},
            stream=True, timeout=120)
        r.raise_for_status()
        for l in r.iter_lines(decode_unicode=True):
            if l and l.startswith("data: "):
                d = l[6:]
                if d=="[DONE]": break
                try:
                    c = json.loads(d)["choices"][0]["delta"].get("content","")
                    if c: yield c
                except: pass

agent = Agent()
app = Flask(__name__)

HTML = f"""<!DOCTYPE html><html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
*{{margin:0;padding:0;box-sizing:border-box}}
html,body{{background:#000;color:#e0e0e0;font:14px monospace}}
#h{{font-size:10px;color:#555;line-height:1;margin:0}}
#m{{white-space:pre-wrap;line-height:1.5;margin:0;padding:0}}
.sep{{line-height:1;margin:0}}
#i{{display:flex}}
#e{{flex:1;background:transparent;border:none;color:#e0e0e0;outline:none}}
</style>
<link rel="stylesheet" href="/css" id="c">
</head><body>
<div id="h">VOID · kimi-k2.5 · {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</div>
<div id="m"><div class="sep">***</div></div>
<div id="i"><span>></span><div id="e" contenteditable></div></div>
<script>
const m=document.getElementById('m'),e=document.getElementById('e')
let lock=false

function add(r,t){
 let d=document.createElement('div')
 d.textContent=(r==='u'?'> ':'~ ')+t
 m.appendChild(d)
 let s=document.createElement('div')
 s.className='sep';s.textContent='***'
 m.appendChild(s)
 scrollTo(0,document.body.scrollHeight)
}

async function send(){
 let t=e.innerText.trim()
 if(!t||lock)return
 lock=true;e.innerText=''
 add('u',t)
 let d=document.createElement('div')
 d.textContent='~ '
 m.appendChild(d)

 let r=await fetch('/chat',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({message:t})})
 let rd=r.body.getReader(),dec=new TextDecoder(),full=''
 while(1){
  let {done,value}=await rd.read()
  if(done)break
  let c=dec.decode(value,{stream:true})
  full+=c;d.textContent='~ '+full
 }
 let s=document.createElement('div')
 s.className='sep';s.textContent='***'
 m.appendChild(s)
 lock=false;e.focus()
}

e.onkeydown=x=>{if(x.key==='Enter'&&!x.shiftKey){x.preventDefault();send()}}
</script>
</body></html>"""

@app.route('/')
def i(): return HTML

@app.route('/css')
def css(): return Response(CSS.read_text() if CSS.exists() else '',mimetype='text/css')

@app.route('/chat',methods=['POST'])
def chat():
    t=request.json.get('message','').strip()
    if not t: return '',400
    memory.append({"role":"user","content":t}); save()
    def g():
        full=""
        for c in agent.stream(memory):
            full+=c; yield c
        memory.append({"role":"assistant","content":full}); save()
    return Response(stream_with_context(g()),mimetype='text/plain')

app.run("0.0.0.0",42424)
EOF

cat > /etc/systemd/system/void.service << EOF
[Unit]
Description=void
After=network.target
[Service]
WorkingDirectory=/opt/void
EnvironmentFile=/opt/void/.env
ExecStart=/opt/void/venv/bin/python3 /opt/void/void.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable void
systemctl start void

IP=$(hostname -I | awk '{print $1}')
echo "http://$IP:42424"
