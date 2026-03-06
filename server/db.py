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

# 数据库文件放在 server 目录下
SERVER_DIR = Path(__file__).resolve().parent
DB_PATH = Path(__file__).resolve().parent / "data.db"


def get_conn() -> sqlite3.Connection:
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    """创建表（若不存在）。首次启动时若存在 users.json 则导入默认用户。"""
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
        """)
        conn.commit()
        # 若用户表为空且存在 users.json，则导入
        cur = conn.execute("SELECT COUNT(*) FROM users")
        if cur.fetchone()[0] == 0:
            _seed_users_from_json(conn)
    finally:
        conn.close()


def _seed_users_from_json(conn: sqlite3.Connection) -> None:
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


# ---------- 用户 ----------
def user_check_password(username: str, password_hash: str) -> bool:
    """校验用户名与密码 hash 是否匹配。"""
    conn = get_conn()
    try:
        cur = conn.execute(
            "SELECT 1 FROM users WHERE username = ? AND password_hash = ?",
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
