# -*- coding: utf-8 -*-
"""使用 sqlite3 做用户、配置、日志持久化。标准库优先；无 _sqlite3 时用 pysqlite3。"""
from __future__ import annotations

import json

try:
    import sqlite3
except ModuleNotFoundError as e:
    if "_sqlite3" in str(e):
        import pysqlite3 as sqlite3  # type: ignore[no-redef]  # 无 _sqlite3 时用 pysqlite3
    else:
        raise
from pathlib import Path
from typing import Any

# 数据库文件放在 server/sqlite/ 目录下
SERVER_DIR = Path(__file__).resolve().parent
DB_DIR = SERVER_DIR / "sqlite"
DB_PATH = DB_DIR / "tradingbots.db"


def get_conn() -> sqlite3.Connection:
    DB_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    return conn


def _run_user_migrations(conn: sqlite3.Connection) -> None:
    """执行 server/migrations/add_user_*.sql，将用户同步到当前数据库（含 AWS 部署）。"""
    migrations_dir = SERVER_DIR / "migrations"
    if not migrations_dir.is_dir():
        return
    for p in sorted(migrations_dir.glob("add_user_*.sql")):
        try:
            conn.executescript(p.read_text(encoding="utf-8"))
            conn.commit()
        except Exception:
            pass


def _seed_users_from_json(conn: sqlite3.Connection) -> None:
    """仅当 users 表为空时从 server/users.json 一次性导入；正式用户数据以 DB 为准。"""
    users_json = SERVER_DIR / "users.json"
    if not users_json.exists():
        return
    try:
        data = json.loads(users_json.read_text(encoding="utf-8"))
        if not isinstance(data, list):
            return
        for u in data:
            username = u.get("username")
            password_hash = u.get("password_hash")
            if username and password_hash:
                conn.execute(
                    "INSERT OR IGNORE INTO users (username, password_hash) VALUES (?, ?)",
                    (username.strip(), password_hash),
                )
        conn.commit()
    except Exception:
        pass


def init_db() -> None:
    """创建表（若不存在）。首次启动时若 users 表为空且存在 users.json 则一次性导入默认用户；之后用户管理以 DB 为准。"""
    conn = get_conn()
    try:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT UNIQUE NOT NULL,
                password_hash TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE TABLE IF NOT EXISTS config (
                key TEXT PRIMARY KEY,
                value TEXT,
                updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE TABLE IF NOT EXISTS logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                level TEXT NOT NULL,
                message TEXT NOT NULL,
                source TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                extra TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_logs_created ON logs(created_at);
            CREATE INDEX IF NOT EXISTS idx_logs_level ON logs(level);
            CREATE TABLE IF NOT EXISTS bot_profit_snapshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                bot_id TEXT NOT NULL,
                snapshot_at TEXT NOT NULL,
                initial_balance REAL NOT NULL DEFAULT 0,
                current_balance REAL NOT NULL DEFAULT 0,
                equity_usdt REAL NOT NULL DEFAULT 0,
                profit_amount REAL NOT NULL DEFAULT 0,
                profit_percent REAL NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_bot_profit_bot_id ON bot_profit_snapshots(bot_id);
            CREATE INDEX IF NOT EXISTS idx_bot_profit_snapshot_at ON bot_profit_snapshots(snapshot_at);
            CREATE TABLE IF NOT EXISTS strategy_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                bot_id TEXT NOT NULL,
                event_type TEXT NOT NULL,
                trigger_type TEXT NOT NULL,
                username TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_strategy_events_bot_id ON strategy_events(bot_id);
            CREATE INDEX IF NOT EXISTS idx_strategy_events_created ON strategy_events(created_at);
            CREATE TABLE IF NOT EXISTS bot_seasons (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                bot_id TEXT NOT NULL,
                started_at TEXT NOT NULL,
                stopped_at TEXT,
                initial_balance REAL NOT NULL DEFAULT 0,
                final_balance REAL,
                profit_amount REAL,
                profit_percent REAL,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_bot_seasons_bot_id ON bot_seasons(bot_id);
            CREATE INDEX IF NOT EXISTS idx_bot_seasons_started ON bot_seasons(started_at);
        """)
        conn.commit()
        # 若用户表为空且存在 users.json，则导入
        cur = conn.execute("SELECT COUNT(*) FROM users")
        if cur.fetchone()[0] == 0:
            _seed_users_from_json(conn)
        # 执行用户同步迁移（add_user_*.sql），保证本地与 AWS 等环境用户一致
        _run_user_migrations(conn)
    finally:
        conn.close()


# ---------- 用户 ----------
def user_check_password(username: str, password_hash: str) -> bool:
    """校验用户名与密码 hash 是否匹配；用户名大小写不敏感。"""
    conn = get_conn()
    try:
        cur = conn.execute(
            "SELECT 1 FROM users WHERE LOWER(TRIM(username)) = LOWER(?) AND password_hash = ?",
            (username.strip(), password_hash),
        )
        return cur.fetchone() is not None
    finally:
        conn.close()


def user_create(username: str, password_hash: str) -> bool:
    """创建用户，成功返回 True，用户名已存在返回 False。"""
    conn = get_conn()
    try:
        conn.execute(
            "INSERT INTO users (username, password_hash) VALUES (?, ?)",
            (username.strip(), password_hash),
        )
        conn.commit()
        return True
    except sqlite3.IntegrityError:
        return False
    finally:
        conn.close()


def user_list() -> list[dict]:
    """返回用户列表（不含 password_hash）。"""
    conn = get_conn()
    try:
        cur = conn.execute(
            "SELECT id, username, created_at FROM users ORDER BY id"
        )
        return [
            {"id": r[0], "username": r[1], "created_at": r[2]}
            for r in cur.fetchall()
        ]
    finally:
        conn.close()


# ---------- 配置 ----------
def config_get(key: str, default: Any = None) -> Any:
    """读取配置项，返回字符串或 default。若 value 为 JSON 则自动 parse。"""
    conn = get_conn()
    try:
        cur = conn.execute("SELECT value FROM config WHERE key = ?", (key,))
        row = cur.fetchone()
        if row is None:
            return default
        val = row[0]
        if val is None:
            return default
        try:
            return json.loads(val)
        except (TypeError, json.JSONDecodeError):
            return val
    finally:
        conn.close()


def config_set(key: str, value: Any) -> None:
    """写入配置项，value 可为 str/int/float/bool/dict/list，会序列化为 JSON。"""
    conn = get_conn()
    try:
        if isinstance(value, (dict, list)):
            val_str = json.dumps(value, ensure_ascii=False)
        else:
            val_str = str(value)
        conn.execute(
            "INSERT INTO config (key, value, updated_at) VALUES (?, ?, datetime('now')) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = datetime('now')",
            (key, val_str),
        )
        conn.commit()
    finally:
        conn.close()


# ---------- 日志 ----------
def log_insert(
    level: str, message: str, source: str | None = None, extra: dict | None = None
) -> None:
    """写入一条日志。level 建议: INFO, WARN, ERROR。"""
    conn = get_conn()
    try:
        extra_str = json.dumps(extra, ensure_ascii=False) if extra else None
        conn.execute(
            "INSERT INTO logs (level, message, source, extra) VALUES (?, ?, ?, ?)",
            (level, message, source or "app", extra_str),
        )
        conn.commit()
    finally:
        conn.close()


def log_query(
    limit: int = 100, level: str | None = None, source: str | None = None
) -> list[dict]:
    """查询最近日志，按 id 降序。"""
    conn = get_conn()
    try:
        sql = (
            "SELECT id, level, message, source, created_at, extra FROM logs WHERE 1=1"
        )
        params: list = []
        if level:
            sql += " AND level = ?"
            params.append(level)
        if source:
            sql += " AND source = ?"
            params.append(source)
        sql += " ORDER BY id DESC LIMIT ?"
        params.append(limit)
        cur = conn.execute(sql, params)
        rows = []
        for r in cur.fetchall():
            extra = None
            if r[5]:
                try:
                    extra = json.loads(r[5])
                except (TypeError, json.JSONDecodeError):
                    extra = r[5]
            rows.append({
                "id": r[0],
                "level": r[1],
                "message": r[2],
                "source": r[3],
                "created_at": r[4],
                "extra": extra,
            })
        return rows
    finally:
        conn.close()


# ---------- 机器人盈利快照（参考 Qtraderweb，定时写入） ----------
def bot_profit_insert(
    bot_id: str,
    snapshot_at: str,
    initial_balance: float = 0,
    current_balance: float = 0,
    equity_usdt: float = 0,
    profit_amount: float = 0,
    profit_percent: float = 0,
) -> None:
    """写入一条机器人盈利快照。snapshot_at 建议 ISO 格式。"""
    conn = get_conn()
    try:
        conn.execute(
            """INSERT INTO bot_profit_snapshots
               (bot_id, snapshot_at, initial_balance, current_balance, equity_usdt, profit_amount, profit_percent)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (bot_id, snapshot_at, initial_balance, current_balance, equity_usdt, profit_amount, profit_percent),
        )
        conn.commit()
    finally:
        conn.close()


def bot_profit_query_by_bot(bot_id: str, limit: int = 500) -> list[dict]:
    """按 bot_id 查询盈利快照，按 snapshot_at 升序。"""
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT id, bot_id, snapshot_at, initial_balance, current_balance, equity_usdt,
                      profit_amount, profit_percent, created_at
               FROM bot_profit_snapshots WHERE bot_id = ? ORDER BY snapshot_at ASC LIMIT ?""",
            (bot_id, limit),
        )
        return [
            {
                "id": r[0],
                "bot_id": r[1],
                "snapshot_at": r[2],
                "initial_balance": r[3],
                "current_balance": r[4],
                "equity_usdt": r[5],
                "profit_amount": r[6],
                "profit_percent": r[7],
                "created_at": r[8],
            }
            for r in cur.fetchall()
        ]
    finally:
        conn.close()


def bot_profit_latest_by_bot(bot_id: str) -> dict | None:
    """取该 bot 最近一条盈利快照。"""
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT id, bot_id, snapshot_at, initial_balance, current_balance, equity_usdt,
                      profit_amount, profit_percent, created_at
               FROM bot_profit_snapshots WHERE bot_id = ? ORDER BY snapshot_at DESC LIMIT 1""",
            (bot_id,),
        )
        r = cur.fetchone()
        if not r:
            return None
        return {
            "id": r[0],
            "bot_id": r[1],
            "snapshot_at": r[2],
            "initial_balance": r[3],
            "current_balance": r[4],
            "equity_usdt": r[5],
            "profit_amount": r[6],
            "profit_percent": r[7],
            "created_at": r[8],
        }
    finally:
        conn.close()


# ---------- 策略启停事件（手动/自动、时间、类型） ----------
def strategy_event_insert(
    bot_id: str,
    event_type: str,
    trigger_type: str,
    username: str | None = None,
) -> None:
    """记录策略启停事件。event_type: start|stop|restart，trigger_type: manual|auto。"""
    conn = get_conn()
    try:
        conn.execute(
            """INSERT INTO strategy_events (bot_id, event_type, trigger_type, username)
               VALUES (?, ?, ?, ?)""",
            (bot_id, event_type, trigger_type, username or None),
        )
        conn.commit()
    finally:
        conn.close()


def strategy_event_query(bot_id: str | None = None, limit: int = 200) -> list[dict]:
    """查询策略事件，可选按 bot_id 过滤，按 created_at 降序。"""
    conn = get_conn()
    try:
        if bot_id:
            cur = conn.execute(
                """SELECT id, bot_id, event_type, trigger_type, username, created_at
                   FROM strategy_events WHERE bot_id = ? ORDER BY created_at DESC LIMIT ?""",
                (bot_id, limit),
            )
        else:
            cur = conn.execute(
                """SELECT id, bot_id, event_type, trigger_type, username, created_at
                   FROM strategy_events ORDER BY created_at DESC LIMIT ?""",
                (limit,),
            )
        return [
            {
                "id": r[0],
                "bot_id": r[1],
                "event_type": r[2],
                "trigger_type": r[3],
                "username": r[4],
                "created_at": r[5],
            }
            for r in cur.fetchall()
        ]
    finally:
        conn.close()


# ---------- 赛季（机器人启停周期：初期金额、盈利、盈利率） ----------
def bot_season_insert(
    bot_id: str,
    started_at: str,
    initial_balance: float = 0,
) -> int:
    """机器人启动时插入一条赛季记录，返回 id。"""
    conn = get_conn()
    try:
        cur = conn.execute(
            """INSERT INTO bot_seasons (bot_id, started_at, initial_balance)
               VALUES (?, ?, ?)""",
            (bot_id, started_at, initial_balance),
        )
        conn.commit()
        return cur.lastrowid or 0
    finally:
        conn.close()


def bot_season_update_on_stop(
    bot_id: str,
    stopped_at: str,
    final_balance: float,
) -> None:
    """机器人停止时更新最近一条未结束的赛季。"""
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT id, initial_balance FROM bot_seasons
               WHERE bot_id = ? AND stopped_at IS NULL ORDER BY started_at DESC LIMIT 1""",
            (bot_id,),
        )
        row = cur.fetchone()
        if not row:
            return
        sid, initial = row[0], float(row[1])
        profit_amount = final_balance - initial
        profit_percent = (profit_amount / initial * 100.0) if initial else 0.0
        conn.execute(
            """UPDATE bot_seasons SET stopped_at = ?, final_balance = ?, profit_amount = ?, profit_percent = ?
               WHERE id = ?""",
            (stopped_at, final_balance, profit_amount, profit_percent, sid),
        )
        conn.commit()
    finally:
        conn.close()


def bot_season_list_by_bot(bot_id: str, limit: int = 50) -> list[dict]:
    """按 bot_id 查询赛季列表，按 started_at 降序。"""
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT id, bot_id, started_at, stopped_at, initial_balance, final_balance,
                      profit_amount, profit_percent, created_at
               FROM bot_seasons WHERE bot_id = ? ORDER BY started_at DESC LIMIT ?""",
            (bot_id, limit),
        )
        return [
            {
                "id": r[0],
                "bot_id": r[1],
                "started_at": r[2],
                "stopped_at": r[3],
                "initial_balance": r[4],
                "final_balance": r[5],
                "profit_amount": r[6],
                "profit_percent": r[7],
                "created_at": r[8],
            }
            for r in cur.fetchall()
        ]
    finally:
        conn.close()
