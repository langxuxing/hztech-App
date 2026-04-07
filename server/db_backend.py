# -*- coding: utf-8 -*-
"""
数据库后端选择：SQLite（默认）或 PostgreSQL。

环境变量（任选其一组合）：
- HZTECH_DB_BACKEND=auto|sqlite|postgresql
  - auto：若设置 DATABASE_URL 且为 postgresql/postgres 开头，或设置了 POSTGRES_HOST / POSTGRES_USER，则用 PostgreSQL；否则 SQLite。
- DATABASE_URL=postgresql://hztech:Alpha@127.0.0.1:5432/hztech
- 或分项：POSTGRES_HOST（默认 localhost）、POSTGRES_PORT（5432）、POSTGRES_DB（hztech）、
  POSTGRES_USER（hztech）、POSTGRES_PASSWORD（Alpha）

依赖：PostgreSQL 模式需安装 psycopg2-binary。
"""
from __future__ import annotations

import os
import sqlite3
from pathlib import Path
from typing import Any

try:
    import psycopg2
except ImportError:
    psycopg2 = None  # type: ignore[misc, assignment]

SERVER_DIR = Path(__file__).resolve().parent
DB_DIR = SERVER_DIR / "sqlite"
DB_PATH = DB_DIR / "tradingbots.db"


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
    raw = (os.environ.get("HZTECH_DB_BACKEND") or "auto").strip().lower()
    if raw in ("postgres", "postgresql", "pg"):
        return "postgresql"
    if raw == "sqlite":
        return "sqlite"
    if raw == "auto":
        return _auto_backend()
    return "sqlite"


BACKEND = _resolve_backend()
IS_POSTGRES = BACKEND == "postgresql"

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


def _connect_postgresql() -> PgConnectionWrapper:
    if psycopg2 is None:
        raise RuntimeError(
            "已选择 PostgreSQL 但未安装 psycopg2-binary，请执行: pip install psycopg2-binary"
        )
    url = (os.environ.get("DATABASE_URL") or "").strip()
    if url:
        return PgConnectionWrapper(psycopg2.connect(url))
    host = (os.environ.get("POSTGRES_HOST") or "localhost").strip()
    port = int((os.environ.get("POSTGRES_PORT") or "5432").strip())
    dbn = (os.environ.get("POSTGRES_DB") or "hztech").strip()
    user = (os.environ.get("POSTGRES_USER") or "hztech").strip()
    password = (os.environ.get("POSTGRES_PASSWORD") or "Alpha").strip()
    return PgConnectionWrapper(
        psycopg2.connect(
            host=host,
            port=port,
            dbname=dbn,
            user=user,
            password=password,
        )
    )


def _configure_sqlite_connection(conn: sqlite3.Connection) -> None:
    """降低 Flask 多线程并发读写下「database is locked」概率：WAL + 等待锁。"""
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


def get_connection() -> sqlite3.Connection | PgConnectionWrapper:
    if IS_POSTGRES:
        return _connect_postgresql()
    DB_DIR.mkdir(parents=True, exist_ok=True)
    timeout_s = float((os.environ.get("HZTECH_SQLITE_TIMEOUT_SEC") or "30").strip())
    if timeout_s <= 0:
        timeout_s = 30.0
    conn = sqlite3.connect(str(DB_PATH), timeout=timeout_s)
    _configure_sqlite_connection(conn)
    return conn


# ---------- PostgreSQL 初次建表（与 SQLite init_db 表结构对齐） ----------
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
    """CREATE TABLE IF NOT EXISTS tradingbot_profit_snapshots (
    id SERIAL PRIMARY KEY,
    bot_id TEXT NOT NULL,
    snapshot_at TEXT NOT NULL,
    initial_balance DOUBLE PRECISION NOT NULL DEFAULT 0,
    current_balance DOUBLE PRECISION NOT NULL DEFAULT 0,
    equity_usdt DOUBLE PRECISION NOT NULL DEFAULT 0,
    profit_amount DOUBLE PRECISION NOT NULL DEFAULT 0,
    profit_percent DOUBLE PRECISION NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP)
)""",
    "CREATE INDEX IF NOT EXISTS idx_tradingbot_profit_snapshots_bot_id ON tradingbot_profit_snapshots(bot_id)",
    "CREATE INDEX IF NOT EXISTS idx_tradingbot_profit_snapshots_snapshot_at ON tradingbot_profit_snapshots(snapshot_at)",
    """CREATE TABLE IF NOT EXISTS strategy_events (
    id SERIAL PRIMARY KEY,
    bot_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    trigger_type TEXT NOT NULL,
    username TEXT,
    created_at TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP)
)""",
    "CREATE INDEX IF NOT EXISTS idx_strategy_events_bot_id ON strategy_events(bot_id)",
    "CREATE INDEX IF NOT EXISTS idx_strategy_events_created ON strategy_events(created_at)",
    """CREATE TABLE IF NOT EXISTS account_season (
    id SERIAL PRIMARY KEY,
    account_id TEXT NOT NULL,
    started_at TEXT NOT NULL,
    stopped_at TEXT,
    initial_balance DOUBLE PRECISION NOT NULL DEFAULT 0,
    initial_cash DOUBLE PRECISION,
    final_balance DOUBLE PRECISION,
    final_cash DOUBLE PRECISION,
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
    profit_amount DOUBLE PRECISION NOT NULL DEFAULT 0,
    profit_percent DOUBLE PRECISION NOT NULL DEFAULT 0,
    cash_profit_amount DOUBLE PRECISION NOT NULL DEFAULT 0,
    cash_profit_percent DOUBLE PRECISION NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP)
)""",
    "CREATE INDEX IF NOT EXISTS idx_account_balance_snapshots_account ON account_balance_snapshots(account_id)",
    "CREATE INDEX IF NOT EXISTS idx_account_balance_snapshots_at ON account_balance_snapshots(snapshot_at)",
    """CREATE TABLE IF NOT EXISTS account_month_open (
    account_id TEXT NOT NULL,
    year_month TEXT NOT NULL,
    open_equity DOUBLE PRECISION NOT NULL,
    open_cash DOUBLE PRECISION,
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
    created_at TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP)
)""",
    "CREATE INDEX IF NOT EXISTS idx_aops_account_at ON account_open_positions_snapshots(account_id, snapshot_at)",
    "CREATE INDEX IF NOT EXISTS idx_aops_account_inst ON account_open_positions_snapshots(account_id, inst_id)",
    """CREATE TABLE IF NOT EXISTS account_daily_performance (
    account_id TEXT NOT NULL,
    day TEXT NOT NULL,
    net_realized_pnl DOUBLE PRECISION NOT NULL DEFAULT 0,
    close_count INTEGER NOT NULL DEFAULT 0,
    equity_change DOUBLE PRECISION,
    cash_change DOUBLE PRECISION,
    pnl_pct DOUBLE PRECISION,
    equity_base_realized_chain DOUBLE PRECISION,
    pnl_pct_realized_chain DOUBLE PRECISION,
    benchmark_inst_id TEXT NOT NULL DEFAULT '',
    market_tr DOUBLE PRECISION,
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


def _pg_migrate_bot_profit_tables(conn: PgConnectionWrapper) -> None:
    """与 SQLite _migrate_bot_profit_tables_to_tradingbot_profit_snapshots 一致。"""
    try:
        def _has(name: str) -> bool:
            r = conn.execute(
                "SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = %s",
                (name,),
            ).fetchone()
            return r is not None

        t_final = "tradingbot_profit_snapshots"
        t_mid = "tradingbot_profit"
        t_old = "bot_profit_snapshots"
        if _has(t_mid) and _has(t_final):
            row_new = conn.execute(f"SELECT COUNT(*) FROM {t_final}").fetchone()
            row_mid = conn.execute(f"SELECT COUNT(*) FROM {t_mid}").fetchone()
            n_new = int(row_new[0]) if row_new else 0
            n_mid = int(row_mid[0]) if row_mid else 0
            if n_new == 0 and n_mid > 0:
                conn.execute(f"DROP TABLE {t_final}")
                conn.execute(f"ALTER TABLE {t_mid} RENAME TO {t_final}")
            elif n_mid > 0:
                conn.execute(
                    f"""INSERT INTO {t_final}
                       (bot_id, snapshot_at, initial_balance, current_balance, equity_usdt, profit_amount, profit_percent, created_at)
                       SELECT b.bot_id, b.snapshot_at, b.initial_balance, b.current_balance, b.equity_usdt,
                              b.profit_amount, b.profit_percent, b.created_at
                       FROM {t_mid} b
                       WHERE NOT EXISTS (
                         SELECT 1 FROM {t_final} t
                         WHERE t.bot_id = b.bot_id AND t.snapshot_at = b.snapshot_at
                       )"""
                )
                conn.execute(f"DROP TABLE {t_mid}")
            else:
                conn.execute(f"DROP TABLE {t_mid}")
        elif _has(t_mid) and not _has(t_final):
            conn.execute(f"ALTER TABLE {t_mid} RENAME TO {t_final}")
        if not _has(t_old):
            conn.commit()
            return
        if not _has(t_final):
            conn.execute(f"ALTER TABLE {t_old} RENAME TO {t_final}")
            conn.commit()
            return
        row_new = conn.execute(f"SELECT COUNT(*) FROM {t_final}").fetchone()
        row_old = conn.execute(f"SELECT COUNT(*) FROM {t_old}").fetchone()
        n_new = int(row_new[0]) if row_new else 0
        n_old = int(row_old[0]) if row_old else 0
        if n_new == 0 and n_old > 0:
            conn.execute(f"DROP TABLE {t_final}")
            conn.execute(f"ALTER TABLE {t_old} RENAME TO {t_final}")
            conn.commit()
            return
        if n_old > 0:
            conn.execute(
                f"""INSERT INTO {t_final}
                   (bot_id, snapshot_at, initial_balance, current_balance, equity_usdt, profit_amount, profit_percent, created_at)
                   SELECT b.bot_id, b.snapshot_at, b.initial_balance, b.current_balance, b.equity_usdt,
                          b.profit_amount, b.profit_percent, b.created_at
                   FROM {t_old} b
                   WHERE NOT EXISTS (
                     SELECT 1 FROM {t_final} t
                     WHERE t.bot_id = b.bot_id AND t.snapshot_at = b.snapshot_at
                   )"""
            )
        conn.execute(f"DROP TABLE {t_old}")
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
    _pg_migrate_bot_profit_tables(conn)
    _pg_drop_balance_snapshot_initial_capital(conn)
    for stmt in PG_INIT_STATEMENTS:
        conn.execute(stmt)
    conn.execute("DROP TABLE IF EXISTS config")
    conn.commit()
