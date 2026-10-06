"""peermon: each VM checks its neighbor every few seconds and keeps a local history.

Endpoints
  GET /health    identity + clock; this is what the neighbor checks
  GET /neighbor  current view of the neighbor (what the client polls)
  GET /history   raw checks for the last N minutes (post-test timeline)
  GET /events    state changes: peer up/down, peer restarted, node started

Run with ONE uvicorn worker: the checker runs inside the app process.
"""
import asyncio
import os
import socket
import sqlite3
import threading
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone

import httpx
from fastapi import FastAPI, Query

# --- configuration (environment) -------------------------------------------
NODE_NAME = os.environ.get("NODE_NAME", socket.gethostname())
SITE = os.environ.get("SITE", "?")
PEER_NAME = os.environ["PEER_NAME"]
PEER_URL = os.environ["PEER_URL"].rstrip("/")
INTERVAL = float(os.environ.get("CHECK_INTERVAL", "5"))       # seconds between checks
TIMEOUT = float(os.environ.get("CHECK_TIMEOUT", "2"))         # per-check timeout, seconds
FAIL_THRESHOLD = int(os.environ.get("FAIL_THRESHOLD", "3"))   # consecutive failures = down
DB_PATH = os.environ.get("DB_PATH", "/var/lib/peermon/checks.db")
RETENTION_HOURS = int(os.environ.get("RETENTION_HOURS", "72"))

BOOT_ID = uuid.uuid4().hex[:12]          # changes every restart, so the peer can detect restarts
STARTED = datetime.now(timezone.utc)


def utcnow():
    return datetime.now(timezone.utc)


def iso(dt):
    return dt.isoformat(timespec="milliseconds") if dt else None


# --- storage ----------------------------------------------------------------
_lock = threading.RLock()
_db = sqlite3.connect(DB_PATH, check_same_thread=False, isolation_level=None)
_db.row_factory = sqlite3.Row
_db.executescript("""
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS checks (
  seq           INTEGER PRIMARY KEY AUTOINCREMENT,
  ts_utc        TEXT NOT NULL,      -- when the check was sent
  boot_id       TEXT NOT NULL,      -- this node's boot id
  ok            INTEGER NOT NULL,   -- 1 = neighbor answered correctly
  latency_ms    REAL,
  http_status   INTEGER,
  error         TEXT,               -- timeout | refused | connect_error | http_error | wrong_peer | ...
  peer_boot_id  TEXT,
  clock_skew_ms REAL                -- neighbor clock minus ours, estimated
);
CREATE INDEX IF NOT EXISTS checks_ts ON checks(ts_utc);
CREATE TABLE IF NOT EXISTS events (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  ts_utc  TEXT NOT NULL,
  event   TEXT NOT NULL,              -- node_started | peer_up | peer_down | peer_restarted
  detail  TEXT
);
""")

state = {
    "status": "unknown",          # unknown | up | down
    "since": None,
    "consecutive_failures": 0,
    "first_failure": None,        # start of the current failure streak
    "down_since": None,           # first failed check of the outage, once declared down
    "last_success": None,
    "last_failure": None,
    "last_check": None,
    "peer_boot_id": None,
}


def event(ts, name, detail=""):
    with _lock:
        _db.execute("INSERT INTO events (ts_utc, event, detail) VALUES (?, ?, ?)", (iso(ts), name, detail))


def record(ts, ok, latency, code, err, peer_boot, skew):
    with _lock:
        _db.execute(
            "INSERT INTO checks (ts_utc, boot_id, ok, latency_ms, http_status, error, peer_boot_id, clock_skew_ms) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (iso(ts), BOOT_ID, int(ok), latency, code, err, peer_boot,
             None if skew is None else round(skew, 1)))
        s = state
        s["last_check"] = {"ts_utc": iso(ts), "ok": ok, "latency_ms": latency, "error": err}

        if ok:
            if s["peer_boot_id"] and peer_boot != s["peer_boot_id"]:
                event(ts, "peer_restarted", f"boot_id {s['peer_boot_id']} -> {peer_boot}")
            s["peer_boot_id"] = peer_boot
            s["last_success"] = ts
            s["consecutive_failures"] = 0
            s["first_failure"] = None
            if s["status"] != "up":
                detail = f"from {s['status']}"
                if s["status"] == "down" and s["down_since"]:
                    outage = (ts - s["down_since"]).total_seconds()
                    detail += f"; outage {outage:.1f}s since first failed check {iso(s['down_since'])}"
                s["status"], s["since"], s["down_since"] = "up", ts, None
                event(ts, "peer_up", detail)
        else:
            s["last_failure"] = ts
            s["consecutive_failures"] += 1
            if s["first_failure"] is None:
                s["first_failure"] = ts
            if s["consecutive_failures"] >= FAIL_THRESHOLD and s["status"] != "down":
                event(ts, "peer_down",
                      f"from {s['status']}; {err} x{s['consecutive_failures']}; "
                      f"first failed check {iso(s['first_failure'])}")
                s["status"], s["since"], s["down_since"] = "down", ts, s["first_failure"]


def purge():
    cutoff = iso(utcnow() - timedelta(hours=RETENTION_HOURS))
    with _lock:
        _db.execute("DELETE FROM checks WHERE ts_utc < ?", (cutoff,))
        _db.execute("DELETE FROM events WHERE ts_utc < ?", (cutoff,))


# --- the checker ------------------------------------------------------------
def _is_refused(exc):
    """True if the connection was actively refused (host up, nothing listening)."""
    seen = set()
    while exc is not None and id(exc) not in seen:
        seen.add(id(exc))
        if isinstance(exc, ConnectionRefusedError) or getattr(exc, "errno", None) == 111 \
                or "refused" in str(exc).lower():
            return True
        exc = exc.__cause__ or exc.__context__
    return False


async def check_once(client):
    sent, t0 = utcnow(), time.perf_counter()
    ok, code, err, peer_boot, skew = False, None, None, None, None
    try:
        r = await client.get(f"{PEER_URL}/health", timeout=TIMEOUT)
        code = r.status_code
        if r.status_code != 200:
            err = "http_error"
        else:
            body = r.json()
            if body.get("node") != PEER_NAME:
                err = "wrong_peer"               # something answered, but not our neighbor
            else:
                ok = True
                peer_boot = body.get("boot_id")
                received = utcnow()
                midpoint = sent + (received - sent) / 2
                skew = (datetime.fromisoformat(body["now_utc"]) - midpoint).total_seconds() * 1000
    except httpx.TimeoutException:
        err = "timeout"                          # VM or network gone (no answer at all)
    except httpx.ConnectError as e:
        err = "refused" if _is_refused(e) else "connect_error"   # refused = VM up, app down
    except Exception as e:                       # noqa: BLE001 - record anything unexpected
        err = type(e).__name__
    latency = round((time.perf_counter() - t0) * 1000, 1)
    record(sent, ok, latency, code, err, peer_boot, skew)


async def checker():
    # No keep-alive: every check opens a fresh TCP connection, like a real client would.
    limits = httpx.Limits(max_keepalive_connections=0)
    async with httpx.AsyncClient(limits=limits) as client:
        n = 0
        while True:
            start = time.monotonic()
            await check_once(client)
            n += 1
            if n % 720 == 0:                     # about hourly at a 5 s interval
                purge()
            await asyncio.sleep(max(0.0, INTERVAL - (time.monotonic() - start)))


@asynccontextmanager
async def lifespan(app):
    event(utcnow(), "node_started", f"boot_id {BOOT_ID}; peer {PEER_NAME} at {PEER_URL}")
    task = asyncio.create_task(checker())
    yield
    task.cancel()


app = FastAPI(title="peermon", lifespan=lifespan)


# --- API --------------------------------------------------------------------
@app.get("/health")
def health():
    return {"node": NODE_NAME, "site": SITE, "boot_id": BOOT_ID,
            "started_utc": iso(STARTED), "now_utc": iso(utcnow())}


@app.get("/neighbor")
def neighbor():
    with _lock:
        s = dict(state)
    return {
        "node": NODE_NAME, "site": SITE, "boot_id": BOOT_ID,
        "peer": PEER_NAME, "peer_url": PEER_URL,
        "peer_status": s["status"],
        "status_since_utc": iso(s["since"]),
        "consecutive_failures": s["consecutive_failures"],
        "last_success_utc": iso(s["last_success"]),
        "last_failure_utc": iso(s["last_failure"]),
        "last_check": s["last_check"],
        "check_interval_s": INTERVAL,
        "fail_threshold": FAIL_THRESHOLD,
        "now_utc": iso(utcnow()),
    }


@app.get("/history")
def history(minutes: int = Query(30, ge=1, le=10080), limit: int = Query(5000, ge=1, le=50000)):
    cutoff = iso(utcnow() - timedelta(minutes=minutes))
    with _lock:
        rows = _db.execute("SELECT * FROM checks WHERE ts_utc >= ? ORDER BY seq LIMIT ?",
                           (cutoff, limit)).fetchall()
    return {"node": NODE_NAME, "peer": PEER_NAME, "checks": [dict(r) for r in rows]}


@app.get("/events")
def events(minutes: int = Query(1440, ge=1, le=10080)):
    cutoff = iso(utcnow() - timedelta(minutes=minutes))
    with _lock:
        rows = _db.execute("SELECT * FROM events WHERE ts_utc >= ? ORDER BY id", (cutoff,)).fetchall()
    return {"node": NODE_NAME, "peer": PEER_NAME, "events": [dict(r) for r in rows]}
