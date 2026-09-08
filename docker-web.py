import html
import hashlib
import hmac
import json
import os
import queue
import re
import shlex
import shutil
import socket
import sqlite3
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
import uuid
import base64
from datetime import datetime
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urljoin, urlparse, quote
from urllib.request import ProxyHandler, Request, build_opener, urlopen
from xml.etree import ElementTree as ET

# DNS 缓存：Docker 内部 DNS (127.0.0.11) 间歇性失败（实测 ~20% 突发失败率），
# 缓存解析结果避免重复查询；过期条目在刷新失败时兜底复用（115 IP 很少变化）
_original_getaddrinfo = socket.getaddrinfo
_dns_cache: dict = {}
_dns_cache_ttl = 1800  # 30 分钟

def _cached_getaddrinfo(host, port, *args, **kwargs):
    # key 必须包含 family/type/proto 等 hints：预热是无 hints 调用（结果可能含 UDP 条目），
    # 若与 create_connection（hints=SOCK_STREAM）共用 key，会拿到 UDP socket，
    # 导致 SSL 握手报 "only stream sockets are supported"
    cache_key = (host, port, args, tuple(sorted(kwargs.items())))
    cached = _dns_cache.get(cache_key)
    if cached:
        result, ts = cached
        if time.time() - ts < _dns_cache_ttl:
            return result
        # 缓存过期：尝试刷新；DNS 抖动刷新失败时用旧结果兜底（而不是让请求硬失败）
        try:
            fresh = _original_getaddrinfo(host, port, *args, **kwargs)
            _dns_cache[cache_key] = (fresh, time.time())
            return fresh
        except socket.gaierror:
            _dns_cache[cache_key] = (result, time.time())  # 续期，避免每次都重试
            return result
    # 无缓存：解析失败按指数退避重试（0.5s/1s/2s/4s），不缓存失败结果
    last_err = None
    for attempt in range(5):
        try:
            result = _original_getaddrinfo(host, port, *args, **kwargs)
            _dns_cache[cache_key] = (result, time.time())
            return result
        except socket.gaierror as e:
            last_err = e
            if attempt < 4:
                time.sleep(0.5 * (2 ** attempt))
    raise last_err

socket.getaddrinfo = _cached_getaddrinfo


def _dns_warmup():
    """后台预热常用域名解析，避免重启后第一波请求撞上 DNS 抖动。"""
    import threading

    def _warm():
        for host in ("webapi.115.com", "proapi.115.com", "115.com", "cdnfhnfile.115cdn.net"):
            try:
                _cached_getaddrinfo(host, 443)
            except Exception:
                pass
    threading.Thread(target=_warm, daemon=True).start()


_dns_warmup()

from flask import Flask, Response, jsonify, redirect, request, send_file, send_from_directory, session, stream_with_context

from src.scraper import Sracper


DATA_DIR = Path(os.getenv("DATA_DIR", "/data"))
MEDIA_DIR = Path(os.getenv("MEDIA_DIR", "/media"))
WORK_DIR = DATA_DIR / "work"
DB_PATH = DATA_DIR / "queue.sqlite3"
BROWSER_METADATA_PATH = DATA_DIR / "latest-browser-metadata.json"
DOWNLOADER = Path(os.getenv("M3U8_DOWNLOADER", "/app/tools/m3u8-Downloader-Go"))
CHROMIUM = os.getenv("CHROMIUM_BINARY", "/usr/bin/chromium")
CHROMEDRIVER = os.getenv("CHROMEDRIVER_BINARY", "/usr/bin/chromedriver")
DEFAULT_SOURCES = [value.strip() for value in os.getenv(
    "SCRAPER_SOURCES", "www.javbus.com,www.busdmm.ink,www.dmmsee.bond"
).split(",") if value.strip()]
MEDIA_EXTENSIONS = {".mp4", ".mkv", ".ts", ".mov", ".m4v", ".webm"}
STRM_EXTENSIONS = {".strm"}
VIDEO_EXTENSIONS = MEDIA_EXTENSIONS | STRM_EXTENSIONS
MAX_LOG = 100_000

DEFAULT_SETTINGS = {
    "threads": 2,
    "allow_duplicate": False,
    "organize_enabled": True,
    "proxy": os.getenv("HTTP_PROXY", "").strip(),
    "jable_cookie": os.getenv("JABLE_COOKIE", "").strip(),
    "failure_route_enabled": False,
    "failure_path": "/media/待整理",
    "cloud115_mode": os.getenv("CLOUD115_MODE", "bridge").strip() or "bridge",
    "cloud115_endpoint": os.getenv("CLOUD115_ENDPOINT", "").strip(),
    "cloud115_token": os.getenv("CLOUD115_TOKEN", "").strip(),
    "cloud115_cookie": os.getenv("CLOUD115_COOKIE", "").strip(),
    # 管线 A:本地下载刮削
    "local_scrape_enabled": True,
    "local_transfer_enabled": True,
    "local_transfer_path": "",
    # 管线 B:手动刮削(strm 等)
    "manual_scrape_enabled": True,
    "manual_transfer_enabled": True,
    "manual_transfer_path": "",
    # Watch folder:实时监控目录自动刮削
    "watch_enabled": False,
    "watch_dir": "",
    "watch_interval": 10,  # 秒
    # 管线 C:115 离线后在 115 网盘内秒转移
    "cloud_transfer_enabled": False,
    "cloud_transfer_path": "",   # 115 网盘内的目标路径(展示用)
    "cloud_transfer_cid": "",    # 115 网盘目标目录 id(移动用)
    "cloud_poll_interval": 300,  # 秒,115 离线状态轮询间隔（最低 5 分钟，避免触发账号异常）
    "cloud_ad_min_mb": 0,        # 离线产物广告清理阈值(MB,0=关闭):完成后删除目录内小于该体积的文件(低频删除防风控)
    # 管线 D:115 离线完成后本地生成 strm 并刮削
    "auto_strm_enabled": False,
    "service_base_url": "",     # 服务访问地址(如 http://192.168.2.50:8788),写入 strm 供播放器访问
    "strm_root_dir": "strm",   # strm 根目录(DATA_DIR 下的子目录,对应容器内 /data/<strm_root_dir>),可自定义
    # 隐私模式:开启后前端所有影片封面模糊(防止截屏泄露)
    "privacy_mode": True,
    # 站点访问密码:公网暴露时先登录再访问页面/API；空表示不启用
    "site_password_hash": "",
    # 115 播放方式: proxy=后端代理流式(默认), redirect=302 直连(浏览器直连 115 CDN,不占后端带宽)
    "cloud115_play_mode": "proxy",
    # 自动离线到 115: 模式A=浏览详情自动离线, 模式B=定时追新扫描
    "auto_offline_enabled": False,
    "auto_offline_browse": True,      # 模式 A:打开详情时命中规则自动离线
    "auto_offline_schedule": True,    # 模式 B:定时扫描最新列表
    "auto_offline_interval": 6,       # 模式 B 检查间隔(小时)
    "auto_offline_pages": 2,          # 模式 B 扫描最新列表页数
    "auto_offline_whitelist": "",     # 番号白名单(逗号分隔,空=不限制)
    "auto_offline_min_duration": 60,  # 时长下限(分钟,0=不限制;模式A无时长数据不校验)
    "auto_offline_min_size": 3,       # 磁力体积下限(GB,过滤预告/CM)
    "auto_offline_daily_limit": 5,    # 单日自动离线上限(保护 115 配额)
    # 黄果短剧: 下载 -> 刮削 -> 完结后上传 115 -> 可选删除源文件
    "hg_upload_strategy": "completed",  # completed=完结后上传, episode=每集完成即上传, never=不上传
    "hg_upload_enabled": False,
    "hg_delete_after_upload": False,
    "hg_target_cid": "",
    "hg_target_path": "/黄果短剧",
    "hg_check_interval": 6,
    "hg_use_proxy": True,  # 黄果下载是否走代理（列表/详情抓取不走，仅影响视频下载）
    "hg_site_mirrors": "",  # 黄果备用镜像域名（逗号/空格分隔），站点不可达时自动切换
    "hg_episode_concurrency": 2,  # 同剧多集并行下载线程数（1-4，过高易触发风控）
    "hg_follow_enabled": True,    # 追更总开关：关闭后不再定期检查连载剧新集
    "hg_follow_pages": 3,         # 每轮追更最多检查的剧集数（按最久未检查优先分批轮询）
}

TASK_COLUMNS = {
    "extra_args": "TEXT NOT NULL DEFAULT ''",
    "organize_enabled": "INTEGER NOT NULL DEFAULT 1",
    "allow_duplicate": "INTEGER NOT NULL DEFAULT 0",
    "download_step": "TEXT NOT NULL DEFAULT 'pending'",
    "scrape_step": "TEXT NOT NULL DEFAULT 'pending'",
    "organize_step": "TEXT NOT NULL DEFAULT 'pending'",
    "downloaded_bytes": "INTEGER NOT NULL DEFAULT 0",
    "total_bytes": "INTEGER NOT NULL DEFAULT 0",
    "eta": "TEXT NOT NULL DEFAULT '-'",
    "cover_path": "TEXT NOT NULL DEFAULT ''",
    "metadata_json": "TEXT NOT NULL DEFAULT ''",
    "source_used": "TEXT NOT NULL DEFAULT ''",
    "task_type": "TEXT NOT NULL DEFAULT 'download'",
    "source_path": "TEXT NOT NULL DEFAULT ''",
    "priority": "INTEGER NOT NULL DEFAULT 0",
    "result_message": "TEXT NOT NULL DEFAULT ''",
    "mode": "TEXT NOT NULL DEFAULT 'normal'"
}

# Vite emits absolute /assets/... URLs. Expose the build root at / so those
# hashed JavaScript and CSS files are available alongside the index route.
app = Flask(__name__, static_folder="web-115/dist", static_url_path="")
db_lock = threading.RLock()
worker_wakeup = threading.Event()
active_process = None
active_task_id = None
active_process_lock = threading.Lock()
browser_lock = threading.Lock()
qr_login_lock = threading.RLock()
qr_login_session = {"uid": "", "time": "", "sign": "", "qrcode": "", "created_at": 0.0}


class ChromeSession:
    def __init__(self, proxy="", persistent=False):
        self.proxy = proxy
        self.persistent = persistent
        self.port = 0
        self.process = None
        self.session_id = ""

    def __enter__(self):
        if not Path(CHROMIUM).exists() or not Path(CHROMEDRIVER).exists():
            raise RuntimeError("容器内 Chromium 自动化组件缺失")
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            self.port = listener.getsockname()[1]
        self.process = subprocess.Popen(
            [CHROMEDRIVER, f"--port={self.port}", "--allowed-ips=127.0.0.1"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        try:
            for _ in range(50):
                try:
                    self.request("GET", "/status")
                    break
                except (URLError, ConnectionError):
                    time.sleep(0.1)
            else:
                raise RuntimeError("Chromium 驱动启动超时")
            arguments = [
                "--headless=new", "--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu",
                "--disable-blink-features=AutomationControlled", "--autoplay-policy=no-user-gesture-required",
                "--window-size=1365,900", "--lang=zh-CN",
                "--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
            ]
            if self.proxy:
                arguments.append(f"--proxy-server={self.proxy}")
            result = self.request("POST", "/session", {
                "capabilities": {"alwaysMatch": {
                    "browserName": "chrome",
                    "goog:chromeOptions": {"binary": CHROMIUM, "args": arguments},
                    "goog:loggingPrefs": {"performance": "ALL"}
                }}
            })
            value = result.get("value", {})
            self.session_id = value.get("sessionId") or result.get("sessionId", "")
            if not self.session_id:
                raise RuntimeError(f"Chromium 会话创建失败：{value.get('message', '未知错误')}")
            self.cdp("Page.addScriptToEvaluateOnNewDocument", {
                "source": "Object.defineProperty(navigator,'webdriver',{get:()=>undefined});"
            })
            return self
        except Exception:
            self.__exit__(None, None, None)
            raise

    def __exit__(self, exc_type, exc_value, traceback):
        if self.persistent:
            return  # 持久模式：会话跨请求复用，不在这里关闭
        self.close()

    def close(self):
        if self.session_id:
            try:
                self.request("DELETE", f"/session/{self.session_id}")
            except Exception:
                pass
            self.session_id = ""
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.process = None

    def request(self, method, path, payload=None, timeout=35):
        body = json.dumps(payload).encode() if payload is not None else None
        request_object = Request(
            f"http://127.0.0.1:{self.port}{path}", data=body, method=method,
            headers={"Content-Type": "application/json"}
        )
        try:
            with urlopen(request_object, timeout=timeout) as response:
                return json.loads(response.read().decode())
        except HTTPError as error:
            detail = error.read().decode(errors="replace")
            raise RuntimeError(f"Chromium 请求失败：{detail[:300]}") from error

    def command(self, name, payload=None):
        result = self.request("POST", f"/session/{self.session_id}/{name}", payload or {})
        value = result.get("value")
        if isinstance(value, dict) and value.get("error"):
            raise RuntimeError(value.get("message", value["error"]))
        return value

    def navigate(self, url):
        self.command("url", {"url": url})

    def execute(self, script, args=None):
        return self.command("execute/sync", {"script": script, "args": args or []})

    def cdp(self, command, params=None):
        return self.command("goog/cdp/execute", {"cmd": command, "params": params or {}})

    def performance_logs(self):
        return self.command("se/log", {"type": "performance"}) or []


# 持久浏览器：跨请求复用 Chromium 实例，省掉每次 3-6 秒的冷启动（详情/列表抓取大幅提速）
_persistent_chrome_instance = None
_persistent_chrome_proxy = None


def _persistent_chrome(proxy=""):
    """获取持久 ChromeSession（带 proxy 一致性校验与存活探测，坏实例自动重建）。"""
    global _persistent_chrome_instance, _persistent_chrome_proxy
    if _persistent_chrome_instance is not None:
        if _persistent_chrome_proxy != (proxy or ""):
            _persistent_chrome_instance.close()
            _persistent_chrome_instance = None
        else:
            try:
                _persistent_chrome_instance.request("GET", "/status", timeout=3)
                return _persistent_chrome_instance
            except Exception:
                try:
                    _persistent_chrome_instance.close()
                except Exception:
                    pass
                _persistent_chrome_instance = None
    session = ChromeSession(proxy, persistent=True)
    session.__enter__()
    _persistent_chrome_instance = session
    _persistent_chrome_proxy = proxy or ""
    return _persistent_chrome_instance


def connect():
    connection = sqlite3.connect(DB_PATH, timeout=30)
    connection.row_factory = sqlite3.Row
    return connection


def initialize():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    MEDIA_DIR.mkdir(parents=True, exist_ok=True)
    WORK_DIR.mkdir(parents=True, exist_ok=True)
    with connect() as db:
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("""
            CREATE TABLE IF NOT EXISTS tasks (
                id TEXT PRIMARY KEY, url TEXT NOT NULL, title TEXT NOT NULL,
                catalog TEXT NOT NULL, performer TEXT NOT NULL, threads INTEGER NOT NULL,
                state TEXT NOT NULL, phase TEXT NOT NULL, progress REAL NOT NULL,
                speed TEXT NOT NULL, size TEXT NOT NULL, output_path TEXT NOT NULL,
                metadata_found INTEGER, log TEXT NOT NULL, created_at TEXT NOT NULL,
                started_at TEXT, finished_at TEXT
            )
        """)
        existing = {row[1] for row in db.execute("PRAGMA table_info(tasks)")}
        for name, declaration in TASK_COLUMNS.items():
            if name not in existing:
                db.execute(f"ALTER TABLE tasks ADD COLUMN {name} {declaration}")
        db.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        db.execute("""
            CREATE TABLE IF NOT EXISTS cloud_tasks (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, catalog TEXT NOT NULL,
                source_url TEXT NOT NULL, detail_url TEXT NOT NULL, state TEXT NOT NULL,
                message TEXT NOT NULL, play_url TEXT NOT NULL, created_at TEXT NOT NULL,
                finished_at TEXT
            )
        """)
        cloud_existing = {row[1] for row in db.execute("PRAGMA table_info(cloud_tasks)")}
        for name, declaration in {"info_hash": "TEXT NOT NULL DEFAULT ''", "file_path": "TEXT NOT NULL DEFAULT ''",
                                  "dest_cid": "TEXT NOT NULL DEFAULT ''", "pickcode": "TEXT NOT NULL DEFAULT ''"}.items():
            if name not in cloud_existing:
                db.execute(f"ALTER TABLE cloud_tasks ADD COLUMN {name} {declaration}")
        # 旧库 tasks 表缺 cover_url 列时补齐（封面回填用）
        tasks_existing = {row[1] for row in db.execute("PRAGMA table_info(tasks)")}
        if tasks_existing and "cover_url" not in tasks_existing:
            db.execute("ALTER TABLE tasks ADD COLUMN cover_url TEXT NOT NULL DEFAULT ''")
        # 旧库 cloud_tasks 表缺 cover_url 列时补齐（115 媒体库封面持久化）
        if "cover_url" not in cloud_existing:
            db.execute("ALTER TABLE cloud_tasks ADD COLUMN cover_url TEXT NOT NULL DEFAULT ''")
        db.execute("""
            CREATE TABLE IF NOT EXISTS strm_items (
                id TEXT PRIMARY KEY, cloud_task_id TEXT NOT NULL, catalog TEXT NOT NULL,
                title TEXT NOT NULL, strm_path TEXT NOT NULL, poster_path TEXT NOT NULL DEFAULT '',
                pickcode TEXT NOT NULL DEFAULT '', file_path TEXT NOT NULL DEFAULT '',
                size INTEGER NOT NULL DEFAULT 0, cover_url TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL
            )
        """)
        db.execute("DELETE FROM settings WHERE key='cloud_scrape_enabled'")  # 已废弃:管线C改为网盘内转移
        db.execute("""
            CREATE TABLE IF NOT EXISTS scraper_sources (
                domain TEXT PRIMARY KEY, enabled INTEGER NOT NULL,
                position INTEGER NOT NULL, health TEXT NOT NULL DEFAULT 'unchecked'
            )
        """)
        db.execute("""
            CREATE TABLE IF NOT EXISTS latest_videos (
                detail_url TEXT PRIMARY KEY, title TEXT NOT NULL, catalog TEXT NOT NULL,
                cover_url TEXT NOT NULL, duration TEXT NOT NULL, updated_at REAL NOT NULL
            )
        """)
        db.execute("""
            CREATE TABLE IF NOT EXISTS auto_offline_log (
                id TEXT PRIMARY KEY, catalog TEXT NOT NULL, title TEXT NOT NULL,
                magnet_url TEXT NOT NULL, magnet_size TEXT NOT NULL DEFAULT '',
                mode TEXT NOT NULL, state TEXT NOT NULL, message TEXT NOT NULL DEFAULT '',
                cloud_task_id TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL
            )
        """)
        db.execute("""
            CREATE TABLE IF NOT EXISTS app_logs (
                id TEXT PRIMARY KEY, created_at TEXT NOT NULL, level TEXT NOT NULL,
                module TEXT NOT NULL, action TEXT NOT NULL, target TEXT NOT NULL DEFAULT '',
                message TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '',
                task_id TEXT NOT NULL DEFAULT ''
            )
        """)
        db.execute("""
            CREATE TABLE IF NOT EXISTS hg_series (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, origin TEXT NOT NULL,
                detail_url TEXT NOT NULL, cover_url TEXT NOT NULL DEFAULT '',
                description TEXT NOT NULL DEFAULT '', follow_enabled INTEGER NOT NULL DEFAULT 1,
                completed INTEGER NOT NULL DEFAULT 0,
                total_episodes INTEGER NOT NULL DEFAULT 0, downloaded_episodes INTEGER NOT NULL DEFAULT 0,
                uploaded_episodes INTEGER NOT NULL DEFAULT 0, latest_episode INTEGER NOT NULL DEFAULT 0,
                rating TEXT NOT NULL DEFAULT '', premiered TEXT NOT NULL DEFAULT '',
                last_checked_at TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL
            )
        """)
        existing_hg_series = {item[1] for item in db.execute("PRAGMA table_info(hg_series)").fetchall()}
        if "completed" not in existing_hg_series:
            db.execute("ALTER TABLE hg_series ADD COLUMN completed INTEGER NOT NULL DEFAULT 0")
        if "rating" not in existing_hg_series:
            db.execute("ALTER TABLE hg_series ADD COLUMN rating TEXT NOT NULL DEFAULT ''")
        if "premiered" not in existing_hg_series:
            db.execute("ALTER TABLE hg_series ADD COLUMN premiered TEXT NOT NULL DEFAULT ''")
        db.execute("""
            CREATE TABLE IF NOT EXISTS hg_episodes (
                id TEXT PRIMARY KEY, series_id TEXT NOT NULL, ep INTEGER NOT NULL,
                title TEXT NOT NULL, play_url TEXT NOT NULL, stream_url TEXT NOT NULL DEFAULT '',
                state TEXT NOT NULL DEFAULT 'pending', upload_state TEXT NOT NULL DEFAULT 'pending',
                progress REAL NOT NULL DEFAULT 0, file_path TEXT NOT NULL DEFAULT '',
                upload_path TEXT NOT NULL DEFAULT '', upload_file_id TEXT NOT NULL DEFAULT '',
                message TEXT NOT NULL DEFAULT '', error TEXT NOT NULL DEFAULT '',
                retry_count INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL, updated_at TEXT NOT NULL
            )
        """)
        db.execute("CREATE INDEX IF NOT EXISTS idx_hg_episodes_series_ep ON hg_episodes(series_id, ep)")
        existing_hg_episodes = {item[1] for item in db.execute("PRAGMA table_info(hg_episodes)").fetchall()}
        if "pickcode" not in existing_hg_episodes:
            db.execute("ALTER TABLE hg_episodes ADD COLUMN pickcode TEXT NOT NULL DEFAULT ''")
        if "retry_count" not in existing_hg_episodes:
            db.execute("ALTER TABLE hg_episodes ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0")
        db.execute("CREATE INDEX IF NOT EXISTS idx_hg_episodes_state ON hg_episodes(state, upload_state)")
        db.execute("CREATE INDEX IF NOT EXISTS idx_app_logs_created_at ON app_logs(created_at DESC)")
        db.execute("CREATE INDEX IF NOT EXISTS idx_app_logs_module ON app_logs(module)")
        db.execute("CREATE INDEX IF NOT EXISTS idx_app_logs_level ON app_logs(level)")
        if not db.execute("SELECT 1 FROM scraper_sources LIMIT 1").fetchone():
            db.executemany(
                "INSERT INTO scraper_sources(domain,enabled,position,health) VALUES(?,?,?,'unchecked')",
                [(domain, 1, index) for index, domain in enumerate(DEFAULT_SOURCES)]
            )
        for key, value in DEFAULT_SETTINGS.items():
            db.execute("INSERT OR IGNORE INTO settings(key,value) VALUES(?,?)", (key, json.dumps(value)))
        db.execute("""
            UPDATE tasks SET state='interrupted', phase='容器重启，可点击重试',
            result_message='容器重启导致任务中断' WHERE state='running'
        """)
        db.execute("""
            UPDATE hg_episodes SET state='queued', progress=0, message='容器重启，重新排队',
            error='', updated_at=? WHERE state='running'
        """, (datetime.now().isoformat(timespec="seconds"),))
        db.execute("""
            UPDATE tasks SET download_step='succeeded',
            scrape_step=CASE WHEN metadata_found=1 THEN 'succeeded' ELSE 'failed' END,
            organize_step='succeeded'
            WHERE state='completed' AND download_step='pending' AND output_path<>''
        """)


def rows(query, values=()):
    with db_lock, connect() as db:
        return [dict(row) for row in db.execute(query, values).fetchall()]


def row(query, values=()):
    """取查询结果第一行（dict）或 None。"""
    results = rows(query, values)
    return results[0] if results else None


def setting_value(key, default=None):
    try:
        with db_lock, connect() as db:
            result = db.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
        return json.loads(result[0]) if result else default
    except Exception:
        return default


def store_setting(key, value):
    with db_lock, connect() as db:
        db.execute("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)",
                   (key, json.dumps(value, ensure_ascii=False)))


def update_task(task_id, **values):
    if not values:
        return
    columns = ", ".join(f"{key}=?" for key in values)
    with db_lock, connect() as db:
        db.execute(f"UPDATE tasks SET {columns} WHERE id=?", (*values.values(), task_id))


def append_log(task_id, message):
    stamp = datetime.now().strftime("%H:%M:%S")
    current = rows("SELECT log FROM tasks WHERE id=?", (task_id,))
    old = current[0]["log"] if current else ""
    update_task(task_id, log=(f"{stamp}  {message}\n" + old)[:MAX_LOG])
    write_app_log("info", "download" if task_id != "watch" else "watch", "task-log",
                  str(message), task_id=task_id, target=task_id)


LOG_LEVELS = {"debug", "info", "success", "warning", "error"}
LOG_MODULES = {
    "system", "access", "license", "settings", "jable", "115",
    "download", "media", "strm", "task", "watch", "auto", "huangguo"
}


def _clip_log_value(value, limit):
    text = str(value or "")
    return text if len(text) <= limit else text[:limit] + "..."


def write_app_log(level, module, action, message, detail="", task_id="", target=""):
    """写入全局日志中心；失败时只打印，不影响主流程。"""
    try:
        level = level if level in LOG_LEVELS else "info"
        module = module if module in LOG_MODULES else "system"
        created_at = datetime.now().isoformat(timespec="seconds")
        with db_lock, connect() as db:
            db.execute(
                """
                INSERT INTO app_logs(id,created_at,level,module,action,target,message,detail,task_id)
                VALUES(?,?,?,?,?,?,?,?,?)
                """,
                (
                    str(uuid.uuid4()), created_at, level, _clip_log_value(module, 32),
                    _clip_log_value(action, 80), _clip_log_value(target, 300),
                    _clip_log_value(message, 600), _clip_log_value(detail, 10000),
                    _clip_log_value(task_id, 80),
                ),
            )
            db.execute("DELETE FROM app_logs WHERE id NOT IN (SELECT id FROM app_logs ORDER BY created_at DESC LIMIT 5000)")
    except Exception as error:
        print(f"[logs] 写入日志失败: {error}")


# ---------- 离线授权（Ed25519：公钥内嵌，私钥离线保管，按设备+有效期） ----------
LICENSE_PUBKEY = "fae5a0003c902052ea48ef51aaf4e37e8774f27c34727f64cdc8bc36380b25fc"
_LICENSE_PREFIX = b"NASSAV1|"

_ED_P = 2 ** 255 - 19
_ED_L = 2 ** 252 + 27742317777372353535851937790883648493
_ED_D = -121665 * pow(121666, _ED_P - 2, _ED_P) % _ED_P
_ED_I = pow(2, (_ED_P - 1) // 4, _ED_P)
_ED_BY = 4 * pow(5, _ED_P - 2, _ED_P) % _ED_P


def _ed_xrecover(y):
    xx = (y * y - 1) * pow(_ED_D * y * y + 1, _ED_P - 2, _ED_P)
    x = pow(xx, (_ED_P + 3) // 8, _ED_P)
    if (x * x - xx) % _ED_P != 0:
        x = (x * _ED_I) % _ED_P
    if (x * x - xx) % _ED_P != 0:
        return None
    if x % 2 != 0:
        x = _ED_P - x
    return x


_ED_BX = _ed_xrecover(_ED_BY)
_ED_B = (_ED_BX % _ED_P, _ED_BY % _ED_P, 1, (_ED_BX * _ED_BY) % _ED_P)
_ED_IDENT = (0, 1, 1, 0)


def _ed_add(P, Q):
    x1, y1, z1, t1 = P
    x2, y2, z2, t2 = Q
    a = (y1 - x1) * (y2 - x2) % _ED_P
    b = (y1 + x1) * (y2 + x2) % _ED_P
    c = t1 * 2 * _ED_D * t2 % _ED_P
    d = z1 * 2 * z2 % _ED_P
    e = b - a
    f = d - c
    g = d + c
    h = b + a
    return (e * f % _ED_P, g * h % _ED_P, f * g % _ED_P, e * h % _ED_P)


def _ed_mult(P, e):
    Q = _ED_IDENT
    while e > 0:
        if e & 1:
            Q = _ed_add(Q, P)
        P = _ed_add(P, P)
        e >>= 1
    return Q


def _ed_equal(P, Q):
    return (P[0] * Q[2] - Q[0] * P[2]) % _ED_P == 0 and (P[1] * Q[2] - Q[1] * P[2]) % _ED_P == 0


def _ed_decompress(s):
    if len(s) != 32:
        return None
    y = int.from_bytes(s, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    if y >= _ED_P:
        return None
    x = _ed_xrecover(y)
    if x is None:
        return None
    if x & 1 != sign:
        x = _ED_P - x
    if (y * y - x * x - 1 - _ED_D * (x * x % _ED_P) * (y * y % _ED_P)) % _ED_P != 0:
        return None
    return (x, y, 1, x * y % _ED_P)


def _ed25519_verify(pub32, msg, sig64):
    try:
        A = _ed_decompress(pub32)
        if A is None:
            return False
        R = _ed_decompress(sig64[:32])
        if R is None:
            return False
        S = int.from_bytes(sig64[32:], "little")
        if S >= _ED_L:
            return False
        k = int.from_bytes(hashlib.sha512(sig64[:32] + pub32 + msg).digest(), "little") % _ED_L
        return _ed_equal(_ed_mult(_ED_B, S), _ed_add(R, _ed_mult(A, k)))
    except Exception:
        return False


_LICENSE_SIG_CACHE = {"device": None, "code": None, "expires_at": None}


def _license_setting(key):
    try:
        with db_lock, connect() as db:
            row = db.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
        return json.loads(row[0]) if row else None
    except Exception:
        return None


def _ensure_device_id():
    """设备码稳定化：/data/instance_id 文件 + settings 双持久化。

    历史版本更换过数据库文件（app.db -> media_library.db -> queue.sqlite3），
    每次迁移 instance_id 丢失都会重新生成导致授权失效；文件层保证升级/换库不变。
    """
    marker = DATA_DIR / "instance_id"
    try:
        if marker.exists():
            stored = marker.read_text(encoding="utf-8").strip()
            if stored:
                if _license_setting("instance_id") != stored:
                    with db_lock, connect() as db:
                        db.execute("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)",
                                   ("instance_id", json.dumps(stored)))
                return stored
    except OSError:
        pass
    device_id = _license_setting("instance_id")
    if isinstance(device_id, str) and device_id.strip():
        device_id = device_id.strip()
        try:
            marker.parent.mkdir(parents=True, exist_ok=True)
            marker.write_text(device_id, encoding="utf-8")
        except OSError:
            pass
        return device_id
    with db_lock, connect() as db:
        row = db.execute("SELECT value FROM settings WHERE key=?", ("instance_id",)).fetchone()
        try:
            existing = json.loads(row[0]) if row else None
        except ValueError:
            existing = None
        if isinstance(existing, str) and existing.strip():
            device_id = existing.strip()
        else:
            device_id = str(uuid.uuid4())
            db.execute("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)",
                       ("instance_id", json.dumps(device_id)))
    try:
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(device_id, encoding="utf-8")
    except OSError:
        pass
    return device_id


def _license_verify_code(device_id, code):
    """校验授权码；成功返回 expires_at(0=永久有效)，失败返回 None。"""
    code = re.sub(r"[\s\-]", "", str(code or ""))
    if not (LICENSE_PUBKEY and device_id and code):
        return None
    try:
        raw = base64.b64decode(code, validate=True)
    except Exception:
        return None
    if len(raw) < 65 or not raw.startswith(_LICENSE_PREFIX):
        return None
    payload, sig = raw[:-64], raw[-64:]
    parts = payload.split(b"|")
    if len(parts) != 3 or parts[1].decode("utf-8", "ignore") != device_id:
        return None
    try:
        expires_at = int(parts[2])
    except ValueError:
        return None
    if not _ed25519_verify(bytes.fromhex(LICENSE_PUBKEY), payload, sig):
        return None
    return expires_at


def _license_state():
    device_id = _license_setting("instance_id") or ""
    code = _license_setting("license_code") or ""
    state = {"device_id": device_id, "activated": False, "expires_at": 0, "expired": False,
             "revoked": device_id in _REVOCATION_CACHE["revoked"]}
    if not device_id or not code:
        return state
    cache = _LICENSE_SIG_CACHE
    if cache["device"] != device_id or cache["code"] != code:
        cache["device"], cache["code"], cache["expires_at"] = device_id, code, _license_verify_code(device_id, code)
    expires_at = cache["expires_at"]
    if expires_at is None:
        return state
    state["expires_at"] = expires_at
    if not state["revoked"] and (expires_at == 0 or expires_at > time.time()):
        state["activated"] = True
    if expires_at != 0 and expires_at <= time.time():
        state["expired"] = True
    return state


# ---------- 吊销名单（远程作废）：LICENSE_REVOCATION_URL 指向 {"revoked": ["device-id", ...]} ----------
APP_BUILD = "20260907-hg-tasks"
LICENSE_REVOCATION_URL = os.environ.get("LICENSE_REVOCATION_URL", "").strip()
# 吊销名单服务根地址（由 revocation.json URL 推导），用于设备心跳上报
_LICENSE_SERVER_BASE = LICENSE_REVOCATION_URL.replace("/revocation.json", "") \
    if LICENSE_REVOCATION_URL.endswith("/revocation.json") else ""
_REVOCATION_CACHE = {"fetched_at": 0, "revoked": frozenset(), "ok": False}
_revocation_lock = threading.Lock()

# 吊销名单/心跳周期：3 分钟（心跳响应同时携带最新名单，吊销约 3 分钟内生效）
_LICENSE_POLL_INTERVAL = 180


def _urlopen_with_fallback(url, data=None, timeout=10):
    """直连优先、代理兜底地打开 URL（国内服务器直连更稳，失败走设置里的代理）。"""
    last_error = None
    for attempt in ("direct", "proxy"):
        try:
            if attempt == "proxy":
                proxy = str(get_settings().get("proxy", "") or "").strip()
                if not proxy:
                    break
                opener = build_opener(ProxyHandler({"http": proxy, "https": proxy}))
            else:
                opener = build_opener()
            return opener.open(url, data=data, timeout=timeout)
        except Exception as e:
            last_error = e
    raise last_error if last_error else RuntimeError("无可用的打开方式")


def _apply_revocation_list(revoked):
    if not isinstance(revoked, list):
        return
    with _revocation_lock:
        _REVOCATION_CACHE.update(fetched_at=time.time(), revoked=frozenset(str(x) for x in revoked), ok=True)


def _fetch_revocation_list():
    if not LICENSE_REVOCATION_URL:
        return
    try:
        with _urlopen_with_fallback(LICENSE_REVOCATION_URL) as resp:
            data = json.loads(resp.read(65536).decode("utf-8", "ignore"))
        revoked = data.get("revoked", []) if isinstance(data, dict) else data
        _apply_revocation_list(revoked)
    except Exception as e:
        print(f"[license] 吊销名单拉取失败: {e}")


def _license_checkin():
    """设备心跳：上报在线状态给授权管理台；响应携带最新吊销名单即时生效。"""
    if not _LICENSE_SERVER_BASE:
        return
    state = _license_state()
    device_id = state.get("device_id") or ""
    if not device_id:
        return
    payload = json.dumps({
        "device_id": device_id,
        "hostname": socket.gethostname()[:64],
        "app_version": APP_BUILD,
        "expires_at": state.get("expires_at", 0),
        "ts": int(time.time()),
    }).encode()
    try:
        request_obj = Request(f"{_LICENSE_SERVER_BASE}/api/checkin", data=payload,
                              headers={"Content-Type": "application/json"}, method="POST")
        with _urlopen_with_fallback(request_obj, timeout=10) as resp:
            data = json.loads(resp.read(65536).decode("utf-8", "ignore"))
        if isinstance(data, dict) and isinstance(data.get("revoked"), list):
            _apply_revocation_list(data["revoked"])
    except Exception:
        pass  # 心跳失败静默（管理台会显示离线），吊销名单仍按周期拉取


def _revocation_daemon():
    time.sleep(5)
    while True:
        try:
            _fetch_revocation_list()
            _license_checkin()
        except Exception as e:
            print(f"[license] 吊销名单刷新异常: {e}")
        time.sleep(_LICENSE_POLL_INTERVAL)


threading.Thread(target=_revocation_daemon, daemon=True, name="license-revocation").start()


def _ensure_site_session_secret():
    secret = os.getenv("SITE_SESSION_SECRET", "").strip()
    if not secret:
        secret = setting_value("site_session_secret", "")
        if not isinstance(secret, str) or not secret.strip():
            secret = base64.urlsafe_b64encode(os.urandom(48)).decode("ascii")
            store_setting("site_session_secret", secret)
    app.secret_key = secret
    app.config.update(
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        PERMANENT_SESSION_LIFETIME=60 * 60 * 24 * 30,
    )


def _password_hash(password):
    salt = os.urandom(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 200_000)
    return "pbkdf2_sha256$200000$" + base64.b64encode(salt).decode("ascii") + "$" + base64.b64encode(digest).decode("ascii")


def _verify_password(password, encoded):
    try:
        algo, rounds, salt_b64, digest_b64 = str(encoded or "").split("$", 3)
        if algo != "pbkdf2_sha256":
            return False
        salt = base64.b64decode(salt_b64)
        expected = base64.b64decode(digest_b64)
        actual = hashlib.pbkdf2_hmac("sha256", str(password or "").encode("utf-8"), salt, int(rounds))
        return hmac.compare_digest(actual, expected)
    except Exception:
        return False


def _site_password_hash():
    value = setting_value("site_password_hash", "")
    return value.strip() if isinstance(value, str) else ""


def _access_configured():
    return bool(_site_password_hash())


def _access_authenticated():
    return not _access_configured() or session.get("site_access") is True


def _access_status():
    return {"configured": _access_configured(), "authenticated": _access_authenticated()}


@app.before_request
def _access_and_license_guard():
    path = request.path
    if path in {"/api/access/status", "/api/access/login", "/api/access/logout", "/api/health"}:
        return None
    if not _access_authenticated():
        if (path in {"/", "/index.html", "/favicon.ico"} or path.startswith("/assets/")):
            return None
        return jsonify(ok=False, error="access_locked", message="请输入访问密码"), 401
    if (path in {"/", "/index.html", "/favicon.ico", "/api/health"}
            or path.startswith("/assets/")
            or path.startswith("/api/license")):
        return None
    state = _license_state()
    if state["activated"]:
        return None
    msg = "授权已被吊销，请联系管理员" if state.get("revoked") else "未授权或授权已过期，请输入授权码"
    return jsonify(ok=False, error="unlicensed", message=msg), 403


@app.after_request
def _audit_api_errors(response):
    try:
        if request.path.startswith("/api/") and not request.path.startswith("/api/logs") and response.status_code >= 400:
            payload = response.get_json(silent=True) or {}
            message = payload.get("message") or payload.get("error") or response.status
            level = "error" if response.status_code >= 500 else "warning"
            write_app_log(level, "system", request.method, str(message), target=request.path)
    except Exception:
        pass
    return response


def get_settings():
    settings = dict(DEFAULT_SETTINGS)
    with db_lock, connect() as db:
        for row in db.execute("SELECT key,value FROM settings"):
            try:
                settings[row[0]] = json.loads(row[1])
            except ValueError:
                pass
    return settings


def public_settings():
    settings = get_settings()
    token_configured = bool(str(settings.get("cloud115_token", "")).strip())
    cookie_configured = bool(str(settings.get("cloud115_cookie", "")).strip())
    jable_cookie_configured = bool(str(settings.get("jable_cookie", "")).strip())
    site_password_configured = bool(str(settings.get("site_password_hash", "")).strip())
    settings["jable_cookie"] = ""
    settings["cloud115_token"] = ""
    settings["cloud115_cookie"] = ""
    settings["site_password_hash"] = ""
    settings["cloud115_token_configured"] = token_configured
    settings["cloud115_cookie_configured"] = cookie_configured
    settings["jable_cookie_configured"] = jable_cookie_configured
    settings["site_password_configured"] = site_password_configured
    # 只读:容器内挂载路径,前端路径选择器会参考
    settings["media_root"] = str(MEDIA_DIR)
    settings["data_root"] = str(DATA_DIR)
    return settings


def save_settings(values):
    allowed = set(DEFAULT_SETTINGS)
    settings = get_settings()
    for key, value in values.items():
        if key not in allowed:
            continue
        if key == "site_password_hash":
            continue
        if key in {"cloud115_token", "cloud115_cookie", "jable_cookie"} and not str(value or "").strip():
            continue
        settings[key] = value
    if values.get("clear_jable_cookie"):
        settings["jable_cookie"] = ""
    if values.get("clear_cloud115_token"):
        settings["cloud115_token"] = ""
    if values.get("clear_cloud115_cookie"):
        settings["cloud115_cookie"] = ""
    settings["threads"] = min(32, max(1, int(settings["threads"])))
    settings["allow_duplicate"] = bool(settings["allow_duplicate"])
    settings["organize_enabled"] = bool(settings["organize_enabled"])
    settings["failure_route_enabled"] = bool(settings["failure_route_enabled"])
    settings["proxy"] = str(settings["proxy"]).strip()
    settings["jable_cookie"] = str(settings.get("jable_cookie", "")).strip()
    settings["failure_path"] = str(settings["failure_path"]).strip() or "/media/待整理"
    settings["cloud115_mode"] = str(settings.get("cloud115_mode", "bridge")).strip()
    if settings["cloud115_mode"] not in ("bridge", "cookie"):
        settings["cloud115_mode"] = "bridge"
    settings["cloud115_endpoint"] = str(settings.get("cloud115_endpoint", "")).strip()
    settings["cloud115_token"] = str(settings.get("cloud115_token", "")).strip()
    settings["cloud115_cookie"] = str(settings.get("cloud115_cookie", "")).strip()
    settings["cloud115_play_mode"] = str(settings.get("cloud115_play_mode", "proxy")).strip()
    if settings["cloud115_play_mode"] not in ("proxy", "redirect"):
        settings["cloud115_play_mode"] = "proxy"
    try:
        settings["cloud_ad_min_mb"] = min(500.0, max(0.0, float(settings.get("cloud_ad_min_mb", 0))))
    except (TypeError, ValueError):
        settings["cloud_ad_min_mb"] = 0
    # 两条刮削管线的开关和路径
    for bool_key in ("local_scrape_enabled", "local_transfer_enabled",
                    "manual_scrape_enabled", "manual_transfer_enabled"):
        settings[bool_key] = bool(settings.get(bool_key, DEFAULT_SETTINGS[bool_key]))
    for path_key in ("local_transfer_path", "manual_transfer_path"):
        raw = str(settings.get(path_key, "") or "").strip()
        if raw:
            try:
                resolved = resolve_media_path(raw)
                settings[path_key] = str(resolved)
            except ValueError:
                settings[path_key] = raw  # 保留原值让用户自己修正
        else:
            settings[path_key] = ""
    # 自动离线配置规范化
    for bool_key in ("auto_offline_enabled", "auto_offline_browse", "auto_offline_schedule"):
        settings[bool_key] = bool(settings.get(bool_key, DEFAULT_SETTINGS[bool_key]))
    try:
        settings["auto_offline_interval"] = min(72, max(1, int(settings.get("auto_offline_interval", 6))))
    except (TypeError, ValueError):
        settings["auto_offline_interval"] = 6
    try:
        settings["auto_offline_pages"] = min(10, max(1, int(settings.get("auto_offline_pages", 2))))
    except (TypeError, ValueError):
        settings["auto_offline_pages"] = 2
    try:
        settings["auto_offline_min_duration"] = min(600, max(0, int(settings.get("auto_offline_min_duration", 60))))
    except (TypeError, ValueError):
        settings["auto_offline_min_duration"] = 60
    try:
        settings["auto_offline_min_size"] = min(200.0, max(0.0, float(settings.get("auto_offline_min_size", 3))))
    except (TypeError, ValueError):
        settings["auto_offline_min_size"] = 3
    try:
        settings["auto_offline_daily_limit"] = min(50, max(1, int(settings.get("auto_offline_daily_limit", 5))))
    except (TypeError, ValueError):
        settings["auto_offline_daily_limit"] = 5
    settings["auto_offline_whitelist"] = str(settings.get("auto_offline_whitelist", "") or "").strip()
    upload_strategy = str(settings.get("hg_upload_strategy", "completed") or "completed").strip()
    if upload_strategy not in ("completed", "episode", "never"):
        upload_strategy = "completed"
    settings["hg_upload_strategy"] = upload_strategy
    settings["hg_upload_enabled"] = upload_strategy != "never"
    settings["hg_delete_after_upload"] = bool(settings.get("hg_delete_after_upload", False))
    settings["hg_target_cid"] = str(settings.get("hg_target_cid", "") or "").strip()
    settings["hg_target_path"] = str(settings.get("hg_target_path", "/黄果短剧") or "/黄果短剧").strip()
    try:
        settings["hg_check_interval"] = min(72, max(1, int(settings.get("hg_check_interval", 6))))
    except (TypeError, ValueError):
        settings["hg_check_interval"] = 6
    settings["hg_use_proxy"] = bool(settings.get("hg_use_proxy", True))
    settings["hg_site_mirrors"] = str(settings.get("hg_site_mirrors", "") or "").strip()
    try:
        settings["hg_episode_concurrency"] = min(4, max(1, int(settings.get("hg_episode_concurrency", 2))))
    except (TypeError, ValueError):
        settings["hg_episode_concurrency"] = 2
    settings["hg_follow_enabled"] = bool(settings.get("hg_follow_enabled", True))
    try:
        settings["hg_follow_pages"] = min(20, max(1, int(settings.get("hg_follow_pages", 3))))
    except (TypeError, ValueError):
        settings["hg_follow_pages"] = 3
    with db_lock, connect() as db:
        db.executemany(
            "INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)",
            [(key, json.dumps(value, ensure_ascii=False)) for key, value in settings.items()]
        )
    return public_settings()


def enabled_sources():
    return [row["domain"] for row in rows(
        "SELECT domain FROM scraper_sources WHERE enabled=1 ORDER BY position,domain"
    )]


def safe_name(value, fallback):
    cleaned = re.sub(r"[\\/:*?\"<>|\x00-\x1f]", " ", value or "").strip().strip(".")
    return cleaned[:150] or fallback


def detect_catalog(*values):
    for value in values:
        match = re.search(r"(?i)(?:^|[^a-z0-9])([a-z]{2,12})[\s_-]?(\d{2,6})(?:[^a-z0-9]|$)", value or "")
        if match:
            return f"{match.group(1).upper()}-{match.group(2)}"
    return ""


def validate_jable_url(page_url):
    parsed = urlparse(page_url)
    hostname = (parsed.hostname or "").lower().rstrip(".")
    if parsed.scheme not in ("http", "https") or not (hostname == "jable.tv" or hostname.endswith(".jable.tv")):
        raise ValueError("请输入 jable.tv 影片详情地址")
    return parsed


def clean_jable_title(value):
    title = html.unescape(re.sub(r"\s+", " ", value or "")).strip()
    title = re.sub(r"\s*[-|–]\s*Jable(?:\.TV)?\s*$", "", title, flags=re.IGNORECASE).strip()
    return safe_name(title, "")


def parse_cookie_header(cookie):
    pairs = []
    for part in str(cookie or "").split(";"):
        if "=" not in part:
            continue
        name, value = part.split("=", 1)
        name = name.strip()
        value = value.strip()
        if name:
            pairs.append((name, value))
    return pairs


def jable_headers(extra=None):
    headers = {"Accept-Language": "zh-CN,zh;q=0.9,en;q=0.7", "Referer": "https://jable.tv/"}
    cookie = str(get_settings().get("jable_cookie", "")).strip()
    if cookie:
        headers["Cookie"] = cookie
    if extra:
        headers.update(extra)
    return headers


def inject_jable_cookie(browser):
    cookie = str(get_settings().get("jable_cookie", "")).strip()
    if not cookie:
        return
    browser.cdp("Network.enable")
    for name, value in parse_cookie_header(cookie):
        browser.cdp("Network.setCookie", {
            "name": name, "value": value, "domain": ".jable.tv", "path": "/",
            "secure": True, "httpOnly": False, "sameSite": "None", "url": "https://jable.tv/"
        })


def inject_javbus_cookie(browser, domain):
    browser.cdp("Network.enable")
    for name, value in (("age", "verified"), ("existmag", "all"), ("over18", "1")):
        browser.cdp("Network.setCookie", {
            "name": name, "value": value, "domain": f".{domain.lstrip('.')}", "path": "/",
            "secure": True, "httpOnly": False, "sameSite": "None", "url": f"https://{domain}/"
        })


def extract_jable_details(page_url):
    parsed = validate_jable_url(page_url)
    from curl_cffi import requests as curl_requests
    catalog = detect_catalog(parsed.path)
    body = ""
    settings = get_settings()
    proxy = settings["proxy"] or None
    proxies = {"http": proxy, "https": proxy} if proxy else None
    try:
        response = curl_requests.get(
            page_url, impersonate="chrome120", timeout=8, allow_redirects=True,
            proxies=proxies,
            headers=jable_headers()
        )
        response.raise_for_status()
        body = response.text
    except Exception:
        pass
    candidates = [
        r'<meta[^>]+property=["\']og:title["\'][^>]+content=["\']([^"\']+)',
        r'<meta[^>]+content=["\']([^"\']+)["\'][^>]+property=["\']og:title["\']',
        r'<h4[^>]*>(.*?)</h4>', r'<title[^>]*>(.*?)</title>'
    ]
    title = ""
    for pattern in candidates:
        match = re.search(pattern, body, re.IGNORECASE | re.DOTALL)
        if match:
            title = clean_jable_title(re.sub(r"<[^>]+>", " ", match.group(1)))
            if title:
                break
    catalog = detect_catalog(catalog, title)
    if not title and catalog:
        for source in enabled_sources()[:1]:
            try:
                scraper = Sracper(str(WORK_DIR), proxy, timeout=8)
                scraper.domain = source
                source_html = scraper._fetch_html(f"https://{source}/{catalog}", referer=f"https://{source}/")
                metadata = scraper._extract(source_html) if source_html else None
                if metadata and metadata.title:
                    title = metadata.title
                    break
            except Exception:
                continue
    if not title and catalog:
        title = catalog
    if not title and not catalog:
        raise ValueError("详情页未找到标题或番号，请确认页面可以正常访问")
    return {"title": title, "catalog": catalog}


catalog_cache = {}
detail_cache = {}
# 磁力链接独立缓存（按番号）：有效结果 6 小时，空结果 5 分钟（避免网络抖动导致长时间空缓存）
_MAGNET_CACHE = {}


CATALOG_URLS = {
    "latest": "https://jable.tv/latest-updates/",
    "chinese": "https://jable.tv/categories/chinese-subtitle/",
}


def _catalog_url(section, page):
    base = CATALOG_URLS.get(section, CATALOG_URLS["latest"])
    if page <= 1:
        return base
    return urljoin(base, f"{page}/")


def chromium_latest_catalog(page=1, force=False, section="latest"):
    section = str(section or "latest").strip()
    if section not in CATALOG_URLS:
        section = "latest"
    page = max(1, int(page or 1))
    cache_key = (section, page)
    cached = catalog_cache.get(cache_key)
    if not force and cached and cached["items"] and time.time() - cached["updated_at"] < 300:
        return cached
    proxy = get_settings()["proxy"]
    script = """
        const roots = [...document.querySelectorAll('#list_videos_latest_videos_list .col-6, #list_videos_latest_videos_list .video-img-box, .video-img-box')];
        const cards = [...new Set(roots.map(node => node.closest('.col-6, .col-sm-4, .col-lg-3') || node))];
        const items = cards.map(card => {
          const link = card.querySelector('.detail h6.title a, h6.title a, .detail a[href*="/videos/"]');
          const image = card.querySelector('.img-box img, img');
          const duration = card.querySelector('.label, .duration, .absolute-bottom-right');
          return link ? {
            detail_url: link.href,
            title: (link.textContent || '').replace(/\\s+/g, ' ').trim(),
            image_url: image ? (image.currentSrc || image.dataset.src || image.src || '') : '',
            duration: duration ? (duration.textContent || '').trim() : ''
          } : null;
        }).filter(Boolean).filter((item, index, all) => all.findIndex(x => x.detail_url === item.detail_url) === index);
        const next = [...document.querySelectorAll('a[href]')].some(a => {
          const text = (a.textContent || '').trim().toLowerCase();
          return text === 'next' || text === '下一页' || text === '›' || text === '»' || a.href.includes('%PAGE_NEXT_PATH%');
        });
        return {items, has_next: next};
    """
    script = script.replace("%PAGE_NEXT_PATH%", urlparse(_catalog_url(section, page + 1)).path)
    url = _catalog_url(section, page)
    with browser_lock, _persistent_chrome(proxy) as browser:
        inject_jable_cookie(browser)
        browser.navigate(url)
        items = []
        has_next = False
        for _ in range(25):
            time.sleep(1)
            result = browser.execute(script) or {}
            items = result.get("items", []) if isinstance(result, dict) else result
            has_next = bool(result.get("has_next")) if isinstance(result, dict) else False
            if items:
                break
        if not items:
            title = browser.execute("return document.title || ''")
            body = browser.execute("return (document.body && document.body.innerText || '').slice(0,200)")
            if re.search(r"just a moment|security verification|verify you are not a bot", f"{title}\n{body}", re.I):
                raise RuntimeError("Jable 返回 Cloudflare 验证页，请在服务设置里填写可访问浏览器的 Jable Cookie 后刷新")
            raise RuntimeError(f"影片列表加载失败：{title or body or 'Jable 拒绝了自动浏览器访问'}")
    normalized = []
    for item in items[:80]:
        detail_url = str(item.get("detail_url", ""))
        try:
            parsed = validate_jable_url(detail_url)
        except ValueError:
            continue
        if "/videos/" not in parsed.path:
            continue
        title = clean_jable_title(str(item.get("title", "")))
        normalized.append({
            "detail_url": detail_url,
            "title": title,
            "catalog": detect_catalog(parsed.path, title),
            "image_url": urljoin(detail_url, str(item.get("image_url", ""))),
            "duration": str(item.get("duration", "")).strip()
        })
    result = {"section": section, "page": page, "items": normalized, "page_size": len(normalized), "has_next": has_next or len(normalized) >= 24}
    catalog_cache[cache_key] = {"updated_at": time.time(), **result}
    return result


def normalize_magnet_name(value, fallback):
    text = html.unescape(re.sub(r"\s+", " ", value or "")).strip()
    text = re.sub(r"複製連結|复制链接|下載|下载|字幕|高清|磁力連結|磁力链接", " ", text)
    text = re.sub(r"\s+", " ", text).strip(" -")
    return safe_name(text, fallback)


def javbus_magnets(catalog, max_domains=0):
    """通过 curl_cffi 请求 JavBus 详情页 + ajax 磁力接口，绕开 Chromium 和 Cloudflare。

    遍历已启用的刮削源（包括 busdmm / dmmsee 等 JavBus 镜像），
    先 GET 详情页提取 gid/img/uc，再 GET /ajax/uncledatoolsbyajax.php 解析磁力。
    max_domains>0 时只尝试前 N 个源，用于详情快速路径控制耗时。
    多源并行探测，首个返回磁力的源直接采用（原来串行遍历最坏 60 秒）。
    """
    catalog = detect_catalog(catalog)
    if not catalog:
        return []
    # 磁力链接内容基本不变，独立缓存：命中时 0 开销
    cached = _MAGNET_CACHE.get(catalog)
    if cached and time.time() - cached["updated_at"] < (300 if not cached["magnets"] else 21600):
        return cached["magnets"]
    from curl_cffi import requests as curl_requests
    settings = get_settings()
    proxy = settings["proxy"] or None
    proxies = {"http": proxy, "https": proxy} if proxy else None
    domains = enabled_sources() or DEFAULT_SOURCES
    if max_domains > 0:
        domains = domains[:max_domains]

    def _fetch_html(domain, path):
        url = f"https://{domain}{path}"
        try:
            resp = curl_requests.get(
                url, impersonate="chrome120", timeout=6, allow_redirects=True,
                proxies=proxies,
                headers={
                    "Referer": f"https://{domain}/",
                    "Cookie": "age=verified; existmag=all; over18=1",
                    "Accept-Language": "zh-CN,zh;q=0.9",
                },
            )
            resp.raise_for_status()
            return resp.text
        except Exception:
            return ""

    def _extract_page_info(html):
        if not html:
            return None
        gid_match = re.search(r"var\s+gid\s*=\s*['\"]?(\d+)", html, re.IGNORECASE)
        if not gid_match:
            return None
        gid = gid_match.group(1)
        uc_match = re.search(r"var\s+uc\s*=\s*['\"]?(\d+)", html, re.IGNORECASE)
        uc = uc_match.group(1) if uc_match else "0"
        img_match = re.search(r"var\s+img\s*=\s*['\"]([^'\"]+)", html, re.IGNORECASE)
        img = img_match.group(1) if img_match else ""
        bigimg = re.search(r'<a class="bigImage"[^>]+href="([^"]+)"', html, re.IGNORECASE)
        if not img and bigimg:
            img = bigimg.group(1)
        return {"gid": gid, "uc": uc, "img": img}

    def _parse_magnets(ajax_html, domain):
        if not ajax_html:
            return []
        magnets = []
        seen = set()
        # 按 <tr> 分行，每行三个 <td>：名字 | 大小 | 日期
        tr_pattern = re.compile(r"<tr[^>]*>(.*?)</tr>", re.IGNORECASE | re.DOTALL)
        for tr_match in tr_pattern.finditer(ajax_html):
            tr_html = tr_match.group(1)
            magnet_match = re.search(
                r'<a\s+[^>]*href=["\'](magnet:[^"\']+)["\'][^>]*>(.*?)</a>',
                tr_html, re.IGNORECASE | re.DOTALL,
            )
            if not magnet_match:
                continue
            url = magnet_match.group(1).strip()
            if not url.startswith("magnet:") or url in seen:
                continue
            seen.add(url)
            td_texts = re.findall(r"<td[^>]*>(.*?)</td>", tr_html, re.IGNORECASE | re.DOTALL)
            td_texts = [
                re.sub(r"<[^>]+>", " ", td) for td in td_texts
            ]
            td_texts = [
                re.sub(r"\s+", " ", html.unescape(td)).strip() for td in td_texts
            ]
            name = td_texts[0] if td_texts else (magnet_match.group(2).strip() or f"{catalog} 磁力")
            size = ""
            date_str = ""
            if len(td_texts) >= 2:
                size_match = re.search(r"(\d+(?:\.\d+)?)\s*(?:GB|GiB|MB|MiB)", td_texts[1], re.IGNORECASE)
                size = size_match.group(0) if size_match else td_texts[1]
            if len(td_texts) >= 3:
                date_str = td_texts[2]
            magnets.append({
                "name": normalize_magnet_name(name, f"{catalog} 磁力 {len(magnets) + 1}"),
                "url": url,
                "size": size,
                "files": date_str,
                "source": domain,
            })
        return magnets

    def _probe_domain(domain):
        """单个源：详情页 → ajax 磁力。返回磁力列表（可能为空）。"""
        domain = str(domain or "").strip().strip("/")
        if not domain:
            return []
        try:
            page_html = _fetch_html(domain, f"/{catalog}")
            if not page_html:
                return []
            info = _extract_page_info(page_html)
            if not info:
                return []
            ajax_html = _fetch_html(
                domain,
                f"/ajax/uncledatoolsbyajax.php?gid={info['gid']}&lang=zh&img={info['img']}&uc={info['uc']}&floor={int(time.time() * 1000) % 1000 + 1}",
            )
            return _parse_magnets(ajax_html, domain)
        except Exception:
            return []

    # 多源并行探测：谁先返回磁力用谁（as_completed 按完成顺序），整体耗时约等于最快的可用源
    live_domains = [d for d in domains if str(d or "").strip().strip("/")]
    if not live_domains:
        return []
    with ThreadPoolExecutor(max_workers=min(len(live_domains), 4)) as executor:
        futures = [executor.submit(_probe_domain, d) for d in live_domains]
        for future in as_completed(futures):
            try:
                magnets = future.result()
            except Exception:
                continue
            if magnets:
                _MAGNET_CACHE[catalog] = {"updated_at": time.time(), "magnets": magnets}
                return magnets
    _MAGNET_CACHE[catalog] = {"updated_at": time.time(), "magnets": []}
    return []


def chromium_javbus_magnets(catalog):
    """Deprecated: kept as wrapper for backward compatibility."""
    return javbus_magnets(catalog)


def _fast_jable_detail(detail_url, parsed):
    """requests 快速抓取 jable 详情（og meta + 截图 + javbus 磁力），失败返回 None。

    比 Chromium 路径快一个量级（约 2-5 秒 vs 15-40 秒），Cloudflare 拦截时回退。
    jable 页面抓取与 javbus 磁力探测并行执行（磁力只依赖番号，不依赖页面内容）。
    """
    from curl_cffi import requests as curl_requests
    settings = get_settings()
    proxy = settings["proxy"] or None
    proxies = {"http": proxy, "https": proxy} if proxy else None
    catalog = detect_catalog(parsed.path)

    # 磁力探测先起后台线程（与 jable 页面抓取并行；缓存命中时立即返回）
    magnet_future = None
    if catalog:
        magnet_executor = ThreadPoolExecutor(max_workers=1)
        magnet_future = magnet_executor.submit(javbus_magnets, catalog, 3)

    try:
        response = curl_requests.get(
            detail_url, impersonate="chrome120", timeout=10, allow_redirects=True,
            proxies=proxies, headers=jable_headers()
        )
        response.raise_for_status()
        body = response.text
    except Exception:
        body = ""
        if magnet_future is not None:
            magnet_future.cancel()
            magnet_executor.shutdown(wait=False)
    else:
        title = ""
        for pattern in (r'<meta[^>]+property=["\']og:title["\'][^>]+content=["\']([^"\']+)',
                        r'<meta[^>]+content=["\']([^"\']+)["\'][^>]+property=["\']og:title["\']',
                        r'<h4[^>]*>(.*?)</h4>'):
            match = re.search(pattern, body, re.IGNORECASE | re.DOTALL)
            if match:
                title = clean_jable_title(re.sub(r"<[^>]+>", " ", match.group(1)))
                if title:
                    break
        if not title:
            if magnet_future is not None:
                magnet_future.cancel()
                magnet_executor.shutdown(wait=False)
            return None
        cover = ""
        cover_match = (re.search(r'<meta[^>]+property=["\']og:image["\'][^>]+content=["\']([^"\']+)', body, re.I)
                       or re.search(r'<meta[^>]+content=["\']([^"\']+)["\'][^>]+property=["\']og:image["\']', body, re.I))
        if cover_match:
            cover = cover_match.group(1)
        samples = []
        for match in re.finditer(r'(?:src|href|data-src)=["\']([^"\']*(?:videos_screenshots|screenshots)[^"\']+)["\']', body, re.I):
            value = urljoin(detail_url, html.unescape(match.group(1)))
            if value not in samples:
                samples.append(value)
        result = {
            "detail_url": detail_url,
            "title": title,
            "catalog": catalog,
            "cover_url": urljoin(detail_url, html.unescape(cover)),
            "samples": samples[:40],
            "magnets": []
        }
        if magnet_future is not None:
            try:
                result["magnets"] = magnet_future.result(timeout=15)
            except Exception:
                result["magnets"] = []
            finally:
                magnet_executor.shutdown(wait=False)
        elif not catalog:
            # URL 路径提取不出番号：用标题二次修正后同步抓磁力
            catalog = detect_catalog(parsed.path, title)
            result["catalog"] = catalog
            if catalog:
                try:
                    result["magnets"] = javbus_magnets(catalog, max_domains=3)
                except Exception:
                    result["magnets"] = []
        return result


def chromium_jable_detail(detail_url, force=False):
    parsed = validate_jable_url(detail_url)
    if "/videos/" not in parsed.path:
        raise ValueError("请选择 Jable 影片详情地址")
    cached = detail_cache.get(detail_url)
    if not force and cached and time.time() - cached["updated_at"] < 900:
        return cached["data"]
    if not force:
        fast = _fast_jable_detail(detail_url, parsed)
        if fast:
            detail_cache[detail_url] = {"updated_at": time.time(), "data": fast}
            return fast
    proxy = get_settings()["proxy"]
    script = """
        const abs = (value) => {
          try { return value ? new URL(value, location.href).href : ''; } catch { return ''; }
        };
        const clean = (value) => (value || '').replace(/\\s+/g, ' ').trim();
        const title = clean(document.querySelector('meta[property="og:title"]')?.content || document.querySelector('h4')?.textContent || document.title || '');
        const cover = abs(document.querySelector('meta[property="og:image"]')?.content || document.querySelector('.video-img-box img, .img-box img, video[poster], img')?.poster || document.querySelector('.video-img-box img, .img-box img, img')?.currentSrc || document.querySelector('.video-img-box img, .img-box img, img')?.src || '');
        const sampleNodes = [...document.querySelectorAll('a[href*="videos_screenshots"], a[href*="screenshots"], img[src*="videos_screenshots"], img[data-src*="videos_screenshots"], img[src*="screenshots"], img[data-src*="screenshots"]')];
        const samples = [...new Set(sampleNodes.map(node => abs(node.href || node.currentSrc || node.dataset?.src || node.src)).filter(Boolean))]
          .filter(url => !cover || url !== cover)
          .slice(0, 40);
        const magnetAnchors = [...document.querySelectorAll('a[href^="magnet:"]')];
        const magnets = magnetAnchors.map(anchor => {
          const row = anchor.closest('tr, li, .row, .item, .magnet, .magnet-item, div') || anchor;
          const text = clean(row.innerText || anchor.textContent || '');
          const size = (text.match(/[0-9]+(?:\\.[0-9]+)?\\s*(?:GB|GiB|MB|MiB)/i) || [''])[0];
          const files = (text.match(/[0-9]+\\s*(?:个文件|files?|文件)/i) || [''])[0];
          return {name: text || '磁力链接', url: anchor.href, size, files};
        }).filter((item, index, all) => item.url && all.findIndex(other => other.url === item.url) === index);
        return {title, cover_url: cover, samples, magnets};
    """
    with browser_lock, _persistent_chrome(proxy) as browser:
        inject_jable_cookie(browser)
        browser.navigate(detail_url)
        data = {}
        for _ in range(50):
            time.sleep(0.3)
            data = browser.execute(script) or {}
            if data.get("title") or data.get("cover_url") or data.get("samples") or data.get("magnets"):
                break
        if not data:
            title = browser.execute("return document.title || ''")
            raise RuntimeError(f"详情页加载失败：{title or 'Jable 拒绝了自动浏览器访问'}")
    title = clean_jable_title(str(data.get("title", "")))
    catalog = detect_catalog(parsed.path, title)
    result = {
        "detail_url": detail_url,
        "title": title or catalog,
        "catalog": catalog,
        "cover_url": urljoin(detail_url, str(data.get("cover_url", ""))),
        "samples": [urljoin(detail_url, str(value)) for value in data.get("samples", []) if value],
        "magnets": data.get("magnets", [])
    }
    if catalog and not result["magnets"]:
        try:
            result["magnets"] = javbus_magnets(catalog)
        except Exception:
            result["magnets"] = []
    detail_cache[detail_url] = {"updated_at": time.time(), "data": result}
    return result


def chromium_capture_video(detail_url):
    parsed = validate_jable_url(detail_url)
    if "/videos/" not in parsed.path:
        raise ValueError("请选择 Jable 影片详情地址")
    proxy = get_settings()["proxy"]
    with browser_lock, _persistent_chrome(proxy) as browser:
        inject_jable_cookie(browser)
        browser.navigate(detail_url)
        streams = []
        title = ""
        for attempt in range(40):
            time.sleep(1)
            if attempt in (3, 8):
                try:
                    browser.execute("""
                        const video=document.querySelector('video');
                        if(video){video.muted=true; video.play().catch(()=>{});}
                        const play=document.querySelector('.plyr__control--overlaid,button[aria-label*="Play"],button[aria-label*="播放"]');
                        if(play) play.click();
                    """)
                except Exception:
                    pass
            try:
                title = browser.execute("""
                    const meta=document.querySelector('meta[property="og:title"]');
                    const heading=document.querySelector('h4');
                    return (meta?.content || heading?.textContent || document.title || '').trim();
                """) or title
                resource_urls = browser.execute("""
                    return performance.getEntriesByType('resource').map(x=>x.name).filter(x=>/\\.m3u8(?:$|\\?)/i.test(x));
                """) or []
                streams.extend(resource_urls)
            except Exception:
                pass
            try:
                for entry in browser.performance_logs():
                    message = json.loads(entry.get("message", "{}")).get("message", {})
                    if message.get("method") != "Network.responseReceived":
                        continue
                    response = message.get("params", {}).get("response", {})
                    candidate = response.get("url", "")
                    if re.search(r"\.m3u8(?:$|\?)", candidate, re.IGNORECASE):
                        streams.append(candidate)
            except Exception:
                pass
            streams = list(dict.fromkeys(streams))
            if streams:
                break
        if not streams:
            page_title = browser.execute("return document.title || ''")
            raise RuntimeError(f"未捕获到 M3U8：{page_title or '请确认影片可以播放'}")
    title = clean_jable_title(title)
    catalog = detect_catalog(parsed.path, title)
    preferred = next((stream for stream in reversed(streams) if re.search(r"/\d+\.m3u8(?:$|\?)", stream)), streams[-1])
    return {"detail_url": detail_url, "title": title or catalog, "catalog": catalog, "media_url": preferred}


def request_with_proxy(url, data=None, headers=None, method=None, timeout=20):
    proxy = str(get_settings().get("proxy", "")).strip()
    request_object = Request(url, data=data, headers=headers or {}, method=method)
    if not proxy:
        return urlopen(request_object, timeout=timeout)
    opener = build_opener(ProxyHandler({"http": proxy, "https": proxy}))
    return opener.open(request_object, timeout=timeout)


def submit_115_bridge(task_id, source_url, title, catalog, detail_url, settings):
    endpoint = str(settings.get("cloud115_endpoint", "")).strip()
    if not endpoint:
        raise ValueError("请先在 115 设置中填写离线服务地址")
    parsed_endpoint = urlparse(endpoint)
    if parsed_endpoint.scheme not in ("http", "https"):
        raise ValueError("115 离线服务地址必须以 HTTP 或 HTTPS 开头")
    bridge_payload = json.dumps({
        "id": task_id, "url": source_url, "name": title, "catalog": catalog, "detail_url": detail_url
    }).encode()
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    token = str(settings.get("cloud115_token", "")).strip()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    with request_with_proxy(endpoint, data=bridge_payload, headers=headers, method="POST", timeout=20) as response:
        return json.loads(response.read().decode("utf-8", errors="replace") or "{}")


def submit_115_cookie(source_url, title, settings, dest_cid=""):
    cookie = str(settings.get("cloud115_cookie", "")).strip()
    if not cookie:
        raise ValueError("请先保存 115 Cookie，或切换为中转服务模式")
    # 指定 wp_path_id：离线产物直接落到目标目录（省去完成后转移）；空 = 默认云下载
    form = urlencode({"url": source_url, "wp_path_id": str(dest_cid or "0")}).encode()
    headers = {
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        "Accept": "application/json, text/plain, */*",
        "Cookie": cookie,
        "Origin": "https://115.com",
        "Referer": "https://115.com/",
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    }
    endpoint = "https://115.com/web/lixian/?ct=lixian&ac=add_task_url"
    with request_with_proxy(endpoint, data=form, headers=headers, method="POST", timeout=25) as response:
        raw = response.read().decode("utf-8", errors="replace")
    try:
        reply = json.loads(raw or "{}")
    except ValueError:
        reply = {"state": False, "message": raw[:180]}
    state_value = reply.get("state", reply.get("status"))
    if state_value not in (True, 1, "1", "true", "success", "ok"):
        message = reply.get("message") or reply.get("error_msg") or reply.get("msg") or "115 返回失败，请检查 Cookie 是否有效"
        raise RuntimeError(str(message))
    return {
        "state": "submitted",
        "message": str(reply.get("message") or reply.get("msg") or f"已提交 115 离线：{title}"),
        "play_url": str(reply.get("play_url") or ""),
        "info_hash": str(reply.get("info_hash") or "")
    }


def submit_115_task(task_id, source_url, title, catalog, detail_url, dest_cid=""):
    settings = get_settings()
    if str(settings.get("cloud115_mode", "bridge")) == "cookie":
        return submit_115_cookie(source_url, title, settings, dest_cid=dest_cid)
    return submit_115_bridge(task_id, source_url, title, catalog, detail_url, settings)


def create_cloud_record(task_id, source_url, title, catalog, detail_url, reply, dest_cid=""):
    state = str(reply.get("state", reply.get("status", "submitted")))
    if state in ("True", "true"):
        state = "submitted"
    message = str(reply.get("message", "已提交到 115 离线队列"))
    play_url = str(reply.get("play_url", ""))
    info_hash = str(reply.get("info_hash", "") or "")
    with db_lock, connect() as db:
        db.execute("""INSERT INTO cloud_tasks(
            id,title,catalog,source_url,detail_url,state,message,play_url,info_hash,dest_cid,created_at,finished_at
        ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""", (
            task_id, title, catalog, source_url, detail_url, state,
            message, play_url, info_hash, str(dest_cid or ""),
            datetime.now().isoformat(timespec="seconds"),
            datetime.now().isoformat(timespec="seconds") if state in ("completed", "failed") else None
        ))
    return {"id": task_id, "state": state, "message": message, "play_url": play_url}


# ---------- 自动离线到 115（模式A=浏览触发, 模式B=定时追新） ----------

_AUTO_OFFLINE_LOCK = threading.Lock()


def _parse_duration_min(text):
    """'1:59:00'/'59:00' → 分钟数；解析失败返回 None。"""
    match = re.search(r"(?:(\d+):)?(\d+):(\d+)", str(text or ""))
    if not match:
        return None
    hours, minutes, seconds = (int(group or 0) for group in match.groups())
    return hours * 60 + minutes + (1 if seconds > 0 else 0)


def _parse_size_gb(text):
    """'4.6GB'/'3256MB' → GB 数值；解析失败返回 0。"""
    match = re.search(r"(\d+(?:\.\d+)?)\s*(GB|GiB|MB|MiB)", str(text or ""), re.IGNORECASE)
    if not match:
        return 0.0
    value = float(match.group(1))
    if match.group(2).upper().startswith("MB"):
        value /= 1024
    return value


def _auto_offline_cfg():
    settings = get_settings()
    return {
        "enabled": bool(settings.get("auto_offline_enabled")),
        "browse": bool(settings.get("auto_offline_browse", True)),
        "schedule": bool(settings.get("auto_offline_schedule", True)),
        "interval": max(1, int(settings.get("auto_offline_interval", 6) or 6)),
        "pages": max(1, int(settings.get("auto_offline_pages", 2) or 2)),
        "whitelist": str(settings.get("auto_offline_whitelist", "") or ""),
        "min_duration": max(0, int(settings.get("auto_offline_min_duration", 60) or 0)),
        "min_size": max(0, float(settings.get("auto_offline_min_size", 3) or 0)),
        "daily_limit": max(1, int(settings.get("auto_offline_daily_limit", 5) or 5)),
    }


def _auto_offline_seen(catalog):
    """番号是否已处理过（cloud_tasks 或 自动离线日志里存在即跳过）。"""
    catalog = str(catalog or "").strip().upper()
    if not catalog:
        return True
    if rows("SELECT 1 FROM cloud_tasks WHERE UPPER(catalog)=? LIMIT 1", (catalog,)):
        return True
    return bool(rows("SELECT 1 FROM auto_offline_log WHERE UPPER(catalog)=? LIMIT 1", (catalog,)))


def _auto_offline_today_count():
    today = datetime.now().strftime("%Y-%m-%d")
    row = rows("SELECT COUNT(*) AS n FROM auto_offline_log WHERE state='submitted' AND created_at LIKE ?", (f"{today}%",))
    return int(row[0]["n"]) if row else 0


def _auto_offline_pick_magnet(magnets):
    """选体积最大的磁力（通常是最高清版本）。"""
    best, best_gb = None, -1.0
    for magnet in magnets or []:
        gb = _parse_size_gb(magnet.get("size", ""))
        if gb > best_gb:
            best, best_gb = magnet, gb
    return best


def auto_offline_evaluate(catalog, title, detail_url, duration_text, magnets, mode):
    """统一评估入口：开关/模式/去重/规则/限额全部通过后提交 115 离线并记日志。"""
    catalog = str(catalog or "").strip().upper()
    result = {"catalog": catalog, "mode": mode, "state": "skipped"}
    try:
        cfg = _auto_offline_cfg()
        if not cfg["enabled"]:
            result["message"] = "自动离线未开启"
            return result
        if mode == "browse" and not cfg["browse"]:
            result["message"] = "浏览触发模式未开启"
            return result
        if mode == "schedule" and not cfg["schedule"]:
            result["message"] = "定时追新模式未开启"
            return result
        if not catalog or not magnets:
            result["message"] = "无番号或磁力"
            return result
        with _AUTO_OFFLINE_LOCK:
            if _auto_offline_seen(catalog):
                result["message"] = "该番号已处理过"
                return result
            whitelist = [word.strip().upper() for word in cfg["whitelist"].split(",") if word.strip()]
            if whitelist and not any(word in catalog for word in whitelist):
                result["message"] = "不在白名单"
                return result
            duration_min = _parse_duration_min(duration_text)
            if cfg["min_duration"] > 0 and duration_min is not None and duration_min < cfg["min_duration"]:
                result["message"] = f"时长 {duration_min} 分钟低于下限 {cfg['min_duration']}"
                return result
            best = _auto_offline_pick_magnet(magnets)
            if not best:
                result["message"] = "磁力无有效体积信息"
                return result
            size_gb = _parse_size_gb(best.get("size", ""))
            if cfg["min_size"] > 0 and size_gb < cfg["min_size"]:
                result["message"] = f"体积 {size_gb:.1f}GB 低于下限 {cfg['min_size']}GB"
                return result
            if _auto_offline_today_count() >= cfg["daily_limit"]:
                result["message"] = f"已达单日上限 {cfg['daily_limit']} 部"
                return result
            # 全部通过：提交 115 离线
            task_id = str(uuid.uuid4())
            settings = get_settings()
            dest_cid = str(settings.get("cloud_transfer_cid", "") or "").strip() \
                if settings.get("cloud_transfer_enabled") else ""
            try:
                reply = submit_115_task(task_id, best["url"], title or catalog, catalog, detail_url, dest_cid=dest_cid)
                record = create_cloud_record(task_id, best["url"], title or catalog, catalog, detail_url, reply, dest_cid=dest_cid)
                state, message = "submitted", str(record.get("message", "已提交"))[:180]
                cloud_task_id = task_id
            except Exception as error:
                state, message, cloud_task_id = "failed", str(error)[:180], ""
            with db_lock, connect() as db:
                db.execute("""INSERT INTO auto_offline_log(
                    id,catalog,title,magnet_url,magnet_size,mode,state,message,cloud_task_id,created_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?)""", (
                    str(uuid.uuid4()), catalog, title or catalog, best["url"],
                    str(best.get("size", "")), mode, state, message, cloud_task_id,
                    datetime.now().isoformat(timespec="seconds"),
                ))
            result.update({"state": state, "message": message, "size": best.get("size", "")})
            return result
    except Exception as error:
        result["message"] = f"评估异常：{str(error)[:120]}"
        return result


def run_auto_offline_scan(pages=None, trigger="manual"):
    """模式 B：扫描 jable 最新列表，逐个匹配规则自动离线。"""
    cfg = _auto_offline_cfg()
    if not cfg["enabled"] or not cfg["schedule"]:
        return {"scanned": 0, "results": [], "message": "定时追新未开启"}
    pages = pages or cfg["pages"]
    collected = []
    for page in range(1, pages + 1):
        try:
            data = chromium_latest_catalog(page=page)
            collected.extend(data.get("items", []))
        except Exception:
            break
    results = []
    for item in collected:
        catalog = str(item.get("catalog", "")).strip().upper()
        if not catalog or _auto_offline_seen(catalog):
            continue
        try:
            magnets = javbus_magnets(catalog, max_domains=2)
        except Exception:
            continue
        if not magnets:
            continue
        result = auto_offline_evaluate(
            catalog, str(item.get("title", "")), str(item.get("detail_url", "")),
            str(item.get("duration", "")), magnets, mode="schedule")
        results.append(result)
        if _auto_offline_today_count() >= cfg["daily_limit"]:
            results.append({"catalog": "-", "state": "skipped", "message": "已达单日上限，停止本轮扫描"})
            break
        time.sleep(2)  # 轻微节流，降低对刮削源的压力
    return {"scanned": len(collected), "results": results}


def auto_offline_scheduler():
    """模式 B 调度线程：按配置间隔自动扫描（5 分钟粒度感知配置变化）。"""
    last_run = 0.0
    while True:
        try:
            cfg = _auto_offline_cfg()
            if cfg["enabled"] and cfg["schedule"]:
                if time.time() - last_run >= cfg["interval"] * 3600:
                    last_run = time.time()
                    try:
                        run_auto_offline_scan(trigger="schedule")
                    except Exception:
                        pass
        except Exception:
            pass
        time.sleep(300)


def qr_cookie_string(value):
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, dict):
        return "; ".join(f"{key}={item}" for key, item in value.items() if item)
    if isinstance(value, list):
        parts = []
        for item in value:
            if isinstance(item, dict) and item.get("name") and item.get("value"):
                parts.append(f"{item['name']}={item['value']}")
        return "; ".join(parts)
    return ""


def qr_image_data_url(qr_url):
    """115 返回的 qrcode 字段是二维码图片地址（PNG 内嵌真实扫码内容），直接取图展示。

    旧实现把该 URL 再编码成二维码导致"扫码打开又一张二维码"的套娃问题。
    """
    try:
        with request_with_proxy(str(qr_url),
                                headers={"User-Agent": "Mozilla/5.0 Chrome/131.0 Safari/537.36"},
                                method="GET", timeout=15) as response:
            data = response.read()
        if data.startswith(b"\x89PNG"):
            return "data:image/png;base64," + base64.b64encode(data).decode()
    except Exception:
        pass
    try:
        import qrcode
        from io import BytesIO
        buffer = BytesIO()
        qrcode.make(qr_url).save(buffer, format="PNG")
        return "data:image/png;base64," + base64.b64encode(buffer.getvalue()).decode()
    except Exception:
        return ""


def request_115_qr_token(client="web"):
    headers = {
        "Accept": "application/json, text/plain, */*",
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    }
    with request_with_proxy(
        f"https://qrcodeapi.115.com/api/1.0/{client}/1.0/token/",
        headers=headers, method="GET", timeout=20
    ) as response:
        reply = json.loads(response.read().decode("utf-8", errors="replace") or "{}")
    data = reply.get("data") or reply
    uid = str(data.get("uid", "")).strip()
    sign = str(data.get("sign", "")).strip()
    timestamp = str(data.get("time", data.get("timestamp", ""))).strip()
    qrcode_url = str(data.get("qrcode", "")).strip()
    if not qrcode_url and uid:
        qrcode_url = f"https://qrcodeapi.115.com/api/1.0/{client}/1.0/qrcode?uid={uid}"
    if not uid or not sign or not timestamp:
        raise RuntimeError("115 没有返回有效二维码参数")
    with qr_login_lock:
        qr_login_session.update(uid=uid, sign=sign, time=timestamp, qrcode=qrcode_url, client=client, created_at=time.time())
    return {"uid": uid, "qrcode": qrcode_url, "image": qr_image_data_url(qrcode_url)}


def poll_115_qr_login():
    with qr_login_lock:
        current = dict(qr_login_session)
    if not current.get("uid"):
        raise ValueError("请先生成 115 登录二维码")
    query = urlencode({"uid": current["uid"], "time": current["time"], "sign": current["sign"]})
    headers = {"Accept": "application/json", "User-Agent": "Mozilla/5.0 Chrome/131.0 Safari/537.36"}
    with request_with_proxy(f"https://qrcodeapi.115.com/get/status/?{query}",
                            headers=headers, method="GET", timeout=8) as response:
        status_reply = json.loads(response.read().decode("utf-8", errors="replace") or "{}")
    status_data = status_reply.get("data") or status_reply
    status = int(status_data.get("status", status_data.get("state", 0)) or 0)
    if status < 2:
        return {"status": "waiting" if status == 0 else "scanned", "message": "等待扫码确认" if status == 0 else "已扫码，等待手机确认"}
    qr_client = str(current.get("client") or "web")
    form = urlencode({"account": current["uid"], "app": qr_client}).encode()
    login_headers = {
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        "Accept": "application/json",
        "User-Agent": "Mozilla/5.0 Chrome/131.0 Safari/537.36",
        "Referer": "https://115.com/"
    }
    with request_with_proxy(f"https://passportapi.115.com/app/1.0/{qr_client}/1.0/login/qrcode/",
                            data=form, headers=login_headers, method="POST", timeout=20) as response:
        login_reply = json.loads(response.read().decode("utf-8", errors="replace") or "{}")
    cookie = qr_cookie_string((login_reply.get("data") or {}).get("cookie") or login_reply.get("cookie"))
    if not cookie:
        raise RuntimeError("扫码已确认，但 115 没有返回 Cookie")
    save_settings({"cloud115_mode": "cookie", "cloud115_cookie": cookie})
    return {"status": "authorized", "message": "115 Cookie 已保存"}


def format_size(byte_count):
    value = float(byte_count or 0)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return f"{value:.1f} {unit}"
        value /= 1024


def format_duration(seconds):
    if not seconds or seconds < 0:
        return "-"
    seconds = int(seconds)
    if seconds >= 3600:
        return f"{seconds // 3600}:{seconds % 3600 // 60:02d}:{seconds % 60:02d}"
    return f"{seconds // 60:02d}:{seconds % 60:02d}"


def directory_size(path):
    total = 0
    try:
        for item in path.rglob("*"):
            if item.is_file():
                total += item.stat().st_size
    except OSError:
        pass
    return total


def media_file_in(path):
    path = Path(path)
    if path.is_file() and path.suffix.lower() in MEDIA_EXTENSIONS:
        return path
    if path.is_dir():
        return next((item for item in path.iterdir() if item.is_file() and item.suffix.lower() in MEDIA_EXTENSIONS), None)
    return None


def resolve_media_path(value):
    candidate = Path(value)
    if not candidate.is_absolute():
        candidate = MEDIA_DIR / candidate
    resolved = candidate.resolve()
    media_root = MEDIA_DIR.resolve()
    if resolved != media_root and media_root not in resolved.parents:
        raise ValueError("路径必须位于 NAS 成片目录 /media 内")
    return resolved


def find_duplicate(catalog, exclude_task_id=""):
    if not catalog:
        return ""
    existing = rows(
        """SELECT output_path FROM tasks WHERE catalog=? AND id<>?
        AND state IN ('pending','running','completed','skipped') LIMIT 1""",
        (catalog, exclude_task_id)
    )
    if existing:
        recorded = existing[0]["output_path"] or ""
        # 成片文件可能已被手动删除（如传到 115 后清理本地）：文件不在了就不算重复，允许重新下载
        if recorded and Path(recorded).exists():
            return recorded
    catalog_pattern = re.escape(catalog).replace(r"\-", "[-_ ]?")
    pattern = re.compile(rf"(?i)(?:^|[^a-z0-9]){catalog_pattern}(?:[^a-z0-9]|$)")
    try:
        for item in MEDIA_DIR.rglob("*"):
            if pattern.search(item.name):
                return str(item)
    except OSError:
        pass
    return ""


def probe_duration(url, proxy="", task_id=""):
    global active_process, active_task_id
    command = ["ffprobe", "-v", "error", "-user_agent", "Mozilla/5.0 Chrome/120", "-headers",
               "Referer: https://jable.tv/\r\nOrigin: https://jable.tv\r\n"]
    if proxy:
        command.extend(["-http_proxy", proxy])
    command.extend(["-show_entries", "format=duration", "-of", "csv=p=0", url])
    process = None
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        with active_process_lock:
            active_process = process
            active_task_id = task_id
        output, _ = process.communicate(timeout=15)
        current = rows("SELECT state FROM tasks WHERE id=?", (task_id,)) if task_id else []
        if current and current[0]["state"] == "cancelled":
            raise InterruptedError("任务已由用户停止")
        return float(output.strip()) if process.returncode == 0 else 0.0
    except subprocess.TimeoutExpired:
        process.terminate()
        return 0.0
    finally:
        with active_process_lock:
            if active_process is process:
                active_process = None
                active_task_id = None


def write_basic_metadata(folder, catalog, title):
    metadata = {
        "title": title or catalog, "cover": "", "avid": catalog, "actress": {},
        "description": "", "duration": "", "release_date": "", "keywords": [], "fanarts": []
    }
    (folder / "metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    movie = ET.Element("movie")
    ET.SubElement(movie, "title").text = metadata["title"]
    ET.SubElement(movie, "id").text = catalog
    ET.ElementTree(movie).write(folder / f"{catalog}.nfo", encoding="utf-8", xml_declaration=True)
    return metadata


def metadata_to_dict(metadata):
    if not metadata:
        return {}
    return {
        "title": getattr(metadata, "title", ""),
        "cover": getattr(metadata, "cover", ""),
        "avid": getattr(metadata, "avid", ""),
        "actress": getattr(metadata, "actress", {}) or {},
        "description": getattr(metadata, "description", ""),
        "duration": getattr(metadata, "duration", ""),
        "release_date": getattr(metadata, "release_date", ""),
        "keywords": getattr(metadata, "keywords", []) or [],
        "fanarts": getattr(metadata, "fanarts", []) or []
    }


def scrape_to_staging(task, source_file, sources=None):
    task_id = task["id"]
    catalog = detect_catalog(task["catalog"], task["title"], source_file.name)
    if not catalog:
        raise RuntimeError("无法识别番号，请手动填写番号")
    staging_root = WORK_DIR / f"scrape-{task_id}"
    shutil.rmtree(staging_root, ignore_errors=True)
    catalog_dir = staging_root / catalog
    catalog_dir.mkdir(parents=True, exist_ok=True)
    is_strm = source_file.suffix.lower() in STRM_EXTENSIONS
    destination_file = catalog_dir / f"{catalog}{source_file.suffix.lower()}"
    if source_file.resolve() != destination_file.resolve():
        if is_strm:
            shutil.copy2(str(source_file), destination_file)
        else:
            shutil.move(str(source_file), destination_file)
    metadata = None
    source_used = ""
    proxy = get_settings()["proxy"] or None
    for source in sources or enabled_sources():
        append_log(task_id, f"尝试刮削源：{source}")
        try:
            scraper = Sracper(str(staging_root), proxy, timeout=15)
            scraper.domain = source
            metadata = scraper.scrape(catalog)
            if metadata:
                metadata.to_json(str(catalog_dir / "metadata.json"))
                source_used = source
                break
        except Exception as error:
            append_log(task_id, f"刮削源失败：{error}")
    metadata_dict = metadata_to_dict(metadata) if metadata else write_basic_metadata(catalog_dir, catalog, task["title"])
    performer = safe_name(task["performer"], "")
    if not performer and metadata and metadata.actress:
        performer = safe_name(sorted(metadata.actress.keys())[0], "未知演员")
    performer = performer or "未知演员"
    return staging_root, catalog_dir, destination_file, catalog, performer, metadata, metadata_dict, source_used


def organize_media(task, source_file, transfer_root=None):
    original = source_file.resolve()
    original_top = None
    try:
        relative = original.relative_to(MEDIA_DIR.resolve())
        if len(relative.parts) > 1:
            original_top = MEDIA_DIR / relative.parts[0]
    except ValueError:
        pass
    result = scrape_to_staging(task, source_file)
    staging_root, catalog_dir, _, catalog, performer, metadata, metadata_dict, source_used = result
    settings = get_settings()
    # 优先使用调用方传入的 transfer_root,否则用配置,最后回退到 MEDIA_DIR
    if transfer_root is None:
        transfer_path = str(settings.get("local_transfer_path", "") or "").strip()
        transfer_root = Path(transfer_path) if transfer_path else MEDIA_DIR
    transfer_root = transfer_root.resolve()
    if not transfer_root.exists():
        transfer_root.mkdir(parents=True, exist_ok=True)
    if not metadata and settings["failure_route_enabled"]:
        failure_root = resolve_media_path(settings["failure_path"])
        destination = failure_root / catalog
    else:
        destination = transfer_root / performer / catalog
    if destination.exists():
        staged_media = media_file_in(catalog_dir)
        if staged_media and not original.exists():
            original.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(staged_media), original)
        shutil.rmtree(staging_root, ignore_errors=True)
        raise RuntimeError(f"整理目标已存在：{destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(catalog_dir), destination)
    shutil.rmtree(staging_root, ignore_errors=True)
    original_catalog = detect_catalog(original_top.name) if original_top else ""
    if (original_top and original_catalog == catalog and original_top.exists()
            and original_top.resolve() != destination.resolve()):
        remaining_media = any(item.is_file() and item.suffix.lower() in MEDIA_EXTENSIONS for item in original_top.rglob("*"))
        if not remaining_media:
            shutil.rmtree(original_top, ignore_errors=True)
            append_log(task["id"], f"已删除原目录：{original_top}")
    cover = next(iter(sorted(destination.glob(f"{catalog}-poster.*"))), None)
    if not cover:
        cover = next(iter(sorted(destination.glob(f"{catalog}-fanart-1.*"))), None)
    return destination, catalog, performer, metadata is not None, metadata_dict, source_used, str(cover or "")


def run_download_process(task, output, task_dir):
    global active_process, active_task_id
    url = task["url"]
    settings = get_settings()
    proxy = settings["proxy"]
    duration = probe_duration(url, proxy, task["id"])
    is_m3u8 = ".m3u8" in urlparse(url).path.lower()
    if is_m3u8 and DOWNLOADER.exists():
        command = [str(DOWNLOADER), "-u", url, "-o", str(output), "-c", str(task["threads"]),
                   "-m", "-F", "ffmpeg", "-H", "Referer:https://jable.tv/", "-H", "Origin:https://jable.tv"]
        if proxy:
            command.extend(["-p", proxy])
    else:
        command = ["ffmpeg", "-y", "-nostdin", "-loglevel", "info", "-stats",
                   "-user_agent", "Mozilla/5.0 Chrome/120",
                   "-headers", "Referer: https://jable.tv/\r\nOrigin: https://jable.tv\r\n"]
        if proxy:
            command.extend(["-http_proxy", proxy])
        command.extend(["-i", url, "-map", "0", "-c", "copy"])
    if task["extra_args"]:
        command.extend(shlex.split(task["extra_args"]))
    if not (is_m3u8 and DOWNLOADER.exists()):
        command.append(str(output))
    append_log(task["id"], f"启动下载核心，分片线程：{task['threads']}")
    process = subprocess.Popen(command, cwd=task_dir, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, bufsize=1, env=os.environ.copy())
    with active_process_lock:
        active_process = process
        active_task_id = task["id"]
    messages = queue.Queue()
    metrics = {"media_seconds": 0.0, "progress": 0.0}
    started = time.monotonic()

    def read_output():
        for line in process.stdout:
            messages.put(line)

    threading.Thread(target=read_output, daemon=True).start()
    last_bytes = 0
    last_time = time.monotonic()
    last_log = 0.0
    while process.poll() is None:
        while True:
            try:
                line = messages.get_nowait()
            except queue.Empty:
                break
            clean = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", line).strip()
            time_match = re.search(r"time=(\d+):(\d+):(\d+(?:\.\d+)?)", clean)
            if time_match:
                media_seconds = int(time_match.group(1)) * 3600 + int(time_match.group(2)) * 60 + float(time_match.group(3))
                metrics["media_seconds"] = media_seconds
                if duration > 0:
                    metrics["progress"] = min(0.80, media_seconds / duration * 0.80)
            segment_match = re.search(r"(?:^|\D)(\d+)\s*/\s*(\d+)(?:\D|$)", clean)
            if segment_match and int(segment_match.group(2)) > 0:
                metrics["progress"] = min(0.80, int(segment_match.group(1)) / int(segment_match.group(2)) * 0.80)
            if clean and time.monotonic() - last_log > 4:
                append_log(task["id"], clean[-500:])
                last_log = time.monotonic()
        now = time.monotonic()
        byte_count = directory_size(task_dir)
        delta_time = max(0.1, now - last_time)
        bytes_per_second = max(0, byte_count - last_bytes) / delta_time
        eta = "-"
        if duration > 0 and metrics["media_seconds"] > 0:
            media_rate = metrics["media_seconds"] / max(1, now - started)
            if media_rate > 0:
                eta = format_duration((duration - metrics["media_seconds"]) / media_rate)
        update_task(task["id"], progress=max(0.02, metrics["progress"]),
                    downloaded_bytes=byte_count, size=format_size(byte_count),
                    speed=f"{format_size(bytes_per_second)}/s" if bytes_per_second > 0 else "-", eta=eta)
        last_bytes, last_time = byte_count, now
        time.sleep(1)
    code = process.wait()
    with active_process_lock:
        active_process = None
        active_task_id = None
    current = rows("SELECT state FROM tasks WHERE id=?", (task["id"],))
    if current and current[0]["state"] == "cancelled":
        raise InterruptedError("任务已由用户停止")
    if code != 0:
        raise RuntimeError(f"下载失败，退出码 {code}")
    if not output.exists():
        candidates = sorted((item for item in task_dir.rglob("*") if item.is_file() and item.suffix.lower() in MEDIA_EXTENSIONS),
                            key=lambda item: item.stat().st_size, reverse=True)
        if not candidates:
            raise RuntimeError("下载核心执行完成，但没有找到视频文件")
        shutil.move(str(candidates[0]), output)
    return output


def finish_failure(task_id, error, step=None):
    values = {"state": "failed", "phase": "执行失败", "result_message": str(error),
              "finished_at": datetime.now().isoformat(timespec="seconds")}
    if step:
        values[step] = "failed"
    update_task(task_id, **values)
    append_log(task_id, str(error))


def run_rescrape(task):
    task_id = task["id"]
    source_file = media_file_in(task["output_path"])
    if not source_file:
        finish_failure(task_id, "找不到可重新刮削的视频文件", "scrape_step")
        return
    update_task(task_id, state="running", phase="重新刮削", progress=0.82,
                scrape_step="running", organize_step="running", started_at=datetime.now().isoformat(timespec="seconds"))
    temporary = WORK_DIR / f"rescrape-source-{task_id}{source_file.suffix.lower()}"
    try:
        shutil.move(str(source_file), temporary)
        old_folder = source_file.parent
        shutil.rmtree(old_folder, ignore_errors=True)
        sources = [task["source_used"]] if task["source_used"] else None
        destination, catalog, performer, found, metadata, source_used, cover = organize_media(task, temporary)
        update_task(task_id, state="completed", phase="重新刮削完成" if found else "完成（刮削未匹配）",
                    progress=1, catalog=catalog, performer=performer, metadata_found=int(found),
                    metadata_json=json.dumps(metadata, ensure_ascii=False), source_used=source_used,
                    cover_path=cover, output_path=str(destination), scrape_step="succeeded" if found else "failed",
                    organize_step="succeeded", result_message="重新刮削成功" if found else "重新刮削仍未匹配，可换源重试",
                    mode="normal", finished_at=datetime.now().isoformat(timespec="seconds"))
    except Exception as error:
        if temporary.exists() and not source_file.exists():
            source_file.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(temporary), source_file)
        finish_failure(task_id, f"重新刮削失败：{error}", "scrape_step")


def run_task(task):
    if task["mode"] == "rescrape":
        run_rescrape(task)
        return
    task_id = task["id"]
    task_dir = WORK_DIR / task_id
    task_dir.mkdir(parents=True, exist_ok=True)
    output = task_dir / "download.mp4"
    try:
        if task["task_type"] == "history":
            source = resolve_media_path(task["source_path"])
            if not source.is_file() or source.suffix.lower() not in MEDIA_EXTENSIONS:
                raise RuntimeError("历史视频不存在或格式不支持")
            output = source
            update_task(task_id, state="running", phase="准备历史文件", progress=0.80,
                        download_step="skipped", scrape_step="running", organize_step="pending",
                        downloaded_bytes=source.stat().st_size, size=format_size(source.stat().st_size),
                        started_at=datetime.now().isoformat(timespec="seconds"))
            append_log(task_id, f"开始处理历史视频：{source}")
        elif task["task_type"] == "manual_scrape":
            source = resolve_media_path(task["source_path"])
            if not source.is_file() or source.suffix.lower() not in VIDEO_EXTENSIONS:
                raise RuntimeError("文件不存在或格式不支持（支持 mp4/mkv/ts/strm 等）")
            output = source
            update_task(task_id, state="running", phase="准备手动刮削", progress=0.80,
                        download_step="skipped", scrape_step="running", organize_step="pending",
                        downloaded_bytes=source.stat().st_size, size=format_size(source.stat().st_size),
                        started_at=datetime.now().isoformat(timespec="seconds"))
            append_log(task_id, f"开始手动刮削：{source}")
        else:
            duplicate = find_duplicate(task["catalog"], task_id) if not task["allow_duplicate"] else ""
            if duplicate:
                update_task(task_id, state="skipped", phase="检测到重复", progress=1,
                            download_step="skipped", scrape_step="skipped", organize_step="skipped",
                            result_message=f"已经下载：{duplicate}", finished_at=datetime.now().isoformat(timespec="seconds"))
                append_log(task_id, f"执行前重复检测：{duplicate}")
                return
            update_task(task_id, state="running", phase="下载中", progress=0.01,
                        download_step="running", scrape_step="pending", organize_step="pending",
                        started_at=datetime.now().isoformat(timespec="seconds"))
            output = run_download_process(task, output, task_dir)
            final_size = output.stat().st_size
            update_task(task_id, download_step="succeeded", progress=0.82, downloaded_bytes=final_size,
                        total_bytes=final_size, size=format_size(final_size), speed="-", eta="-")
            append_log(task_id, "下载完成")
        scrape_enabled_key = "manual_scrape_enabled" if task["task_type"] == "manual_scrape" else "local_scrape_enabled"
        transfer_path_key = "manual_transfer_path" if task["task_type"] == "manual_scrape" else "local_transfer_path"
        transfer_enabled_key = "manual_transfer_enabled" if task["task_type"] == "manual_scrape" else "local_transfer_enabled"
        if not task["organize_enabled"] or not get_settings().get(scrape_enabled_key, True):
            loose_dir = MEDIA_DIR / "未整理"
            loose_dir.mkdir(parents=True, exist_ok=True)
            loose_file = loose_dir / f"{safe_name(task['title'], task['catalog'] or task_id)}{output.suffix.lower()}"
            if output.resolve() != loose_file.resolve():
                shutil.move(str(output), loose_file)
            update_task(task_id, state="completed", phase="下载完成（未刮削）", progress=1,
                        output_path=str(loose_file), scrape_step="skipped", organize_step="skipped",
                        result_message="下载完成，已按设置跳过刮削整理",
                        finished_at=datetime.now().isoformat(timespec="seconds"))
            return
        update_task(task_id, phase="刮削中", progress=0.84, scrape_step="running", organize_step="running")
        settings = get_settings()
        transfer_path = str(settings.get(transfer_path_key, "") or "").strip()
        transfer_root = Path(transfer_path) if transfer_path else MEDIA_DIR
        transfer_enabled = bool(settings.get(transfer_enabled_key, True))
        if not transfer_enabled:
            # 跳过转移:只刮削 metadata,文件留在原地
            destination, catalog, performer, found, metadata, source_used, cover = organize_media(task, output, transfer_root=output.parent)
        else:
            destination, catalog, performer, found, metadata, source_used, cover = organize_media(task, output, transfer_root=transfer_root)
        message = "下载、刮削和整理均已完成" if found else "下载完成，刮削未匹配；已完成基础整理，可重试刮削"
        update_task(task_id, state="completed", phase="全部完成" if found else "完成（刮削未匹配）", progress=1,
                    catalog=catalog, performer=performer, metadata_found=int(found),
                    metadata_json=json.dumps(metadata, ensure_ascii=False), source_used=source_used,
                    cover_path=cover, output_path=str(destination), scrape_step="succeeded" if found else "failed",
                    organize_step="succeeded", result_message=message,
                    finished_at=datetime.now().isoformat(timespec="seconds"))
        append_log(task_id, f"整理完成：{destination}")
    except InterruptedError:
        update_task(task_id, state="cancelled", phase="已取消", result_message="用户取消任务",
                    finished_at=datetime.now().isoformat(timespec="seconds"))
    except Exception as error:
        current = rows("SELECT download_step,scrape_step FROM tasks WHERE id=?", (task_id,))
        step = "download_step" if not current or current[0]["download_step"] == "running" else "scrape_step"
        finish_failure(task_id, error, step)
    finally:
        if output.parent == task_dir:
            shutil.rmtree(task_dir, ignore_errors=True)


def _115_headers(cookie, ua=None):
    return {
        "Accept": "application/json, text/plain, */*",
        "Cookie": cookie,
        "Origin": "https://115.com",
        "Referer": "https://115.com/",
        "User-Agent": ua or ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                             "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
    }


def _115_request(cookie, url, data=None, ua=None):
    """调用 115 网盘 webapi，失败抛 RuntimeError，成功返回 JSON。

    115 是国内服务，直连访问更稳定；走海外代理会因出口 IP 漂移触发风控踢下线。
    """
    headers = _115_headers(cookie, ua=ua)
    if data is not None:
        headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
    request_object = Request(url, data=data, headers=headers,
                             method="POST" if data is not None else "GET")
    with urlopen(request_object, timeout=20) as response:
        raw = response.read().decode("utf-8", errors="replace")
    try:
        reply = json.loads(raw or "{}")
    except ValueError:
        raise RuntimeError(f"115 返回异常内容：{raw[:120]}")
    if reply.get("state") not in (True, 1, "1", "true"):
        reason = str(reply.get("error") or reply.get("error_msg") or reply.get("message")
                     or reply.get("msg") or raw[:120] or "115 API 调用失败")
        raise RuntimeError(f"115 API 调用失败：{reason[:180]}")
    return reply


def list_115_nodes(cookie, cid):
    """列出 115 指定目录下的子目录和文件。目录 id 取 cid，文件 id 取 fid。"""
    url = f"https://webapi.115.com/files?cid={cid}&o=user_ptime&asc=0&show_dir=1&limit=1000&format=json"
    reply = _115_request(cookie, url)
    nodes = []
    for item in reply.get("data") or []:
        if not isinstance(item, dict):
            continue
        name = str(item.get("n", "")).strip()
        # 115 API 字段: pickcode 用 "pc"（不是 "pickcode"），文件大小用 "s"
        if item.get("fid"):
            nodes.append({"id": str(item.get("fid")), "name": name, "is_dir": False,
                          "pickcode": str(item.get("pc", "") or item.get("pickcode", "") or ""),
                          "size": str(item.get("s", "0") or "0")})
        elif item.get("cid") is not None:
            nodes.append({"id": str(item.get("cid")), "name": name, "is_dir": True,
                          "pickcode": "", "size": "0"})
    return nodes


def find_115_download_dir(cookie):
    """定位 115 根目录下的「云下载」离线默认目录。"""
    for node in list_115_nodes(cookie, 0):
        if node["is_dir"] and node["name"] == "云下载":
            return node
    return None


def _115_cleanup_ad_files(cookie, parent, children, settings):
    """清理 115 离线产物目录里的广告小文件（cloud_ad_min_mb，0=关闭）。

    不限制后缀：目录内（含子目录，最多递归 2 层）所有小于阈值的文件全部删除，
    按体积从小到大优先删（最小的基本都是广告/网址/封面图）。
    低频逐个删除（每次间隔 1.5 秒、单次总上限 80 个），避免触发 115 风控。
    返回 (已删除数, 失败列表)。
    """
    try:
        min_mb = float(settings.get("cloud_ad_min_mb", 0) or 0)
    except (TypeError, ValueError):
        min_mb = 0
    if min_mb <= 0:
        return 0, []
    threshold = int(min_mb * 1024 * 1024)
    deleted, failures = 0, []
    # 收集候选（文件 id, 所在父目录 id, 文件名, 体积）；递归子目录 2 层，不限后缀
    candidates = []

    def _collect(nodes, parent_id, depth):
        for node in nodes:
            if node.get("is_dir"):
                if depth < 2:
                    try:
                        _collect(list_115_nodes(cookie, node["id"]), str(node["id"]), depth + 1)
                    except Exception:
                        pass
                continue
            try:
                size = int(node.get("size", 0) or 0)
            except (TypeError, ValueError):
                continue
            if size < threshold:
                candidates.append((str(node["id"]), parent_id, str(node.get("name", ""))[:40], size))

    _collect(children, str(parent["id"]), 0)
    candidates.sort(key=lambda item: item[3])
    for fid, pid, name, _size in candidates:
        if deleted + len(failures) >= 80:
            break
        form = urlencode({"pid": pid, "fid[0]": fid}).encode()
        try:
            _115_request(cookie, "https://webapi.115.com/rb/delete", data=form)
            deleted += 1
        except Exception as error:
            failures.append(f"{name}: {str(error)[:60]}")
        time.sleep(1.5)
    if deleted or failures:
        write_app_log("info", "115", "ad-cleanup",
                      f"离线目录「{str(parent.get('name', ''))[:40]}」清理 {deleted} 个小于 {min_mb:g}MB 的广告文件"
                      + (f"，{len(failures)} 个失败" if failures else ""),
                      detail="；".join(failures[:5]))
    return deleted, failures


def move_115_node(cookie, node, target_cid):
    """把 115 文件/文件夹移动到目标目录，并验证它真的到达了目标目录。

    115 偶发对「云下载」内产物 move 返回成功但文件落在根目录，
    因此移动后复查目标目录，未找到则抛错提醒手动处理。
    """
    form = urlencode({"pid": str(target_cid), "fid[0]": str(node["id"])}).encode()
    _115_request(cookie, "https://webapi.115.com/files/move", data=form)
    try:
        target_nodes = list_115_nodes(cookie, target_cid)
    except Exception as error:
        raise RuntimeError(f"移动后无法读取目标目录进行确认：{str(error)[:120]}")
    if not any(n["id"] == str(node["id"]) or n["name"] == node["name"] for n in target_nodes):
        raise RuntimeError(f"移动后未在目标目录找到「{node['name'][:60]}」，请到 115 网盘手动检查（可能落在了根目录）")


def _match_115_node(nodes, title, catalog=None):
    """在 115「云下载」目录列表里按番号/标题匹配离线产物（番号优先）。"""
    for node in nodes:
        if catalog and catalog.upper() in node["name"].upper():
            return node
    clean_title = title.replace(" ", "").lower()
    for node in nodes:
        clean_name = node["name"].replace(" ", "").lower()
        if clean_title and (clean_title in clean_name or clean_name in clean_title):
            return node
    return None


def generate_strm_item(task, pickcode, file_path, size=0):
    """管线 D：为已完成的 115 离线任务生成本地 strm 文件并刮削入库。

    strm 内容指向本服务 /api/115/stream/<id>（实时换 115 直链并 302 重定向，
    播放器直连 115 CDN），避免 115 直链过期问题；刮削复用 Sracper（封面/fanart/nfo 落盘）。
    返回 strm_item id；未启用或无法刮出番号时返回 None。
    """
    settings = get_settings()
    if not settings.get("auto_strm_enabled"):
        return None
    base_url = str(settings.get("service_base_url", "") or "").strip().rstrip("/")
    if not base_url:
        print("[strm] 未配置服务访问地址，跳过 strm 生成", flush=True)
        return None
    catalog = detect_catalog(str(task.get("catalog", "")), task["title"])
    if not catalog:
        print(f"[strm] 无法从标题识别番号，跳过：{task['title'][:40]}", flush=True)
        return None
    catalog = safe_name(catalog, "untitled")
    strm_root = Path("/strm")
    strm_root.mkdir(parents=True, exist_ok=True)
    catalog_dir = strm_root / catalog
    catalog_dir.mkdir(parents=True, exist_ok=True)

    metadata = None
    proxy = settings["proxy"] or None
    title = str(task["title"])
    for source in enabled_sources():
        try:
            scraper = Sracper(str(strm_root), proxy, timeout=10)
            scraper.domain = source
            metadata = scraper.scrape(catalog)
            if metadata:
                title = metadata.title or title
                break
        except Exception as error:
            print(f"[strm] 刮削源 {source} 失败：{error}", flush=True)

    strm_path = catalog_dir / f"{catalog}.strm"
    strm_path.write_text(f"{base_url}/api/115/stream/{task['id']}\n", encoding="utf-8")
    poster_path = catalog_dir / f"{catalog}-poster.jpg"
    with db_lock, connect() as db:
        db.execute(
            """INSERT INTO strm_items (id, cloud_task_id, catalog, title, strm_path, poster_path,
                                       pickcode, file_path, size, cover_url, created_at)
               VALUES (?,?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT(id) DO UPDATE SET title=excluded.title, pickcode=excluded.pickcode,
                   file_path=excluded.file_path, size=excluded.size, cover_url=excluded.cover_url""",
            (task["id"], task["id"], catalog, title, str(strm_path),
             str(poster_path) if poster_path.exists() else "",
             str(pickcode or ""), str(file_path or ""), int(size or 0),
             str(getattr(metadata, "cover", "") or ""),
             datetime.now().isoformat(timespec="seconds"))
        )
    print(f"[strm] 已生成：{strm_path}", flush=True)
    return task["id"]


# ---------- 黄果短剧：剧集追更、完整刮削、本地入库、可选上传 115 ----------
HG_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
         "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
HG_SITE = os.getenv("HUANGGUO_SITE", "https://huangguoai.com").rstrip("/")
# 官方地址发布页：自动获取最新可用镜像域名（可用环境变量 HUANGGUO_PUBLISH_PAGES 覆盖）
HG_PUBLISH_PAGES = [
    item.rstrip("/")
    for item in re.split(r"[\s,;]+", os.getenv("HUANGGUO_PUBLISH_PAGES", ""))
    if item.startswith(("http://", "https://"))
] or [
    "https://huangguoai.pages.dev",
    "https://huangguoai.github.io",
    "https://gitlab.com/huangguo/huangguo",
]
HG_TABS = [
    {"name": "首页", "id": "home"},
    {"name": "成人短剧", "id": "ai-duanju"},
    {"name": "成人漫剧", "id": "ai-manju"},
    {"name": "AI换脸", "id": "ai-huanlian"},
    {"name": "AI魔改", "id": "ai-mogai"},
    {"name": "排行榜", "id": "ranks/hot"},
]
hg_worker_wakeup = threading.Event()


_HG_SITES_LOCK = threading.Lock()

# 发布页镜像缓存：成功 30 分钟 / 失败 60 秒短缓存，有旧值时后台刷新不阻塞请求
_HG_PUBLISH_CACHE = {"mirrors": [], "fetched_at": 0.0, "failed_at": 0.0}
_HG_PUBLISH_REFRESHING = threading.Event()

_HG_PUBLISH_PAGE_DOMAINS = ("pages.dev", "github.io", "gitlab.com", "huangguoai.com")


def _hg_publish_fetch_text(url):
    try:
        return _hg_fetch_text_once(url, referer=urlparse(url).scheme + "://" + urlparse(url).netloc + "/")
    except Exception:
        return ""


def _hg_extract_publish_mirrors(text, allow_link_fallback=True):
    """从发布页文本解析镜像列表：优先 publish.js 的 subdomains+urls 数组（生成 https://<前缀>.<域名>），
    allow_link_fallback 时回退到 HTML 里直接内嵌的镜像链接（排除发布页自身与主站）。"""
    domains_block = re.search(r"var\s+urls\s*=\s*\[(.*?)\]", text, re.S)
    if domains_block:
        hosts = []
        for raw in re.findall(r"""['"]([^'"]+)['"]""", domains_block.group(1)):
            host = re.sub(r"^https?://", "", raw.strip().strip("/"))
            if re.search(r"\.[a-z]{2,}$", host, re.I) and host not in hosts:
                hosts.append(host)
        prefixes = []
        subs_block = re.search(r"var\s+subdomains\s*=\s*\[(.*?)\]", text, re.S)
        if subs_block:
            prefixes = [s.strip() for s in re.findall(r"""['"]([^'"]+)['"]""", subs_block.group(1))
                        if re.fullmatch(r"[a-z0-9-]+", s.strip(), re.I)]
        # 发布页前端每次刷新只是随机展示其中 9 个；这里把公布数据（前缀×域名）全部展开入池
        result = []
        for host in hosts:
            for prefix in (prefixes or [""]):
                url = f"https://{prefix + '.' if prefix else ''}{host}"
                if url not in result:
                    result.append(url)
        return result
    if not allow_link_fallback:
        return []
    result = []
    for url in re.findall(r"https?://[a-z0-9.-]+\.[a-z]{2,}(?::\d+)?", text, re.I):
        url = url.rstrip("/").lower()
        host = urlparse(url).netloc
        if not host or any(host == d or host.endswith("." + d) for d in _HG_PUBLISH_PAGE_DOMAINS):
            continue
        if url not in result:
            result.append(url)
    return result


def _hg_parse_publish_page(page):
    """解析单个发布页：gitlab 只认 raw publish.js（CF 盾页面的 HTML 链接是噪音）；普通页直接抓，
    仅含 publish.js 引用时再抓 js 解析。"""
    pages = []
    if "gitlab.com" in page:
        pages += [(f"{page}/-/raw/{branch}/publish.js", False) for branch in ("main", "master")]
    pages.append((page, True))
    js_url = ""
    for target, allow_fallback in pages:
        text = _hg_publish_fetch_text(target)
        if not text:
            continue
        mirrors = _hg_extract_publish_mirrors(text, allow_link_fallback=allow_fallback)
        if mirrors:
            return mirrors
        matched = re.search(r"""src=["']([^"']*?publish\.js[^"']*)["']""", text)
        if matched and not js_url:
            js_url = urljoin(page + "/", html.unescape(matched.group(1)))
    if js_url and js_url not in [p for p, _ in pages]:
        return _hg_extract_publish_mirrors(_hg_publish_fetch_text(js_url))
    return []


def _hg_fetch_publish_mirrors_once():
    """依次尝试各发布页，任一成功即返回（每个发布页都是全量官方镜像列表）。"""
    for page in HG_PUBLISH_PAGES:
        try:
            mirrors = _hg_parse_publish_page(page)
        except Exception:
            continue
        if mirrors:
            return mirrors
    return []


def _hg_publish_mirrors(max_age=1800):
    """发布页最新镜像（带缓存）：未过期直接用；过期则触发后台刷新，永不阻塞请求线程。
    预热线程启动时会重试拉取，正常运行时缓存早已就绪。"""
    now = time.time()
    with _HG_SITES_LOCK:
        mirrors = list(_HG_PUBLISH_CACHE["mirrors"])
        fetched_at = _HG_PUBLISH_CACHE["fetched_at"]
        failed_at = _HG_PUBLISH_CACHE["failed_at"]
    if mirrors and now - fetched_at < max_age:
        return mirrors
    if _HG_PUBLISH_REFRESHING.is_set() or (not mirrors and now - failed_at < 60):
        return mirrors
    _HG_PUBLISH_REFRESHING.set()
    threading.Thread(target=_hg_publish_refresh_once, daemon=True, name="hg-publish-mirrors").start()
    return mirrors


def _hg_publish_refresh_once():
    """抓取一次发布页并写缓存：成功记录镜像并写日志，失败记 60 秒短缓存。"""
    try:
        result = _hg_fetch_publish_mirrors_once()
        with _HG_SITES_LOCK:
            if result:
                if result != _HG_PUBLISH_CACHE["mirrors"]:
                    write_app_log("info", "huangguo", "publish-mirrors",
                                  "发布页镜像已更新：" + "、".join(result))
                _HG_PUBLISH_CACHE.update(mirrors=result, fetched_at=time.time(), failed_at=0.0)
            else:
                _HG_PUBLISH_CACHE["failed_at"] = time.time()
    except Exception:
        with _HG_SITES_LOCK:
            _HG_PUBLISH_CACHE["failed_at"] = time.time()
    finally:
        _HG_PUBLISH_REFRESHING.clear()


def _hg_publish_warmup(retry=10, interval=15):
    """启动预热：容器刚起时网络可能未就绪，失败后间隔重试直到成功或次数用尽。"""
    for attempt in range(retry):
        time.sleep(interval if attempt else 0)
        _hg_publish_refresh_once()
        with _HG_SITES_LOCK:
            if _HG_PUBLISH_CACHE["mirrors"]:
                return


# 站点黑名单：网络失败或页面解析 0 条的镜像进入黑名单（TTL 过期自动解除），failover 时跳过
_HG_SITE_BLACKLIST = {}  # site -> expire_ts


def _hg_site_blacklist_add(site, ttl=1800):
    if site:
        _HG_SITE_BLACKLIST[site] = time.time() + ttl


def _hg_site_blacklisted(site):
    expire = _HG_SITE_BLACKLIST.get(site, 0)
    if expire and expire <= time.time():
        _HG_SITE_BLACKLIST.pop(site, None)
        return False
    return bool(expire)


def _hg_mirror_candidates():
    """备用镜像列表：设置里的 hg_site_mirrors + 环境变量 HUANGGUO_MIRRORS + 发布页自动获取的最新镜像 + 当前主站。"""
    raw = " ".join([
        str(get_settings().get("hg_site_mirrors", "") or ""),
        os.getenv("HUANGGUO_MIRRORS", ""),
    ])
    candidates = []
    for item in re.split(r"[\s,;]+", raw):
        item = item.strip()
        if item.startswith(("http://", "https://")):
            candidates.append(item.rstrip("/"))
    candidates += _hg_publish_mirrors()
    # 用户指定：thu.fdxqupvz.cc 为默认首选镜像（发布页地址随机组合，首个最稳定）
    preferred = "https://thu.fdxqupvz.cc"
    if preferred in candidates:
        candidates = [preferred] + [item for item in candidates if item != preferred]
    ordered = [HG_SITE] + candidates
    seen, result = set(), []
    for item in ordered:
        if item not in seen:
            seen.add(item)
            result.append(item)
    return result


def _hg_fetch_text(url, referer="", valid_fn=None):
    """黄果页面抓取：先抓原始 URL（含库里保存的旧域名详情页），失败后自动切换镜像重试，成功后全局切换站点。
    黑名单站点（网络失败/解析 0 条）会被跳过，TTL 过期后自动恢复尝试。
    valid_fn：内容校验回调；HTTP 成功但内容是空壳页（假站/风控页）时同样拉黑并切换下一镜像。"""
    parsed = urlparse(url)
    origin = f"{parsed.scheme}://{parsed.netloc}" if parsed.netloc else ""
    errors = []
    tried = set()
    for site in [origin] + [item for item in _hg_mirror_candidates() if item != origin]:
        if site in tried:
            continue
        tried.add(site)
        if _hg_site_blacklisted(site):
            continue
        candidate = url.replace(origin, site, 1) if origin and site else url
        try:
            text = _hg_fetch_text_once(candidate, referer=referer)
        except Exception as error:
            errors.append(f"{site}: {str(error)[:120]}")
            # 网络失败进入短黑名单（15 分钟），避免后续请求继续撞死站点
            _hg_site_blacklist_add(site, ttl=900)
            continue
        if valid_fn and not valid_fn(text):
            errors.append(f"{site}: HTTP 成功但返回空壳页")
            # 空壳页（能连通但无数据）按解析 0 条处理，拉黑 30 分钟
            _hg_site_blacklist_add(site, ttl=1800)
            continue
        if site and site != origin and site != HG_SITE:
            with _HG_SITES_LOCK:
                globals()["HG_SITE"] = site
            write_app_log("info", "huangguo", "site-failover", f"黄果站点不可达，已自动切换到 {site}")
        return text
    raise RuntimeError("；".join(errors)[:500] or "黄果站点访问失败")


def _hg_fetch_text_once(url, referer=""):
    headers = {
        "User-Agent": HG_UA,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
    }
    if referer:
        headers["Referer"] = referer
    errors = []
    try:
        with request_with_proxy(url, headers=headers, method="GET", timeout=25) as response:
            return response.read().decode("utf-8", errors="replace")
    except Exception as error:
        errors.append(str(error))

    curl = shutil.which("curl")
    if curl:
        command = [
            curl, "-fsSL", "--compressed", "--http1.1", "--connect-timeout", "12",
            "--max-time", "30", "-A", HG_UA, "-H", f"Accept: {headers['Accept']}",
            "-H", f"Accept-Language: {headers['Accept-Language']}", url,
        ]
        if referer:
            command.extend(["-e", referer])
        proxy = str(get_settings().get("proxy", "")).strip()
        if proxy:
            command.extend(["--proxy", proxy])
        try:
            result = subprocess.run(command, check=True, capture_output=True, timeout=35)
            return result.stdout.decode("utf-8", errors="replace")
        except Exception as error:
            stderr = getattr(error, "stderr", b"")
            detail = stderr.decode("utf-8", errors="replace") if isinstance(stderr, bytes) else str(stderr or "")
            errors.append(detail or str(error))

    if url.startswith("https://"):
        # 仅对同一站点降级 http 再试一次（不再走完整 failover：镜像候选替换 origin 后协议来回
        # 翻转会导致 _hg_fetch_text 无限递归、每层都跑满 urllib+curl 超时，请求组合爆炸挂死）
        try:
            return _hg_fetch_text_once("http://" + url[len("https://"):],
                                       referer=referer.replace("https://", "http://", 1))
        except Exception as error:
            errors.append(str(error))
    raise RuntimeError("；".join([item for item in errors if item])[:500] or "黄果站点访问失败")


def _hg_origin(url):
    parsed = urlparse(url)
    if not parsed.scheme or not parsed.netloc:
        raise ValueError("请输入完整的黄果短剧 URL")
    return f"{parsed.scheme}://{parsed.netloc}"


def _hg_site_url(path):
    path = str(path or "").strip()
    if not path or path == "home":
        return f"{HG_SITE}/"
    if path.startswith(("http://", "https://")):
        return path
    return f"{HG_SITE}/{path.strip('/')}/"


def _hg_strip_tags(value):
    text = re.sub(r"<[^>]+>", "", str(value or ""))
    return html.unescape(re.sub(r"\s+", " ", text)).strip()


def _hg_fix_site_url(value):
    value = html.unescape(str(value or "").strip()).replace("\\u0026", "&")
    if value.startswith("//"):
        return "https:" + value
    if value.startswith("/"):
        return HG_SITE + value
    return value


def _hg_script_data(html_text):
    match = re.search(r'id=["\']videoInitialData["\'][^>]*>([\s\S]*?)</script>', html_text)
    if not match:
        return {}
    try:
        return json.loads(html.unescape(match.group(1)).strip())
    except Exception as error:
        raise ValueError(f"videoInitialData 解析失败：{error}")


def _hg_grid_slices(html_text, all_grids=False):
    matches = list(re.finditer(r'<div\s+class=["\'][^"\']*\bhg-card-grid\b[^"\']*["\'][^>]*>', html_text))
    if not matches:
        return []
    limit = len(matches) if all_grids else 1
    slices = []
    for index, match in enumerate(matches[:limit]):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(html_text)
        slices.append(html_text[match.end():end])
    return slices


def _hg_card_blocks(slice_text):
    matches = list(re.finditer(r'<div\s+class=["\'][^"\']*\bhg-drama-card\b[^"\']*["\'][^>]*>', slice_text))
    blocks = []
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(slice_text)
        blocks.append(slice_text[match.end():end])
    return blocks


def _hg_parse_card_block(block):
    link = re.search(r'href=["\'][^"\']*/detail/(\d+)/[^"\']*["\']', block)
    if not link:
        return None
    title_match = re.search(r'hg-drama-card__title[^>]*>([\s\S]*?)</a>', block)
    if not title_match:
        title_match = re.search(r'<a[^>]+href=["\'][^"\']*/detail/\d+/["\'][^>]*>([\s\S]*?)</a>', block)
    title = _hg_strip_tags(title_match.group(1) if title_match else "")
    if not title:
        return None
    image = re.search(r'data-src=["\']([^"\']+)["\']', block) or re.search(r'src=["\']([^"\']+)["\']', block)
    episode = re.search(r'hg-drama-card__episode[^>]*>([\s\S]*?)</span>', block)
    score = re.search(r'hg-drama-card__score[^>]*>([\s\S]*?)</span>', block)
    episode_text = _hg_strip_tags(episode.group(1)) if episode else ""
    remark = " · ".join(filter(None, [
        episode_text,
        _hg_strip_tags(score.group(1)) if score else "",
    ]))
    item_id = link.group(1)
    return {
        "id": item_id,
        "title": title,
        "cover_url": _hg_fix_site_url(image.group(1)) if image else "",
        "remark": remark,
        # 站方徽标：连载中显示"更新至X集"，已完结显示"全X集"或含"完结"
        "is_finished": bool(re.search(r"全\d+集|完结", episode_text)),
        "detail_url": f"{HG_SITE}/detail/{item_id}/",
    }


def _hg_parse_grid_cards(html_text, all_grids=False):
    seen = set()
    items = []
    for slice_text in _hg_grid_slices(html_text, all_grids):
        for block in _hg_card_blocks(slice_text):
            item = _hg_parse_card_block(block)
            if item and item["id"] not in seen:
                seen.add(item["id"])
                items.append(item)
    return items


def _hg_parse_rank_cards(html_text):
    match = re.search(r'<div\s+class=["\'][^"\']*\bhg-rank-list\b[^"\']*["\'][^>]*>', html_text)
    slice_text = html_text[match.end():] if match else html_text
    starts = list(re.finditer(r'<div\s+class=["\'][^"\']*\bhg-rank-item\b[^"\']*["\'][^>]*>', slice_text))
    seen = set()
    items = []
    for index, start in enumerate(starts):
        end = starts[index + 1].start() if index + 1 < len(starts) else len(slice_text)
        block = slice_text[start.end():end]
        link = re.search(r'href=["\'][^"\']*/detail/(\d+)/[^"\']*["\']', block)
        if not link or link.group(1) in seen:
            continue
        title_match = re.search(r'hg-rank-item__title[^>]*>([\s\S]*?)</h2>', block)
        if not title_match:
            title_match = re.search(r'<a[^>]+href=["\'][^"\']*/detail/\d+/["\'][^>]*>([\s\S]*?)</a>', block)
        title = _hg_strip_tags(title_match.group(1) if title_match else "")
        if not title:
            continue
        image = re.search(r'data-src=["\']([^"\']+)["\']', block) or re.search(r'src=["\']([^"\']+)["\']', block)
        tags = re.search(r'hg-rank-item__tags[^>]*>([\s\S]*?)</div>', block)
        item_id = link.group(1)
        seen.add(item_id)
        items.append({
            "id": item_id,
            "title": title,
            "cover_url": _hg_fix_site_url(image.group(1)) if image else "",
            "remark": _hg_strip_tags(tags.group(1)) if tags else "",
            "detail_url": f"{HG_SITE}/detail/{item_id}/",
        })
    return items


# 黄果列表缓存：进入页面/翻页命中缓存直接返回，不再每次请求站点（避免进页面转圈）
_HG_CATALOG_CACHE = {}  # key=(tab_id,page,keyword) -> {"updated_at": float, ...result}
_HG_CATALOG_CACHE_TTL = 600


def _hg_fetch_html_until_items(url, referer="", parse_fn=None, max_sites=4):
    """列表页抓取 + 数据有效性循环：镜像 HTTP 成功但解析 0 条（假站点/空壳页）时，
    拉黑该站点并切换下一个镜像重抓，直到拿到数据或试满 max_sites 个站点。
    返回 (text, items)。"""
    parsed = urlparse(url)
    origin = f"{parsed.scheme}://{parsed.netloc}" if parsed.netloc else ""
    attempts = 0
    last_text = ""
    for site in [origin] + [item for item in _hg_mirror_candidates() if item != origin]:
        if attempts >= max_sites:
            break
        if _hg_site_blacklisted(site):
            continue
        attempts += 1
        candidate = url.replace(origin, site, 1) if origin and site else url
        try:
            text = _hg_fetch_text(candidate, referer=referer)
        except Exception:
            continue
        last_text = text
        items = parse_fn(text) if parse_fn else []
        if items:
            return text, items
        # HTTP 成功但解析 0 条：坏镜像/空壳页，拉黑 30 分钟后换下一个
        _hg_site_blacklist_add(site, ttl=1800)
    return last_text, []


def _hg_catalog_items(tab_id="home", page=1, keyword="", force=False):
    page = max(1, int(page or 1))
    keyword = str(keyword or "").strip()
    cache_key = (tab_id, page, keyword)
    cached = _HG_CATALOG_CACHE.get(cache_key)
    if not force and cached and cached.get("items") and time.time() - cached["updated_at"] < _HG_CATALOG_CACHE_TTL:
        return cached
    if keyword:
        url = f"{HG_SITE}/search/video/{quote(keyword)}/"
        html_text, items = _hg_fetch_html_until_items(url, referer=HG_SITE + "/",
                                                      parse_fn=lambda t: _hg_parse_grid_cards(t, False))
        result = {"items": items, "source_url": url, "tabs": HG_TABS, "page": page, "query": keyword}
        if items:
            _HG_CATALOG_CACHE[cache_key] = {**result, "updated_at": time.time()}
        elif cached and cached.get("items"):
            return {**cached, "stale": True}  # 抓取失败时回退旧缓存
        return result
    tab_id = str(tab_id or "home").strip()
    if tab_id not in {item["id"] for item in HG_TABS}:
        tab_id = "home"
    if tab_id == "home":
        url = HG_SITE + "/"
    else:
        url = _hg_site_url(tab_id)
        if page > 1:
            url = url.rstrip("/") + f"/{page}/"
    def _parse(t):
        return _hg_parse_rank_cards(t) if "rank" in tab_id else _hg_parse_grid_cards(t, tab_id == "home")

    html_text, items = _hg_fetch_html_until_items(url, referer=HG_SITE + "/", parse_fn=_parse)
    result = {"items": items, "source_url": url, "tabs": HG_TABS, "page": page, "query": ""}
    if items:
        _HG_CATALOG_CACHE[cache_key] = {**result, "updated_at": time.time()}
    elif cached and cached.get("items"):
        return {**cached, "stale": True}  # 抓取失败时回退旧缓存
    return result


def _hg_parse_detail_episodes(html_text, origin):
    block = re.search(r'<div[^>]*(?:data-ep-grid|hg-web-detail__ep-grid)[^>]*>([\s\S]*?)</div>', html_text)
    if not block:
        return []
    episodes = []
    for tag in re.findall(r'<a\b[^>]*>[\s\S]*?</a>', block.group(1)):
        href = re.search(r'href=["\']([^"\']+)["\']', tag)
        ep_id = re.search(r'data-ep-id=["\'](\d+)["\']', tag)
        if not href:
            continue
        ep_match = ep_id or re.search(r'/ep-(\d+)/', href.group(1)) or re.search(r'第\s*(\d+)\s*集', tag)
        if not ep_match:
            continue
        episodes.append({"ep": int(ep_match.group(1)), "play_url": urljoin(origin, href.group(1)), "locked": "is-locked" in tag})
    unique = {item["ep"]: item for item in episodes}
    return [unique[key] for key in sorted(unique)]


def _hg_json_ld(html_text):
    """解析详情页 JSON-LD 结构化数据（TVSeries/Series/Movie 等），失败返回空 dict 由正则回退兜底。"""
    for match in re.finditer(r'<script[^>]+type=["\']application/ld\+json["\'][^>]*>([\s\S]*?)</script>', html_text):
        raw = match.group(1).strip()
        if not raw:
            continue
        try:
            data = json.loads(html.unescape(raw))
        except Exception:
            continue
        for node in (data if isinstance(data, list) else [data]):
            if isinstance(node, dict) and str(node.get("@type") or "") in (
                    "TVSeries", "Series", "Movie", "VideoObject", "TVClip", "Clip", "CreativeWork"):
                return node
    return {}


def _hg_jsonld_rating(node):
    agg = node.get("aggregateRating") if isinstance(node, dict) else None
    if isinstance(agg, dict) and agg.get("ratingValue"):
        try:
            return str(float(agg["ratingValue"]))
        except (TypeError, ValueError):
            return ""
    return ""


def _hg_jsonld_date(node):
    raw = str(node.get("datePublished") or "") if isinstance(node, dict) else ""
    match = re.match(r"(\d{4}-\d{2}-\d{2})", raw)
    return match.group(1) if match else ""


def _hg_detail_text_valid(text):
    """详情/播放页内容有效性：空壳站（HTTP 200 但无任何数据）返回 False，触发镜像切换。"""
    if not text:
        return False
    return ("videoInitialData" in text
            or "og:title" in text
            or "application/ld+json" in text)


def _hg_parse_series(url):
    origin = _hg_origin(url)
    html_text = _hg_fetch_text(url, valid_fn=_hg_detail_text_valid)
    data = _hg_script_data(html_text)
    parsed = urlparse(url)
    series_id = str(data.get("id") or "")
    if not series_id:
        match = re.search(r'/(?:detail|video)/(\d+)/?', parsed.path)
        if match:
            series_id = match.group(1)
    if not series_id:
        raise ValueError("没有识别到黄果短剧 ID")
    title = str(data.get("title") or "").strip()
    if not title:
        og = re.search(r'<meta[^>]+property=["\']og:title["\'][^>]+content=["\']([^"\']+)["\']', html_text)
        title = html.unescape(og.group(1)).strip() if og else f"黄果短剧 {series_id}"
    detail_url = f"{origin}/detail/{series_id}/"
    detail_html = html_text if f"/detail/{series_id}" in parsed.path else _hg_fetch_text(detail_url, referer=url, valid_fn=_hg_detail_text_valid)
    jsonld = _hg_json_ld(detail_html)
    cover = ""
    cover_match = re.search(r'<meta[^>]+property=["\']og:image["\'][^>]+content=["\']([^"\']+)["\']', detail_html)
    if cover_match:
        cover = urljoin(origin, html.unescape(cover_match.group(1)).strip())
    desc = ""
    desc_match = re.search(r'<meta[^>]+name=["\']description["\'][^>]+content=["\']([^"\']+)["\']', detail_html)
    if desc_match:
        desc = html.unescape(desc_match.group(1)).strip()
    if not desc:
        desc = str(jsonld.get("description") or "").strip()
    if not cover:
        cover = urljoin(origin, str(jsonld.get("image") or "").strip()) if jsonld.get("image") else ""
    if title == f"黄果短剧 {series_id}" and jsonld.get("name"):
        title = str(jsonld.get("name")).strip() or title
    episodes = _hg_parse_detail_episodes(detail_html, origin)
    if not episodes and data.get("epPlaySrcs"):
        for key in sorted(data["epPlaySrcs"], key=lambda x: int(x) if str(x).isdigit() else 0):
            ep = int(key) if str(key).isdigit() else 1
            play_url = f"{origin}/video/{series_id}/" if ep == 1 else f"{origin}/video/{series_id}/ep-{ep}/"
            episodes.append({"ep": ep, "play_url": play_url, "locked": False})
    if not episodes:
        # AI换脸等单视频内容：详情页无分集网格、无 videoInitialData，只有 /video/<id>/ 播放链接
        video_link = re.search(r'href=["\'](?:' + re.escape(origin) + r')?/video/' + re.escape(str(series_id)) + r'/?(?:[#?"\'])', detail_html)
        if video_link:
            episodes = [{"ep": 1, "play_url": f"{origin}/video/{series_id}/", "locked": False}]
    badge = str(data.get("episode") or "").strip()
    if not badge:
        badge_match = re.search(r'data-ep-base=["\']([^"\']*)["\']', detail_html)
        badge = html.unescape(badge_match.group(1)).strip() if badge_match else ""
    # 站方评分与上线日期（详情页 meta 区块，如 9.1分 · 2026-08-07 上线）：写入 nfo 供播放器显示
    score_match = re.search(r'hg-web-detail__score[^>]*>\s*(?:<em>)?([\d.]+)', detail_html)
    premiered_match = re.search(r'(\d{4}-\d{2}-\d{2})\s*上线', detail_html)
    return {"id": series_id, "origin": origin, "title": title, "detail_url": detail_url,
            "cover_url": cover, "description": desc, "episodes": episodes,
            "episode_badge": badge, "is_finished": bool(re.search(r"全\d+集|完结", badge)),
            "rating": score_match.group(1) if score_match else _hg_jsonld_rating(jsonld),
            "premiered": premiered_match.group(1) if premiered_match else _hg_jsonld_date(jsonld)}


def _hg_resolve_episode_stream(play_url, ep):
    html_text = _hg_fetch_text(play_url, referer=play_url, valid_fn=_hg_detail_text_valid)
    data = _hg_script_data(html_text)
    srcs = data.get("epPlaySrcs") or {}
    stream = str(srcs.get(str(ep)) or data.get("videoSrc") or "").replace("\\u0026", "&").strip()
    if stream and not stream.startswith(("http://", "https://")):
        match = re.search(r'https?://[^\s"\']+', stream)
        stream = match.group(0) if match else ""
    if not stream:
        raise RuntimeError("该集没有解析到可用媒体流")
    return stream


def _hg_episode_id(series_id, ep):
    return f"hg-{series_id}-{int(ep):04d}"


def _hg_refresh_series_counts(series_id):
    stats = row(
        """SELECT COUNT(*) AS total,
                  SUM(CASE WHEN state='completed' THEN 1 ELSE 0 END) AS downloaded,
                  SUM(CASE WHEN upload_state='uploaded' THEN 1 ELSE 0 END) AS uploaded,
                  MAX(ep) AS latest
           FROM hg_episodes WHERE series_id=?""",
        (series_id,)
    ) or {}
    with db_lock, connect() as db:
        db.execute(
            "UPDATE hg_series SET total_episodes=?, downloaded_episodes=?, uploaded_episodes=?, latest_episode=? WHERE id=?",
            (int(stats.get("total") or 0), int(stats.get("downloaded") or 0),
             int(stats.get("uploaded") or 0), int(stats.get("latest") or 0), series_id)
        )


def _hg_cover_path(series_id):
    return DATA_DIR / "hg-covers" / f"{series_id}.jpg"


def _hg_persist_cover(series_id, cover_url, force=False):
    """下载黄果封面(自动识别解密)存到持久目录；短时效 token 过期时返回 None。"""
    if not str(cover_url or "").strip():
        return None
    path = _hg_cover_path(series_id)
    if path.exists() and path.stat().st_size > 0 and not force:
        return path
    try:
        cover = cache_remote_image(str(cover_url))
        if cover and cover.exists() and cover.stat().st_size > 0 and _image_signature(cover.read_bytes()):
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(cover, path)
            return path
    except Exception:
        pass
    return None


def _hg_search_cover(series_id, title):
    """og:image 带的短时效 token 过期时，从站内搜索卡片拿新鲜封面（data-src 优先）。"""
    keyword = re.sub(r"\s*-\s*黄果短剧\s*$", "", str(title or "")).strip()
    if not keyword:
        return ""
    try:
        html_text = _hg_fetch_text(f"{HG_SITE}/search/video/{quote(keyword)}/", referer=HG_SITE + "/")
        for item in _hg_parse_grid_cards(html_text, False):
            if str(item.get("id")) == str(series_id) and item.get("cover_url"):
                return item["cover_url"]
    except Exception:
        pass
    return ""


def _hg_upsert_series(parsed):
    now = datetime.now().isoformat(timespec="seconds")
    episodes = parsed.get("episodes", [])
    latest = max([int(e["ep"]) for e in episodes], default=0)
    with db_lock, connect() as db:
        db.execute(
            """INSERT INTO hg_series(id,title,origin,detail_url,cover_url,description,follow_enabled,
                                     total_episodes,latest_episode,rating,premiered,last_checked_at,created_at)
               VALUES(?,?,?,?,?,?,1,?,?,?,?,?,?)
               ON CONFLICT(id) DO UPDATE SET title=excluded.title, origin=excluded.origin,
                   detail_url=excluded.detail_url, cover_url=excluded.cover_url, description=excluded.description,
                   total_episodes=excluded.total_episodes, latest_episode=excluded.latest_episode,
                   rating=CASE WHEN excluded.rating<>'' THEN excluded.rating ELSE hg_series.rating END,
                   premiered=CASE WHEN excluded.premiered<>'' THEN excluded.premiered ELSE hg_series.premiered END,
                   last_checked_at=excluded.last_checked_at""",
            (parsed["id"], parsed["title"], parsed["origin"], parsed["detail_url"], parsed.get("cover_url", ""),
             parsed.get("description", ""), len(episodes), latest, str(parsed.get("rating", "") or ""),
             str(parsed.get("premiered", "") or ""), now, now)
        )
        for item in episodes:
            ep = int(item["ep"])
            episode_id = _hg_episode_id(parsed["id"], ep)
            db.execute(
                """INSERT INTO hg_episodes(id,series_id,ep,title,play_url,state,upload_state,message,created_at,updated_at)
                   VALUES(?,?,?,?,?,'pending','pending','等待下载',?,?)
                   ON CONFLICT(id) DO UPDATE SET title=excluded.title, play_url=excluded.play_url, updated_at=excluded.updated_at""",
                (episode_id, parsed["id"], ep, f"{parsed['title']} 第{ep}集", item["play_url"], now, now)
            )
    _hg_refresh_series_counts(parsed["id"])
    if parsed.get("is_finished"):
        existing = row("SELECT completed FROM hg_series WHERE id=?", (parsed["id"],))
        if not (existing and existing["completed"]):
            finish_now = datetime.now().isoformat(timespec="seconds")
            with db_lock, connect() as db:
                db.execute("UPDATE hg_series SET completed=1, follow_enabled=0 WHERE id=?", (parsed["id"],))
                cursor = db.execute(
                    """UPDATE hg_episodes SET upload_state='retry', message='站方标记全剧完结，等待上传 115',
                              error='', updated_at=?
                       WHERE series_id=? AND state='completed'
                         AND upload_state IN ('pending','skipped','waiting_complete','failed')""",
                    (finish_now, parsed["id"]))
                queued = cursor.rowcount
            if queued:
                hg_worker_wakeup.set()
            write_app_log("success", "huangguo", "auto-complete",
                          f"站方标记完结（{parsed.get('episode_badge') or '全剧完结'}），已自动完结：{parsed['title']}",
                          detail=f"upload_queue={queued}", target=parsed["detail_url"])
    if not _hg_persist_cover(parsed["id"], parsed.get("cover_url", "")):
        fresh_cover = _hg_search_cover(parsed["id"], parsed.get("title", ""))
        if fresh_cover:
            if _hg_persist_cover(parsed["id"], fresh_cover, force=True):
                parsed["cover_url"] = fresh_cover
                with db_lock, connect() as db:
                    db.execute("UPDATE hg_series SET cover_url=? WHERE id=?", (fresh_cover, parsed["id"]))
    _hg_refresh_local_metadata(parsed["id"])
    write_app_log("success", "huangguo", "scrape-series",
                  f"黄果短剧刮削完成：{parsed['title']}，共 {len(episodes)} 集", target=parsed["detail_url"])
    return parsed["id"]


def _write_episode_nfo(nfo_path, series, episode, premiered="", rating=""):
    """每集一个 episodedetails nfo：Infuse/Kodi 等播放器用它显示真实日期，缺失时会显示 1970。"""
    try:
        root = ET.Element("episodedetails")
        ET.SubElement(root, "title").text = f"第{int(episode['ep'])}集"
        ET.SubElement(root, "showtitle").text = series["title"]
        ET.SubElement(root, "season").text = "1"
        ET.SubElement(root, "episode").text = str(int(episode["ep"]))
        if premiered:
            ET.SubElement(root, "aired").text = premiered
        if rating:
            ET.SubElement(root, "rating").text = rating
        ET.SubElement(root, "id").text = str(episode.get("id", ""))
        ET.ElementTree(root).write(nfo_path, encoding="utf-8", xml_declaration=True)
    except Exception:
        pass


def _hg_render_series_files(series_dir, series, episodes=()):
    """写 metadata.json / tvshow.nfo / poster.jpg / 每集 nfo，附站方评分与上线日期。"""
    series_dir = Path(series_dir)
    premiered = str(series.get("premiered", "") or "")
    rating = str(series.get("rating", "") or "")
    metadata = {
        "type": "huangguo_short_drama",
        "series_id": series["id"],
        "title": series["title"],
        "detail_url": series["detail_url"],
        "cover": series.get("cover_url", ""),
        "description": series.get("description", ""),
        "premiered": premiered,
        "year": premiered[:4],
        "rating": rating,
        "scraped_at": datetime.now().isoformat(timespec="seconds"),
    }
    (series_dir / "metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    tvshow = ET.Element("tvshow")
    ET.SubElement(tvshow, "title").text = series["title"]
    ET.SubElement(tvshow, "plot").text = series.get("description", "")
    ET.SubElement(tvshow, "id").text = str(series["id"])
    if premiered:
        ET.SubElement(tvshow, "premiered").text = premiered
        ET.SubElement(tvshow, "year").text = premiered[:4]
    if rating:
        ET.SubElement(tvshow, "rating").text = rating
    ET.ElementTree(tvshow).write(series_dir / "tvshow.nfo", encoding="utf-8", xml_declaration=True)
    for ep in episodes:
        media = Path(ep["file_path"] or "")
        if media.name and media.exists() and media.suffix.lower() != ".nfo":
            _write_episode_nfo(media.with_suffix(".nfo"), series, ep, premiered, rating)
    if series.get("cover_url"):
        try:
            cover = _hg_persist_cover(series["id"], series["cover_url"])
            if cover and cover.exists():
                shutil.copy2(cover, series_dir / "poster.jpg")
        except Exception:
            pass
    return metadata


def _hg_write_metadata(series, episode, media_file):
    return _hg_render_series_files(Path(media_file).parent, series, [episode])


def _hg_refresh_local_metadata(series_id):
    """入库/追更后重写本地剧集目录元数据：给旧库补上评分与上线日期（修复播放器日期 1970）。

    源文件已传 115 被删的目录也能刷新：本地还剩 .strm 时按 strm 写每集 nfo。
    """
    series = row("SELECT * FROM hg_series WHERE id=?", (series_id,))
    if not series:
        return
    series_dir = MEDIA_DIR / "黄果短剧" / safe_name(series["title"], series["id"])
    if not series_dir.exists():
        return
    eps_meta = []
    for ep in rows("SELECT * FROM hg_episodes WHERE series_id=? ORDER BY ep", (series_id,)):
        for candidate in (ep["file_path"], str(series_dir / f"第{int(ep['ep']):03d}集.mp4"),
                          str(series_dir / f"第{int(ep['ep']):03d}集.strm")):
            media = Path(candidate or "")
            if media.name and media.exists():
                eps_meta.append({**ep, "file_path": str(media)})
                break
    if not eps_meta and not (series_dir / "tvshow.nfo").exists():
        return
    try:
        with _HG_METADATA_LOCK:
            _hg_render_series_files(series_dir, series, eps_meta)
    except Exception as error:
        write_app_log("warning", "huangguo", "nfo-refresh", f"刷新剧集元数据失败：{series['title']}", detail=str(error))


_HG_DOWNLOAD_STALL_TIMEOUT = 300  # 下载进程连续无输出超过该秒数判定卡死，终止后自动重试


def _hg_download_episode(episode, stream_url, output, work_dir):
    settings = get_settings()
    # 黄果代理开关：关闭后视频下载直连（列表/详情/封面抓取始终不走代理）
    proxy = str(settings.get("proxy", "") or "") if settings.get("hg_use_proxy", True) else ""
    is_m3u8 = ".m3u8" in urlparse(stream_url).path.lower() or "m3u8" in stream_url.lower()
    if is_m3u8 and DOWNLOADER.exists():
        command = [str(DOWNLOADER), "-u", stream_url, "-o", str(output), "-c", str(settings.get("threads", 2)),
                   "-m", "-F", "ffmpeg", "-H", f"Referer:{episode['play_url']}",
                   "-H", f"Origin:{_hg_origin(episode['play_url'])}", "-H", f"User-Agent:{HG_UA}"]
        if proxy:
            command.extend(["-p", proxy])
    else:
        command = ["ffmpeg", "-y", "-nostdin", "-loglevel", "info", "-stats", "-user_agent", HG_UA,
                   "-headers", f"Referer: {episode['play_url']}\r\nOrigin: {_hg_origin(episode['play_url'])}\r\n",
                   "-i", stream_url, "-map", "0", "-c", "copy", str(output)]
        if proxy:
            command[1:1] = ["-http_proxy", proxy]
    write_app_log("info", "huangguo", "download-start", f"开始下载第 {episode['ep']} 集",
                  detail=" ".join(shlex.quote(x) for x in command), task_id=episode["id"], target=stream_url)
    process = subprocess.Popen(command, cwd=work_dir, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, bufsize=1, env=os.environ.copy())
    last_log = 0
    last_progress_write = 0.0
    last_percent = -1.0
    last_output_at = time.monotonic()
    for line in process.stdout:
        if time.monotonic() - last_output_at > _HG_DOWNLOAD_STALL_TIMEOUT:
            process.kill()
            process.wait()
            raise RuntimeError(f"下载超时：连续 {_HG_DOWNLOAD_STALL_TIMEOUT} 秒无任何输出，已终止进程（将自动重试）")
        last_output_at = time.monotonic()
        clean = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", line).strip()
        if clean and time.monotonic() - last_log > 5:
            write_app_log("info", "huangguo", "download-log", clean[-500:], task_id=episode["id"])
            last_log = time.monotonic()
        percent_match = re.search(r"(\d+(?:\.\d+)?)%", clean)
        if percent_match:
            percent = min(100.0, float(percent_match.group(1)))
            now = time.monotonic()
            if percent != last_percent and now - last_progress_write >= 5:
                last_percent = percent
                last_progress_write = now
                try:
                    with db_lock, connect() as db:
                        db.execute("UPDATE hg_episodes SET progress=?, message=? WHERE id=?",
                                   (0.15 + (percent / 100) * 0.7, f"下载中 {percent:.0f}%", episode["id"]))
                except Exception:
                    pass
    code = process.wait()
    if code != 0:
        raise RuntimeError(f"黄果短剧下载失败，退出码 {code}")
    if not output.exists():
        candidates = sorted((item for item in work_dir.rglob("*") if item.is_file() and item.suffix.lower() in MEDIA_EXTENSIONS),
                            key=lambda item: item.stat().st_size, reverse=True)
        if not candidates:
            raise RuntimeError("下载完成但没有找到成片文件")
        shutil.move(str(candidates[0]), output)
    return output


class _115OpenApiAuthError(RuntimeError):
    """115 OpenAPI 鉴权类错误（token 失效），调用方可清缓存重登。"""


def _raise_115_openapi_error(resp, prefix):
    """根据 OpenAPI 响应抛错；鉴权类错误抛 _115OpenApiAuthError 供上层重试。"""
    message = str(resp.get("message") or resp.get("error") or resp)
    err_low = message.lower()
    if ("access_token" in message and ("无效" in message or "invalid" in err_low)) \
            or "no auth" in err_low or "990001" in message or "未授权" in message or "登录超时" in message:
        raise _115OpenApiAuthError(f"{prefix}：{message[:180]}")
    raise RuntimeError(f"{prefix}：{message[:180]}")


def _sha1_file_115(path, first_chunk=False):
    """115 上传指纹：整文件 SHA1 或前 128KB SHA1（preid），返回大写十六进制。"""
    sha1 = hashlib.sha1()
    with open(path, "rb") as handle:
        if first_chunk:
            sha1.update(handle.read(128 * 1024))
        else:
            while True:
                block = handle.read(1024 * 1024)
                if not block:
                    break
                sha1.update(block)
    return sha1.hexdigest().upper()


def _sha1_range_115(path, start, end):
    """115 双向校验：计算 [start, end] 闭区间字节的 SHA1（大写）。"""
    sha1 = hashlib.sha1()
    with open(path, "rb") as handle:
        handle.seek(max(0, start))
        remaining = max(0, end - max(0, start) + 1)
        while remaining > 0:
            block = handle.read(min(1024 * 1024, remaining))
            if not block:
                break
            sha1.update(block)
            remaining -= len(block)
    return sha1.hexdigest().upper()


def _115_upload_init(token, file_name, file_size, target_cid, fileid, preid, sign_key="", sign_val=""):
    """POST /open/upload/init：fileid 命中秒传返回 status=2；status 6/7/8 需带 sign_key/sign_val 复核。"""
    resp = _openapi_request(
        "POST", "https://proapi.115.com/open/upload/init",
        body={
            "file_name": file_name,
            "file_size": str(int(file_size)),
            "target": f"U_1_{target_cid}",
            "fileid": fileid,
            "preid": preid,
            "pick_code": "",
            "topupload": "",
            "sign_key": sign_key,
            "sign_val": sign_val,
        },
        headers={"Authorization": f"Bearer {token}"},
        add_default_ua=False,
    )
    if resp.get("state") not in (True, 1):
        _raise_115_openapi_error(resp, "115 上传初始化失败")
    data = resp.get("data") or {}
    if not isinstance(data, dict) or not data:
        raise RuntimeError("115 上传初始化返回数据异常")
    return data


def _oss_request(method, bucket, endpoint, object_key, query="", data=None,
                 extra_headers=None, sts=None, timeout=60):
    """直连阿里云 OSS（115 OpenAPI 上传通道），带 V1 签名。返回 (状态码, 小写响应头 dict, body)。

    签名要点：x-oss-* 头（含 security-token/callback/callback-var）必须按名排序进签名；
    Content-Type 必须显式指定（urllib 会默认塞 form 类型导致签名错位）。
    """
    import email.utils
    host = f"{bucket}.{endpoint}"
    url = f"https://{host}/{object_key}"
    if query:
        url += f"?{query}"
    headers = {"Date": email.utils.formatdate(usegmt=True)}
    if extra_headers:
        headers.update(extra_headers)
    if sts:
        headers["x-oss-security-token"] = str(sts.get("SecurityToken", "") or "")
    canonical_headers = "".join(
        f"{key.lower()}:{str(headers[key]).strip()}\n"
        for key in sorted(headers, key=str.lower) if key.lower().startswith("x-oss-")
    )
    resource = f"/{bucket}/{object_key}"
    if query:
        signed = sorted(
            (key, value[0] if len(value) > 1 else "")
            for key, *rest in (part.split("=", 1) for part in query.split("&"))
            for value in [rest]
            if key in ("uploads", "partNumber", "uploadId")
        )
        if signed:
            resource += "?" + "&".join(f"{key}={value}" if value else key for key, value in signed)
    content_type = str(headers.get("Content-Type", "") or "")
    content_md5 = str(headers.get("Content-MD5", "") or "")
    string_to_sign = "\n".join([method, content_md5, content_type, headers["Date"],
                                canonical_headers + resource])
    secret = str(sts.get("AccessKeySecret", "") or "") if sts else ""
    access_key = str(sts.get("AccessKeyId", "") or "") if sts else ""
    digest = hmac.new(secret.encode("utf-8"), string_to_sign.encode("utf-8"), hashlib.sha1).digest()
    headers["Authorization"] = f"OSS {access_key}:{base64.b64encode(digest).decode()}"
    request_object = Request(url, data=data, headers=headers, method=method)
    try:
        with urlopen(request_object, timeout=timeout) as resp:
            return resp.status, {k.lower(): v for k, v in resp.headers.items()}, resp.read()
    except HTTPError as error:
        body = error.read()
        return error.code, {k.lower(): v for k, v in error.headers.items()}, body


def _115_oss_upload(upload_data, file_path, token):
    """把文件分片上传到 115 指定的阿里云 OSS，完成后带回调头合并分片触发 115 入库。

    返回 (pickcode, file_id)。失败时尽力 abort 分片任务。
    """
    resp = _openapi_request(
        "GET", "https://proapi.115.com/open/upload/get_token",
        headers={"Authorization": f"Bearer {token}"},
        add_default_ua=False,
    )
    if resp.get("state") not in (True, 1):
        _raise_115_openapi_error(resp, "获取 115 上传凭证失败")
    sts = resp.get("data") or {}
    bucket = str(upload_data.get("bucket") or "").strip()
    object_key = str(upload_data.get("object") or "").strip().lstrip("/")
    endpoint = str(sts.get("endpoint") or upload_data.get("endpoint") or "").strip()
    endpoint = endpoint.replace("https://", "").replace("http://", "").rstrip("/")
    if not (bucket and object_key and endpoint):
        raise RuntimeError(f"115 上传存储参数缺失：bucket/object/endpoint 为空")
    callback_obj = upload_data.get("callback") or {}
    callback_b64 = base64.b64encode(str(callback_obj.get("callback", "")).encode("utf-8")).decode()
    callback_var = callback_obj.get("callback_var", "")
    if isinstance(callback_var, (dict, list)):
        callback_var = json.dumps(callback_var, ensure_ascii=False, separators=(",", ":"))
    callback_var_b64 = base64.b64encode(str(callback_var).encode("utf-8")).decode()

    upload_id = ""
    try:
        # 1. 初始化分片上传
        status, _, body = _oss_request("POST", bucket, endpoint, object_key, query="uploads",
                                       data=b"", sts=sts, extra_headers={"Content-Type": "application/xml"})
        if status not in (200, 201):
            raise RuntimeError(f"OSS 初始化分片失败：HTTP {status} {body[:150]!r}")
        match = re.search(r"<UploadId>([^<]+)</UploadId>", body.decode("utf-8", errors="replace"))
        if not match:
            raise RuntimeError("OSS 未返回 UploadId")
        upload_id = match.group(1)
        # 2. 逐片上传（20MB/片，收集 ETag）
        etags = []
        part_number = 0
        with open(file_path, "rb") as handle:
            while True:
                chunk = handle.read(20 * 1024 * 1024)
                if not chunk:
                    break
                part_number += 1
                status, headers, body = _oss_request(
                    "PUT", bucket, endpoint, object_key,
                    query=f"partNumber={part_number}&uploadId={upload_id}",
                    data=chunk, sts=sts,
                    extra_headers={"Content-Type": "application/octet-stream"}, timeout=600)
                if status not in (200, 201):
                    raise RuntimeError(f"OSS 分片 {part_number} 上传失败：HTTP {status} {body[:150]!r}")
                etag = str(headers.get("etag", "") or "").strip()
                if not etag:
                    raise RuntimeError(f"OSS 分片 {part_number} 未返回 ETag")
                if not etag.startswith('"'):
                    etag = f'"{etag}"'
                etags.append(f"<Part><PartNumber>{part_number}</PartNumber><ETag>{etag}</ETag></Part>")
                if part_number % 10 == 0:
                    write_app_log("info", "huangguo", "upload-115",
                                  f"已上传 {part_number} 片（{part_number * 20} MB）")
        # 3. 合并分片并触发 115 回调入库
        complete_body = ("<CompleteMultipartUpload>" + "".join(etags) + "</CompleteMultipartUpload>").encode("utf-8")
        status, _, body = _oss_request(
            "POST", bucket, endpoint, object_key, query=f"uploadId={upload_id}",
            data=complete_body, sts=sts,
            extra_headers={"Content-Type": "application/xml",
                           "x-oss-callback": callback_b64,
                           "x-oss-callback-var": callback_var_b64}, timeout=60)
        text = body.decode("utf-8", errors="replace")
        if status != 200:
            raise RuntimeError(f"OSS 合并分片失败：HTTP {status} {text[:150]}")
        try:
            reply = json.loads(text)
        except ValueError:
            raise RuntimeError(f"115 回调返回异常：{text[:150]}")
        if not isinstance(reply, dict) or reply.get("state") not in (True, 1):
            raise RuntimeError(f"115 入库确认失败：{str(reply.get('message') if isinstance(reply, dict) else reply)[:150]}")
        data = reply.get("data") or {}
        return str(data.get("pick_code") or data.get("pickcode") or ""), str(data.get("file_id") or data.get("fid") or "")
    except Exception:
        if upload_id:
            try:
                _oss_request("DELETE", bucket, endpoint, object_key, query=f"uploadId={upload_id}", sts=sts)
            except Exception:
                pass
        raise


def upload_local_file_to_115(file_path, target_cid, target_path):
    """115 OpenAPI 文件上传：秒传 → 双向校验 → OSS 分片（协议参考 OpenList 115_open 驱动）。

    返回 {"file_id", "pickcode", "fast"}；鉴权失效自动重登重试一次。
    """
    settings = get_settings()
    cookie = str(settings.get("cloud115_cookie", "")).strip()
    if not cookie:
        raise RuntimeError("请先在 115 设置中保存 Cookie，才能上传黄果短剧")
    file_path = Path(file_path)
    if not file_path.exists():
        raise RuntimeError(f"待上传文件不存在：{file_path}")
    if not str(target_cid or "").strip():
        raise RuntimeError("未选择 115 网盘目标目录（请先在黄果设置中选择目标目录）")

    file_size = file_path.stat().st_size
    file_name = file_path.name
    fileid = _sha1_file_115(file_path)
    preid = _sha1_file_115(file_path, first_chunk=True)
    target_cid = str(target_cid).strip()
    write_app_log("info", "huangguo", "upload-115",
                  f"开始上传 {file_name}（{file_size / 1048576:.1f} MB）到 115：{target_path}")

    for attempt in range(2):
        token = _get_115_openapi_token(cookie)
        try:
            upload_data = _115_upload_init(token, file_name, file_size, target_cid, fileid, preid)
            status = int(upload_data.get("status") or 0)
            # 双向校验：服务端抽查一段字节要求补签名，复核后可能转为秒传
            if status in (6, 7, 8) and upload_data.get("sign_check") and upload_data.get("sign_key"):
                start_s, end_s = str(upload_data["sign_check"]).split("-", 1)
                sign_val = _sha1_range_115(file_path, int(start_s), int(end_s))
                upload_data = _115_upload_init(token, file_name, file_size, target_cid, fileid, preid,
                                               sign_key=str(upload_data["sign_key"]), sign_val=sign_val)
                status = int(upload_data.get("status") or 0)
            if status == 2:
                pickcode = str(upload_data.get("pick_code") or upload_data.get("pickcode") or "")
                write_app_log("success", "huangguo", "upload-115", "秒传成功（SHA1 命中 115 已有文件）", target=target_path)
                return {"file_id": "", "pickcode": pickcode, "fast": True}
            if status not in (0, 1):
                raise RuntimeError(f"115 上传初始化返回异常状态 {status}：{str(upload_data)[:160]}")
            pickcode, file_id = _115_oss_upload(upload_data, file_path, token)
            write_app_log("success", "huangguo", "upload-115", f"上传完成：{target_path}")
            return {"file_id": file_id, "pickcode": pickcode, "fast": False}
        except _115OpenApiAuthError as error:
            _clear_openapi_cache()
            if attempt == 1:
                raise RuntimeError(f"115 上传鉴权失败（已重试）：{error}") from error
            write_app_log("warning", "huangguo", "upload-115", f"115 鉴权失效，自动重新登录后重试：{error}")


def _hg_make_episode_strm(series, episode, settings, pickcode, upload_path, file_size):
    """黄果上传成功且删除本地源文件后，在原剧集目录生成 strm 并入库 strm_items。

    strm 指向 /api/115/stream/hg_<episode_id>（播放时用 pickcode 实时换 115 直链）。
    返回是否生成成功；未配置服务访问地址时跳过并记录日志。
    """
    base_url = str(settings.get("service_base_url", "") or "").strip().rstrip("/")
    if not base_url:
        write_app_log("warning", "huangguo", "upload-115",
                      "已上传但未在服务设置中配置「服务访问地址」，跳过 strm 生成（本地将无法播放）")
        return False
    safe_series = safe_name(series["title"], series["id"])
    dest_dir = MEDIA_DIR / "黄果短剧" / safe_series
    dest_dir.mkdir(parents=True, exist_ok=True)
    ep = int(episode["ep"])
    item_id = f"hg_{episode['id']}"
    strm_path = dest_dir / f"第{ep:03d}集.strm"
    strm_path.write_text(f"{base_url}/api/115/stream/{item_id}\n", encoding="utf-8")
    poster = dest_dir / "poster.jpg"
    with db_lock, connect() as db:
        db.execute(
            """INSERT INTO strm_items (id, cloud_task_id, catalog, title, strm_path, poster_path,
                                       pickcode, file_path, size, cover_url, created_at)
               VALUES (?,?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT(id) DO UPDATE SET title=excluded.title, pickcode=excluded.pickcode,
                   file_path=excluded.file_path, size=excluded.size, strm_path=excluded.strm_path""",
            (item_id, episode["id"], safe_series, f"{series['title']} 第{ep:03d}集", str(strm_path),
             str(poster) if poster.exists() else "", str(pickcode or ""), str(upload_path or ""),
             int(file_size or 0), str(series.get("cover_url", "") or ""),
             datetime.now().isoformat(timespec="seconds"))
        )
    write_app_log("success", "huangguo", "upload-115", f"第 {ep} 集 strm 已生成：{strm_path}")
    return True


def _hg_stream_url_expired(url):
    """auth_key=<时间戳>- 形式的流地址是时效签名，过期后必须重新解析"""
    if "auth_key=" not in (url or ""):
        return False
    try:
        ts = int(url.split("auth_key=", 1)[1].split("-", 1)[0])
        return ts <= time.time() + 60
    except Exception:
        return True


def _hg_process_episode(episode_id):
    episode = row("SELECT * FROM hg_episodes WHERE id=?", (episode_id,))
    if not episode:
        return
    series = row("SELECT * FROM hg_series WHERE id=?", (episode["series_id"],))
    if not series:
        raise RuntimeError("短剧记录不存在")
    work_dir = WORK_DIR / "huangguo" / episode_id
    work_dir.mkdir(parents=True, exist_ok=True)
    safe_series = safe_name(series["title"], series["id"])
    dest_dir = MEDIA_DIR / "黄果短剧" / safe_series
    dest_dir.mkdir(parents=True, exist_ok=True)
    output = dest_dir / f"第{int(episode['ep']):03d}集.mp4"
    try:
        if episode["state"] != "completed":
            with db_lock, connect() as db:
                db.execute("UPDATE hg_episodes SET state='running', progress=0.05, message='解析媒体流', error='', updated_at=? WHERE id=?",
                           (datetime.now().isoformat(timespec="seconds"), episode_id))
            stream = episode.get("stream_url") or ""
            if stream and _hg_stream_url_expired(stream):
                stream = ""  # 时效签名已过期，重试必须重新解析
            if not stream:
                stream = _hg_resolve_episode_stream(episode["play_url"], episode["ep"])
            with db_lock, connect() as db:
                db.execute("UPDATE hg_episodes SET stream_url=?, progress=0.15, message='下载中', updated_at=? WHERE id=?",
                           (stream, datetime.now().isoformat(timespec="seconds"), episode_id))
            temp_output = work_dir / f"{episode_id}.mp4"
            try:
                _hg_download_episode(episode, stream, temp_output, work_dir)
            except Exception as first_err:
                # 流地址含时效签名时，下载失败多为签名过期/被踢，重新解析后重试一次
                if "auth_key=" not in stream:
                    raise
                stream = _hg_resolve_episode_stream(episode["play_url"], episode["ep"])
                with db_lock, connect() as db:
                    db.execute("UPDATE hg_episodes SET stream_url=?, message='流地址已刷新，重新下载', updated_at=? WHERE id=?",
                               (stream, datetime.now().isoformat(timespec="seconds"), episode_id))
                try:
                    _hg_download_episode(episode, stream, temp_output, work_dir)
                except Exception:
                    raise first_err
            shutil.move(str(temp_output), output)
            refreshed = dict(episode)
            refreshed["stream_url"] = stream
            refreshed["file_path"] = str(output)
            _hg_write_metadata(series, refreshed, output)
            with db_lock, connect() as db:
                db.execute("""UPDATE hg_episodes SET state='completed', progress=0.86, file_path=?, retry_count=0, message='已完成刮削，等待上传策略',
                              updated_at=? WHERE id=?""", (str(output), datetime.now().isoformat(timespec="seconds"), episode_id))
            write_app_log("success", "huangguo", "scrape-episode", f"第 {episode['ep']} 集完整刮削完成",
                          task_id=episode_id, target=str(output))
        elif episode.get("file_path"):
            output = Path(episode["file_path"])
        settings = get_settings()
        upload_strategy = str(settings.get("hg_upload_strategy") or ("episode" if settings.get("hg_upload_enabled") else "never"))
        series_completed = bool(int(series.get("completed") or 0))
        should_upload = upload_strategy == "episode" or (upload_strategy == "completed" and series_completed)
        if should_upload:
            with db_lock, connect() as db:
                db.execute("UPDATE hg_episodes SET upload_state='uploading', message='上传 115 中', updated_at=? WHERE id=?",
                           (datetime.now().isoformat(timespec="seconds"), episode_id))
            upload_path = f"{str(settings.get('hg_target_path') or '/黄果短剧').rstrip('/')}/{safe_series}/第{int(episode['ep']):03d}集.mp4"
            upload_reply = upload_local_file_to_115(output, settings.get("hg_target_cid", ""), upload_path)
            upload_file_id = str(upload_reply.get("file_id", "") or upload_reply.get("fid", "") or "")
            pickcode = str(upload_reply.get("pickcode", "") or "")
            file_size = output.stat().st_size if output.exists() else 0
            delete_local = bool(settings.get("hg_delete_after_upload"))
            if delete_local and output.exists():
                output.unlink()
            strm_ok = False
            if delete_local:
                # 本地源文件已删，在原剧集目录生成 strm（播放走 /api/115/stream 换 115 直链）
                strm_ok = _hg_make_episode_strm(series, episode, settings, pickcode, upload_path, file_size)
            message_text = ("已上传并删除本地源文件" + ("，strm 已生成" if strm_ok else
                            ("；未配置服务访问地址，未生成 strm" if delete_local else ""))
                            if delete_local else "已上传到 115")
            with db_lock, connect() as db:
                db.execute("""UPDATE hg_episodes SET upload_state='uploaded', progress=1, upload_path=?, upload_file_id=?, pickcode=?,
                              message=?, updated_at=? WHERE id=?""",
                           (upload_path, upload_file_id, pickcode, message_text,
                            datetime.now().isoformat(timespec="seconds"), episode_id))
        else:
            message_text = "本地入库完成，等待全剧完结后上传" if upload_strategy == "completed" else "本地入库完成，已按设置跳过上传"
            upload_state = "waiting_complete" if upload_strategy == "completed" else "skipped"
            with db_lock, connect() as db:
                db.execute("""UPDATE hg_episodes SET upload_state=?, progress=1, message=?,
                              updated_at=? WHERE id=?""", (upload_state, message_text, datetime.now().isoformat(timespec="seconds"), episode_id))
    except Exception as error:
        current = row("SELECT state FROM hg_episodes WHERE id=?", (episode_id,)) or {}
        with db_lock, connect() as db:
            if current.get("state") == "completed":
                db.execute("UPDATE hg_episodes SET upload_state='failed', message='上传失败，本地已保留', error=?, updated_at=? WHERE id=?",
                           (str(error), datetime.now().isoformat(timespec="seconds"), episode_id))
            else:
                ep_row = row("SELECT retry_count FROM hg_episodes WHERE id=?", (episode_id,)) or {}
                retries = int(ep_row.get("retry_count") or 0)
                if retries < 2:
                    db.execute("UPDATE hg_episodes SET state='queued', progress=0, retry_count=?, message=?, error=?, updated_at=? WHERE id=?",
                               (retries + 1, f"下载失败，自动重试（第 {retries + 1} 次）", str(error)[:200],
                                datetime.now().isoformat(timespec="seconds"), episode_id))
                    hg_worker_wakeup.set()
                    write_app_log("warning", "huangguo", "auto-retry",
                                  f"第 {episode['ep']} 集下载失败，自动重试（第 {retries + 1} 次）",
                                  detail=str(error)[:200], task_id=episode_id)
                else:
                    db.execute("UPDATE hg_episodes SET state='failed', upload_state='pending', progress=0, message='执行失败（已自动重试 2 次）', error=?, updated_at=? WHERE id=?",
                               (str(error), datetime.now().isoformat(timespec="seconds"), episode_id))
        write_app_log("error", "huangguo", "episode-failed", f"第 {episode['ep']} 集处理失败",
                      detail=str(error), task_id=episode_id, target=episode.get("play_url", ""))
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)
        _hg_refresh_series_counts(series["id"])


_HG_ACTIVE_LOCK = threading.Lock()
_HG_ACTIVE_COUNT = 0
_HG_WORKER_THREADS = 4  # 常驻线程数上限，实际并发由 hg_episode_concurrency 设置动态控制
_HG_METADATA_LOCK = threading.Lock()  # 多 worker 并行时串行化共享元数据文件写盘


def _hg_claim_next_episode():
    """原子领取下一集：queued->running / retry->uploading，防止多 worker 重复领取同一集。"""
    now = datetime.now().isoformat(timespec="seconds")
    with db_lock, connect() as db:
        item = db.execute(
            """SELECT id, state FROM hg_episodes
               WHERE state='queued' OR upload_state='retry'
               ORDER BY updated_at ASC LIMIT 1"""
        ).fetchone()
        if not item:
            return None
        if item["state"] == "queued":
            db.execute("UPDATE hg_episodes SET state='running', progress=0.05, message='解析媒体流', error='', updated_at=? WHERE id=?",
                       (now, item["id"]))
        else:
            db.execute("UPDATE hg_episodes SET upload_state='uploading', message='等待上传 115', updated_at=? WHERE id=?",
                       (now, item["id"]))
        return item["id"]


def hg_worker():
    global _HG_ACTIVE_COUNT
    while True:
        claimed = None
        with _HG_ACTIVE_LOCK:
            try:
                limit = min(4, max(1, int(get_settings().get("hg_episode_concurrency", 2))))
            except Exception:
                limit = 2
            if _HG_ACTIVE_COUNT < limit:
                claimed = _hg_claim_next_episode()
                if claimed:
                    _HG_ACTIVE_COUNT += 1
        if not claimed:
            hg_worker_wakeup.wait(5)
            hg_worker_wakeup.clear()
            continue
        try:
            _hg_process_episode(claimed)
        finally:
            with _HG_ACTIVE_LOCK:
                _HG_ACTIVE_COUNT -= 1


def hg_follow_scheduler():
    time.sleep(15)
    while True:
        settings = get_settings()
        if not settings.get("hg_follow_enabled", True):
            time.sleep(300)
            continue
        interval = max(1, int(settings.get("hg_check_interval", 6))) * 3600
        try:
            batch = min(20, max(1, int(settings.get("hg_follow_pages", 3))))
        except (TypeError, ValueError):
            batch = 3
        now = time.time()
        for item in rows(f"SELECT * FROM hg_series WHERE follow_enabled=1 AND completed=0 ORDER BY last_checked_at ASC LIMIT {batch}"):
            try:
                last = 0
                if item.get("last_checked_at"):
                    last = datetime.fromisoformat(item["last_checked_at"]).timestamp()
                if now - last < interval:
                    continue
                parsed = _hg_parse_series(item["detail_url"])
                before = int(item.get("latest_episode") or 0)
                _hg_upsert_series(parsed)
                after = max([int(e["ep"]) for e in parsed.get("episodes", [])], default=0)
                if after > before:
                    with db_lock, connect() as db:
                        db.execute("""UPDATE hg_episodes SET state='queued', message='追更发现新集，等待下载',
                                      updated_at=? WHERE series_id=? AND ep>? AND state='pending'""",
                                   (datetime.now().isoformat(timespec="seconds"), item["id"], before))
                    hg_worker_wakeup.set()
                    write_app_log("success", "huangguo", "follow-update",
                                  f"发现新集：{item['title']} 第 {before + 1}-{after} 集", target=item["detail_url"])
                else:
                    write_app_log("info", "huangguo", "follow-checked",
                                  f"追更检查：{item['title']} 暂无更新（共 {after} 集）", target=item["detail_url"])
            except Exception as error:
                write_app_log("error", "huangguo", "follow-check", "黄果短剧自动追更检查失败",
                              detail=str(error), target=item.get("detail_url", ""))
        time.sleep(300)


# 轮询探测冷却：单任务连续 12 次未命中后冷却 1 小时（失效任务不再无限探测）
_TASK_PROBE_STATE = {}  # key=task_id, value=(probe_count, last_probe_ts)
_TASK_PROBE_LOCK = threading.Lock()
_PROBE_GIVE_UP = 12
_PROBE_COOLDOWN = 3600


def poll_cloud_tasks():
    """后台线程：定时检查 115 目录，发现离线产物后更新状态。

    新任务提交时直接指定 wp_path_id（产物落在目标目录）；
    旧任务/未配置目标目录的任务落在「云下载」，完成后按需执行网盘内转移。
    115 的 lixian 状态接口已启用签名风控无法直调，改用 webapi 目录探测判定完成。

    优化：避免频繁请求 115 API 触发"账号使用异常"：
    1. 轮询间隔不低于 300 秒（5 分钟）
    2. 指数退避：连续探测无变化时频率降低（最多 10 分钟）
    3. 缓存「云下载」文件夹 ID，避免每次查找
    4. 单任务连续 12 次未命中后冷却 1 小时（防失效任务无限探测）
    """
    last_error = 0
    cached_download_dir_id = ""
    no_change_count = 0  # 连续探测无变化的次数（用于指数退避）
    while True:
        try:
            settings = get_settings()
            interval = max(300, int(settings.get("cloud_poll_interval", 300)))  # 最低 5 分钟
            if str(settings.get("cloud115_mode", "bridge")) != "cookie":
                time.sleep(interval); continue
            cookie = str(settings.get("cloud115_cookie", "")).strip()
            if not cookie:
                time.sleep(interval); continue

            # 找出所有未完成的 cloud_tasks，按探测目录分组
            pending = rows(
                "SELECT * FROM cloud_tasks WHERE state IN ('submitted','pending','running') ORDER BY created_at DESC LIMIT 30"
            )
            if not pending:
                no_change_count = 0
                time.sleep(interval); continue

            now = time.time()
            # 探测冷却：单任务连续 12 次未命中后进入 1 小时冷却，防止对失效任务无限探测
            active_tasks = []
            with _TASK_PROBE_LOCK:
                for ct in pending:
                    count, last_ts = _TASK_PROBE_STATE.get(ct["id"], (0, 0.0))
                    if count >= _PROBE_GIVE_UP and now - last_ts < _PROBE_COOLDOWN:
                        continue  # 冷却中，本轮跳过
                    active_tasks.append(ct)
            if not active_tasks:
                time.sleep(interval); continue

            download_dir_id = cached_download_dir_id
            groups: dict = {}
            for ct in active_tasks:
                cid = str(ct.get("dest_cid") or "").strip()
                if not cid:
                    if not download_dir_id:
                        download_dir = find_115_download_dir(cookie)
                        if not download_dir:
                            raise RuntimeError("未在 115 网盘根目录找到「云下载」文件夹")
                        download_dir_id = str(download_dir["id"])
                        cached_download_dir_id = download_dir_id
                    cid = download_dir_id
                groups.setdefault(cid, []).append(ct)

            any_completed = False
            for probe_cid, cts in groups.items():
                try:
                    nodes = list_115_nodes(cookie, probe_cid)
                except Exception as probe_error:
                    if time.time() - last_error > 300:
                        print(f"[poll-cloud] 115 探测失败: {probe_error}", flush=True)
                    last_error = time.time()
                    continue

                dest_label = str(settings.get("cloud_transfer_path") or "").strip()
                for ct in cts:
                    matched = _match_115_node(nodes, ct["title"], ct.get("catalog"))
                    if not matched:
                        # 未命中：累计探测次数（达到上限后冷却 1 小时）
                        with _TASK_PROBE_LOCK:
                            count, _ = _TASK_PROBE_STATE.get(ct["id"], (0, 0.0))
                            _TASK_PROBE_STATE[ct["id"]] = (count + 1, now)
                        continue
                    any_completed = True
                    with _TASK_PROBE_LOCK:
                        _TASK_PROBE_STATE.pop(ct["id"], None)
                    if str(ct.get("dest_cid") or "").strip():
                        file_path = f"{dest_label.rstrip('/')}/{matched['name']}" if dest_label \
                            else f"115 网盘目标目录/{matched['name']}"
                    else:
                        file_path = f"云下载/{matched['name']}"
                    message = f"115 离线完成（云盘位置：{file_path}）"

                    play_url = ""
                    best_pickcode = ""
                    best_size = int(matched.get("size", 0) or 0)
                    video_exts = (".mp4", ".mkv", ".wmv", ".avi", ".mov", ".flv", ".ts", ".webm", ".rmvb", ".m2ts")
                    if matched["is_dir"]:
                        try:
                            all_children = list_115_nodes(cookie, matched["id"])
                            ad_deleted, _ad_failed = _115_cleanup_ad_files(cookie, matched, all_children, settings)
                            if ad_deleted:
                                message += f"；已清理 {ad_deleted} 个广告小文件"
                            children = [child for child in all_children
                                        if not child["is_dir"] and child["name"].lower().endswith(video_exts)]
                            if children:
                                biggest = max(children, key=lambda child: int(child["size"] or 0))
                                best_pickcode = biggest.get("pickcode", "")
                                best_size = int(biggest.get("size", 0) or 0)
                                if best_pickcode:
                                    play_url = f"https://115.com/web/play/?pickcode={best_pickcode}"
                        except Exception:
                            pass
                    else:
                        best_pickcode = matched.get("pickcode", "")
                        if best_pickcode:
                            play_url = f"https://115.com/web/play/?pickcode={best_pickcode}"

                    if not str(ct.get("dest_cid") or "").strip() and settings.get("cloud_transfer_enabled"):
                        target_cid = str(settings.get("cloud_transfer_cid", "") or "").strip()
                        if not target_cid:
                            message += "；转移失败：未在服务设置中选择 115 网盘目标目录"
                        else:
                            try:
                                move_115_node(cookie, matched, target_cid)
                                message += f"；已转移到 115 网盘 {dest_label or '目标目录'}"
                                file_path = f"{dest_label.rstrip('/')}/{matched['name']}" if dest_label else file_path
                            except Exception as transfer_error:
                                message += f"；转移失败：{str(transfer_error)[:120]}"

                    try:
                        if generate_strm_item(dict(ct), best_pickcode, file_path, best_size):
                            message += "；已生成 strm 并刮削入库"
                    except Exception as strm_error:
                        message += f"；strm 生成失败：{str(strm_error)[:100]}"

                    with db_lock, connect() as db:
                        db.execute(
                            "UPDATE cloud_tasks SET state='completed', message=?, play_url=?, file_path=?, finished_at=?, pickcode=? WHERE id=?",
                            (message, play_url, file_path, datetime.now().isoformat(timespec="seconds"), best_pickcode, ct["id"])
                        )

            # 指数退避：本次探测无新完成，增加退避计数
            if any_completed:
                no_change_count = 0
            else:
                no_change_count += 1

        except Exception as error:
            print(f"[poll-cloud] 异常: {error}", flush=True)
        # 指数退避：连续无变化时降低频率（最多 10 分钟）
        sleep_interval = min(interval * (2 ** no_change_count), 600)
        time.sleep(sleep_interval)


def watch_folder():
    """定时扫描监控目录，发现新文件自动创建手动刮削任务。"""
    processed: dict[str, float] = {}
    while True:
        try:
            settings = get_settings()
            if not settings.get("watch_enabled") or not settings.get("watch_dir"):
                processed.clear()
                time.sleep(5)
                continue
            watch_dir_raw = str(settings.get("watch_dir", "")).strip()
            try:
                watch_dir = resolve_media_path(watch_dir_raw)
            except ValueError:
                time.sleep(5); continue
            if not watch_dir.is_dir():
                time.sleep(5); continue
            interval = max(3, int(settings.get("watch_interval", 10)))
            found_new = 0
            for item in watch_dir.rglob("*"):
                if not item.is_file():
                    continue
                if item.suffix.lower() not in VIDEO_EXTENSIONS:
                    continue
                mtime = item.stat().st_mtime
                abs_path = str(item.resolve())
                if abs_path in processed and processed[abs_path] == mtime:
                    continue
                if time.time() - mtime < 2:
                    continue
                try:
                    with db_lock, connect() as db:
                        existing = db.execute(
                            "SELECT id FROM tasks WHERE source_path=? AND task_type='manual_scrape' AND state NOT IN ('failed','cancelled')",
                            (abs_path,)
                        ).fetchone()
                    if existing:
                        processed[abs_path] = mtime
                        continue
                    tid = _insert_manual_scrape_task(item, settings, {})
                    processed[abs_path] = mtime
                    found_new += 1
                    append_log(tid, f"Watch folder 自动发现：{item}")
                except Exception as error:
                    append_log("watch", f"处理文件失败 {item}: {error}")
            if found_new:
                worker_wakeup.set()
        except Exception as error:
            print(f"[watch-folder] 异常: {error}", flush=True)
        time.sleep(max(3, int(get_settings().get("watch_interval", 10))))


def worker():
    while True:
        pending = rows("SELECT * FROM tasks WHERE state='pending' ORDER BY priority DESC,created_at LIMIT 1")
        if pending:
            run_task(pending[0])
            continue
        worker_wakeup.wait(2)
        worker_wakeup.clear()


def build_catalog_cover_map():
    """番号 → 封面 URL 映射（本地任务、列表缓存、详情页缓存）"""
    cover_map = {}
    for source in ("SELECT catalog, cover_url FROM tasks WHERE cover_url != ''",
                   "SELECT catalog, cover_url FROM latest_videos"):
        try:
            source_rows = rows(source)
        except Exception:
            continue
        for r in source_rows:
            cover_map.setdefault(str(r["catalog"]).upper(), r["cover_url"])
    for cached in detail_cache.values():
        data = cached.get("data") or {}
        catalog_key = detect_catalog("", str(data.get("title", "")))
        if catalog_key and data.get("cover_url"):
            cover_map.setdefault(catalog_key.upper(), data["cover_url"])
    return cover_map


def catalog_poster_url(catalog, cover_map=None):
    """按番号查封面，返回可直接作 <img> src 的 URL（jable 图走代理）"""
    catalog_key = str(catalog or "").strip().upper()
    if not catalog_key:
        return ""
    cover = (cover_map if cover_map is not None else build_catalog_cover_map()).get(catalog_key, "")
    if not cover:
        return ""
    return cover if cover.startswith("/api/") else "/api/proxy-image?url=" + quote(cover, safe="")


def task_payload(row, cover_map=None):
    row["cover_url"] = f"/api/tasks/{row['id']}/cover" if row.get("cover_path") else ""
    if not row["cover_url"]:
        row["cover_url"] = catalog_poster_url(row.get("catalog"), cover_map)
    return row


@app.get("/")
@app.get("/index.html")
def index():
    html = (Path(app.static_folder) / "index.html").read_text(encoding="utf-8")
    if not _access_authenticated():
        html = html.replace("<head>", '<head><script>window.__ACCESS_LOCKED__=true</script>', 1)
    if not _license_state()["activated"]:
        html = html.replace("<head>", '<head><script>window.__UNLICENSED__=true</script>', 1)
    response = app.response_class(html, mimetype="text/html")
    response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"
    return response


@app.get("/api/health")
def health():
    return jsonify(status="ok", architecture=os.uname().machine, media=str(MEDIA_DIR),
                   downloader=DOWNLOADER.exists(), browser=Path(CHROMIUM).exists() and Path(CHROMEDRIVER).exists())


@app.get("/api/logs")
def api_logs():
    module = str(request.args.get("module", "") or "").strip()
    level = str(request.args.get("level", "") or "").strip()
    keyword = str(request.args.get("q", "") or "").strip()
    try:
        limit = min(500, max(20, int(request.args.get("limit", "200") or "200")))
    except (TypeError, ValueError):
        limit = 200
    where = []
    params = []
    if module and module != "all":
        where.append("module=?")
        params.append(module)
    if level and level != "all":
        where.append("level=?")
        params.append(level)
    if keyword:
        like = f"%{keyword}%"
        where.append("(message LIKE ? OR detail LIKE ? OR action LIKE ? OR target LIKE ? OR task_id LIKE ?)")
        params.extend([like, like, like, like, like])
    clause = " WHERE " + " AND ".join(where) if where else ""
    logs = rows(
        f"SELECT id,created_at,level,module,action,target,message,detail,task_id FROM app_logs{clause} "
        "ORDER BY created_at DESC LIMIT ?",
        (*params, limit),
    )
    return jsonify(ok=True, logs=logs, limit=limit)


@app.get("/api/logs/stats")
def api_logs_stats():
    today = datetime.now().date().isoformat()
    total = row("SELECT COUNT(*) AS n FROM app_logs")["n"]
    today_rows = rows(
        "SELECT level, COUNT(*) AS n FROM app_logs WHERE created_at>=? GROUP BY level",
        (today,),
    )
    module_rows = rows("SELECT module, COUNT(*) AS n FROM app_logs GROUP BY module ORDER BY n DESC")
    last_error = row(
        "SELECT created_at,module,action,message,target FROM app_logs WHERE level='error' ORDER BY created_at DESC LIMIT 1"
    )
    return jsonify(ok=True, total=total, today={item["level"]: item["n"] for item in today_rows},
                   modules=module_rows, last_error=last_error)


@app.get("/api/logs/export")
def api_logs_export():
    items = rows(
        "SELECT created_at,level,module,action,target,message,detail,task_id FROM app_logs ORDER BY created_at DESC LIMIT 1000"
    )
    lines = []
    for item in items:
        target = f" target={item['target']}" if item.get("target") else ""
        task = f" task={item['task_id']}" if item.get("task_id") else ""
        lines.append(f"[{item['created_at']}] {item['level'].upper()} {item['module']}.{item['action']}{target}{task} - {item['message']}")
        if item.get("detail"):
            lines.append(str(item["detail"]))
    body = "\n".join(lines) + ("\n" if lines else "")
    response = Response(body, mimetype="text/plain; charset=utf-8")
    response.headers["Content-Disposition"] = "attachment; filename=jable-logs.txt"
    return response


@app.delete("/api/logs")
def api_logs_clear():
    with db_lock, connect() as db:
        db.execute("DELETE FROM app_logs")
    write_app_log("warning", "system", "logs-clear", "日志中心已清空", target="/api/logs")
    return jsonify(ok=True)


@app.get("/api/access/status")
def api_access_status():
    return jsonify(ok=True, **_access_status())


@app.post("/api/access/login")
def api_access_login():
    password = str((request.get_json(silent=True) or {}).get("password", ""))
    encoded = _site_password_hash()
    if not encoded:
        session["site_access"] = True
        session.permanent = True
        write_app_log("info", "access", "login", "未配置访问密码，自动放行", target=request.remote_addr or "")
        return jsonify(ok=True, configured=False, authenticated=True)
    if not password:
        return jsonify(ok=False, error="请输入访问密码"), 400
    if not _verify_password(password, encoded):
        write_app_log("warning", "access", "login-failed", "访问密码错误", target=request.remote_addr or "")
        return jsonify(ok=False, error="访问密码错误"), 403
    session["site_access"] = True
    session.permanent = True
    write_app_log("success", "access", "login", "访问密码验证通过", target=request.remote_addr or "")
    return jsonify(ok=True, configured=True, authenticated=True)


@app.post("/api/access/logout")
def api_access_logout():
    session.pop("site_access", None)
    write_app_log("info", "access", "logout", "当前浏览器会话已退出", target=request.remote_addr or "")
    return jsonify(ok=True, **_access_status())


@app.put("/api/access/password")
def api_access_password():
    payload = request.get_json(silent=True) or {}
    current_password = str(payload.get("current_password", "") or "")
    new_password = str(payload.get("new_password", "") or "")
    encoded = _site_password_hash()
    if encoded and not _verify_password(current_password, encoded):
        return jsonify(ok=False, error="当前访问密码错误"), 403
    if len(new_password) < 6:
        return jsonify(ok=False, error="访问密码至少 6 位"), 400
    store_setting("site_password_hash", _password_hash(new_password))
    session["site_access"] = True
    session.permanent = True
    write_app_log("success", "access", "password-update", "访问密码已更新", target=request.remote_addr or "")
    return jsonify(ok=True, message="访问密码已更新", **_access_status())


@app.delete("/api/access/password")
def api_access_password_clear():
    payload = request.get_json(silent=True) or {}
    current_password = str(payload.get("current_password", "") or "")
    encoded = _site_password_hash()
    if encoded and not _verify_password(current_password, encoded):
        return jsonify(ok=False, error="当前访问密码错误"), 403
    store_setting("site_password_hash", "")
    session["site_access"] = True
    write_app_log("warning", "access", "password-clear", "访问密码已关闭", target=request.remote_addr or "")
    return jsonify(ok=True, message="访问密码已关闭", **_access_status())


@app.get("/api/license")
def api_license_info():
    state = _license_state()
    if not state["device_id"]:
        state["device_id"] = _ensure_device_id()
    return jsonify(ok=True, **state)


@app.post("/api/license/activate")
def api_license_activate():
    data = request.get_json(silent=True) or {}
    code = re.sub(r"[\s\-]", "", str(data.get("license_code", "") or ""))
    if not code:
        return jsonify(ok=False, error="请输入授权码"), 400
    state0 = _license_state()
    device_id = state0["device_id"] or _ensure_device_id()
    if state0.get("revoked"):
        write_app_log("warning", "license", "activate", "吊销设备尝试激活授权", target=device_id)
        return jsonify(ok=False, error="该设备授权已被吊销，请联系管理员"), 403
    expires_at = _license_verify_code(device_id, code)
    if expires_at is None:
        write_app_log("warning", "license", "activate", "授权码无效", target=device_id)
        return jsonify(ok=False, error="授权码无效：与本机设备码不匹配或内容已损坏"), 400
    if 0 < expires_at <= time.time():
        write_app_log("warning", "license", "activate", "授权码已过期", target=device_id)
        return jsonify(ok=False, error="授权码已过期，请获取新的授权码"), 400
    with db_lock, connect() as db:
        db.execute("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)",
                   ("license_code", json.dumps(code)))
    _LICENSE_SIG_CACHE.update(device=None, code=None, expires_at=None)
    state = _license_state()
    expire_text = "永久有效" if state["expires_at"] == 0 else "有效期至 " + datetime.fromtimestamp(state["expires_at"]).strftime("%Y-%m-%d")
    write_app_log("success", "license", "activate", "授权激活成功，" + expire_text, target=device_id)
    return jsonify(ok=True, **state, message="授权成功，" + expire_text)


@app.post("/api/license/deactivate")
def api_license_deactivate():
    with db_lock, connect() as db:
        db.execute("DELETE FROM settings WHERE key=?", ("license_code",))
    _LICENSE_SIG_CACHE.update(device=None, code=None, expires_at=None)
    state = _license_state()
    write_app_log("warning", "license", "deactivate", "已清除本机授权", target=state.get("device_id", ""))
    return jsonify(ok=True, **state, message="已清除本机授权")


@app.get("/api/settings")
def read_settings():
    return jsonify(public_settings())


@app.put("/api/settings")
def update_settings():
    try:
        result = save_settings(request.get_json(force=True))
        write_app_log("success", "settings", "save", "服务设置已保存")
        return jsonify(result)
    except (TypeError, ValueError) as error:
        write_app_log("warning", "settings", "save", "服务设置保存失败", detail=str(error))
        return jsonify(error=str(error)), 400


@app.post("/api/115/qrcode")
def create_115_qrcode():
    client = "web"
    payload = request.get_json(silent=True) or {}
    candidate = str(payload.get("client", "web")).strip()
    if candidate in {"web", "windows", "mac", "linux", "android", "ios", "tv", "alipaymini", "wechatmini"}:
        client = candidate
    try:
        result = request_115_qr_token(client)
        write_app_log("success", "115", "qrcode", f"115 扫码登录二维码已生成：{client}")
        return jsonify(result)
    except Exception as error:
        write_app_log("error", "115", "qrcode", "115 二维码生成失败", detail=str(error))
        return jsonify(error=f"115 二维码生成失败：{str(error)[:180]}"), 502


@app.get("/api/115/qrcode/status")
def qrcode_115_status():
    try:
        result = poll_115_qr_login()
        if result.get("status") == "authorized":
            write_app_log("success", "115", "qrcode-status", "115 扫码登录已授权")
        return jsonify(result)
    except ValueError as error:
        return jsonify(error=str(error)), 400
    except Exception as error:
        write_app_log("error", "115", "qrcode-status", "115 扫码登录检测失败", detail=str(error))
        return jsonify(error=f"115 扫码登录失败：{str(error)[:180]}"), 502


# 目录浏览缓存：Cascader 展开目录树时每个节点一次 API 调用，60 秒内重复展开不再请求 115
_115_DIRS_CACHE = {}  # key=(md5(cookie), cid), value=(dirs, expire_timestamp)
_115_DIRS_CACHE_LOCK = threading.Lock()
_DIRS_CACHE_TTL = 60


@app.get("/api/115/dirs")
def list_115_dirs_api():
    """列出 115 网盘指定目录下的子目录，供管线 C 目标目录选择器使用（60 秒缓存）。"""
    settings = get_settings()
    cookie = str(settings.get("cloud115_cookie", "")).strip()
    if str(settings.get("cloud115_mode", "bridge")) != "cookie" or not cookie:
        return jsonify(error="115 目录浏览需要 Cookie 模式，请先在服务设置中保存 115 Cookie"), 400
    cid = request.args.get("cid", "0").strip() or "0"
    cache_key = (hashlib.md5(cookie.encode()).hexdigest(), cid)
    now = time.time()
    with _115_DIRS_CACHE_LOCK:
        cached = _115_DIRS_CACHE.get(cache_key)
        if cached:
            dirs, expire = cached
            if now < expire:
                return jsonify([{"cid": node["id"], "name": node["name"], "type": "dir"} for node in dirs])
            _115_DIRS_CACHE.pop(cache_key, None)
    try:
        dirs = [node for node in list_115_nodes(cookie, cid) if node["is_dir"]]
    except Exception as error:
        return jsonify(error=f"读取 115 目录失败：{str(error)[:180]}"), 502
    with _115_DIRS_CACHE_LOCK:
        _115_DIRS_CACHE[cache_key] = (dirs, now + _DIRS_CACHE_TTL)
    return jsonify([{"cid": node["id"], "name": node["name"], "type": "dir"} for node in dirs])


@app.post("/api/115/check-login")
def check_115_login():
    """手动检测 115 登录状态：Cookie 模式实测读取网盘目录，中转模式探活服务地址。"""
    settings = get_settings()
    if str(settings.get("cloud115_mode", "bridge")) == "cookie":
        cookie = str(settings.get("cloud115_cookie", "")).strip()
        if not cookie:
            return jsonify(error="尚未保存 115 Cookie，无法检测"), 400
        try:
            dirs = [node for node in list_115_nodes(cookie, 0) if node["is_dir"]]
            names = "、".join(node["name"] for node in dirs[:5])
            if not dirs:
                write_app_log("warning", "115", "check-login", "115 Cookie 有效但根目录没有读取到任何文件夹")
                return jsonify(ok=True, message="115 Cookie 有效，但根目录没有读取到任何文件夹——115 目标目录选择器将无数据。请确认该账号网盘根目录下存在文件夹，或重新扫码登录后再检测")
            write_app_log("success", "115", "check-login", f"115 Cookie 有效，根目录读取到 {len(dirs)} 个目录")
            return jsonify(ok=True, message=f"115 Cookie 有效，已登录（根目录：{names}...）")
        except Exception as error:
            write_app_log("error", "115", "check-login", "115 Cookie 登录检测失败", detail=str(error))
            return jsonify(ok=False, message=f"115 登录检测失败：{str(error)[:180]}")
    endpoint = str(settings.get("cloud115_endpoint", "")).strip()
    if not endpoint:
        return jsonify(error="尚未填写 115 中转服务地址，无法检测"), 400
    try:
        with request_with_proxy(endpoint, headers={"Accept": "application/json"}, method="GET", timeout=10) as response:
            status = response.status
        write_app_log("success", "115", "check-login", f"中转服务可达（HTTP {status}）", target=endpoint)
        return jsonify(ok=True, message=f"中转服务可达（HTTP {status}），登录状态由中转服务管理")
    except HTTPError as error:
        write_app_log("success", "115", "check-login", f"中转服务可达（HTTP {error.code}）", target=endpoint)
        return jsonify(ok=True, message=f"中转服务可达（HTTP {error.code}），登录状态由中转服务管理")
    except Exception as error:
        write_app_log("error", "115", "check-login", "无法连接中转服务", detail=str(error), target=endpoint)
        return jsonify(ok=False, message=f"无法连接中转服务：{str(error)[:180]}")


@app.get("/api/tasks")
def list_tasks():
    cover_map = build_catalog_cover_map()
    task_rows = rows("SELECT * FROM tasks ORDER BY created_at DESC")
    missing = []
    for item in task_rows:
        if not item.get("cover_path") and not item.get("cover_url") and item.get("detail_url"):
            missing.append(dict(item))
    if missing:
        threading.Thread(target=_fetch_missing_covers, args=(missing, "tasks"), daemon=True).start()
    return jsonify([task_payload(row, cover_map) for row in task_rows])


@app.get("/api/tasks/<task_id>/cover")
def task_cover(task_id):
    task = rows("SELECT cover_path FROM tasks WHERE id=?", (task_id,))
    if not task or not task[0]["cover_path"] or not Path(task[0]["cover_path"]).is_file():
        return Response(status=404)
    return send_file(task[0]["cover_path"])


@app.get("/api/tasks/<task_id>/play")
def task_play(task_id):
    task = rows("SELECT output_path FROM tasks WHERE id=?", (task_id,))
    if not task or not task[0]["output_path"]:
        return Response(status=404)
    media = media_file_in(task[0]["output_path"])
    if not media or not media.is_file():
        return Response(status=404)
    return send_file(media, conditional=True)


@app.get("/api/tasks/<task_id>/preview")
def task_preview(task_id):
    task = rows("SELECT * FROM tasks WHERE id=?", (task_id,))
    if not task:
        return jsonify(error="任务不存在"), 404
    item = task[0]
    try:
        metadata = json.loads(item["metadata_json"] or "{}")
    except ValueError:
        metadata = {}
    return jsonify(task=task_payload(item), metadata=metadata)


@app.post("/api/extract")
def extract_details():
    payload = request.get_json(force=True)
    try:
        return jsonify(extract_jable_details(str(payload.get("page_url", "")).strip()))
    except ValueError as error:
        return jsonify(error=str(error)), 400
    except Exception as error:
        return jsonify(error=f"影片信息获取失败：{error}"), 502


@app.route("/api/browser-metadata", methods=["POST", "OPTIONS"])
def browser_metadata():
    if request.method == "OPTIONS":
        response = Response(status=204)
    else:
        payload = request.get_json(force=True)
        try:
            page_url = str(payload.get("page_url", "")).strip()
            parsed = validate_jable_url(page_url)
            title = clean_jable_title(str(payload.get("title", "")))
            catalog = detect_catalog(str(payload.get("catalog", "")), parsed.path, title)
            media_url = str(payload.get("media_url", "")).strip()
            if media_url and urlparse(media_url).scheme not in ("http", "https"):
                media_url = ""
            if not title and not catalog:
                raise ValueError("浏览器页面中未找到标题或番号")
            metadata = {"page_url": page_url, "title": title or catalog, "catalog": catalog,
                        "media_url": media_url, "updated_at": time.time()}
            temporary = BROWSER_METADATA_PATH.with_suffix(".tmp")
            temporary.write_text(json.dumps(metadata, ensure_ascii=False), encoding="utf-8")
            temporary.replace(BROWSER_METADATA_PATH)
            response = jsonify(metadata)
        except ValueError as error:
            response = jsonify(error=str(error))
            response.status_code = 400
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type"
    response.headers["Access-Control-Allow-Methods"] = "POST, OPTIONS"
    return response


@app.get("/api/latest-browser-metadata")
def latest_browser_metadata():
    try:
        return jsonify(json.loads(BROWSER_METADATA_PATH.read_text(encoding="utf-8")))
    except (OSError, ValueError):
        return jsonify({})


@app.get("/jable-helper.user.js")
def jable_helper():
    endpoint = request.host_url.rstrip("/") + "/api/browser-metadata"
    connect_host = request.host.split(":", 1)[0]
    script = r'''// ==UserScript==
// @name         Jable 下载工具媒体同步
// @namespace    jable-tv-downloader
// @version      2.0.0
// @description  自动同步 Jable 影片标题、番号和页面捕获到的 M3U8
// @match        https://jable.tv/videos/*
// @match        https://*.jable.tv/videos/*
// @grant        GM_xmlhttpRequest
// @connect      __CONNECT_HOST__
// @run-at       document-start
// ==/UserScript==
(function () {
  'use strict';
  const endpoint = '__ENDPOINT__';
  let mediaURL = '';
  let lastSignature = '';
  function consider(url) {
    if (!url || !/^https?:/i.test(url)) return;
    if (/\.m3u8(?:$|\?)/i.test(url)) mediaURL = url;
    else if (!mediaURL && /\.(?:mpd|mp4)(?:$|\?)/i.test(url)) mediaURL = url;
  }
  function scan() { performance.getEntriesByType('resource').forEach(entry => consider(entry.name)); }
  try { new PerformanceObserver(list => list.getEntries().forEach(entry => consider(entry.name))).observe({type:'resource', buffered:true}); } catch (_) {}
  function readTitle() {
    const meta = document.querySelector('meta[property="og:title"]');
    const heading = document.querySelector('h4');
    return (meta?.content || heading?.textContent || document.title || '').replace(/\s*[-|–]\s*Jable(?:\.TV)?\s*$/i, '').replace(/\s+/g, ' ').trim();
  }
  function sync() {
    scan();
    const title = readTitle();
    const signature = location.href + '\n' + title + '\n' + mediaURL;
    if (!title || signature === lastSignature) return;
    lastSignature = signature;
    GM_xmlhttpRequest({method:'POST', url:endpoint, headers:{'Content-Type':'application/json'},
      data:JSON.stringify({page_url:location.href,title,media_url:mediaURL}), onerror:()=>{lastSignature='';}});
  }
  setInterval(sync, 2000);
  addEventListener('load', sync);
})();
'''.replace("__CONNECT_HOST__", connect_host).replace("__ENDPOINT__", endpoint)
    return Response(script, content_type="application/javascript; charset=utf-8")


def enqueue_download(payload):
    url = str(payload.get("url", "")).strip()
    if urlparse(url).scheme not in ("http", "https"):
        raise ValueError("请输入有效的 HTTP/HTTPS 媒体地址")
    settings = get_settings()
    title = safe_name(str(payload.get("title", "")), "自动标题")
    catalog = detect_catalog(str(payload.get("catalog", "")), title, url)
    allow_duplicate = bool(payload.get("allow_duplicate", settings["allow_duplicate"]))
    duplicate = find_duplicate(catalog) if not allow_duplicate else ""
    if duplicate:
        raise FileExistsError(f"检测到已经下载：{duplicate}")
    task_id = str(uuid.uuid4())
    values = {
        "id": task_id, "url": url, "title": title, "catalog": catalog,
        "performer": safe_name(str(payload.get("performer", "")), ""),
        "threads": min(32, max(1, int(payload.get("threads", settings["threads"])))),
        "extra_args": str(payload.get("extra_args", "")).strip(),
        "organize_enabled": int(payload.get("organize_enabled", settings["organize_enabled"])),
        "allow_duplicate": int(allow_duplicate)
    }
    with db_lock, connect() as db:
        db.execute("""INSERT INTO tasks(
            id,url,title,catalog,performer,threads,state,phase,progress,speed,size,output_path,
            metadata_found,log,created_at,started_at,finished_at,extra_args,organize_enabled,
            allow_duplicate,download_step,scrape_step,organize_step
        ) VALUES(?,?,?,?,?,?,'pending','等待执行',0,'-','-','',NULL,'任务已加入队列\n',?,NULL,NULL,?,?,?,'pending','pending','pending')""",
                   (values["id"], values["url"], values["title"], values["catalog"], values["performer"],
                    values["threads"], datetime.now().isoformat(timespec="microseconds"), values["extra_args"],
                    values["organize_enabled"], values["allow_duplicate"]))
    worker_wakeup.set()
    return task_id


@app.get("/api/jable/catalog")
def jable_catalog():
    try:
        force = request.args.get("refresh") == "1"
        page = int(request.args.get("page", "1") or "1")
        section = str(request.args.get("section", "latest") or "latest").strip()
        result = chromium_latest_catalog(page, force, section)
        write_app_log("info", "jable", "catalog", f"影片浏览加载完成：{section} 第 {page} 页，共 {len(result.get('items', []))} 部",
                      target=section)
        if "page" not in request.args:
            return jsonify(result["items"])
        return jsonify(result)
    except Exception as error:
        write_app_log("error", "jable", "catalog", "影片浏览加载失败", detail=str(error))
        return jsonify(error=str(error)), 502


@app.get("/api/jable/detail")
def jable_detail():
    try:
        detail_url = str(request.args.get("detail_url", "")).strip()
        force = request.args.get("refresh") == "1"
        duration = str(request.args.get("duration", "")).strip()
        detail = chromium_jable_detail(detail_url, force)
        # 模式 A：浏览触发——详情拿到磁力后，后台线程按规则自动离线（不阻塞响应）
        if detail and not detail.get("error") and detail.get("magnets"):
            threading.Thread(
                target=auto_offline_evaluate,
                kwargs=dict(
                    catalog=detail.get("catalog"), title=detail.get("title"),
                    detail_url=detail.get("detail_url") or detail_url,
                    duration_text=duration, magnets=detail.get("magnets"), mode="browse",
                ), daemon=True,
            ).start()
        write_app_log("info", "jable", "detail", f"详情抓取完成：{detail.get('catalog') or detail_url}",
                      target=detail_url)
        return jsonify(detail)
    except ValueError as error:
        return jsonify(error=str(error)), 400
    except Exception as error:
        write_app_log("error", "jable", "detail", "详情抓取失败", detail=str(error), target=request.args.get("detail_url", ""))
        return jsonify(error=f"详情抓取失败：{error}"), 502


@app.post("/api/jable/auto-task")
def jable_auto_task():
    payload = request.get_json(force=True)
    try:
        captured = chromium_capture_video(str(payload.get("detail_url", "")).strip())
        task_id = enqueue_download({
            "url": captured["media_url"], "title": captured["title"], "catalog": captured["catalog"],
            "threads": payload.get("threads", get_settings()["threads"]),
            "organize_enabled": payload.get("organize_enabled", True),
            "allow_duplicate": payload.get("allow_duplicate", False)
        })
        write_app_log("success", "jable", "auto-task", f"已创建本地下载任务：{captured['catalog']}",
                      task_id=task_id, target=captured.get("detail_url", ""))
        return jsonify(id=task_id, **captured), 201
    except ValueError as error:
        return jsonify(error=str(error)), 400
    except FileExistsError as error:
        return jsonify(error=str(error)), 409
    except Exception as error:
        write_app_log("error", "jable", "auto-task", "自动获取失败", detail=str(error), target=str(payload.get("detail_url", "")))
        return jsonify(error=f"自动获取失败：{error}"), 502


@app.post("/api/jable/capture")
def jable_capture():
    payload = request.get_json(force=True)
    try:
        result = chromium_capture_video(str(payload.get("detail_url", "")).strip())
        write_app_log("success", "jable", "capture", f"媒体地址抓取完成：{result.get('catalog')}", target=result.get("detail_url", ""))
        return jsonify(result)
    except ValueError as error:
        return jsonify(error=str(error)), 400
    except Exception as error:
        write_app_log("error", "jable", "capture", "媒体抓取失败", detail=str(error), target=str(payload.get("detail_url", "")))
        return jsonify(error=f"媒体抓取失败：{error}"), 502


@app.post("/api/jable/auto-cloud-task")
def jable_auto_cloud_task():
    payload = request.get_json(force=True)
    try:
        detail_url = str(payload.get("detail_url", "")).strip()
        # 磁力优先：115 离线磁力成功率高，且无需启动 Chromium 抓 m3u8（快）
        detail = chromium_jable_detail(detail_url)
        title = safe_name(str(payload.get("title") or detail["title"]), detail["catalog"] or "未命名影片")
        catalog = detect_catalog(str(payload.get("catalog", "")), detail["catalog"], title)
        magnets = [m for m in detail.get("magnets", []) if str(m.get("url", "")).startswith("magnet:")]
        if magnets:
            source_url = str(magnets[0]["url"])
        else:
            # 无磁力回退：抓取 m3u8 直链离线
            captured = chromium_capture_video(detail_url)
            source_url = captured["media_url"]
        # 提交时直接指定 115 目标目录（离线产物直接落位，无需完成后转移）
        settings = get_settings()
        dest_cid = str(settings.get("cloud_transfer_cid", "") or "").strip() \
            if settings.get("cloud_transfer_enabled") else ""
        task_id = str(uuid.uuid4())
        reply = submit_115_task(task_id, source_url, title, catalog, detail_url, dest_cid=dest_cid)
        result = create_cloud_record(task_id, source_url, title, catalog, detail_url, reply, dest_cid=dest_cid)
        write_app_log("success", "115", "auto-cloud-task", f"已提交 115 离线：{catalog}", task_id=task_id, target=detail_url)
        return jsonify(**result, media_url=source_url), 201
    except ValueError as error:
        return jsonify(error=str(error)), 400
    except Exception as error:
        write_app_log("error", "115", "auto-cloud-task", "抓取并提交 115 失败", detail=str(error), target=str(payload.get("detail_url", "")))
        return jsonify(error=f"抓取并提交 115 失败：{str(error)[:180]}"), 502


@app.post("/api/tasks")
def create_task():
    try:
        task_id = enqueue_download(request.get_json(force=True))
    except ValueError as error:
        return jsonify(error=str(error)), 400
    except FileExistsError as error:
        return jsonify(error=str(error)), 409
    write_app_log("success", "task", "create", "已创建下载任务", task_id=task_id, target=task_id)
    return jsonify(id=task_id), 201


@app.get("/api/cloud-tasks")
def list_cloud_tasks():
    result = rows(
        "SELECT c.*, s.id AS strm_id FROM cloud_tasks c "
        "LEFT JOIN strm_items s ON s.cloud_task_id = c.id ORDER BY c.created_at DESC"
    )
    cover_map = build_catalog_cover_map()
    missing = []
    for item in result:
        if not item.get("cover_url"):
            item["cover_url"] = catalog_poster_url(item.get("catalog"), cover_map)
            if not item["cover_url"] and item.get("detail_url"):
                missing.append(dict(item))
    if missing:
        # 重启后 detail_cache 清空导致封面缺失时，后台补抓并持久化
        threading.Thread(target=_fetch_missing_covers, args=(missing,), daemon=True).start()
    return result


@app.delete("/api/cloud-tasks/<task_id>")
def delete_cloud_task(task_id):
    with db_lock, connect() as db:
        cursor = db.execute("DELETE FROM cloud_tasks WHERE id=?", (task_id,))
        if cursor.rowcount == 0:
            return jsonify(error="任务不存在"), 404
    write_app_log("warning", "115", "delete-cloud-task", "已删除 115 离线任务记录", task_id=task_id, target=task_id)
    return jsonify(ok=True)


def cache_remote_image(url, force=False):
    """下载外部图片到磁盘缓存，返回缓存文件路径；失败返回 None。

    依次尝试「带代理 → 不带代理」×「站点 Referer → 图床根 Referer」，提高弱网/防盗图下的成功率；
    失败写 60 秒负缓存，避免页面反复渲染时反复回源。
    """
    import hashlib
    import urllib.request
    cache_dir = Path("/tmp/img-cache")
    cache_dir.mkdir(parents=True, exist_ok=True)
    digest = hashlib.md5(url.encode()).hexdigest()
    cache_file = cache_dir / f"{digest}.jpg"
    fail_file = cache_dir / f"{digest}.fail"
    if not force and cache_file.exists() and cache_file.stat().st_size > 0:
        return cache_file
    if not force and fail_file.exists() and time.time() - fail_file.stat().st_mtime < 60:
        return None
    settings = get_settings()
    proxy = settings.get("proxy") or None
    host_root = "/".join(url.split("/", 3)[:3])
    referers = [HG_SITE + "/"] if "huangguo" in url else []
    referers.append(host_root + "/")
    handlers = []
    if proxy:
        handlers.append(ProxyHandler({"http": proxy, "https": proxy}))
    handlers.append(ProxyHandler({}))  # 直连兜底：代理对个别图床反而不通
    for handler in handlers:
        for referer in referers:
            try:
                opener = build_opener(handler)
                headers = [("User-Agent", HG_UA)]
                if referer:
                    headers.append(("Referer", referer))
                opener.addheaders = headers
                req = Request(url)
                resp = opener.open(req, timeout=15)
                data = _maybe_decrypt_hg_image(resp.read())
                if data and len(data) > 100 and _image_signature(data):
                    cache_file.write_bytes(data)
                    fail_file.unlink(missing_ok=True)
                    return cache_file
            except Exception:
                continue
    try:
        fail_file.write_text(str(time.time()), encoding="utf-8")
    except Exception:
        pass
    return None


def _image_signature(data):
    if data.startswith(b"\xff\xd8"):
        return "jpg"
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if data.startswith(b"RIFF") and data[8:12] == b"WEBP":
        return "webp"
    if data.startswith((b"GIF87a", b"GIF89a")):
        return "gif"
    return ""


def _trim_image_payload(data):
    sig = _image_signature(data)
    if sig == "jpg":
        end = data.rfind(b"\xff\xd9")
        return data[:end + 2] if end >= 0 else data
    if sig == "png":
        end = data.rfind(b"IEND\xaeB`\x82")
        return data[:end + 8] if end >= 0 else data
    return data


def _maybe_decrypt_hg_image(data):
    """黄果封面是 AES-128-CBC 字节；非黄果或已是图片时原样返回。

    个别响应长度不是 16 的倍数（尾部被截断/附加字节），裁齐后再试一次。
    """
    if not data or _image_signature(data):
        return data
    candidates = [data]
    if len(data) % 16 != 0:
        candidates.append(data[:len(data) - (len(data) % 16)])
    for candidate in candidates:
        if len(candidate) % 16 != 0:
            continue
        try:
            from Crypto.Cipher import AES
            cipher = AES.new(b"f5d965df75336270", AES.MODE_CBC, b"97b60394abc2fbe1")
            plain = cipher.decrypt(candidate)
            sig = _image_signature(plain)
            if not sig:
                continue
            pad = plain[-1]
            if 1 <= pad <= 16 and plain.endswith(bytes([pad]) * pad):
                plain = plain[:-pad]
            return _trim_image_payload(plain)
        except Exception:
            continue
    return data


@app.get("/api/proxy-image")
def proxy_image():
    """代理外部图片（jable CDN 等被墙资源），带磁盘缓存避免重复下载。

    带 retry=1 时跳过缓存/负缓存强制回源（前端图片加载失败后的自动重试）。
    """
    url = request.args.get("url", "").strip()
    if not url or not url.startswith(("http://", "https://")):
        return "", 400
    force = request.args.get("retry", "") in {"1", "true"}
    cache_file = cache_remote_image(url, force=force)
    if cache_file:
        return send_file(cache_file, mimetype="image/jpeg")
    return "", 502


@app.get("/api/strm-library")
def strm_library():
    """115 媒体库：合并 strm_items 和已完成的 cloud_tasks（有 pickcode 的）。
    即使未开启管线D，完成的云下载也会显示在此。"""
    # strm_items 表中的条目（管线D 入库的）
    strm_rows = rows("SELECT * FROM strm_items ORDER BY created_at DESC")
    strm_ids = {r["id"] for r in strm_rows}
    # 已完成的 cloud_tasks（有 pickcode），但不在 strm_items 中的
    cloud_rows = rows("SELECT * FROM cloud_tasks WHERE state='completed' AND pickcode != '' ORDER BY finished_at DESC")
    # 封面回填源：本地任务、列表浏览缓存、详情页缓存（按番号匹配）
    cover_map = build_catalog_cover_map()
    missing = []
    for ct in cloud_rows:
        if ct["id"] in strm_ids:
            continue
        catalog_key = str(ct.get("catalog", "")).upper()
        # 封面优先级：cloud_tasks 持久封面 → 本地任务/列表缓存 → 详情页缓存
        cover = str(ct.get("cover_url", "") or "") or cover_map.get(catalog_key, "")
        if not cover:
            missing.append(ct)
        # 补充为 strm_items 兼容格式
        strm_rows.append({
            "id": ct["id"],
            "cloud_task_id": ct["id"],
            "catalog": ct.get("catalog", ""),
            "title": ct["title"],
            "strm_path": "",
            "poster_path": "",
            "pickcode": ct.get("pickcode", ""),
            "file_path": ct.get("file_path", ""),
            "size": 0,
            "cover_url": cover,
            "created_at": ct.get("finished_at") or ct.get("created_at", ""),
        })
    if missing:
        # 缺封面的条目交给后台线程补抓（不阻塞响应，抓到后持久化到 cloud_tasks.cover_url）
        threading.Thread(target=_fetch_missing_covers, args=([dict(ct) for ct in missing],), daemon=True).start()
    return jsonify(strm_rows)


_COVER_FETCH_LOCK = threading.Lock()


def _fetch_missing_covers(items, table="cloud_tasks"):
    """后台补抓缺失封面：抓详情页 og:image，成功后持久化到 cover_url 列。"""
    if not _COVER_FETCH_LOCK.acquire(blocking=False):
        return  # 已有线程在补抓，避免重复
    try:
        for item in items:
            detail_url = item.get("detail_url", "")
            if not detail_url:
                continue
            try:
                detail = chromium_jable_detail(detail_url)
                cover = str(detail.get("cover_url", "") or "")
            except Exception:
                continue
            if cover:
                with db_lock, connect() as db:
                    db.execute(f"UPDATE {table} SET cover_url=? WHERE id=?", (cover, item["id"]))
                try:
                    cache_remote_image(cover)  # 顺手预热图片缓存，页面打开秒出图
                except Exception:
                    pass
                time.sleep(1)
    finally:
        _COVER_FETCH_LOCK.release()


@app.get("/api/strm-library/<item_id>/poster")
def strm_library_poster(item_id):
    item = row("SELECT * FROM strm_items WHERE id=?", (item_id,))
    if item and item.get("poster_path") and Path(item["poster_path"]).exists():
        return send_file(item["poster_path"], mimetype="image/jpeg")
    return "", 404


@app.delete("/api/strm-library/<item_id>")
def strm_library_delete(item_id):
    """删除媒体库条目：同时清理本地 strm 目录与任务记录。"""
    item = row("SELECT * FROM strm_items WHERE id=?", (item_id,))
    if not item:
        return jsonify(error="条目不存在"), 404
    strm_path = Path(item["strm_path"]) if item.get("strm_path") else None
    if strm_path and strm_path.exists():
        shutil.rmtree(strm_path.parent, ignore_errors=True)
    with db_lock, connect() as db:
        db.execute("DELETE FROM strm_items WHERE id=?", (item_id,))
        db.execute("DELETE FROM cloud_tasks WHERE id=?", (item_id,))
    write_app_log("warning", "strm", "delete", f"媒体库条目已删除：{item.get('catalog') or item.get('title')}",
                  task_id=item_id, target=item.get("strm_path", ""))
    return jsonify(ok=True)


def _strm_diag_probe_base_url(base_url):
    """容器内自检服务访问地址是否可达（直连，不走代理）。"""
    try:
        req = Request(base_url.rstrip("/") + "/api/health", headers={"User-Agent": "nassav-strm-diag"})
        with urlopen(req, timeout=6) as resp:
            return resp.status == 200, f"HTTP {resp.status}"
    except Exception as error:
        return False, str(error)[:160]


@app.get("/api/strm/diagnose")
def strm_diagnose():
    """管线 D 自检：逐项检查「115 离线完成 → 生成 strm → 刮削入库」链路，定位未刮削/未入库的原因。

    deep=1 时额外用最近一个可识别番号的任务实测刮削源（耗时较长）。
    """
    deep = request.args.get("deep", "") in {"1", "true"}
    settings = get_settings()
    checks = []

    def add_check(key, ok, title, detail="", hint="", warn=False):
        checks.append({"key": key, "level": "ok" if ok else ("warn" if warn else "error"),
                       "title": title, "detail": detail, "hint": hint})

    # 1. 管线 D 开关
    enabled = bool(settings.get("auto_strm_enabled"))
    add_check("enabled", enabled, "管线 D 开关（离线完成后自动生成 strm 并刮削）",
              "已开启" if enabled else "当前未开启",
              "" if enabled else "到「服务设置 → 路径配置 → 管线 D」打开开关并点右上角「保存设置」")

    # 2. 服务访问地址 + 容器内可达性
    base_url = str(settings.get("service_base_url", "") or "").strip().rstrip("/")
    if not base_url:
        probe_ok, probe_detail = False, "未配置"
        add_check("base_url", False, "服务访问地址（写入 strm 文件的地址）", "未配置",
                  "管线 D 会因地址为空直接跳过生成；请在「路径配置 → 管线 D」填写，例如 http://192.168.2.50:8788")
    else:
        probe_ok, probe_detail = _strm_diag_probe_base_url(base_url)
        add_check("base_url_reachable", probe_ok, f"服务访问地址自检：{base_url}", probe_detail,
                  "" if probe_ok else "容器内访问不到该地址。常见原因：地址或端口写错、误填 127.0.0.1（应填 NAS 局域网 IP）、防火墙拦截。地址不可达时 strm 生成不受影响，但播放器打开 strm 会失败",
                  warn=True)

    # 3. /strm 目录可写
    strm_writable, strm_detail = False, ""
    try:
        strm_root = Path("/strm")
        strm_root.mkdir(parents=True, exist_ok=True)
        probe_file = strm_root / ".diagnose-probe"
        probe_file.write_text("ok", encoding="utf-8")
        probe_file.unlink()
        strm_writable = True
    except Exception as error:
        strm_detail = str(error)[:160]
    add_check("strm_dir", strm_writable, "strm 目录可写（容器内 /strm）",
              "可写" if strm_writable else f"写入失败：{strm_detail}",
              "" if strm_writable else "检查 compose 是否挂载了 strm 目录以及宿主机目录权限")

    # 4. 刮削源与代理
    sources = enabled_sources()
    add_check("sources", bool(sources), "已启用刮削源",
              "、".join(sources) if sources else "未启用任何刮削源",
              "" if sources else "请在「服务设置」里启用至少一个刮削源，否则只生成 strm 不刮削封面/nfo")
    proxy = str(settings.get("proxy", "") or "").strip()
    add_check("proxy", bool(proxy), "刮削代理",
              proxy or "未配置（刮削源多在墙外，无代理时可能连不上，表现为封面/nfo 缺失）",
              "" if proxy else "建议在「网络代理」页签配置代理并点「检测连通」", warn=True)

    # 5. 番号识别率
    completed = rows("SELECT * FROM cloud_tasks WHERE state='completed' AND pickcode!='' ORDER BY finished_at DESC LIMIT 200")
    recognized, unrecognized = [], []
    for ct in completed:
        catalog = detect_catalog(str(ct.get("catalog", "")), str(ct.get("title", "")))
        (recognized if catalog else unrecognized).append(ct)
    add_check("detect", bool(recognized) if completed else True,
              f"番号识别：最近 {len(completed)} 个已完成的 115 离线任务，{len(recognized)} 个可识别番号",
              ("；".join(f"《{ct['title'][:36]}》" for ct in unrecognized[:5]) + ("…" if len(unrecognized) > 5 else "")) if unrecognized else "全部可识别",
              "标题里没有「字母+数字」番号时管线 D 会主动跳过（预期行为）；提交离线时尽量用带番号的磁力/文件名" if unrecognized else "")

    # 6. 入库覆盖率：已完成任务中有多少已生成 strm
    strm_ids = {r["cloud_task_id"] for r in rows("SELECT cloud_task_id FROM strm_items")}
    missing = [ct for ct in completed if ct["id"] not in strm_ids]
    add_check("coverage", (not missing) or (not enabled),
              f"入库覆盖：{len(completed) - len(missing)}/{len(completed)} 个已完成任务已生成 strm 入库",
              ("；".join(f"《{ct['title'][:36]}》" for ct in missing[:5]) + ("…" if len(missing) > 5 else "")) if missing else "全部已入库",
              "以下任务完成时管线 D 未生效（当时未开启/地址未配置/番号未识别），修复配置后可点「一键补跑未入库任务」" if missing else "")

    # 7. 最近 strm 日志
    recent_logs = rows("SELECT created_at,level,message FROM app_logs WHERE module='strm' ORDER BY id DESC LIMIT 10")

    # 8. 深度实测：真实跑一次刮削
    deep_result = None
    if deep:
        deep_result = {"catalog": "", "attempts": []}
        if not sources:
            deep_result["attempts"].append({"source": "-", "ok": False, "detail": "未启用任何刮削源"})
        elif not recognized:
            deep_result["attempts"].append({"source": "-", "ok": False, "detail": "最近任务中没有可识别番号的，无法实测"})
        else:
            target = recognized[0]
            catalog = safe_name(detect_catalog(str(target.get("catalog", "")), str(target.get("title", ""))), "untitled")
            deep_result["catalog"] = catalog
            test_root = Path("/tmp/strm-diagnose")
            for source in sources[:3]:
                started = time.time()
                try:
                    scraper = Sracper(str(test_root), proxy or None, timeout=10)
                    scraper.domain = source
                    metadata = scraper.scrape(catalog)
                    if metadata:
                        deep_result["attempts"].append({
                            "source": source, "ok": True,
                            "detail": f"命中《{(getattr(metadata, 'title', '') or catalog)[:40]}》· {time.time() - started:.1f}s"})
                        break
                    deep_result["attempts"].append({"source": source, "ok": False,
                                                    "detail": f"未命中 · {time.time() - started:.1f}s"})
                except Exception as error:
                    deep_result["attempts"].append({"source": source, "ok": False,
                                                    "detail": f"{str(error)[:120]} · {time.time() - started:.1f}s"})
            shutil.rmtree(test_root, ignore_errors=True)

    passed = sum(1 for c in checks if c["level"] == "ok")
    write_app_log("info", "strm", "diagnose",
                  f"管线 D 自检：{passed}/{len(checks)} 项通过" + ("（含深度刮削实测）" if deep else ""))
    return jsonify(
        checks=checks,
        stats={"enabled": enabled, "base_url": base_url, "base_url_reachable": probe_ok,
               "completed": len(completed), "recognized": len(recognized),
               "missing": len(missing), "strm_items": len(strm_ids)},
        missing_tasks=[{"id": ct["id"], "title": ct["title"], "finished_at": ct.get("finished_at", "")} for ct in missing[:50]],
        recent_logs=recent_logs,
        deep=deep_result)


@app.post("/api/strm/diagnose/repair")
def strm_diagnose_repair():
    """管线 D 一键补跑：为已完成但未入库的 115 离线任务重新生成 strm 并刮削。"""
    settings = get_settings()
    if not settings.get("auto_strm_enabled"):
        return jsonify(ok=False, error="请先开启管线 D 开关并保存设置"), 400
    if not str(settings.get("service_base_url", "") or "").strip():
        return jsonify(ok=False, error="请先配置服务访问地址并保存设置"), 400
    completed = rows("SELECT * FROM cloud_tasks WHERE state='completed' AND pickcode!='' ORDER BY finished_at DESC LIMIT 200")
    strm_ids = {r["cloud_task_id"] for r in rows("SELECT cloud_task_id FROM strm_items")}
    repaired, skipped = [], []
    for ct in completed:
        if ct["id"] in strm_ids:
            continue
        catalog = detect_catalog(str(ct.get("catalog", "")), str(ct.get("title", "")))
        if not catalog:
            skipped.append({"id": ct["id"], "title": ct["title"], "reason": "无法识别番号"})
            continue
        try:
            if generate_strm_item(dict(ct), ct.get("pickcode", ""), ct.get("file_path", ""), int(ct.get("size") or 0)):
                repaired.append({"id": ct["id"], "title": ct["title"]})
            else:
                skipped.append({"id": ct["id"], "title": ct["title"], "reason": "生成返回空，请看日志中心"})
        except Exception as error:
            skipped.append({"id": ct["id"], "title": ct["title"], "reason": str(error)[:120]})
    write_app_log("success" if repaired else "warning", "strm", "repair",
                  f"管线 D 补跑完成：新入库 {len(repaired)} 个，跳过 {len(skipped)} 个")
    return jsonify(ok=True, repaired=repaired, skipped=skipped)


@app.get("/api/115/stream/<item_id>")
def stream_115_item(item_id):
    """strm 播放端点（代理流式模式，同 /api/115/play/<pickcode>）。"""
    item = row("SELECT * FROM strm_items WHERE id=?", (item_id,))
    if not item or not item.get("pickcode"):
        write_app_log("error", "media", "play-strm", "strm 播放失败：条目不存在或缺少 pickcode",
                      target=item_id, detail=str(item.get("title", ""))[:80] if item else "")
        return jsonify(error="媒体条目不存在或无可播放文件"), 404
    ua = request.headers.get("User-Agent", "") or None
    url, error, is_large = _resolve_115_direct_url(item["pickcode"], ua=ua)
    if url:
        write_app_log("info", "media", "play-strm", f"开始播放 strm：{item['title'][:60]}",
                      target=item_id, detail=f"pickcode={item['pickcode']} ua={str(ua)[:40]}")
        # 302 直连模式：浏览器直连 115 CDN，不经后端转发
        if _play_mode_redirect():
            return redirect(url, 302)
        return _proxy_stream_115(url, ua=ua)
    write_app_log("error", "media", "play-strm", f"strm 播放失败：{error or '获取直链失败'}",
                  target=item_id, detail=f"{item['title'][:60]} pickcode={item['pickcode']} large={is_large}")
    if is_large:
        return "<html><body style='font-family:PingFang SC,sans-serif;padding:60px 40px;background:#f4f8ff'><h2 style='color:#d4380d'>⚠ 大文件无法直接播放</h2><p>115 Web 端对大文件（约 1GB 以上）有下载限制，请使用 115 电脑端下载后本地播放。</p></body></html>", 400
    return jsonify(error=error or "获取直链失败"), 502


def _openapi_request(method, url, body=None, headers=None, cookie=None, timeout=20, add_default_ua=True):
    """通用 HTTP 请求，返回 JSON。body 可以是 dict 或 bytes。

    add_default_ua=False 时完全不发 User-Agent header（p115client 某些端点要求这样）。
    """
    import hashlib
    hdrs = {}
    if cookie:
        hdrs["Cookie"] = cookie
    if headers:
        hdrs.update(headers)
    if add_default_ua:
        # 只在调用方没指定 UA 时才加默认值
        has_ua = any(k.lower() == "user-agent" for k in hdrs)
        if not has_ua:
            hdrs["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36"
    if isinstance(body, dict):
        body = urlencode(body).encode()
        hdrs.setdefault("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
    req = Request(url, data=body, headers=hdrs, method=method)
    try:
        with urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
    except HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:
            return json.loads(raw or "{}")
        except Exception:
            raise RuntimeError(f"HTTP {e.code}: {raw[:200]}")
    try:
        return json.loads(raw or "{}")
    except Exception:
        raise RuntimeError(f"非 JSON 响应: {raw[:200]}")


_115_OPENAPI_CACHE = {"access": None, "refresh": None, "expires_at": 0}


def _load_openapi_cache():
    try:
        conn = sqlite3.connect(DB_PATH)
        row = conn.execute(
            "SELECT value FROM settings WHERE key='cloud115_openapi_tokens'"
        ).fetchone()
        conn.close()
        if row and row[0]:
            return json.loads(row[0])
    except Exception:
        pass
    return {}


def _save_openapi_cache(access, refresh, expires_at=None):
    # 解析 115 OpenAPI 返回的真实过期时间；默认保守按 1 小时处理（115 access_token 实际有效期为 1~2 小时）
    if expires_at is None:
        expires_at = time.time() + 3600
    try:
        conn = sqlite3.connect(DB_PATH)
        conn.execute(
            "INSERT OR REPLACE INTO settings(key, value) VALUES(?, ?)",
            ("cloud115_openapi_tokens",
             json.dumps({"access": access, "refresh": refresh, "expires_at": expires_at}))
        )
        conn.commit()
        conn.close()
    except Exception:
        pass
    _115_OPENAPI_CACHE.update({"access": access, "refresh": refresh, "expires_at": expires_at})


def _clear_openapi_cache():
    """清空 OpenAPI token 缓存（强制下次重新登录）。"""
    _115_OPENAPI_CACHE.update({"access": None, "refresh": None, "expires_at": 0})
    try:
        conn = sqlite3.connect(DB_PATH)
        conn.execute(
            "INSERT OR REPLACE INTO settings(key, value) VALUES(?, ?)",
            ("cloud115_openapi_tokens", json.dumps({"access": "", "refresh": "", "expires_at": 0}))
        )
        conn.commit()
        conn.close()
    except Exception:
        pass


def _extract_openapi_expiry(data):
    """从 115 OpenAPI token 响应中提取过期时间戳（秒）。"""
    if not isinstance(data, dict):
        return None
    # 优先用 expires_at（已是时间戳）
    ea = data.get("expires_at")
    if isinstance(ea, (int, float)) and ea > 0:
        # 兼容毫秒时间戳
        if ea > 1e12:
            ea = ea / 1000
        return float(ea)
    # 其次用 expires_in（相对秒数）
    ei = data.get("expires_in")
    if isinstance(ei, (int, float)) and ei > 0:
        return time.time() + float(ei)
    return None


def _get_115_openapi_token(cookie):
    """用 cookie 自动获取 115 OpenAPI access_token（参考 p115client.login_with_open）。

    流程：
    1. POST /open/authDeviceCode (不需要 cookie) → 拿到 device_code (uid)
    2. GET /api/2.0/prompt.php?uid=xxx (需要 cookie) → "扫描"二维码
    3. GET /api/2.0/slogin.php?key=xxx&uid=xxx (需要 cookie) → 确认扫码
    4. POST /open/deviceCodeToToken (不需要 cookie) → 换 access_token
    """
    cache = _load_openapi_cache()
    access = cache.get("access") or _115_OPENAPI_CACHE.get("access")
    refresh = cache.get("refresh") or _115_OPENAPI_CACHE.get("refresh")
    expires_at = float(cache.get("expires_at") or _115_OPENAPI_CACHE.get("expires_at") or 0)

    if access and time.time() < expires_at - 60:
        _115_OPENAPI_CACHE.update({"access": access, "refresh": refresh, "expires_at": expires_at})
        return access

    if refresh:
        try:
            resp = _openapi_request(
                "POST", "https://qrcodeapi.115.com/open/refreshToken",
                body={"refresh_token": refresh},
            )
            if resp.get("state") in (True, 1) and resp.get("data", {}).get("access_token"):
                data = resp["data"]
                real_expiry = _extract_openapi_expiry(data) or (time.time() + 3600)
                _save_openapi_cache(data["access_token"], data.get("refresh_token", refresh), expires_at=real_expiry)
                return data["access_token"]
        except Exception:
            pass

    # === 从 app_id 开始全新登录 ===
    APP_ID = 100195125

    # Step 1: 获取 device code（PKCE, code_challenge = b64(md5("0"*64))）
    import base64 as _b64, hashlib as _hlib
    _verifier = b"0" * 64
    _challenge = _b64.b64encode(_hlib.md5(_verifier).digest()).decode()
    resp = _openapi_request(
        "POST", "https://qrcodeapi.115.com/open/authDeviceCode",
        body={
            "client_id": APP_ID,
            "code_challenge": _challenge,
            "code_challenge_method": "md5",
        },
    )
    if resp.get("state") not in (True, 1) or not resp.get("data"):
        raise RuntimeError(f"authDeviceCode 失败: {resp}")
    login_uid = resp["data"]["uid"]

    # Step 2: 用 cookie "扫描"（prompt.php）
    resp = _openapi_request(
        "GET", f"https://qrcodeapi.115.com/api/2.0/prompt.php?uid={login_uid}",
        cookie=cookie,
    )
    if resp.get("state") not in (True, 1):
        msg = resp.get("message") or resp.get("error") or resp
        raise RuntimeError(f"扫码失败（cookie 可能过期）: {msg}")

    # Step 3: 确认扫码（slogin.php, key == uid）
    resp = _openapi_request(
        "GET", f"https://qrcodeapi.115.com/api/2.0/slogin.php?key={login_uid}&uid={login_uid}",
        cookie=cookie,
    )
    if resp.get("state") not in (True, 1):
        msg = resp.get("message") or resp.get("error") or resp
        raise RuntimeError(f"确认扫码失败: {msg}")

    # Step 4: 换 access_token
    resp = _openapi_request(
        "POST", "https://qrcodeapi.115.com/open/deviceCodeToToken",
        body={"uid": login_uid, "code_verifier": "0" * 64},
    )
    if resp.get("state") not in (True, 1) or not resp.get("data"):
        raise RuntimeError(f"换 token 失败: {resp}")
    data = resp["data"]
    if not data.get("access_token"):
        raise RuntimeError(f"token 返回为空: {resp}")

    real_expiry = _extract_openapi_expiry(data) or (time.time() + 3600)
    _save_openapi_cache(data["access_token"], data.get("refresh_token", ""), expires_at=real_expiry)
    return data["access_token"]


def _115_openapi_downurl(pickcode, cookie, ua=None):
    """用 115 OpenAPI 获取直链，能绕过 webapi 大文件限制（msg_code 50028）。

    关键（2026-09 起策略）：CDN 直链一律 f=1（UA 签名校验），绑定的是**取链请求的
    User-Agent**。必须把播放器 UA 原样传入，浏览器/播放器用同一 UA 访问才能通过校验。
    （旧行为：不带 UA 请求可得到宽松链，现已失效——不带 UA 取的链只允许无 UA 访问。）
    """
    for _attempt in range(2):
        token = _get_115_openapi_token(cookie)
        headers = {"Authorization": f"Bearer {token}"}
        if ua:
            # UA 绑定：取链时的 UA = 播放器访问 CDN 时的 UA，签名校验才能通过
            headers["User-Agent"] = ua
        resp = _openapi_request(
            "POST", "https://proapi.115.com/open/ufile/downurl",
            body={"pick_code": pickcode},
            headers=headers,
            add_default_ua=False,
        )
        if resp.get("state") in (True, 1, "1", "true"):
            break
        # 鉴权类错误：清掉缓存，重新走完整登录流程，再试一次
        err_msg = str(resp.get("message") or resp.get("error") or "")
        err_low = err_msg.lower()
        is_auth_err = (
            "access_token" in err_msg and ("无效" in err_msg or "invalid" in err_low)
        ) or "no auth" in err_low or "990001" in err_msg or "未授权" in err_msg or "登录超时" in err_msg
        if is_auth_err and _attempt == 0:
            _clear_openapi_cache()
            continue
        raise RuntimeError(f"OpenAPI 失败: {err_msg or resp}")
    data = resp.get("data") or {}
    if isinstance(data, list):
        data = data[0] if data else {}
    if not isinstance(data, dict) or not data:
        raise RuntimeError(f"OpenAPI data 格式异常: {type(data).__name__}")
    first_key = next(iter(data.keys()), None)
    if not first_key:
        raise RuntimeError("OpenAPI 返回空数据")
    file_info = data[first_key]
    url_obj = file_info.get("url") or {}
    if isinstance(url_obj, dict):
        return url_obj.get("url", "") or ""
    return str(url_obj or "")


def _resolve_115_direct_url(pickcode, ua=None):
    """内部工具：用 pickcode 换取 115 直链。返回 (url, error_msg, is_large_file)。

    优先走 webapi（快），大文件失败时降级走 OpenAPI downurl（绕过 50028）。
    注意：直链带 UA 签名（f=1，绑定取链请求的 UA），调用方必须用同一 ua 访问 CDN。
    """
    settings = get_settings()
    cookie = str(settings.get("cloud115_cookie", "")).strip()
    if not cookie:
        return None, "尚未配置 115 Cookie，无法播放", False
    if not pickcode or len(pickcode) < 4:
        return None, "pickcode 无效", False

    cookie_expired = False
    try:
        reply = _115_request(cookie, f"https://webapi.115.com/files/download?pickcode={pickcode}", ua=ua)
        url = str(reply.get("url", "") or "")
        if url:
            return url, None, False
    except Exception as error:
        msg = str(error)[:200]
        if "登录超时" in msg or "990001" in msg or "cookie" in msg.lower():
            cookie_expired = True
        elif "文件大小超出限制" in msg or "50028" in msg:
            pass  # 大文件，继续走 OpenAPI
        else:
            return None, f"获取 115 直链失败：{msg}", False

    if cookie_expired:
        return None, "115 登录已过期，请重新登录后重试", False

    # 降级走 OpenAPI（支持大文件）
    try:
        url = _115_openapi_downurl(pickcode, cookie, ua=ua)
        if url:
            return url, None, False
    except Exception as openapi_err:
        err_msg = str(openapi_err)[:200]
        if "登录超时" in err_msg or "990001" in err_msg or "过期" in err_msg or "cookie" in err_msg.lower():
            return None, "115 登录已过期，请重新登录后重试", False
        return None, f"大文件获取失败：{err_msg}", True
    return None, "获取 115 直链失败", False


@app.get("/api/115/resolve/<pickcode>")
def resolve_115_direct_url(pickcode):
    """返回直链 JSON（供前端 AJAX 调用，能友好处理大文件限制等场景）。
    走统一缓存入口：与 /api/115/play 共享缓存，失败结果也短缓存。"""
    ua = request.headers.get("User-Agent", "") or None
    url, error, is_large = _get_cached_115_direct_url(pickcode, ua=ua)
    if url:
        return jsonify(url=url)
    if is_large:
        return jsonify(error=error, is_large_file=True), 400
    return jsonify(error=error or "获取直链失败"), 502


# CDN 直链缓存：避免每次 Range 请求都重新 resolve pickcode（很慢）
# key=(pickcode, ua)，value=(cdn_url, expire_timestamp)——直链绑定取链 UA，必须按 UA 区分
_115_DIRECT_URL_CACHE = {}
_115_DIRECT_URL_LOCK = threading.Lock()
# 失败缓存：resolve 失败（如 token 过期/大文件限制）也短缓存，避免播放器/用户重试时反复打 115 API
_115_RESOLVE_FAIL_CACHE = {}  # key=pickcode, value=(error, is_large, expire_timestamp)
_RESOLVE_FAIL_TTL = 60  # 失败缓存 60 秒


def _get_cached_115_direct_url(pickcode, ua=None):
    """获取 115 直链（带缓存，按 pickcode+UA 区分——直链绑定取链时的 UA）。
    浏览器播放 moov-in-tail MP4 会发多次 Range 请求，每次都 resolve 会很慢（要请求 115 API），
    缓存直链后只 resolve 一次。失败结果短缓存 60 秒，防止重复请求触发风控。"""
    cache_key = (pickcode, ua or "")
    now = time.time()
    with _115_DIRECT_URL_LOCK:
        cached = _115_DIRECT_URL_CACHE.get(cache_key)
        if cached:
            url, expire = cached
            if now < expire:
                return url, None, False
            else:
                _115_DIRECT_URL_CACHE.pop(cache_key, None)
        failed = _115_RESOLVE_FAIL_CACHE.get(pickcode)
        if failed:
            error, is_large, expire = failed
            if now < expire:
                return None, error, is_large
            _115_RESOLVE_FAIL_CACHE.pop(pickcode, None)

    url, error, is_large = _resolve_115_direct_url(pickcode, ua=ua)
    if url:
        # 从 URL 参数解析有效期（t=时间戳），保守按 30 分钟缓存
        expire = now + 1800
        try:
            from urllib.parse import urlparse, parse_qs
            qs = parse_qs(urlparse(url).query)
            t_val = qs.get("t", [None])[0]
            if t_val:
                expire = min(int(t_val) - 60, now + 3600)  # 比真实过期早 60 秒
        except Exception:
            pass
        with _115_DIRECT_URL_LOCK:
            _115_DIRECT_URL_CACHE[cache_key] = (url, expire)
    else:
        with _115_DIRECT_URL_LOCK:
            _115_RESOLVE_FAIL_CACHE[pickcode] = (error, is_large, now + _RESOLVE_FAIL_TTL)
    return url, error, is_large


def _play_mode_redirect():
    """当前播放方式是否为 302 直连（cloud115_play_mode == 'redirect'）。"""
    return str(get_settings().get("cloud115_play_mode", "proxy")).strip() == "redirect"


def play_115_redirect_response(pickcode):
    """302 直连播放：取直链后 302 重定向，浏览器直连 115 CDN，视频流量不经后端。

    取链时透传播放器 UA（115 签发的直链与该 UA 绑定，浏览器跟随跳转时 UA 一致，
    签名校验才能通过）。直链解析与缓存复用 _get_cached_115_direct_url。
    """
    ua = request.headers.get("User-Agent", "") or None
    url, error, is_large = _get_cached_115_direct_url(pickcode, ua=ua)
    if url:
        write_app_log("info", "media", "play-115-redirect", "开始 302 直连播放", target=pickcode)
        return redirect(url, 302)
    if is_large:
        write_app_log("warning", "media", "play-115-redirect", error or "文件大小超出 WebAPI 限制，且 OpenAPI token 已失效", target=pickcode)
        return jsonify(error=error or "文件大小超出 WebAPI 限制，且 OpenAPI token 已失效"), 400
    write_app_log("error", "media", "play-115-redirect", error or "获取直链失败", target=pickcode)
    return jsonify(error=error or "获取直链失败"), 502


# CDN 连接池：复用 TLS 连接，避免每次 Range 请求都重新握手（moov-in-tail MP4 会发多次 Range）
_115_CDN_POOL = {}  # key=host, value=http.client.HTTPSConnection
_115_CDN_POOL_LOCK = threading.Lock()


def _get_cdn_connection(host, port=443):
    """从连接池获取可复用的 HTTPS 连接，如果连接已断则新建。"""
    import http.client
    import ssl
    with _115_CDN_POOL_LOCK:
        conn = _115_CDN_POOL.get(host)
    if conn is not None:
        # 测试连接是否还活着
        try:
            conn.sock.send(b'')  # 非阻塞探测
            return conn
        except Exception:
            try:
                conn.close()
            except Exception:
                pass
            with _115_CDN_POOL_LOCK:
                _115_CDN_POOL.pop(host, None)
    # 新建连接
    ip = socket.gethostbyname(host)
    raw_sock = socket.create_connection((ip, port), timeout=15)
    ctx = ssl.create_default_context()
    ssl_sock = ctx.wrap_socket(raw_sock, server_hostname=host)
    conn = http.client.HTTPSConnection(host, port, timeout=60)
    conn.sock = ssl_sock
    with _115_CDN_POOL_LOCK:
        _115_CDN_POOL[host] = conn
    return conn


def _proxy_stream_115(cdn_url, ua=None):
    """流式代理 115 CDN 直链：后端自己拉 CDN，转发给浏览器。

    优化：
    1. HTTPS 连接池复用 TLS 连接（moov-in-tail MP4 多次 Range 请求不再重新握手）
    2. 115 CDN 直链绑定取链时的 UA（f=1 签名校验），必须用同一 UA 访问
    3. 去掉 Content-Disposition: attachment（否则浏览器下载不播放）
    4. DNS 缓存 + 重试，解决 Docker 内部 DNS 间歇性失败
    """
    from urllib.parse import urlparse

    parsed = urlparse(cdn_url)
    host = parsed.hostname
    port = parsed.port or 443
    path = parsed.path + ("?" + parsed.query if parsed.query else "")

    # 构建请求头：UA 必须与取链时的 UA 一致（f=1 签名校验）
    req_headers = {"User-Agent": ua or "Python-urllib/3.11"}
    range_header = request.headers.get("Range", "")
    if range_header:
        req_headers["Range"] = range_header

    # 用连接池发请求，失败则重试（新建连接）
    upstream = None
    last_err = None
    for attempt in range(4):
        try:
            conn = _get_cdn_connection(host, port)
            conn.request("GET", path, headers=req_headers)
            upstream = conn.getresponse()
            if upstream.status == 403:
                # 签名失败可能是连接复用问题，新建连接重试
                upstream.read()
                with _115_CDN_POOL_LOCK:
                    _115_CDN_POOL.pop(host, None)
                upstream = None
                continue
            break
        except Exception as e:
            last_err = e
            with _115_CDN_POOL_LOCK:
                _115_CDN_POOL.pop(host, None)
            if attempt < 3:
                time.sleep(0.3)
            continue
    if upstream is None:
        return jsonify(error=f"CDN 连接失败(重试4次): {last_err}"), 502

    upstream_status = upstream.status
    upstream_headers = {k: v for k, v in upstream.getheaders()}

    # 构建要转发给浏览器的 header
    forward_headers = {}
    skip_headers = {
        "transfer-encoding", "connection", "content-encoding",
        "server", "x-115-request-id",
    }
    for k, v in upstream_headers.items():
        kl = k.lower()
        if kl in skip_headers:
            continue
        forward_headers[k] = v

    # 去掉 Content-Disposition: attachment（否则浏览器下载不播放）
    forward_headers.pop("Content-Disposition", None)
    forward_headers.pop("content-disposition", None)

    # 确保 Content-Type 正确
    ct = forward_headers.get("Content-Type") or forward_headers.get("content-type")
    if not ct or ct == "application/octet-stream":
        forward_headers["Content-Type"] = "video/mp4"

    forward_headers["Access-Control-Allow-Origin"] = "*"

    ar = forward_headers.get("Accept-Ranges") or forward_headers.get("accept-ranges")
    if not ar:
        forward_headers["Accept-Ranges"] = "bytes"

    def _stream():
        try:
            while True:
                chunk = upstream.read(1024 * 1024)  # 1MB per chunk
                if not chunk:
                    break
                yield chunk
        finally:
            # 不关闭 conn，放回连接池复用
            pass

    return Response(_stream(), status=upstream_status, headers=forward_headers)


@app.get("/api/115/play/<pickcode>")
def play_115_by_pickcode(pickcode):
    # 302 直连模式：浏览器直连 115 CDN，不经后端转发
    if _play_mode_redirect():
        return play_115_redirect_response(pickcode)
    """代理流式播放：后端拉 CDN 转发给浏览器，绕过 CDN 的 UA/IP 锁定和 attachment 下载问题。"""
    ua = request.headers.get("User-Agent", "") or None
    # 使用缓存：浏览器播放 moov-in-tail MP4 会发多次 Range 请求，每次都 resolve 很慢
    url, error, is_large = _get_cached_115_direct_url(pickcode, ua=ua)
    if url:
        write_app_log("info", "media", "play-115-proxy", "开始代理流式播放", target=pickcode)
        return _proxy_stream_115(url, ua=ua)
    if is_large:
        # 大文件无法获取直链（cookie 过期 + 50028）
        write_app_log("warning", "media", "play-115-proxy", error or "文件大小超出 WebAPI 限制，且 OpenAPI token 已失效", target=pickcode)
        return jsonify(error=error or "文件大小超出 WebAPI 限制，且 OpenAPI token 已失效"), 400
    write_app_log("error", "media", "play-115-proxy", error or "获取直链失败", target=pickcode)
    return jsonify(error=error or "获取直链失败"), 502


@app.post("/api/cloud-tasks/poll-now")
def poll_cloud_tasks_now():
    """手动触发一次 115 离线状态轮询（同步执行，最多等 30 秒）。"""
    import concurrent.futures
    settings = get_settings()
    cookie = str(settings.get("cloud115_cookie", "")).strip()
    if str(settings.get("cloud115_mode", "bridge")) != "cookie" or not cookie:
        return jsonify(error="需要 Cookie 模式且已配置 115 Cookie 才能手动轮询"), 400

    def _run_once():
        # 复制 poll_cloud_tasks 的探测逻辑，但只跑一轮
        pending = rows(
            "SELECT * FROM cloud_tasks WHERE state IN ('submitted','pending','running') ORDER BY created_at DESC LIMIT 30"
        )
        if not pending:
            return {"checked": 0, "completed": 0, "message": "没有待轮询的任务"}
        download_dir_id = ""
        groups: dict = {}
        for ct in pending:
            cid = str(ct.get("dest_cid") or "").strip()
            if not cid:
                if not download_dir_id:
                    dd = find_115_download_dir(cookie)
                    if not dd:
                        continue
                    download_dir_id = str(dd["id"])
                cid = download_dir_id
            groups.setdefault(cid, []).append(ct)
        completed_count = 0
        dest_label = str(settings.get("cloud_transfer_path") or "").strip()
        for probe_cid, cts in groups.items():
            try:
                nodes = list_115_nodes(cookie, probe_cid)
            except Exception:
                continue
            for ct in cts:
                matched = _match_115_node(nodes, ct["title"], ct.get("catalog"))
                if not matched:
                    continue
                if str(ct.get("dest_cid") or "").strip():
                    file_path = f"{dest_label.rstrip('/')}/{matched['name']}" if dest_label else f"115 网盘目标目录/{matched['name']}"
                else:
                    file_path = f"云下载/{matched['name']}"
                video_exts = (".mp4", ".mkv", ".wmv", ".avi", ".mov", ".flv", ".ts", ".webm", ".rmvb", ".m2ts")
                best_pickcode = ""
                if matched["is_dir"]:
                    try:
                        all_children = list_115_nodes(cookie, matched["id"])
                        _115_cleanup_ad_files(cookie, matched, all_children, settings)
                        children = [c for c in all_children
                                    if not c["is_dir"] and c["name"].lower().endswith(video_exts)]
                        if children:
                            best_pickcode = max(children, key=lambda c: int(c["size"] or 0)).get("pickcode", "")
                    except Exception:
                        pass
                else:
                    best_pickcode = matched.get("pickcode", "")
                play_url = f"https://115.com/web/play/?pickcode={best_pickcode}" if best_pickcode else ""
                message = f"115 离线完成（云盘位置：{file_path}）"
                with db_lock, connect() as db:
                    db.execute(
                        "UPDATE cloud_tasks SET state='completed', message=?, play_url=?, file_path=?, finished_at=?, pickcode=? WHERE id=?",
                        (message, play_url, file_path, datetime.now().isoformat(timespec="seconds"), best_pickcode, ct["id"])
                    )
                completed_count += 1
        return {"checked": len(pending), "completed": completed_count, "message": f"轮询 {len(pending)} 个任务，完成 {completed_count} 个"}

    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(_run_once)
        try:
            result = future.result(timeout=30)
        except concurrent.futures.TimeoutError:
            write_app_log("warning", "115", "poll-now", "115 离线状态轮询超时")
            return jsonify(error="轮询超时（30 秒），后台仍在执行"), 504
        except Exception as err:
            write_app_log("error", "115", "poll-now", "115 离线状态轮询失败", detail=str(err))
            return jsonify(error=f"轮询失败：{str(err)[:160]}"), 400
    write_app_log("success", "115", "poll-now",
                  f"115 离线状态已同步：检查 {result.get('checked', 0)} 个，完成 {result.get('completed', 0)} 个")
    return jsonify(result)


# ---------- 广告小文件手动清理：对已完成的离线产物目录立即执行一遍 ----------
_AD_CLEANUP_STATE = {"running": False, "deleted": 0, "dirs": 0, "current": "", "started_at": 0, "finished_at": 0, "error": ""}
_ad_cleanup_lock = threading.Lock()


def _resolve_115_dir_path(cookie, path):
    """按 'a/b/c' 路径从根目录逐级定位云盘目录，返回目录节点；找不到返回 None。"""
    node = {"id": "0", "name": "", "is_dir": True}
    for segment in [s for s in str(path or "").split("/") if s.strip()]:
        nodes = list_115_nodes(cookie, node["id"])
        node = next((n for n in nodes if n["is_dir"] and n["name"] == segment), None)
        if node is None:
            return None
    return node


def _ad_cleanup_worker(cookie):
    try:
        settings = get_settings()
        tasks = rows(
            "SELECT file_path FROM cloud_tasks WHERE state='completed' AND file_path<>'' "
            "ORDER BY finished_at DESC LIMIT 80"
        )
        # 按父目录分组去重：(父目录路径 -> [产物目录名])
        groups: dict = {}
        for t in tasks:
            parent_path, _, dir_name = str(t["file_path"] or "").strip().rpartition("/")
            if parent_path and dir_name:
                groups.setdefault(parent_path, [])
                if dir_name not in groups[parent_path]:
                    groups[parent_path].append(dir_name)
        deleted_total, dirs_total = 0, 0
        for parent_path, names in groups.items():
            if not _AD_CLEANUP_STATE["running"]:
                break
            parent_node = _resolve_115_dir_path(cookie, parent_path)
            if not parent_node:
                continue
            try:
                nodes = list_115_nodes(cookie, parent_node["id"])
            except Exception:
                continue
            for name in names:
                if not _AD_CLEANUP_STATE["running"]:
                    break
                matched = next((n for n in nodes if n["is_dir"] and n["name"] == name), None)
                if not matched:
                    continue
                _AD_CLEANUP_STATE["current"] = f"{parent_path}/{name}"
                try:
                    children = list_115_nodes(cookie, matched["id"])
                    deleted, _ = _115_cleanup_ad_files(cookie, matched, children, settings)
                    deleted_total += deleted
                    dirs_total += 1
                except Exception:
                    continue
        _AD_CLEANUP_STATE.update(running=False, current="", finished_at=time.time(),
                                 deleted=deleted_total, dirs=dirs_total)
        write_app_log("success" if not _AD_CLEANUP_STATE["error"] else "warning", "115", "ad-cleanup-manual",
                      f"手动清理广告文件完成：扫描 {dirs_total} 个离线目录，共清理 {deleted_total} 个小文件")
    except Exception as error:
        _AD_CLEANUP_STATE.update(running=False, current="", finished_at=time.time(), error=str(error)[:200])
        write_app_log("error", "115", "ad-cleanup-manual", "手动清理广告文件失败", detail=str(error)[:200])


@app.post("/api/115/cleanup-ads")
def api_115_cleanup_ads():
    """立即清理：对最近完成的离线产物目录按当前阈值跑一遍广告清理（不限后缀）。"""
    if str(get_settings().get("cloud115_mode", "")) != "cookie":
        return jsonify(error="需要 Cookie 模式且已配置 115 Cookie"), 400
    cookie = str(get_settings().get("cloud115_cookie", "")).strip()
    if not cookie:
        return jsonify(error="未配置 115 Cookie"), 400
    if float(get_settings().get("cloud_ad_min_mb", 0) or 0) <= 0:
        return jsonify(error="请先把「离线产物广告清理阈值」设置为大于 0 的值"), 400
    with _ad_cleanup_lock:
        if _AD_CLEANUP_STATE["running"]:
            return jsonify(ok=True, running=True, state=_AD_CLEANUP_STATE, message="清理已在后台进行中")
        _AD_CLEANUP_STATE.update(running=True, deleted=0, dirs=0, current="",
                                 started_at=time.time(), finished_at=0, error="")
        threading.Thread(target=_ad_cleanup_worker, args=(cookie,), daemon=True, name="ad-cleanup").start()
    write_app_log("info", "115", "ad-cleanup-manual", "手动清理广告文件已启动（后台执行，结果见日志中心）")
    return jsonify(ok=True, running=True, message="后台清理已启动，完成后可在日志中心查看结果")


@app.get("/api/hero-stats")
def hero_stats():
    """首页横幅统计：115 离线/媒体库/自动离线计数。"""
    today = datetime.now().strftime("%Y-%m-%d")

    def count(sql, args=()):
        row = rows(sql, args)
        return int(row[0]["n"]) if row else 0

    return jsonify(
        cloud_active=count("SELECT COUNT(*) AS n FROM cloud_tasks WHERE state NOT IN ('completed','failed')"),
        cloud_done=count("SELECT COUNT(*) AS n FROM cloud_tasks WHERE state='completed'"),
        strm_count=count("SELECT COUNT(*) AS n FROM strm_items"),
        auto_today=count("SELECT COUNT(*) AS n FROM auto_offline_log WHERE state='submitted' AND created_at LIKE ?", (f"{today}%",)),
    )


@app.get("/api/auto-offline")
def auto_offline_status():
    """自动离线配置 + 今日计数 + 最近日志。"""
    cfg = _auto_offline_cfg()
    logs = rows("SELECT * FROM auto_offline_log ORDER BY created_at DESC LIMIT 50")
    return jsonify(config=cfg, today_count=_auto_offline_today_count(), logs=logs)


@app.post("/api/auto-offline")
def auto_offline_save():
    payload = request.get_json(force=True)
    allowed = {
        "auto_offline_enabled", "auto_offline_browse", "auto_offline_schedule",
        "auto_offline_interval", "auto_offline_pages", "auto_offline_whitelist",
        "auto_offline_min_duration", "auto_offline_min_size", "auto_offline_daily_limit",
    }
    with db_lock, connect() as db:
        for key, value in payload.items():
            if key in allowed:
                db.execute("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)", (key, json.dumps(value)))
    return jsonify(ok=True, config=_auto_offline_cfg())


@app.post("/api/auto-offline/run")
def auto_offline_run():
    """手动触发一轮定时追新扫描（后台执行）。"""
    cfg = _auto_offline_cfg()
    if not cfg["enabled"] or not cfg["schedule"]:
        return jsonify(error="请先开启自动离线并勾选定时追新模式"), 400
    threading.Thread(target=run_auto_offline_scan, daemon=True, name="auto-offline-manual").start()
    return jsonify(ok=True, message="扫描已启动，结果请稍后在执行记录中查看")


@app.get("/api/hg/series")
def hg_series_list():
    """追剧库列表：附每部剧失败集数与排队/下载中集的实时进度（前端轮询直接展示）。"""
    series = rows("SELECT * FROM hg_series ORDER BY COALESCE(last_checked_at, created_at) DESC")
    if series:
        failed_counts = {r["series_id"]: int(r["c"]) for r in rows(
            "SELECT series_id, COUNT(*) AS c FROM hg_episodes WHERE state='failed' GROUP BY series_id")}
        active = {}
        for r in rows("""SELECT series_id, ep, state, progress, message FROM hg_episodes
                         WHERE state IN ('queued','running') ORDER BY ep"""):
            active.setdefault(r["series_id"], []).append(
                {"ep": r["ep"], "state": r["state"],
                 "progress": float(r["progress"] or 0), "message": r["message"] or ""})
        for item in series:
            item["failed_count"] = failed_counts.get(item["id"], 0)
            item["active_episodes"] = active.get(item["id"], [])
    return jsonify(series)


def _hg_series_cover_response(series_id, series=None):
    """按 series_id 返回封面文件；缺失时回源（token 过期则重抓详情页取新 og:image）。"""
    path = _hg_cover_path(series_id)
    if path.exists() and path.stat().st_size > 0:
        return send_file(path, mimetype="image/jpeg")
    series = series or row("SELECT * FROM hg_series WHERE id=?", (series_id,))
    if not series:
        return "", 404
    saved = _hg_persist_cover(series_id, series.get("cover_url", ""), force=True)
    if not saved:
        fresh_cover = _hg_search_cover(series_id, series.get("title", ""))
        if fresh_cover:
            saved = _hg_persist_cover(series_id, fresh_cover, force=True)
            if saved:
                with db_lock, connect() as db:
                    db.execute("UPDATE hg_series SET cover_url=? WHERE id=?", (fresh_cover, series_id))
    if saved and saved.exists():
        return send_file(saved, mimetype="image/jpeg")
    return "", 404


@app.get("/api/hg/cover/<series_id>")
def hg_series_cover(series_id):
    """追剧库封面。"""
    return _hg_series_cover_response(series_id)


@app.get("/api/hg/local-cover")
def hg_local_series_cover():
    """媒体库本地短剧封面（纯磁盘快速返回，不做网络回源）：name 为 黄果短剧/<剧名> 目录名。
    优先目录内刮削好的 poster.jpg；缺失时按目录名（safe_name(title,id)）匹配 hg_series 的持久化解密封面。"""
    raw = str(request.args.get("name", "") or "").strip()
    if not raw or "/" in raw or "\\" in raw or ".." in raw:
        return "", 404
    try:
        poster = MEDIA_DIR / "黄果短剧" / raw / "poster.jpg"
        if poster.is_file() and poster.stat().st_size > 0:
            return send_file(poster, mimetype="image/jpeg")
    except OSError:
        pass
    all_series = rows("SELECT * FROM hg_series")
    matched = [s for s in all_series if safe_name(s.get("title", ""), s.get("id", "")) == raw]
    if not matched:
        compact = re.sub(r"\s+", "", raw)
        matched = [s for s in all_series
                   if re.sub(r"\s+", "", safe_name(s.get("title", ""), s.get("id", ""))) == compact]
    for item in matched:
        persisted = _hg_cover_path(item["id"])
        if persisted.is_file() and persisted.stat().st_size > 0:
            return send_file(persisted, mimetype="image/jpeg")
    return "", 404


@app.get("/api/hg/catalog")
def hg_catalog():
    tab_id = request.args.get("tab", "home")
    keyword = request.args.get("q", "")
    force = str(request.args.get("refresh", "") or "").strip() in ("1", "true")
    try:
        page = max(1, int(request.args.get("page", "1")))
    except (TypeError, ValueError):
        page = 1
    try:
        result = _hg_catalog_items(tab_id, page, keyword, force=force)
        write_app_log("info", "huangguo", "catalog", f"黄果列表解析完成：{len(result['items'])} 条",
                      target=result.get("source_url", ""))
        return jsonify(result)
    except Exception as error:
        write_app_log("error", "huangguo", "catalog", "黄果列表解析失败", detail=str(error), target=str(tab_id))
        return jsonify(error=f"黄果列表解析失败：{str(error)[:180]}"), 400


@app.post("/api/hg/series")
def hg_series_create():
    payload = request.get_json(force=True)
    url = str(payload.get("url", "") or "").strip()
    if not url:
        return jsonify(error="请输入黄果短剧播放页或详情页地址"), 400
    try:
        parsed = _hg_parse_series(url)
        existed = bool(row("SELECT id FROM hg_series WHERE id=?", (parsed["id"],)))
        series_id = _hg_upsert_series(parsed)
        episodes = rows("SELECT * FROM hg_episodes WHERE series_id=? ORDER BY ep", (series_id,))
        # 新入库自动触发全量下载：入库即下载，无需再点「下载缺失」
        queued = 0
        if not existed:
            now = datetime.now().isoformat(timespec="seconds")
            with db_lock, connect() as db:
                cursor = db.execute(
                    """UPDATE hg_episodes SET state='queued', message='入库自动下载', error='', retry_count=0, updated_at=?
                       WHERE series_id=? AND state='pending'""", (now, series_id))
                queued = cursor.rowcount
            if queued:
                hg_worker_wakeup.set()
                write_app_log("success", "huangguo", "auto-download",
                              f"入库自动下载：{parsed['title']} 已加入 {queued} 集", target=parsed["detail_url"])
        return jsonify(ok=True, existed=existed, queued=queued, series=row("SELECT * FROM hg_series WHERE id=?", (series_id,)), episodes=episodes), 201
    except Exception as error:
        write_app_log("error", "huangguo", "add-series", "添加黄果短剧失败", detail=str(error), target=url)
        return jsonify(error=f"黄果短剧解析失败：{str(error)[:180]}"), 400


@app.get("/api/hg/series/<series_id>/episodes")
def hg_episode_list(series_id):
    return jsonify(rows("SELECT * FROM hg_episodes WHERE series_id=? ORDER BY ep", (series_id,)))


# ---------- 黄果在线播放（未入库也能播：解析流 + HLS 改写代理） ----------
_HG_ONLINE_RESOLVE_CACHE = {}      # (play_url, ep) -> {"stream": url, "ts": time}
_HG_ONLINE_RESOLVE_TTL = 1800      # auth_key 实测约 1-2 小时时效，30 分钟内直接复用
_HG_ONLINE_EPISODES_CACHE = {}     # detail_url -> {"data": {...}, "ts": time}
_HG_ONLINE_EPISODES_TTL = 300

_HG_M3U8_MIME = "application/vnd.apple.mpegurl"


def _b64u_encode(value):
    return base64.urlsafe_b64encode(str(value).encode("utf-8")).decode("ascii").rstrip("=")


def _b64u_decode(value):
    padded = str(value or "") + "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(padded.encode("ascii")).decode("utf-8", errors="replace")


def _hg_media_open(url, referer, extra_headers=None, timeout=30):
    """黄果媒体请求（播放列表/key/分片）：带 UA/Referer/Origin，代理开关与下载一致（hg_use_proxy）。"""
    headers = {"User-Agent": HG_UA, "Accept": "*/*"}
    if referer:
        headers["Referer"] = referer
        try:
            headers["Origin"] = _hg_origin(referer)
        except ValueError:
            pass
    if extra_headers:
        headers.update(extra_headers)
    request_object = Request(url, headers=headers)
    settings = get_settings()
    proxy = str(settings.get("proxy", "")).strip() if settings.get("hg_use_proxy", True) else ""
    if proxy:
        opener = build_opener(ProxyHandler({"http": proxy, "https": proxy}))
        return opener.open(request_object, timeout=timeout)
    return urlopen(request_object, timeout=timeout)


def _hg_online_stream(play_url, ep, force=False):
    """解析某集的流地址（带短缓存；auth_key 过期自动重解析）"""
    cache_key = (play_url, int(ep))
    cached = _HG_ONLINE_RESOLVE_CACHE.get(cache_key)
    if (cached and not force and time.time() - cached["ts"] < _HG_ONLINE_RESOLVE_TTL
            and not _hg_stream_url_expired(cached["stream"])):
        return cached["stream"]
    stream = _hg_resolve_episode_stream(play_url, int(ep))
    _HG_ONLINE_RESOLVE_CACHE[cache_key] = {"stream": stream, "ts": time.time()}
    return stream


def _hg_proxy_media_url(target, referer):
    return f"/api/hg/media-proxy?u={_b64u_encode(target)}&r={_b64u_encode(referer)}"


def _hg_rewrite_m3u8(text, playlist_url, referer):
    """把 m3u8 里的 key/分片/子播放列表地址改写为本机代理，保持浏览器可播（AES-128 key 同样走代理）。"""
    def rewrite_uri(raw_uri):
        absolute = urljoin(playlist_url, raw_uri)
        return _hg_proxy_media_url(absolute, referer)

    rewritten = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            rewritten.append(line)
            continue
        if stripped.startswith("#"):
            if "URI=\"" in stripped:
                line = re.sub(r'URI="([^"]+)"', lambda m: f'URI="{rewrite_uri(m.group(1))}"', line)
            rewritten.append(line)
        else:
            rewritten.append(rewrite_uri(stripped))
    return "\n".join(rewritten) + "\n"


@app.get("/api/hg/online-episodes")
def hg_online_episodes():
    """在线播放：解析详情页拿分集列表（不写库），供未入库影片直接选集播放"""
    url = str(request.args.get("url", "") or "").strip()
    if not url.startswith(("http://", "https://")):
        return jsonify(error="请提供黄果详情页或播放页地址"), 400
    cache_key = url.split("?")[0].rstrip("/")
    cached = _HG_ONLINE_EPISODES_CACHE.get(cache_key)
    if cached and time.time() - cached["ts"] < _HG_ONLINE_EPISODES_TTL:
        return jsonify(cached["data"])
    try:
        parsed = _hg_parse_series(url)
    except Exception as error:
        write_app_log("error", "huangguo", "online-play", "在线播放解析剧集失败", detail=str(error), target=url)
        return jsonify(error=f"解析剧集失败：{str(error)[:180]}"), 400
    data = {"id": parsed["id"], "title": parsed["title"],
            "detail_url": parsed["detail_url"],
            "episodes": [{"ep": item["ep"], "play_url": item["play_url"], "locked": bool(item.get("locked"))}
                         for item in parsed["episodes"]]}
    # 封面本地化：og:image 域名（如 expose.eisees.com）常拉不到，持久化失败再用站内搜索封面兜底，
    # 成功后返回本地 /api/hg/cover/<id>，保证弹窗必有封面/背景图
    cover = str(parsed.get("cover_url") or "")
    persisted = _hg_persist_cover(str(parsed["id"]), cover)
    if not persisted:
        fresh = _hg_search_cover(str(parsed["id"]), parsed.get("title", ""))
        if fresh:
            persisted = _hg_persist_cover(str(parsed["id"]), fresh)
            cover = fresh
    if persisted and Path(persisted).exists():
        data["cover_url"] = f"/api/hg/cover/{parsed['id']}"
    else:
        data["cover_url"] = cover
    if data["episodes"]:
        # 解析失败/空分集不缓存，避免空结果在 TTL 内反复命中
        _HG_ONLINE_EPISODES_CACHE[cache_key] = {"data": data, "ts": time.time()}
    return jsonify(data)


@app.get("/api/hg/online-play")
def hg_online_play():
    """在线播放：解析指定集的流地址并返回改写后的 m3u8（key/分片全部经本机代理转发）"""
    play_url = str(request.args.get("url", "") or "").strip()
    try:
        ep = int(request.args.get("ep", "1"))
    except (TypeError, ValueError):
        ep = 1
    if not play_url.startswith(("http://", "https://")):
        return jsonify(error="请提供黄果播放页地址"), 400
    stream, force = "", False
    for attempt in range(2):
        try:
            stream = _hg_online_stream(play_url, ep, force=force)
            with _hg_media_open(stream, referer=play_url) as upstream:
                playlist_url = upstream.geturl()
                content_type = (upstream.headers.get("Content-Type") or "").lower()
                text = upstream.read().decode("utf-8", errors="replace")
            if "mpegurl" not in content_type and not playlist_url.lower().split("?")[0].endswith(".m3u8"):
                # 直接是完整媒体文件（少见）：交给媒体代理按普通文件流式转发
                return redirect(_hg_proxy_media_url(stream, play_url))
            return Response(_hg_rewrite_m3u8(text, playlist_url, play_url), mimetype=_HG_M3U8_MIME)
        except Exception as error:
            if attempt == 0:
                force = True
                _HG_ONLINE_RESOLVE_CACHE.pop((play_url, ep), None)
                continue
            write_app_log("error", "huangguo", "online-play", "在线播放解析媒体流失败",
                          detail=str(error), target=play_url)
            return jsonify(error=f"解析媒体流失败：{str(error)[:180]}"), 502
    return jsonify(error="解析媒体流失败"), 502


@app.get("/api/hg/media-proxy")
def hg_media_proxy():
    """HLS key/分片转发：带上游要求的 UA/Referer/Origin，支持 Range 透传"""
    try:
        target = _b64u_decode(request.args.get("u", ""))
        referer = _b64u_decode(request.args.get("r", "")) if request.args.get("r", "") else ""
    except Exception:
        return jsonify(error="代理参数无效"), 400
    if not target.startswith(("http://", "https://")):
        return jsonify(error="仅支持 http/https 媒体地址"), 400
    headers = {"Range": request.headers.get("Range")} if request.headers.get("Range") else None
    try:
        upstream = _hg_media_open(target, referer=referer, extra_headers=headers)
    except HTTPError as error:
        upstream.close() if hasattr(upstream, "close") else None
        return jsonify(error=f"上游返回 {error.code}"), 502 if error.code >= 500 else error.code
    except Exception as error:
        return jsonify(error=f"媒体代理失败：{str(error)[:140]}"), 502
    content_type = upstream.headers.get("Content-Type") or "application/octet-stream"
    if "mpegurl" in content_type.lower() or target.lower().split("?")[0].endswith(".m3u8"):
        try:
            text = upstream.read().decode("utf-8", errors="replace")
            playlist_url = upstream.geturl()
        finally:
            upstream.close()
        return Response(_hg_rewrite_m3u8(text, playlist_url, referer or target), mimetype=_HG_M3U8_MIME)

    def _generate():
        try:
            while True:
                chunk = upstream.read(65536)
                if not chunk:
                    break
                yield chunk
        finally:
            upstream.close()

    response = Response(stream_with_context(_generate()), content_type=content_type)
    for header in ("Content-Length", "Content-Range", "Accept-Ranges"):
        value = upstream.headers.get(header)
        if value:
            response.headers[header] = value
    response.headers["Cache-Control"] = "no-store"
    return response


@app.get("/api/hg/recent-episodes")
def hg_recent_episodes():
    """下载任务页黄果记录：最近更新的集数下载/上传状态（联表取剧名与封面）。"""
    try:
        limit = min(300, max(20, int(request.args.get("limit", "120") or "120")))
    except (TypeError, ValueError):
        limit = 120
    items = rows(
        """SELECT e.id, e.series_id, e.ep, e.title AS episode_title, e.state, e.upload_state,
                  e.progress, e.message, e.error, e.file_path, e.upload_path, e.created_at, e.updated_at,
                  s.title AS series_title, s.cover_url
           FROM hg_episodes e LEFT JOIN hg_series s ON s.id = e.series_id
           ORDER BY e.updated_at DESC LIMIT ?""", (limit,))
    return jsonify(items)


@app.post("/api/hg/series/<series_id>/check")
def hg_series_check(series_id):
    item = row("SELECT * FROM hg_series WHERE id=?", (series_id,))
    if not item:
        return jsonify(error="短剧不存在"), 404
    try:
        parsed = _hg_parse_series(item["detail_url"])
        _hg_upsert_series(parsed)
        episodes = rows("SELECT * FROM hg_episodes WHERE series_id=? ORDER BY ep", (series_id,))
        return jsonify(ok=True, series=row("SELECT * FROM hg_series WHERE id=?", (series_id,)), episodes=episodes)
    except Exception as error:
        write_app_log("error", "huangguo", "check-series", "黄果短剧追更检查失败", detail=str(error), target=item["detail_url"])
        return jsonify(error=f"检查更新失败：{str(error)[:180]}"), 400


@app.post("/api/hg/series/<series_id>/rescrape")
def hg_series_rescrape(series_id):
    """重新刮削：重抓详情页更新元数据/封面/nfo，失败与未下载的集重新排队下载。"""
    item = row("SELECT * FROM hg_series WHERE id=?", (series_id,))
    if not item:
        return jsonify(error="短剧不存在"), 404
    try:
        parsed = _hg_parse_series(item["detail_url"])
        _hg_upsert_series(parsed)
        now = datetime.now().isoformat(timespec="seconds")
        with db_lock, connect() as db:
            cursor = db.execute(
                """UPDATE hg_episodes SET state='queued', message='重新刮削后重试下载', error='',
                       stream_url='', retry_count=0, updated_at=?
                   WHERE series_id=? AND state IN ('failed','pending')""", (now, series_id))
            queued = cursor.rowcount
        if queued:
            hg_worker_wakeup.set()
        _hg_refresh_local_metadata(series_id)
        write_app_log("success", "huangguo", "rescrape", f"重新刮削完成：{item['title']}，{queued} 集待重试下载",
                      target=item["detail_url"])
        return jsonify(ok=True, queued=queued, series=row("SELECT * FROM hg_series WHERE id=?", (series_id,)),
                       episodes=rows("SELECT * FROM hg_episodes WHERE series_id=? ORDER BY ep", (series_id,)))
    except Exception as error:
        write_app_log("error", "huangguo", "rescrape", "黄果短剧重新刮削失败", detail=str(error), target=item["detail_url"])
        return jsonify(error=f"重新刮削失败：{str(error)[:180]}"), 400


@app.post("/api/hg/series/<series_id>/download-missing")
def hg_download_missing(series_id):
    if not row("SELECT id FROM hg_series WHERE id=?", (series_id,)):
        return jsonify(error="短剧不存在"), 404
    now = datetime.now().isoformat(timespec="seconds")
    with db_lock, connect() as db:
        cursor = db.execute(
            """UPDATE hg_episodes SET state='queued', message='等待下载', error='', retry_count=0, updated_at=?
               WHERE series_id=? AND state NOT IN ('running','completed')""",
            (now, series_id)
        )
    hg_worker_wakeup.set()
    write_app_log("info", "huangguo", "download-missing", f"已加入缺失集下载队列：{cursor.rowcount} 集", target=series_id)
    return jsonify(ok=True, queued=cursor.rowcount)


@app.post("/api/hg/episodes/<episode_id>/download")
def hg_episode_download(episode_id):
    if not row("SELECT id FROM hg_episodes WHERE id=?", (episode_id,)):
        return jsonify(error="剧集不存在"), 404
    with db_lock, connect() as db:
        db.execute("UPDATE hg_episodes SET state='queued', message='等待下载', error='', retry_count=0, updated_at=? WHERE id=?",
                   (datetime.now().isoformat(timespec="seconds"), episode_id))
    hg_worker_wakeup.set()
    return jsonify(ok=True)


@app.post("/api/hg/retry-failed-all")
def hg_retry_failed_all():
    """一键批量重试：所有下载失败的集数重新入队。"""
    now = datetime.now().isoformat(timespec="seconds")
    with db_lock, connect() as db:
        cursor = db.execute(
            """UPDATE hg_episodes SET state='queued', progress=0, message='批量重试下载', error='', retry_count=0, updated_at=?
               WHERE state='failed'""", (now,))
    queued = cursor.rowcount
    if queued:
        hg_worker_wakeup.set()
    write_app_log("info", "huangguo", "retry-failed-all", f"批量重试失败集：{queued} 集")
    return jsonify(ok=True, queued=queued)


@app.post("/api/hg/download-missing-all")
def hg_download_missing_all():
    """一键批量下载：所有短剧未下载的集数全部入队。"""
    now = datetime.now().isoformat(timespec="seconds")
    with db_lock, connect() as db:
        cursor = db.execute(
            """UPDATE hg_episodes SET state='queued', message='批量下载缺失', error='', retry_count=0, updated_at=?
               WHERE state='pending'""", (now,))
    queued = cursor.rowcount
    if queued:
        hg_worker_wakeup.set()
    write_app_log("info", "huangguo", "download-missing-all", f"批量下载缺失集：{queued} 集")
    return jsonify(ok=True, queued=queued)


@app.post("/api/hg/episodes/<episode_id>/retry-upload")
def hg_episode_retry_upload(episode_id):
    item = row("SELECT * FROM hg_episodes WHERE id=?", (episode_id,))
    if not item:
        return jsonify(error="剧集不存在"), 404
    if item["state"] != "completed":
        return jsonify(error="剧集尚未完成本地下载和刮削"), 400
    with db_lock, connect() as db:
        db.execute("UPDATE hg_episodes SET upload_state='retry', message='等待重新上传', error='', updated_at=? WHERE id=?",
                   (datetime.now().isoformat(timespec="seconds"), episode_id))
    hg_worker_wakeup.set()
    return jsonify(ok=True)


@app.post("/api/hg/series/<series_id>/complete")
def hg_series_complete(series_id):
    item = row("SELECT * FROM hg_series WHERE id=?", (series_id,))
    if not item:
        return jsonify(error="短剧不存在"), 404
    payload = request.get_json(silent=True) or {}
    completed = 1 if bool(payload.get("completed", True)) else 0
    now = datetime.now().isoformat(timespec="seconds")
    with db_lock, connect() as db:
        db.execute(
            "UPDATE hg_series SET completed=?, follow_enabled=? WHERE id=?",
            (completed, 0 if completed else 1, series_id)
        )
        queued = 0
        if completed:
            cursor = db.execute(
                """UPDATE hg_episodes SET upload_state='retry', message='全剧已完结，等待上传 115',
                          error='', updated_at=?
                   WHERE series_id=? AND state='completed'
                     AND upload_state IN ('pending','skipped','waiting_complete','failed')""",
                (now, series_id)
            )
            queued = cursor.rowcount
        else:
            cursor = db.execute(
                """UPDATE hg_episodes SET upload_state='waiting_complete', message='已恢复追更，等待全剧完结后上传',
                          updated_at=?
                   WHERE series_id=? AND state='completed'
                     AND upload_state IN ('pending','skipped','retry','failed')""",
                (now, series_id)
            )
            queued = cursor.rowcount
    if completed and queued:
        hg_worker_wakeup.set()
    write_app_log("info", "huangguo", "complete-series",
                  "黄果短剧已标记完结" if completed else "黄果短剧已恢复追更",
                  detail=f"upload_queue={queued}", target=series_id)
    return jsonify(ok=True, completed=completed, queued=queued, series=row("SELECT * FROM hg_series WHERE id=?", (series_id,)))


@app.post("/api/proxy-test")
def proxy_test():
    """代理连通检测：优先用请求体里未保存的代理值，否则用当前设置；访问百度测可达性。"""
    payload = request.get_json(silent=True) or {}
    proxy = str(payload.get("proxy", "") or "").strip() or str(get_settings().get("proxy", "") or "").strip()
    if not proxy:
        return jsonify(ok=False, message="未配置代理地址")
    opener = build_opener(ProxyHandler({"http": proxy, "https": proxy}))
    req = Request("https://www.baidu.com", headers={
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"})
    start = time.time()
    try:
        resp = opener.open(req, timeout=10)
        resp.read(64)
        ms = int((time.time() - start) * 1000)
        write_app_log("success", "network", "proxy-test", f"代理连通正常（{ms}ms）", detail=proxy)
        return jsonify(ok=True, message=f"代理连通正常（{ms}ms，HTTP {resp.status}）")
    except Exception as error:
        write_app_log("error", "network", "proxy-test", "代理连通失败", detail=f"{proxy} -> {error}")
        return jsonify(ok=False, message=f"代理连通失败：{str(error)[:160]}")


@app.delete("/api/hg/series/<series_id>")
def hg_series_delete(series_id):
    """删除追剧记录：集数状态、持久化封面与本地已下载的视频目录一并清理。"""
    item = row("SELECT * FROM hg_series WHERE id=?", (series_id,))
    if not item:
        return jsonify(error="短剧不存在"), 404
    removed_dirs = 0
    try:
        root = MEDIA_DIR / "黄果短剧"
        if root.exists():
            for meta_path in root.glob("*/metadata.json"):
                try:
                    if str(json.loads(meta_path.read_text(encoding="utf-8")).get("series_id", "")) == str(series_id):
                        shutil.rmtree(meta_path.parent, ignore_errors=True)
                        removed_dirs += 1
                except Exception:
                    continue
    except Exception:
        pass
    try:
        cover = _hg_cover_path(series_id)
        if cover.exists():
            cover.unlink()
    except OSError:
        pass
    with db_lock, connect() as db:
        db.execute("DELETE FROM hg_episodes WHERE series_id=?", (series_id,))
        db.execute("DELETE FROM hg_series WHERE id=?", (series_id,))
    write_app_log("warning", "huangguo", "delete-series", "已删除黄果短剧记录", detail=f"removed_dirs={removed_dirs}", target=series_id)
    return jsonify(ok=True, removed_dirs=removed_dirs)


@app.post("/api/cloud-tasks")
def create_cloud_task():
    payload = request.get_json(force=True)
    source_url = str(payload.get("source_url", "")).strip()
    if not source_url or urlparse(source_url).scheme not in ("http", "https", "magnet"):
        return jsonify(error="请输入有效的磁力链接或 HTTP 下载地址"), 400
    title = safe_name(str(payload.get("title", "")), "未命名影片")
    catalog = detect_catalog(str(payload.get("catalog", "")), title)
    task_id = str(uuid.uuid4())
    detail_url = str(payload.get("detail_url", "")).strip()
    try:
        settings = get_settings()
        dest_cid = str(settings.get("cloud_transfer_cid", "") or "").strip() \
            if settings.get("cloud_transfer_enabled") else ""
        reply = submit_115_task(task_id, source_url, title, catalog, detail_url, dest_cid=dest_cid)
    except Exception as error:
        write_app_log("error", "115", "create-cloud-task", "115 离线提交失败", detail=str(error), task_id=task_id, target=source_url)
        return jsonify(error=f"115 离线提交失败：{str(error)[:180]}"), 502
    result = create_cloud_record(task_id, source_url, title, catalog, detail_url, reply, dest_cid=dest_cid)
    write_app_log("success", "115", "create-cloud-task", f"已提交 115 离线：{catalog}", task_id=task_id, target=source_url)
    return jsonify(result), 201


def _media_scan_roots():
    roots = [MEDIA_DIR]
    try:
        transfer_path = str(get_settings().get("local_transfer_path", "") or "").strip()
        if transfer_path:
            transfer_root = Path(transfer_path)  # 与 organize_media 一致：允许任意挂载路径
            if transfer_root.exists() and transfer_root != MEDIA_DIR \
                    and not transfer_root.is_relative_to(MEDIA_DIR) \
                    and not MEDIA_DIR.is_relative_to(transfer_root):
                roots.append(transfer_root)
    except (ValueError, OSError):
        pass
    return roots


@app.get("/api/media/play")
def play_media_file():
    """本地文件流式播放（支持 Range，供媒体库 <video> 使用）"""
    raw = request.args.get("path", "")
    target = Path(raw)
    try:
        resolved = target.resolve()
    except (OSError, ValueError):
        return jsonify(error="路径无效"), 400
    if target.suffix.lower() not in MEDIA_EXTENSIONS:
        return jsonify(error="不支持的文件格式"), 400
    allowed = False
    for root in _media_scan_roots():
        try:
            if resolved.is_relative_to(root.resolve()):
                allowed = True
                break
        except (OSError, ValueError):
            continue
    if not (allowed and resolved.is_file()):
        return jsonify(error="文件不存在或不在媒体库范围内"), 404
    write_app_log("info", "media", "play-local", f"开始播放本地文件：{resolved.name}", target=str(resolved))
    return send_file(resolved, conditional=True)


@app.get("/api/media-files")
def list_media_files():
    query_text = request.args.get("q", "").lower().strip()
    files = []
    seen = set()
    for scan_root in _media_scan_roots():
        try:
            for item in scan_root.rglob("*"):
                if item.is_file() and item.suffix.lower() in MEDIA_EXTENSIONS:
                    relative = str(item.relative_to(scan_root))
                    key = str(item.resolve())
                    if key in seen:
                        continue
                    if not query_text or query_text in relative.lower() or query_text in str(item).lower():
                        seen.add(key)
                        files.append({"path": str(item), "name": relative, "size": item.stat().st_size})
                    if len(files) >= 5000:
                        break
        except OSError:
            continue
        if len(files) >= 5000:
            break
    return jsonify(sorted(files, key=lambda value: value["name"].lower()))


@app.get("/api/dirs")
def list_dirs():
    """列出 MEDIA_DIR 下的目录树，供前端路径选择器使用。"""
    base = request.args.get("base", "").strip() or str(MEDIA_DIR)
    pattern = request.args.get("pattern", "").strip()  # 如果传了，同时匹配该后缀的文件
    recursive = request.args.get("recursive", "1").strip() not in ("0", "false", "no")
    try:
        root = Path(base)
        if not root.is_absolute():
            root = MEDIA_DIR / base
        resolved_root = root.resolve()
        media_root = MEDIA_DIR.resolve()
        if media_root not in resolved_root.parents and resolved_root != media_root:
            return jsonify(error="路径必须位于 /media 下"), 400
        if not resolved_root.exists():
            return jsonify(error="目录不存在"), 404
    except Exception as error:
        return jsonify(error=f"路径解析失败：{error}"), 400

    items = []
    # 先加根自身
    items.append({"path": str(resolved_root), "name": "/media" if resolved_root == media_root else resolved_root.name, "type": "dir"})
    try:
        iterator = resolved_root.rglob("*") if recursive else resolved_root.iterdir()
        for item in iterator:
            try:
                resolved = item.resolve()
                if media_root not in resolved.parents and resolved != media_root:
                    continue
                if item.is_dir():
                    items.append({"path": str(item), "name": str(item.relative_to(resolved_root)), "type": "dir"})
                elif item.is_file() and pattern and item.suffix.lower() == pattern.lower():
                    items.append({"path": str(item), "name": str(item.relative_to(resolved_root)), "type": "file"})
                if len(items) >= 1000:
                    break
            except OSError:
                continue
    except OSError:
        pass
    return jsonify(items)


@app.post("/api/history-tasks")
def create_history_task():
    payload = request.get_json(force=True)
    try:
        source = resolve_media_path(str(payload.get("path", "")))
    except ValueError as error:
        return jsonify(error=str(error)), 400
    if not source.is_file() or source.suffix.lower() not in MEDIA_EXTENSIONS:
        return jsonify(error="请选择 NAS 成片目录中的视频文件"), 400
    settings = get_settings()
    catalog = detect_catalog(str(payload.get("catalog", "")), source.name)
    task_id = str(uuid.uuid4())
    with db_lock, connect() as db:
        db.execute("""INSERT INTO tasks(
            id,url,title,catalog,performer,threads,state,phase,progress,speed,size,output_path,
            metadata_found,log,created_at,started_at,finished_at,extra_args,organize_enabled,
            allow_duplicate,download_step,scrape_step,organize_step,task_type,source_path,downloaded_bytes
        ) VALUES(?, '',?,?,?,?, 'pending','等待处理历史文件',0,'-',?,'',NULL,'历史文件已加入队列\n',?,NULL,NULL,'',1,1,'skipped','pending','pending','history',?,?)""",
                   (task_id, safe_name(str(payload.get("title", "")), source.stem), catalog,
                    safe_name(str(payload.get("performer", "")), ""), settings["threads"],
                    format_size(source.stat().st_size), datetime.now().isoformat(timespec="microseconds"),
                    str(source), source.stat().st_size))
    worker_wakeup.set()
    return jsonify(id=task_id), 201


@app.post("/api/manual-scrape")
def create_manual_scrape_task():
    """手动刮削 strm 或视频文件，支持批量或单文件。"""
    payload = request.get_json(force=True)
    settings = get_settings()
    if not settings.get("manual_scrape_enabled", True):
        return jsonify(error="手动刮削管线已在服务设置中关闭"), 400
    paths = payload.get("paths") or [payload.get("path", "")]
    paths = [str(p).strip() for p in paths if str(p).strip()]
    if not paths:
        return jsonify(error="请选择至少一个文件或目录"), 400
    task_ids = []
    errors = []
    for raw_path in paths:
        try:
            source = resolve_media_path(raw_path)
        except ValueError as error:
            errors.append(f"{raw_path}: {error}")
            continue
        if source.is_dir():
            # 递归扫描目录下的 strm/video 文件
            for item in source.rglob("*"):
                if item.is_file() and item.suffix.lower() in VIDEO_EXTENSIONS:
                    tid = _insert_manual_scrape_task(item, settings, payload)
                    task_ids.append(tid)
            continue
        if not source.is_file() or source.suffix.lower() not in VIDEO_EXTENSIONS:
            errors.append(f"{raw_path}: 格式不支持（支持 mp4/mkv/ts/strm 等）")
            continue
        tid = _insert_manual_scrape_task(source, settings, payload)
        task_ids.append(tid)
    if not task_ids:
        return jsonify(error="未创建任何任务", details=errors), 400
    if errors:
        return jsonify(ids=task_ids, warnings=errors), 201
    worker_wakeup.set()
    return jsonify(ids=task_ids), 201


def _insert_manual_scrape_task(source, settings, payload):
    task_id = str(uuid.uuid4())
    catalog = detect_catalog(str(payload.get("catalog", "")), source.name)
    if not catalog:
        raise ValueError(f"无法从 {source.name} 识别番号，请重命名或手动指定")
    title = safe_name(str(payload.get("title", "")), source.stem)
    performer = safe_name(str(payload.get("performer", "")), "")
    with db_lock, connect() as db:
        db.execute("""INSERT INTO tasks(
            id,url,title,catalog,performer,threads,state,phase,progress,speed,size,output_path,
            metadata_found,log,created_at,started_at,finished_at,extra_args,organize_enabled,
            allow_duplicate,download_step,scrape_step,organize_step,task_type,source_path,downloaded_bytes
        ) VALUES(?, '',?,?,?,?, 'pending','等待手动刮削',0,'-',?,'',NULL,'手动刮削已加入队列\n',?,NULL,NULL,'',1,0,'skipped','pending','pending','manual_scrape',?,?)""",
                   (task_id, title, catalog, performer, settings["threads"],
                    format_size(source.stat().st_size), datetime.now().isoformat(timespec="microseconds"),
                    str(source), source.stat().st_size))
    return task_id


@app.post("/api/tasks/<task_id>/retry")
def retry_task(task_id):
    update_task(task_id, state="pending", phase="等待重试", progress=0, speed="-", eta="-",
                download_step="pending", scrape_step="pending", organize_step="pending",
                result_message="", mode="normal", finished_at=None)
    worker_wakeup.set()
    write_app_log("info", "task", "retry", "任务已加入重试队列", task_id=task_id, target=task_id)
    return jsonify(ok=True)


@app.post("/api/tasks/<task_id>/retry-scrape")
def retry_scrape(task_id):
    payload = request.get_json(silent=True) or {}
    task = rows("SELECT * FROM tasks WHERE id=?", (task_id,))
    if not task or not task[0]["output_path"]:
        return jsonify(error="找不到可重新刮削的结果文件"), 400
    source = str(payload.get("source", "")).strip()
    update_task(task_id, state="pending", phase="等待重新刮削", progress=0.80, mode="rescrape",
                source_used=source, scrape_step="pending", organize_step="pending", result_message="", finished_at=None)
    worker_wakeup.set()
    write_app_log("info", "task", "retry-scrape", "任务已加入重新刮削队列", task_id=task_id, target=task_id)
    return jsonify(ok=True)


@app.post("/api/tasks/<task_id>/priority")
def prioritize_task(task_id):
    update_task(task_id, priority=int(time.time()))
    worker_wakeup.set()
    return jsonify(ok=True)


@app.post("/api/tasks/<task_id>/cancel")
def cancel_task(task_id):
    global active_process
    task = rows("SELECT state FROM tasks WHERE id=?", (task_id,))
    if not task:
        return jsonify(error="任务不存在"), 404
    item = rows("SELECT * FROM tasks WHERE id=?", (task_id,))[0]
    if item["state"] == "running":
        with active_process_lock:
            if active_task_id == task_id and active_process:
                active_process.terminate()
    steps = {}
    for step in ("download_step", "scrape_step", "organize_step"):
        if item[step] == "running":
            steps[step] = "failed"
        elif item["state"] == "pending" and item[step] == "pending":
            steps[step] = "skipped"
    update_task(task_id, state="cancelled", phase="已取消", result_message="用户取消任务",
                finished_at=datetime.now().isoformat(timespec="seconds"), **steps)
    append_log(task_id, "任务已取消")
    write_app_log("warning", "task", "cancel", "任务已取消", task_id=task_id, target=task_id)
    return jsonify(ok=True)


@app.delete("/api/tasks/<task_id>")
def delete_task(task_id):
    with db_lock, connect() as db:
        db.execute("DELETE FROM tasks WHERE id=? AND state<>'running'", (task_id,))
    write_app_log("warning", "task", "delete", "任务记录已删除", task_id=task_id, target=task_id)
    return jsonify(ok=True)


@app.get("/api/scraper-sources")
def scraper_sources():
    return jsonify(rows("SELECT domain,enabled,position,health FROM scraper_sources ORDER BY position,domain"))


@app.put("/api/scraper-sources")
def update_scraper_sources():
    payload = request.get_json(force=True)
    sources = payload.get("sources", [])
    cleaned = []
    for index, source in enumerate(sources):
        domain = re.sub(r"^https?://", "", str(source.get("domain", "")).strip()).strip("/")
        if domain and re.fullmatch(r"[a-zA-Z0-9.-]+", domain):
            cleaned.append((domain, int(bool(source.get("enabled", True))), index,
                            str(source.get("health", "unchecked"))))
    if not cleaned:
        return jsonify(error="至少保留一个有效刮削源"), 400
    with db_lock, connect() as db:
        db.execute("DELETE FROM scraper_sources")
        db.executemany("INSERT INTO scraper_sources(domain,enabled,position,health) VALUES(?,?,?,?)", cleaned)
    return scraper_sources()


@app.post("/api/scraper-sources/check")
def check_scraper_source():
    domain = re.sub(r"^https?://", "", str(request.get_json(force=True).get("domain", "")).strip()).strip("/")
    if not re.fullmatch(r"[a-zA-Z0-9.-]+", domain):
        return jsonify(error="刮削源域名无效"), 400
    from curl_cffi import requests as curl_requests
    settings = get_settings()
    proxy = settings["proxy"] or None
    proxies = {"http": proxy, "https": proxy} if proxy else None
    health = "unavailable"
    detail = "连接失败"
    try:
        response = curl_requests.get(f"https://{domain}/", timeout=8, impersonate="chrome120",
                                     proxies=proxies, allow_redirects=True)
        if response.status_code < 500:
            health, detail = "available", f"HTTP {response.status_code}"
        else:
            detail = f"HTTP {response.status_code}"
    except Exception as error:
        detail = str(error)[:120]
    with db_lock, connect() as db:
        db.execute("UPDATE scraper_sources SET health=? WHERE domain=?", (health, domain))
    return jsonify(domain=domain, health=health, detail=detail)


initialize()
_ensure_site_session_secret()
# ---------- 数据维护：统计 / 备份 / 清理 ----------


def _dir_size(path):
    total = 0
    try:
        for item in Path(path).rglob("*"):
            try:
                if item.is_file():
                    total += item.stat().st_size
            except OSError:
                pass
    except Exception:
        pass
    return total


@app.get("/api/hg/maintenance/stats")
def hg_maintenance_stats():
    series_stats = row("SELECT COUNT(*) AS series FROM hg_series") or {}
    ep_stats = row("""SELECT COUNT(*) AS total,
                             SUM(CASE WHEN state='completed' THEN 1 ELSE 0 END) AS downloaded,
                             SUM(CASE WHEN state='failed' THEN 1 ELSE 0 END) AS failed,
                             SUM(CASE WHEN state IN ('queued','running') THEN 1 ELSE 0 END) AS active
                      FROM hg_episodes""") or {}
    backups = []
    backup_dir = DATA_DIR / "backups"
    if backup_dir.exists():
        for item in sorted(backup_dir.glob("*.db"), reverse=True):
            try:
                backups.append({"name": item.name, "size": item.stat().st_size,
                                "mtime": datetime.fromtimestamp(item.stat().st_mtime).isoformat(timespec="seconds")})
            except OSError:
                continue
    return jsonify(ok=True, series=series_stats.get("series", 0), episodes=ep_stats,
                   db_size=DB_PATH.stat().st_size if DB_PATH.exists() else 0,
                   media_size=_dir_size(MEDIA_DIR / "黄果短剧"),
                   work_size=_dir_size(WORK_DIR),
                   img_cache_size=_dir_size(DATA_DIR / "img-cache"),
                   backups=backups)


@app.post("/api/hg/maintenance/backup")
def hg_maintenance_backup():
    """SQLite 在线备份到 /data/backups（保留最近 10 份）。"""
    backup_dir = DATA_DIR / "backups"
    backup_dir.mkdir(parents=True, exist_ok=True)
    name = f"queue-{datetime.now().strftime('%Y%m%d-%H%M%S')}.db"
    dest = backup_dir / name
    src = sqlite3.connect(DB_PATH)
    dst = sqlite3.connect(dest)
    try:
        with dst:
            src.backup(dst)
    finally:
        dst.close()
        src.close()
    old = sorted(backup_dir.glob("*.db"))
    removed = 0
    while len(old) > 10:
        old.pop(0).unlink()
        removed += 1
    write_app_log("success", "maintenance", "backup", f"数据库备份完成：{name}（{dest.stat().st_size // 1024} KB）")
    return jsonify(ok=True, name=name, size=dest.stat().st_size, removed=removed)


@app.post("/api/hg/maintenance/cleanup")
def hg_maintenance_cleanup():
    """清理临时文件：work 目录下载分片（跳过 6 小时内的活跃项）+ 过期图片失败标记。"""
    freed = 0
    removed = 0
    now = time.time()
    if WORK_DIR.exists():
        for item in list(WORK_DIR.iterdir()):
            try:
                if now - item.stat().st_mtime < 6 * 3600:
                    continue
                size = _dir_size(item) if item.is_dir() else item.stat().st_size
                if item.is_dir():
                    shutil.rmtree(item, ignore_errors=True)
                else:
                    item.unlink()
                freed += size
                removed += 1
            except OSError:
                continue
    fail_removed = 0
    img_cache = DATA_DIR / "img-cache"
    if img_cache.exists():
        for item in img_cache.glob("*.fail"):
            try:
                if now - item.stat().st_mtime > 24 * 3600:
                    item.unlink()
                    fail_removed += 1
            except OSError:
                pass
    write_app_log("success", "maintenance", "cleanup",
                  f"临时文件清理完成：{removed} 项（{freed / 1024 / 1024:.1f} MB），过期失败缓存 {fail_removed} 个")
    return jsonify(ok=True, removed=removed, freed=freed, fail_removed=fail_removed)


@app.post("/api/hg/verify-library")
def hg_verify_library():
    """全库完整性校验：对比 DB 与磁盘，自动补齐缺失的 tvshow.nfo/metadata.json/每集 nfo/poster/strm；
    视频文件缺失仅报告不自动重下。纯磁盘操作（strm 生成需已配置服务访问地址）。"""
    fixed = {"metadata": 0, "poster": 0, "nfo": 0, "strm": 0}
    missing_files = []
    checked = 0
    settings = get_settings()
    base_url = str(settings.get("service_base_url", "") or "").strip()
    with _HG_METADATA_LOCK:
        for series in rows("SELECT * FROM hg_series ORDER BY title"):
            checked += 1
            series_dir = MEDIA_DIR / "黄果短剧" / safe_name(series["title"], series["id"])
            eps = rows("SELECT * FROM hg_episodes WHERE series_id=? ORDER BY ep", (series["id"],))
            completed_eps = [e for e in eps if e["state"] == "completed"]
            if not series_dir.exists():
                if completed_eps:
                    missing_files.append({"title": series["title"], "ep": 0, "message": "整个剧集目录缺失"})
                continue
            eps_meta = []
            for ep in eps:
                found = False
                for candidate in (ep["file_path"], str(series_dir / f"第{int(ep['ep']):03d}集.mp4"),
                                  str(series_dir / f"第{int(ep['ep']):03d}集.strm")):
                    media = Path(candidate or "")
                    if media.name and media.exists():
                        eps_meta.append({**ep, "file_path": str(media)})
                        found = True
                        break
                if not found and ep["state"] == "completed":
                    missing_files.append({"title": series["title"], "ep": int(ep["ep"]), "message": "DB 标记已完成但文件缺失"})
            try:
                before = {p.name for p in series_dir.iterdir()}
                _hg_render_series_files(series_dir, series, eps_meta)
                after = {p.name for p in series_dir.iterdir()}
                fixed["metadata"] += 1
                if "tvshow.nfo" not in before and "tvshow.nfo" in after:
                    fixed["nfo"] += 1
                if "poster.jpg" not in before and "poster.jpg" in after:
                    fixed["poster"] += 1
            except Exception:
                pass
            poster = series_dir / "poster.jpg"
            if not poster.exists():
                cover = _hg_cover_path(series["id"])
                if cover.exists():
                    try:
                        shutil.copy2(cover, poster)
                        fixed["poster"] += 1
                    except OSError:
                        pass
            if base_url:
                for ep in eps:
                    if ep["upload_state"] == "uploaded" and ep.get("pickcode"):
                        strm = series_dir / f"第{int(ep['ep']):03d}集.strm"
                        if not strm.exists():
                            try:
                                if _hg_make_episode_strm(series, ep, settings, ep["pickcode"], ep["upload_path"], 0):
                                    fixed["strm"] += 1
                            except Exception:
                                pass
    write_app_log("success", "maintenance", "verify-library",
                  f"全库校验完成：{checked} 部剧集，补齐 {sum(fixed.values())} 项，缺失文件 {len(missing_files)} 处")
    return jsonify(ok=True, checked=checked, fixed=fixed, missing=missing_files[:50], missing_count=len(missing_files))


# ---------- 全库自动扫描入库并下载 ----------
_HG_SCAN_LOCK = threading.Lock()
_HG_SCAN_STATE = {"running": False, "phase": "", "tabs": 0, "tabs_done": 0, "pages": 0, "pages_done": 0,
                  "page": 0, "found": 0, "added": 0, "skipped": 0, "failed": 0, "queued_episodes": 0,
                  "current": "", "started_at": "", "finished_at": "", "stop": False, "error": ""}


def _hg_scan_all_worker():
    state = _HG_SCAN_STATE
    try:
        tabs = [t for t in HG_TABS if "rank" not in t["id"]]
        state.update(running=True, phase="准备扫描", tabs=len(tabs), tabs_done=0,
                     pages=0, pages_done=0, page=0, found=0, added=0, skipped=0, failed=0,
                     queued_episodes=0, current="", started_at=datetime.now().isoformat(timespec="seconds"),
                     finished_at="", stop=False, error="")
        write_app_log("info", "huangguo", "scan-all", f"全库扫描启动：{len(tabs)} 个分类逐页扫描直到翻完（无页数上限，串行 + 延时防风控）")
        for tab in tabs:
            if state["stop"]:
                break
            page = 0
            seen_ids = set()
            while not state["stop"]:
                page += 1
                state["page"] = page
                state["phase"] = f"扫描 {tab['name']} 第 {page} 页"
                state["current"] = tab["name"]
                try:
                    # 不强制刷新：优先命中目录缓存，避免冷启动时镜像 failover 长时间阻塞扫描线程
                    items = _hg_catalog_items(tab["id"], page).get("items", [])
                except Exception as error:
                    state["failed"] += 1
                    write_app_log("warning", "huangguo", "scan-all", f"分类 {tab['name']} 第 {page} 页抓取失败，按翻完处理",
                                  detail=str(error)[:200])
                    break
                if not items:
                    write_app_log("info", "huangguo", "scan-all", f"分类 {tab['name']} 已翻到第 {page} 页无更多数据（共 {page - 1} 页）")
                    break
                # 翻页无新增（站点忽略页码/翻到末页回显同一批）→ 本分类翻完，防止死循环
                new_items = [item for item in items if str(item.get("id") or "") not in seen_ids]
                if not new_items:
                    write_app_log("info", "huangguo", "scan-all",
                                  f"分类 {tab['name']} 第 {page} 页与之前页内容重复，按翻完处理（共 {page - 1} 页）")
                    break
                seen_ids.update(str(item.get("id") or "") for item in new_items)
                state["found"] += len(new_items)
                for item in new_items:
                    if state["stop"]:
                        break
                    series_id = str(item.get("id") or "")
                    if not series_id or row("SELECT id FROM hg_series WHERE id=?", (series_id,)):
                        state["skipped"] += 1
                        continue
                    state["current"] = item.get("title") or series_id
                    try:
                        parsed = _hg_parse_series(item["detail_url"])
                        if row("SELECT id FROM hg_series WHERE id=?", (str(parsed["id"]),)):
                            state["skipped"] += 1
                            continue
                        _hg_upsert_series(parsed)
                        now = datetime.now().isoformat(timespec="seconds")
                        with db_lock, connect() as db:
                            cursor = db.execute(
                                """UPDATE hg_episodes SET state='queued', message='全库扫描入库', error='', retry_count=0, updated_at=?
                                   WHERE series_id=? AND state='pending'""", (now, str(parsed["id"])))
                        queued = cursor.rowcount
                        state["queued_episodes"] += queued
                        state["added"] += 1
                        if queued:
                            hg_worker_wakeup.set()
                        write_app_log("success", "huangguo", "scan-all",
                                      f"全库扫描入库：{parsed['title']}（{queued} 集待下载）", target=parsed["detail_url"])
                    except Exception as error:
                        state["failed"] += 1
                        write_app_log("warning", "huangguo", "scan-all", f"入库失败：{item.get('title') or series_id}",
                                      detail=str(error)[:200])
                    time.sleep(2)  # 串行 + 延时防风控
                time.sleep(3)
            state["tabs_done"] += 1
        state["phase"] = "已停止" if state["stop"] else "完成"
        write_app_log("success" if not state["stop"] else "warning", "huangguo", "scan-all",
                      f"全库扫描结束：新增 {state['added']} 部 / 跳过 {state['skipped']} 部 / 失败 {state['failed']} 部，入队 {state['queued_episodes']} 集")
    except Exception as error:
        state["error"] = str(error)[:300]
        state["phase"] = "异常终止"
        write_app_log("error", "huangguo", "scan-all", "全库扫描异常终止", detail=str(error))
    finally:
        state["running"] = False
        state["finished_at"] = datetime.now().isoformat(timespec="seconds")
        hg_worker_wakeup.set()


@app.post("/api/hg/scan-all")
def hg_scan_all_start():
    with _HG_SCAN_LOCK:
        if _HG_SCAN_STATE.get("running"):
            return jsonify(error="已有全库扫描在进行中"), 409
        _HG_SCAN_STATE.update({"stop": False, "error": "", "phase": "准备启动"})
        threading.Thread(target=_hg_scan_all_worker, daemon=True, name="hg-scan-all").start()
        return jsonify(ok=True)


@app.get("/api/hg/scan-all/status")
def hg_scan_all_status():
    state = dict(_HG_SCAN_STATE)
    state.pop("stop", None)
    return jsonify(state)


@app.post("/api/hg/scan-all/stop")
def hg_scan_all_stop():
    _HG_SCAN_STATE["stop"] = True
    return jsonify(ok=True)


threading.Thread(target=worker, daemon=True, name="download-worker").start()
for _hg_worker_index in range(_HG_WORKER_THREADS):
    threading.Thread(target=hg_worker, daemon=True, name=f"huangguo-worker-{_hg_worker_index}").start()
threading.Thread(target=hg_follow_scheduler, daemon=True, name="huangguo-follow").start()
# 启动预热：后台拉发布页最新镜像（网络未就绪时自动重试），后续黄果抓取失败切换镜像时无需现抓
threading.Thread(target=_hg_publish_warmup, daemon=True, name="hg-publish-warmup").start()
threading.Thread(target=watch_folder, daemon=True, name="watch-folder").start()
threading.Thread(target=poll_cloud_tasks, daemon=True, name="poll-cloud").start()
threading.Thread(target=auto_offline_scheduler, daemon=True, name="auto-offline-scheduler").start()


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8788, threaded=True)
