#!/usr/bin/env python3
"""NASSAV 授权发码服务器（独立部署，不进主应用镜像）。

功能：
- 网页发码：输入设备码 + 有效期（天数，0=永久）→ 生成授权码
- 设备心跳：主应用定期 POST /api/checkin 上报在线状态（设备码/主机名/版本/IP）
- 在线状态：授权记录表实时显示各设备在线/离线与最后上线时间
- 吊销管理：维护设备吊销名单，支持一键拉黑/解除（行内直接吊销）；主应用拉取名单或心跳响应即时生效
- 公开端点 /revocation.json：主应用通过 LICENSE_REVOCATION_URL 定期拉取
- 密码保护：环境变量 LICENSE_SERVER_PASSWORD
- 私钥：环境变量 LICENSE_PRIVATE_KEY_HEX，或文件 {LICENSE_DATA_DIR}/nassav_private_key.hex
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import time
from datetime import datetime, timedelta, timezone
from functools import wraps

from flask import Flask, redirect, render_template_string, request, session, url_for

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ed25519 import sign

DATA_DIR = os.environ.get("LICENSE_DATA_DIR", "/data")
PRIV_HEX = os.environ.get("LICENSE_PRIVATE_KEY_HEX", "").strip()
if not PRIV_HEX:
    with open(os.path.join(DATA_DIR, "nassav_private_key.hex"), encoding="utf-8") as f:
        PRIV_HEX = f.read().strip()
PASSWORD = os.environ.get("LICENSE_SERVER_PASSWORD", "")
if not PASSWORD:
    raise SystemExit("请通过环境变量 LICENSE_SERVER_PASSWORD 设置访问密码")
REV_PATH = os.path.join(DATA_DIR, "revocation.json")
REC_PATH = os.path.join(DATA_DIR, "records.json")

app = Flask(__name__)
app.secret_key = hashlib.sha256(("nassav-license-server:" + PASSWORD).encode()).digest()


@app.template_filter("timestamp2date")
def _ts2date(v):
    try:
        return datetime.fromtimestamp(int(v), tz=timezone(timedelta(hours=8))).strftime("%Y-%m-%d")
    except Exception:
        return "-"


@app.template_filter("timestamp2datetime")
def _ts2datetime(v):
    try:
        return datetime.fromtimestamp(int(v), tz=timezone(timedelta(hours=8))).strftime("%Y-%m-%d %H:%M")
    except Exception:
        return "-"


def load_rev():
    try:
        with open(REV_PATH, encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and isinstance(data.get("revoked"), list):
            return data
    except Exception:
        pass
    return {"revoked": [], "updated_at": 0}


def save_rev(revoked):
    data = {"revoked": sorted(set(str(x).strip() for x in revoked if str(x).strip())),
            "updated_at": int(time.time())}
    os.makedirs(DATA_DIR, exist_ok=True)
    tmp = REV_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, REV_PATH)
    return data


def load_records():
    if not os.path.exists(REC_PATH):
        return []
    try:
        with open(REC_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return []


def save_records(recs):
    os.makedirs(DATA_DIR, exist_ok=True)
    tmp = REC_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(recs, f, ensure_ascii=False, indent=2)
    os.replace(tmp, REC_PATH)


def upsert_record(device_id, owner, code, days):
    device_id = device_id.strip()
    recs = [r for r in load_records() if r.get("device_id") != device_id]
    recs.insert(0, {
        "device_id": device_id,
        "owner": (owner or "").strip() or "-",
        "code": code,
        "days": days,
        "issued_at": int(time.time()),
        "expires_at": 0 if days == 0 else int(time.time()) + days * 86400,
    })
    save_records(recs)


# 设备心跳在线判定窗口：最后上线时间在窗口内视为「在线」
ONLINE_WINDOW = 30 * 60


def upsert_checkin(device_id, hostname, app_version, ip):
    """记录设备心跳。未知设备自动补一条记录（owner 为 -，便于直接吊销）。"""
    device_id = str(device_id or "").strip()
    if not device_id:
        return
    recs = load_records()
    rec = next((r for r in recs if r.get("device_id") == device_id), None)
    if rec is None:
        recs.insert(0, {"device_id": device_id, "owner": "-", "code": "", "days": 0,
                        "issued_at": int(time.time()), "expires_at": 0})
        rec = recs[0]
    rec["last_seen"] = int(time.time())
    rec["last_ip"] = str(ip or "")[:64]
    if hostname:
        rec["hostname"] = str(hostname)[:64]
    if app_version:
        rec["app_version"] = str(app_version)[:32]
    save_records(recs)


def issue(device_id, days):
    expires = 0 if days <= 0 else int(time.time()) + days * 86400
    payload = b"NASSAV1|" + device_id.strip().encode() + b"|" + str(expires).encode()
    code = base64.b64encode(payload + sign(bytes.fromhex(PRIV_HEX), payload)).decode()
    return "-".join(code[i:i + 7] for i in range(0, len(code), 7))


def auth(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if not session.get("auth"):
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return wrapper


def api_auth(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        auth_header = request.headers.get("Authorization", "")
        bearer = auth_header[7:].strip() if auth_header.lower().startswith("bearer ") else ""
        header_password = request.headers.get("X-License-Password", "")
        if not (hmac.compare_digest(header_password, PASSWORD) or hmac.compare_digest(bearer, PASSWORD)):
            return {"ok": False, "error": "授权控制台密码错误或未填写"}, 401
        return f(*args, **kwargs)
    return wrapper


def records_snapshot():
    rev = load_rev()
    revoked_set = set(rev["revoked"])
    records = sorted(load_records(), key=lambda r: (r.get("last_seen") or 0, r.get("issued_at", 0)), reverse=True)
    now = int(time.time())
    online_set = {r["device_id"] for r in records
                  if r.get("last_seen") and now - int(r["last_seen"]) <= ONLINE_WINDOW}
    enriched = []
    for record in records:
        item = dict(record)
        device_id = str(item.get("device_id", "")).strip()
        item["online"] = device_id in online_set
        item["revoked"] = device_id in revoked_set
        enriched.append(item)
    return {
        "ok": True,
        "records": enriched,
        "revoked": rev["revoked"],
        "updated_at": rev["updated_at"],
        "online_count": len(online_set),
        "record_count": len(records),
        "revoked_count": len(rev["revoked"]),
        "base_url": request.host_url.rstrip("/"),
        "revocation_url": request.host_url.rstrip("/") + "/revocation.json",
    }


PAGE = """<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>NASSAV 授权管理</title>
<style>
body{font-family:-apple-system,'PingFang SC','Microsoft YaHei',sans-serif;background:#f0f4f8;margin:0;padding:24px 16px;color:#1f2937}
.wrap{max-width:1440px;margin:0 auto}
h1{font-size:20px;margin:0 0 16px}
.card{background:#fff;border-radius:12px;padding:20px;margin-bottom:16px;box-shadow:0 2px 10px rgba(15,27,61,.06)}
h2{font-size:15px;margin:0 0 12px;color:#334155}
label{display:block;font-size:13px;color:#64748b;margin:10px 0 4px}
input,textarea{width:100%;box-sizing:border-box;padding:9px 11px;border:1px solid #cbd5e1;border-radius:8px;font-size:14px}
button{background:#2563eb;color:#fff;border:0;border-radius:8px;padding:9px 18px;font-size:14px;cursor:pointer;margin-top:12px}
button.gray{background:#64748b}button.red{background:#dc2626}
.code{background:#0f172a;color:#7dd3fc;border-radius:8px;padding:12px;font-family:ui-monospace,Consolas,monospace;font-size:12px;word-break:break-all;margin-top:12px;white-space:pre-wrap}
.msg{margin-top:12px;font-size:14px}.ok{color:#16a34a}.err{color:#dc2626}
li{font-family:ui-monospace,monospace;font-size:12px;margin:4px 0;display:flex;justify-content:space-between;gap:8px}
ul{list-style:none;padding:0;margin:0}
form.inline{display:inline}
.hint{font-size:12px;color:#94a3b8;margin-top:6px}
.tblwrap{overflow-x:auto;margin-top:10px}
table.tbl{width:100%;border-collapse:collapse;font-size:13px;min-width:560px}
.tbl th{font-size:12px;color:#64748b;text-align:left;padding:6px 8px;border-bottom:2px solid #e2e8f0;white-space:nowrap}
.tbl td{padding:8px;border-bottom:1px solid #eef2f7;vertical-align:top}
.tbl .mono{font-family:ui-monospace,Consolas,monospace;font-size:11px;word-break:break-all}
.tag{display:inline-block;padding:2px 8px;border-radius:10px;font-size:12px;white-space:nowrap}
.tag.ok{background:#dcfce7;color:#15803d}.tag.bad{background:#fee2e2;color:#b91c1c}
.tag.gray{background:#e2e8f0;color:#64748b}
button.mini{padding:3px 10px;margin:0;font-size:12px;white-space:nowrap}
.tbl form.inline{display:inline-block;margin:0 2px 2px 0}
.tbl td:last-child{white-space:nowrap}
</style>
<script>
function legacyCopy(value) {
  const input = document.createElement('textarea');
  input.value = value;
  input.setAttribute('readonly', '');
  input.style.position = 'fixed';
  input.style.top = '0';
  input.style.left = '0';
  input.style.width = '2em';
  input.style.height = '2em';
  input.style.padding = '0';
  input.style.border = '0';
  input.style.outline = '0';
  input.style.boxShadow = 'none';
  input.style.background = 'transparent';
  document.body.appendChild(input);
  input.focus();
  input.select();
  input.setSelectionRange(0, input.value.length);
  const ok = document.execCommand && document.execCommand('copy');
  document.body.removeChild(input);
  return ok;
}
function markCopy(button, text) {
  button.textContent = text;
  setTimeout(() => { button.textContent = button.dataset.label || '复制'; }, 1600);
}
function copyCode(button, text) {
  const value = String(text || button.dataset.c || '').trim();
  if (!value) return false;
  if (legacyCopy(value)) {
    markCopy(button, '已复制');
    return false;
  }
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(value).then(() => {
      markCopy(button, '已复制');
    }).catch(() => {
      markCopy(button, '复制失败');
      window.prompt('自动复制失败，请手动复制授权码：', value);
    });
  } else {
    markCopy(button, '手动复制');
    window.prompt('请手动复制授权码：', value);
  }
  return false;
}
document.addEventListener('click', function(event) {
  const button = event.target && event.target.closest ? event.target.closest('[data-copy-code]') : null;
  if (button) {
    event.preventDefault();
    copyCode(button);
  }
});
</script></head><body><div class="wrap">
<h1>NASSAV 授权管理台</h1>

<div class="card">
<h2>签发授权码</h2>
<form method="post" action="/issue">
<label>设备码（对方授权页上复制）</label>
<input name="device_id" placeholder="例如 a347c93c-11c2-4c30-bc8a-964279969dd1" required>
<label>所属人姓名（备注，显示在授权记录里）</label>
<input name="owner" placeholder="例如 张三">
<label>有效期（天数，留空或 0 = 永久）</label>
<input name="days" placeholder="365">
<button type="submit">生成授权码</button>
</form>
{% if issued %}
<div class="msg ok">已签发（{{ issued_exp }}）：</div>
<div class="code" id="lic">{{ issued }}</div>
<button type="button" class="gray" data-label="复制授权码" data-c="{{ issued }}" data-copy-code>复制授权码</button>
{% endif %}
{% if issue_err %}<div class="msg err">{{ issue_err }}</div>{% endif %}
</div>

<div class="card">
<h2>授权记录与设备在线状态</h2>
<p class="hint">同一设备码重复签发时覆盖旧记录（续期）。设备每 3 分钟向本台上报一次心跳，30 分钟内有心跳视为「在线」。状态「已吊销」表示该设备码在下方吊销名单中，名单更新后设备最迟约 3 分钟内失效且无法再次激活。</p>
<div class="tblwrap">
<table class="tbl">
<tr><th>所属人</th><th>设备码</th><th>有效期</th><th>在线状态</th><th>设备详情</th><th>状态</th><th>激活码</th><th></th></tr>
{% for r in records %}
<tr>
<td>{{ r.owner or '-' }}</td>
<td class="mono">{{ r.device_id }}</td>
<td>{{ '永久' if r.expires_at == 0 else (r.expires_at | timestamp2date) }}</td>
<td>{% if r.last_seen %}{% if r.device_id in online_set %}<span class="tag ok">在线</span>{% else %}<span class="tag gray">离线</span>{% endif %}<div class="hint">{{ r.last_seen | timestamp2datetime }}</div>{% else %}<span class="tag gray">从未上线</span>{% endif %}</td>
<td class="mono">{% if r.hostname or r.app_version %}{{ r.hostname or '-' }}<br>v{{ r.app_version or '-' }}<br>{{ r.last_ip or '-' }}{% else %}-{% endif %}</td>
<td>{% if r.device_id in revoked_set %}<span class="tag bad">已吊销</span>{% else %}<span class="tag ok">正常</span>{% endif %}</td>
<td>{% if r.code %}<button type="button" class="gray mini" data-label="复制" data-c="{{ r.code }}" data-copy-code>复制</button>{% else %}-{% endif %}</td>
<td>
{% if r.device_id in revoked_set %}
<form class="inline" method="post" action="/unrevoke"><input type="hidden" name="device_id" value="{{ r.device_id }}"><button class="gray mini" type="submit">解除吊销</button></form>
{% else %}
<form class="inline" method="post" action="/revoke" onsubmit="return confirm('立即吊销该设备？设备最迟约 3 分钟内失去授权，且无法再次激活。')"><input type="hidden" name="device_id" value="{{ r.device_id }}"><button class="red mini" type="submit">立即吊销</button></form>
{% endif %}
<form class="inline" method="post" action="/del_record" onsubmit="return confirm('删除该条授权记录？（不影响已激活设备的授权）')"><input type="hidden" name="device_id" value="{{ r.device_id }}"><button class="gray mini" type="submit" title="删除记录">删</button></form>
</td>
</tr>
{% endfor %}
{% if not records %}<tr><td colspan="8" style="color:#94a3b8">暂无记录</td></tr>{% endif %}
</table>
</div>
</div>

<div class="card">
<h2>吊销名单（远程作废）</h2>
<p class="hint">主应用每 3 分钟拉取一次名单（心跳响应同时携带名单），名单内的设备码约 3 分钟内失去授权且无法再次激活。主应用侧通过环境变量 LICENSE_REVOCATION_URL 指向本页地址。</p>
<form method="post" action="/revoke">
<label>要吊销的设备码</label>
<input name="device_id" placeholder="设备码" required>
<button class="red" type="submit">加入吊销名单</button>
</form>
<ul>
{% for d in revoked %}
<li><span>{{ d }}</span>
<form class="inline" method="post" action="/unrevoke"><input type="hidden" name="device_id" value="{{ d }}"><button class="gray" type="submit" style="padding:3px 10px;margin:0;font-size:12px">解除</button></form>
</li>
{% endfor %}
{% if not revoked %}<li style="color:#94a3b8;font-family:inherit">（空）</li>{% endif %}
</ul>
</div>

<div class="card">
<h2>吊销名单导出地址</h2>
<div class="code">{{ base_url }}/revocation.json</div>
<p class="hint">把该地址设为各部署实例的环境变量 LICENSE_REVOCATION_URL（需重新创建容器生效）。</p>
</div>
</div></body></html>"""

LOGIN = """<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>登录</title>
<style>body{font-family:-apple-system,'PingFang SC',sans-serif;background:#f0f4f8;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}
.card{background:#fff;border-radius:12px;padding:28px;width:320px;box-shadow:0 2px 10px rgba(15,27,61,.06)}
h1{font-size:17px;margin:0 0 14px}input{width:100%;box-sizing:border-box;padding:9px 11px;border:1px solid #cbd5e1;border-radius:8px;margin-bottom:10px}
button{width:100%;background:#2563eb;color:#fff;border:0;border-radius:8px;padding:10px;font-size:14px;cursor:pointer}
.err{color:#dc2626;font-size:13px;margin-bottom:8px}</style></head><body>
<div class="card"><h1>NASSAV 授权管理台</h1>
{% if err %}<div class="err">密码错误</div>{% endif %}
<form method="post" action="/login"><input type="password" name="password" placeholder="访问密码" autofocus><button>登录</button></form>
</div></body></html>"""


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.get("/api/admin/health")
@api_auth
def api_admin_health():
    return {"ok": True, "service": "nassav-license-server"}


@app.get("/api/admin/summary")
@api_auth
def api_admin_summary():
    return records_snapshot()


@app.post("/api/admin/issue")
@api_auth
def api_admin_issue():
    data = request.get_json(silent=True) or {}
    device_id = str(data.get("device_id", "")).strip()
    owner = str(data.get("owner", "")).strip()
    try:
        days = int(str(data.get("days", "0")).strip() or 0)
    except ValueError:
        days = -1
    if len(device_id) < 8:
        return {"ok": False, "error": "设备码格式不正确"}, 400
    if days < 0:
        return {"ok": False, "error": "有效期天数不正确"}, 400
    code = issue(device_id, days)
    upsert_record(device_id, owner, code, days)
    payload = records_snapshot()
    payload.update({
        "issued": code,
        "expires_text": "永久有效" if days == 0 else f"{days} 天",
    })
    return payload


@app.post("/api/admin/revoke")
@api_auth
def api_admin_revoke():
    data = request.get_json(silent=True) or {}
    device_id = str(data.get("device_id", "")).strip()
    if len(device_id) < 8:
        return {"ok": False, "error": "设备码格式不正确"}, 400
    rev = load_rev()
    save_rev(list(rev["revoked"]) + [device_id])
    return records_snapshot()


@app.post("/api/admin/unrevoke")
@api_auth
def api_admin_unrevoke():
    data = request.get_json(silent=True) or {}
    device_id = str(data.get("device_id", "")).strip()
    if len(device_id) < 8:
        return {"ok": False, "error": "设备码格式不正确"}, 400
    rev = load_rev()
    save_rev([d for d in rev["revoked"] if d != device_id])
    return records_snapshot()


@app.post("/api/admin/delete-record")
@api_auth
def api_admin_delete_record():
    data = request.get_json(silent=True) or {}
    device_id = str(data.get("device_id", "")).strip()
    if len(device_id) < 8:
        return {"ok": False, "error": "设备码格式不正确"}, 400
    save_records([r for r in load_records() if r.get("device_id") != device_id])
    return records_snapshot()


@app.route("/login", methods=["GET", "POST"])
def login():
    err = False
    if request.method == "POST":
        if hmac.compare_digest(str(request.form.get("password", "")), PASSWORD):
            session["auth"] = True
            session.permanent = True
            return redirect(url_for("index"))
        err = True
    return render_template_string(LOGIN, err=err)


@app.get("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


@app.get("/")
@auth
def index():
    rev = load_rev()
    revoked_set = set(rev["revoked"])
    records = sorted(load_records(), key=lambda r: (r.get("last_seen") or 0, r.get("issued_at", 0)), reverse=True)
    now = int(time.time())
    online_set = {r["device_id"] for r in records
                  if r.get("last_seen") and now - int(r["last_seen"]) <= ONLINE_WINDOW}
    return render_template_string(PAGE, issued=request.args.get("issued", ""),
                                  issued_exp=request.args.get("exp", ""),
                                  issue_err=request.args.get("err", ""),
                                  revoked=rev["revoked"],
                                  records=records,
                                  revoked_set=revoked_set,
                                  online_set=online_set,
                                  base_url=request.host_url.rstrip("/"))


@app.post("/issue")
@auth
def do_issue():
    device_id = str(request.form.get("device_id", "")).strip()
    owner = str(request.form.get("owner", "")).strip()
    try:
        days = int(str(request.form.get("days", "0")).strip() or 0)
    except ValueError:
        days = -1
    if len(device_id) < 8:
        return redirect(url_for("index", err="设备码格式不正确"))
    if days < 0:
        return redirect(url_for("index", err="有效期天数不正确"))
    code = issue(device_id, days)
    upsert_record(device_id, owner, code, days)
    exp = "永久有效" if days == 0 else f"{days} 天"
    return redirect(url_for("index", issued=code, exp=exp))


@app.post("/del_record")
@auth
def do_del_record():
    device_id = str(request.form.get("device_id", "")).strip()
    if device_id:
        save_records([r for r in load_records() if r.get("device_id") != device_id])
    return redirect(url_for("index"))


@app.post("/revoke")
@auth
def do_revoke():
    device_id = str(request.form.get("device_id", "")).strip()
    if device_id:
        rev = load_rev()
        save_rev(list(rev["revoked"]) + [device_id])
    return redirect(url_for("index"))


@app.post("/unrevoke")
@auth
def do_unrevoke():
    device_id = str(request.form.get("device_id", "")).strip()
    rev = load_rev()
    save_rev([d for d in rev["revoked"] if d != device_id])
    return redirect(url_for("index"))


@app.get("/revocation.json")
def revocation_json():
    rev = load_rev()
    return {"revoked": rev["revoked"], "updated_at": rev["updated_at"]}


@app.post("/api/checkin")
def api_checkin():
    """主应用设备心跳：上报在线状态，响应携带最新吊销名单（约 3 分钟内吊销即时生效）。"""
    data = request.get_json(silent=True) or {}
    device_id = str(data.get("device_id", "")).strip()
    if len(device_id) < 8 or len(device_id) > 128:
        return {"ok": False, "error": "device_id 无效"}, 400
    ip = request.headers.get("X-Forwarded-For", request.remote_addr or "").split(",")[0].strip()
    upsert_checkin(device_id,
                   hostname=str(data.get("hostname", ""))[:64],
                   app_version=str(data.get("app_version", ""))[:32],
                   ip=ip)
    rev = load_rev()
    return {"ok": True, "revoked": rev["revoked"], "updated_at": rev["updated_at"]}


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8789, threaded=True)
