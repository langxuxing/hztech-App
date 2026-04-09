# -*- coding: utf-8 -*-
"""
数据库后端选择：默认 PostgreSQL，或 SQLite。

配置文件（可选）：baasapi/database_config.json
  - 复制 database_config.example.json 为 database_config.json 后修改
  - HZTECH_DB_CONFIG=/绝对或相对路径.json 覆盖配置文件路径（相对 baasapi 目录）
  - 仅当对应环境变量未设置时写入配置（环境变量优先）

环境变量（任选其一组合）：
- HZTECH_DB_PROFILE=default|test|…  加载配置里 profiles.<name>（在顶层键之后合并）
- HZTECH_DB_BACKEND=auto|sqlite|postgresql  未设置时默认为 postgresql
- auto：若 DATABASE_URL 为 postgresql/postgres 开头，或设置了 POSTGRES_HOST / POSTGRES_USER，则用 PostgreSQL；否则 SQLite
- DATABASE_URL=postgresql://…
- 或分项：POSTGRES_HOST、POSTGRES_PORT、POSTGRES_DB、POSTGRES_USER、POSTGRES_PASSWORD
- HZTECH_POSTGRES_SCHEMA=flutterapp（默认 flutterapp，连接后自动 CREATE SCHEMA 并 SET search_path）
- HZTECH_SQLITE_DB_PATH=绝对路径 或相对 baasapi 的 sqlite 文件路径（配置项 sqlite_path）

依赖：PostgreSQL 模式需安装 psycopg2-binary。
"""
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

try:
    import psycopg2
except ImportError:
    psycopg2 = None  # type: ignore[misc, assignment]

# PostgreSQL 模式下不加载 sqlite（EC2 上 pyenv Python 常缺 _sqlite3）；SQLite 模式再加载，与 db.py 相同回退。
sqlite3: Any = None


def _load_sqlite3() -> Any:
    """导入 sqlite3；无内置 _sqlite3 时使用 pysqlite3（与 baasapi/db.py 一致）。"""
    global sqlite3
    if sqlite3 is not None:
        return sqlite3
    try:
        import sqlite3 as _m
    except ModuleNotFoundError as e:
        if "_sqlite3" in str(e):
            import pysqlite3 as _m  # type: ignore[no-redef, misc]
        else:
            raise
    sqlite3 = _m
    return _m


SERVER_DIR = Path(__file__).resolve().parent


def _config_file_path() -> Path | None:
    raw = (os.environ.get("HZTECH_DB_CONFIG") or "").strip()
    if raw:
        p = Path(raw)
        cand = p if p.is_absolute() else (SERVER_DIR / p)
        return cand if cand.is_file() else None
    default = SERVER_DIR / "database_config.json"
    return default if default.is_file() else None


def _setdefault_env(key: str, val: Any) -> None:
    if val is None:
        return
    if isinstance(val, bool):
        s = "1" if val else "0"
    elif isinstance(val, int):
        s = str(val)
    elif isinstance(val, float):
        s = str(int(val)) if val == int(val) else str(val)
    else:
        s = str(val).strip()
    if not s:
        return
    cur = os.environ.get(key)
    if cur is None or str(cur).strip() == "":
        os.environ[key] = s


def _apply_db_mapping(mapping: dict[str, Any]) -> None:
    if mapping.get("backend") is not None:
        _setdefault_env("HZTECH_DB_BACKEND", mapping["backend"])
    if mapping.get("database_url") is not None:
        _setdefault_env("DATABASE_URL", mapping["database_url"])
    pairs = [
        ("postgres_host", "POSTGRES_HOST"),
        ("postgres_port", "POSTGRES_PORT"),
        ("postgres_db", "POSTGRES_DB"),
        ("postgres_user", "POSTGRES_USER"),
        ("postgres_password", "POSTGRES_PASSWORD"),
        ("postgres_schema", "HZTECH_POSTGRES_SCHEMA"),
    ]
    for ck, ek in pairs:
        if mapping.get(ck) is not None:
            _setdefault_env(ek, mapping[ck])
    sp = mapping.get("sqlite_path")
    if sp:
        p = Path(str(sp))
        full = str(p.resolve()) if p.is_absolute() else str((SERVER_DIR / p).resolve())
        _setdefault_env("HZTECH_SQLITE_DB_PATH", full)


def _apply_database_config_file() -> None:
    path = _config_file_path()
    if path is None:
        return
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        return
    if not isinstance(data, dict):
        return
    base = {k: v for k, v in data.items() if k != "profiles"}
    _apply_db_mapping(base)
    profile = (os.environ.get("HZTECH_DB_PROFILE") or "default").strip() or "default"
    if profile == "default":
        return
    profiles = data.get("profiles")
    if not isinstance(profiles, dict):
        return
    section = profiles.get(profile)
    if isinstance(section, dict):
        _apply_db_mapping(section)


_apply_database_config_file()


def _sqlite_db_path() -> Path:
    raw = (os.environ.get("HZTECH_SQLITE_DB_PATH") or "").strip()
    if raw:
        p = Path(raw)
        return p if p.is_absolute() else (SERVER_DIR / p)
    return SERVER_DIR / "sqlite" / "tradingbots.db"


DB_PATH = _sqlite_db_path()
DB_DIR = DB_PATH.parent


def _auto_backend() -> str:
    url = (os.environ.get("DATABASE_URL") or "").strip().lower()
    if url.startswith("postgresql://") or url.startswith("postgres://"):
        return "postgresql"
    if (os.environ.get("POSTGRES_HOST") or "").strip():
        return "postgresql"
    if (os.environ.get("POSTGRES_USER") or "").strip():
        return "postgresql"
    return "sqlite"


def _resolve_backend() -> str:
    raw = (os.environ.get("HZTECH_DB_BACKEND") or "postgresql").strip().lower()
    if raw in ("postgres", "postgresql", "pg"):
        return "postgresql"
    if raw == "sqlite":
        return "sqlite"
    if raw == "auto":
        return _auto_backend()
    return "postgresql"


BACKEND = _resolve_backend()
IS_POSTGRES = BACKEND == "postgresql"


def _resolve_pg_schema() -> str:
    raw = (os.environ.get("HZTECH_POSTGRES_SCHEMA") or "flutterapp").strip()
    if not raw:
        return "flutterapp"
    first = raw[0]
    if not (first.isalpha() or first == "_"):
        return "flutterapp"
    for ch in raw:
        if not (ch.isalnum() or ch == "_"):
            return "flutterapp"
    return raw


PG_SCHEMA = _resolve_pg_schema()

if IS_POSTGRES:
    if psycopg2 is not None:
        DB_INTEGRITY_ERRORS = (psycopg2.IntegrityError,)
        DB_OPERATIONAL_ERRORS = (psycopg2.OperationalError,)
    else:
        DB_INTEGRITY_ERRORS = ()
        DB_OPERATIONAL_ERRORS = ()
else:
    _load_sqlite3()
    assert sqlite3 is not None
    if psycopg2 is not None:
        DB_INTEGRITY_ERRORS = (
            sqlite3.IntegrityError,
            psycopg2.IntegrityError,
        )
        DB_OPERATIONAL_ERRORS = (
            sqlite3.OperationalError,
            psycopg2.OperationalError,
        )
    else:
        DB_INTEGRITY_ERRORS = (sqlite3.IntegrityError,)
        DB_OPERATIONAL_ERRORS = (sqlite3.OperationalError,)


def adapt_sql_pg(sql: str) -> str:
    """SQLite 占位符与函数转为 PostgreSQL。"""
    s = sql.replace("datetime('now')", "CURRENT_TIMESTAMP")
    if "?" in s:
        s = s.replace("?", "%s")
    return s


class _PgCursor:
    __slots__ = ("_cur",)

    def __init__(self, cur: Any) -> None:
        self._cur = cur

    def fetchone(self) -> Any:
        return self._cur.fetchone()

    def fetchall(self) -> Any:
        return self._cur.fetchall()

    @property
    def rowcount(self) -> int:
        n = self._cur.rowcount
        return int(n) if n is not None else -1

    @property
    def lastrowid(self) -> int:
        return 0


class PgConnectionWrapper:
    """模拟 sqlite3.Connection 的 execute/commit/close，便于 db.py 共用。"""

    __slots__ = ("_raw",)

    def __init__(self, raw: Any) -> None:
        self._raw = raw

    def execute(self, sql: str, parameters: Any = None) -> _PgCursor:
        sql2 = adapt_sql_pg(sql)
        cur = self._raw.cursor()
        if parameters is not None:
            cur.execute(sql2, parameters)
        else:
            cur.execute(sql2)
        return _PgCursor(cur)

    def commit(self) -> None:
        self._raw.commit()

    def rollback(self) -> None:
        self._raw.rollback()

    def close(self) -> None:
        self._raw.close()


def _pg_apply_schema_search_path(raw: Any) -> None:
    """建 schema（若有权限）并设置 search_path。云库常见仅授予 schema 内权限，无库级 CREATE。"""
    from psycopg2 import errors as pg_errors

    schema_esc = PG_SCHEMA.replace('"', '""')
    cur = raw.cursor()
    try:
        try:
            cur.execute(f'CREATE SCHEMA IF NOT EXISTS "{schema_esc}"')
        except pg_errors.InsufficientPrivilege:
            raw.rollback()
        cur.execute(f'SET search_path TO "{schema_esc}", public')
        raw.commit()
    finally:
        cur.close()


def _connect_postgresql() -> PgConnectionWrapper:
    if psycopg2 is None:
        raise RuntimeError(
            "已选择 PostgreSQL 但未安装 psycopg2-binary，请执行: pip install psycopg2-binary"
        )
    url = (os.environ.get("DATABASE_URL") or "").strip()
    if url:
        raw = psycopg2.connect(url)
        _pg_apply_schema_search_path(raw)
        return PgConnectionWrapper(raw)
    host = (os.environ.get("POSTGRES_HOST") or "localhost").strip()
    port = int((os.environ.get("POSTGRES_PORT") or "5432").strip())
    dbn = (os.environ.get("POSTGRES_DB") or "hztech").strip()
    user = (os.environ.get("POSTGRES_USER") or "hztech").strip()
    password = (os.environ.get("POSTGRES_PASSWORD") or "Alpha").strip()
    raw = psycopg2.connect(
        host=host,
        port=port,
        dbname=dbn,
        user=user,
        password=password,
    )
    _pg_apply_schema_search_path(raw)
    return PgConnectionWrapper(raw)


def _configure_sqlite_connection(conn: Any) -> None:
    """降低 Flask 多线程并发读写下「database is locked」概率：WAL + 等待锁。"""
    _load_sqlite3()
    assert sqlite3 is not None
    conn.row_factory = sqlite3.Row
    busy_ms = int((os.environ.get("HZTECH_SQLITE_BUSY_TIMEOUT_MS") or "30000").strip())
    if busy_ms < 0:
        busy_ms = 0
    conn.execute(f"PRAGMA busy_timeout = {busy_ms}")
    # WAL：读与写可更好并发；journal_mode 会持久化到库文件。
    # 若另有进程正占用库，切换可能短暂失败，不影响本连接使用 busy_timeout。
    try:
        conn.execute("PRAGMA journal_mode=WAL")
    except sqlite3.OperationalError:
        pass


def get_connection() -> Any:
    if IS_POSTGRES:
        return _connect_postgresql()
    _load_sqlite3()
    assert sqlite3 is not None
    DB_DIR.mkdir(parents=True, exist_ok=True)
    timeout_s = float((os.environ.get("HZTECH_SQLITE_TIMEOUT_SEC") or "30").strip())
    if timeout_s <= 0:
        timeout_s = 30.0
    conn = sqlite3.connect(str(DB_PATH), timeout=timeout_s)
    _configure_sqlite_connection(conn)
    return conn


# ---------- PostgreSQL 初次建表（与 SQLite init_db 表结构对齐） ----------
# 手工对照 SQL：migrations/add_account_daily_performance.postgresql.sql、add_account_season.postgresql.sql
PG_INIT_STATEMENTS: list[str] = [
    """CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP),
    role TEXT NOT NULL DEFAULT 'trader',
    linked_account_ids TEXT,
    full_name TEXT,
    phone TEXT
)""",
    """CREATE TABLE IF NOT EXISTS logs (
    id SERIAL PRIMARY KEY,
    level TEXT NOT NULL,
    message TEXT NOT NULL,
    source TEXT,
    created_at TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP),
    extra TEXT
)""",
    "CREATE INDEX IF NOT EXISTS idx_logs_created ON logs(created_at)",
    "CREATE INDEX IF NOT EXISTS idx_logs_level ON logs(level)",
    """CREATE TABLE IF NOT EXISTS strategy_events (
    id SERIAL PRIMARY KEY,
    bot_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    trigger_type TEXT NOT NULL,
    username TEXT,
    created_at TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP),
    success INTEGER,
    detail TEXT,
    action_icon TEXT
)""",
    "CREATE INDEX IF NOT EXISTS idx_strategy_events_bot_id ON strategy_events(bot_id)",
    "CREATE INDEX IF NOT EXISTS idx_strategy_events_created ON strategy_events(created_at)",
    """CREATE TABLE IF NOT EXISTS account_season (
    id SERIAL PRIMARY KEY,
    account_id TEXT NOT NULL,
    started_at TEXT NOT NULL,
    stopped_at TEXT,
    initial_equity DOUBLE PRECISION NOT NULL DEFAULT 0,
    initial_balance DOUBLE PRECISION,
    final_equity DOUBLE PRECISION,
    final_balance DOUBLE PRECISION,
    profit_amount DOUBLE PRECISION,
    profit_percent DOUBLE PRECISION,
    created_at TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP)
)""",
    "CREATE INDEX IF NOT EXISTS idx_account_season_account_id ON account_season(account_id)",
    "CREATE INDEX IF NOT EXISTS idx_account_season_started ON account_season(started_at)",
    """CREATE TABLE IF NOT EXISTS tradingbot_mgr (
    id SERIAL PRIMARY KEY,
    account_id TEXT NOT NULL,
    started_at TEXT NOT NULL,
    stopped_at TEXT,
    recorded_at TEXT NOT NULL
)""",
    "CREATE INDEX IF NOT EXISTS idx_tradingbot_mgr_account ON tradingbot_mgr(account_id)",
    "CREATE INDEX IF NOT EXISTS idx_tradingbot_mgr_started ON tradingbot_mgr(started_at)",
    """CREATE TABLE IF NOT EXISTS account_list (
    account_id TEXT PRIMARY KEY,
    account_name TEXT,
    exchange_account TEXT,
    symbol TEXT,
    initial_capital DOUBLE PRECISION NOT NULL DEFAULT 0,
    trading_strategy TEXT,
    account_key_file TEXT,
    script_file TEXT,
    enabled INTEGER NOT NULL DEFAULT 1,
    updated_at TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP)
)""",
    """CREATE TABLE IF NOT EXISTS account_balance_snapshots (
    id SERIAL PRIMARY KEY,
    account_id TEXT NOT NULL,
    snapshot_at TEXT NOT NULL,
    cash_balance DOUBLE PRECISION NOT NULL DEFAULT 0,
    available_margin DOUBLE PRECISION NOT NULL DEFAULT 0,
    used_margin DOUBLE PRECISION NOT NULL DEFAULT 0,
    equity_usdt DOUBLE PRECISION NOT NULL DEFAULT 0,
    equity_profit_amount DOUBLE PRECISION NOT NULL DEFAULT 0,
    equity_profit_percent DOUBLE PRECISION NOT NULL DEFAULT 0,
    balance_profit_amount DOUBLE PRECISION NOT NULL DEFAULT 0,
    balance_profit_percent DOUBLE PRECISION NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP)
)""",
    "CREATE INDEX IF NOT EXISTS idx_account_balance_snapshots_account ON account_balance_snapshots(account_id)",
    "CREATE INDEX IF NOT EXISTS idx_account_balance_snapshots_at ON account_balance_snapshots(snapshot_at)",
    """CREATE TABLE IF NOT EXISTS account_month_balance_baseline (
    account_id TEXT NOT NULL,
    year_month TEXT NOT NULL,
    initial_equity DOUBLE PRECISION NOT NULL,
    initial_balance DOUBLE PRECISION,
    recorded_at TEXT NOT NULL,
    PRIMARY KEY (account_id, year_month)
)""",
    """CREATE TABLE IF NOT EXISTS account_positions_history (
    id SERIAL PRIMARY KEY,
    account_id TEXT NOT NULL,
    okx_pos_id TEXT NOT NULL,
    inst_id TEXT NOT NULL DEFAULT '',
    inst_type TEXT,
    pos_side TEXT,
    mgn_mode TEXT,
    open_avg_px DOUBLE PRECISION,
    close_avg_px DOUBLE PRECISION,
    open_max_pos TEXT,
    close_total_pos TEXT,
    pnl DOUBLE PRECISION,
    realized_pnl DOUBLE PRECISION,
    fee DOUBLE PRECISION,
    funding_fee DOUBLE PRECISION,
    close_type TEXT,
    c_time_ms TEXT,
    u_time_ms TEXT NOT NULL,
    raw_json TEXT NOT NULL,
    synced_at TEXT NOT NULL,
    UNIQUE(account_id, okx_pos_id, u_time_ms)
)""",
    "CREATE INDEX IF NOT EXISTS idx_aph_account ON account_positions_history(account_id)",
    "CREATE INDEX IF NOT EXISTS idx_aph_utime ON account_positions_history(u_time_ms)",
    """CREATE TABLE IF NOT EXISTS account_open_positions_snapshots (
    id SERIAL PRIMARY KEY,
    account_id TEXT NOT NULL,
    inst_id TEXT NOT NULL,
    snapshot_at TEXT NOT NULL,
    last_px DOUBLE PRECISION NOT NULL DEFAULT 0,
    long_pos_size DOUBLE PRECISION NOT NULL DEFAULT 0,
    short_pos_size DOUBLE PRECISION NOT NULL DEFAULT 0,
    mark_px DOUBLE PRECISION NOT NULL DEFAULT 0,
    long_upl DOUBLE PRECISION NOT NULL DEFAULT 0,
    short_upl DOUBLE PRECISION NOT NULL DEFAULT 0,
    total_upl DOUBLE PRECISION NOT NULL DEFAULT 0,
    open_leg_count INTEGER NOT NULL DEFAULT 0,
    long_avg_px DOUBLE PRECISION NOT NULL DEFAULT 0,
    short_avg_px DOUBLE PRECISION NOT NULL DEFAULT 0,
    long_liq_px DOUBLE PRECISION NOT NULL DEFAULT 0,
    short_liq_px DOUBLE PRECISION NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP)
)""",
    "CREATE INDEX IF NOT EXISTS idx_aops_account_at ON account_open_positions_snapshots(account_id, snapshot_at)",
    "CREATE INDEX IF NOT EXISTS idx_aops_account_inst ON account_open_positions_snapshots(account_id, inst_id)",
    """CREATE TABLE IF NOT EXISTS account_daily_performance (
    account_id TEXT NOT NULL,
    day TEXT NOT NULL,
    net_realized_pnl DOUBLE PRECISION NOT NULL DEFAULT 0,
    close_pos_count INTEGER NOT NULL DEFAULT 0,
    equlity_changed DOUBLE PRECISION,
    balance_changed DOUBLE PRECISION,
    balance_changed_pct DOUBLE PRECISION,
    pnl_pct DOUBLE PRECISION,
    instrument_id TEXT NOT NULL DEFAULT '',
    market_truevolatility DOUBLE PRECISION,
    efficiency_ratio DOUBLE PRECISION,
    updated_at TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP),
    PRIMARY KEY (account_id, day)
)""",
    "CREATE INDEX IF NOT EXISTS idx_adp_account ON account_daily_performance(account_id)",
    "CREATE INDEX IF NOT EXISTS idx_adp_day ON account_daily_performance(day)",
    # open/high/low/close 为保留名，使用双引号
    """CREATE TABLE IF NOT EXISTS market_daily_bars (
    inst_id TEXT NOT NULL,
    day TEXT NOT NULL,
    "open" DOUBLE PRECISION NOT NULL,
    "high" DOUBLE PRECISION NOT NULL,
    "low" DOUBLE PRECISION NOT NULL,
    "close" DOUBLE PRECISION NOT NULL,
    tr DOUBLE PRECISION NOT NULL,
    updated_at TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP),
    PRIMARY KEY (inst_id, day)
)""",
    "CREATE INDEX IF NOT EXISTS idx_market_daily_bars_inst_day ON market_daily_bars(inst_id, day)",
]


def _pg_drop_legacy_bot_profit_tables(conn: PgConnectionWrapper) -> None:
    """废弃旧 bot 盈利快照表；与 SQLite _drop_legacy_bot_profit_tables 一致。"""
    try:
        for t in ("tradingbot_profit_snapshots", "tradingbot_profit", "bot_profit_snapshots"):
            conn.execute(f"DROP TABLE IF EXISTS {t}")
        conn.commit()
    except Exception:
        conn.rollback()


def _pg_drop_balance_snapshot_initial_capital(conn: PgConnectionWrapper) -> None:
    """旧库 account_balance_snapshots 去掉 initial_capital（与 SQLite 迁移一致）。"""
    try:
        conn.execute(
            "ALTER TABLE account_balance_snapshots DROP COLUMN IF EXISTS initial_capital"
        )
        conn.commit()
    except Exception:
        conn.rollback()


def pg_run_init(conn: PgConnectionWrapper) -> None:
    """执行 PG_INIT_STATEMENTS 建表（幂等）。"""
    _pg_drop_legacy_bot_profit_tables(conn)
    _pg_drop_balance_snapshot_initial_capital(conn)
    for stmt in PG_INIT_STATEMENTS:
        conn.execute(stmt)
    conn.execute("DROP TABLE IF EXISTS config")
    conn.commit()
