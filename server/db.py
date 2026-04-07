# -*- coding: utf-8 -*-
"""持久化：默认 SQLite；可通过环境变量切换 PostgreSQL（见 db_backend）。"""
from __future__ import annotations

import json

try:
    import sqlite3
except ModuleNotFoundError as e:
    if "_sqlite3" in str(e):
        import pysqlite3 as sqlite3  # type: ignore[no-redef]  # 无 _sqlite3 时用 pysqlite3
    else:
        raise
import sys
from pathlib import Path
from typing import Any

# 从项目根执行「from server.db import …」时，须将本目录加入 path，才能解析同目录的 db_backend
_server_dir = str(Path(__file__).resolve().parent)
if _server_dir not in sys.path:
    sys.path.insert(0, _server_dir)

from db_backend import (
    DB_DIR,
    DB_INTEGRITY_ERRORS,
    DB_OPERATIONAL_ERRORS,
    DB_PATH,
    IS_POSTGRES,
    PgConnectionWrapper,
    SERVER_DIR,
    get_connection,
    pg_run_init,
)

# 与 SQLite 类型注解兼容：PostgreSQL 时使用封装连接
def get_conn() -> sqlite3.Connection | PgConnectionWrapper:
    return get_connection()


def _run_user_migrations_pg(conn: PgConnectionWrapper) -> None:
    """PostgreSQL：执行 add_user_*.sql（INSERT 转为 ON CONFLICT；ALTER 失败则忽略）。"""
    migrations_dir = SERVER_DIR / "migrations"
    if not migrations_dir.is_dir():
        return
    for p in sorted(migrations_dir.glob("add_user_*.sql")):
        text = p.read_text(encoding="utf-8")
        if "ALTER TABLE" in text.upper():
            for part in text.split(";"):
                part = part.strip()
                if not part or part.startswith("--"):
                    continue
                try:
                    conn.execute(part)
                    conn.commit()
                except DB_OPERATIONAL_ERRORS:
                    conn.rollback()
            continue
        if "INSERT OR IGNORE" in text.upper():
            text2 = text.replace(
                "INSERT OR IGNORE INTO users (username, password_hash)",
                "INSERT INTO users (username, password_hash) ON CONFLICT (username) DO NOTHING",
            )
            try:
                conn.execute(text2)
                conn.commit()
            except Exception:
                conn.rollback()
            continue
        try:
            conn.execute(text)
            conn.commit()
        except Exception:
            conn.rollback()


def _run_user_migrations(conn: sqlite3.Connection | PgConnectionWrapper) -> None:
    """执行 server/migrations/add_user_*.sql，将用户同步到当前数据库（含 AWS 部署）。"""
    if IS_POSTGRES:
        _run_user_migrations_pg(conn)
        return
    if not isinstance(conn, sqlite3.Connection):
        return
    migrations_dir = SERVER_DIR / "migrations"
    if not migrations_dir.is_dir():
        return
    for p in sorted(migrations_dir.glob("add_user_*.sql")):
        try:
            conn.executescript(p.read_text(encoding="utf-8"))
            conn.commit()
        except Exception:
            pass


def _ensure_account_schema_columns(conn: sqlite3.Connection) -> None:
    """旧库补列：月初现金、赛季起止现金（与 QTrader-web 口径对齐的扩展字段）。"""
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='account_balance_snapshots'"
    )
    if cur.fetchone():
        cur = conn.execute("PRAGMA table_info(account_balance_snapshots)")
        snap_cols = {str(r[1]) for r in cur.fetchall()}
        if "initial_capital" in snap_cols:
            conn.execute(
                "ALTER TABLE account_balance_snapshots DROP COLUMN initial_capital"
            )
    cur = conn.execute("PRAGMA table_info(account_month_open)")
    cols = {str(r[1]) for r in cur.fetchall()}
    if "open_cash" not in cols:
        conn.execute("ALTER TABLE account_month_open ADD COLUMN open_cash REAL")
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='account_season'"
    )
    if not cur.fetchone():
        return
    cur = conn.execute("PRAGMA table_info(account_season)")
    cols_b = {str(r[1]) for r in cur.fetchall()}
    if "initial_cash" not in cols_b:
        conn.execute("ALTER TABLE account_season ADD COLUMN initial_cash REAL")
    if "final_cash" not in cols_b:
        conn.execute("ALTER TABLE account_season ADD COLUMN final_cash REAL")


def _migrate_account_meta_to_account_list(conn: sqlite3.Connection) -> None:
    """旧库：仅有 account_meta 时重命名为 account_list（须在 CREATE account_list 之前执行）。"""
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('account_meta', 'account_list')"
    )
    names = {str(r[0]) for r in cur.fetchall()}
    if "account_meta" in names and "account_list" not in names:
        conn.execute("ALTER TABLE account_meta RENAME TO account_list")


def _migrate_account_snapshots_to_account_balance_snapshots(
    conn: sqlite3.Connection,
) -> None:
    """旧库：account_snapshots 重命名为 account_balance_snapshots（须在 CREATE 之前执行）。"""
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('account_snapshots', 'account_balance_snapshots')"
    )
    names = {str(r[0]) for r in cur.fetchall()}
    if "account_snapshots" in names and "account_balance_snapshots" not in names:
        conn.execute(
            "ALTER TABLE account_snapshots RENAME TO account_balance_snapshots"
        )


def _migrate_account_daily_close_performance_to_account_daily_performance(
    conn: sqlite3.Connection,
) -> None:
    """旧库：account_daily_close_performance 重命名为 account_daily_performance（须在 CREATE 之前执行）。"""
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN "
        "('account_daily_close_performance', 'account_daily_performance')"
    )
    names = {str(r[0]) for r in cur.fetchall()}
    if "account_daily_close_performance" in names and "account_daily_performance" not in names:
        conn.execute(
            "ALTER TABLE account_daily_close_performance RENAME TO account_daily_performance"
        )


def _migrate_account_season_spaced_name_and_bot_id(conn: sqlite3.Connection) -> None:
    """修正误写的表名 \"account_season \"（尾部空格）及列 bot_id -> account_id。

    历史脚本若少写引号可能建成带空格的表名，导致与代码中的 account_season 不一致。
    """
    cur = conn.execute("SELECT name FROM sqlite_master WHERE type='table'")
    all_names = [str(r[0]) for r in cur.fetchall()]
    spaced = "account_season "  # 与历史误建一致（尾部空格）
    has_spaced = spaced in all_names
    has_normal = "account_season" in all_names

    if has_spaced and not has_normal:
        conn.execute(f'ALTER TABLE "{spaced}" RENAME TO account_season')
    elif has_spaced and has_normal:
        n_norm = int(conn.execute("SELECT COUNT(*) FROM account_season").fetchone()[0])
        n_sp = int(conn.execute(f'SELECT COUNT(*) FROM "{spaced}"').fetchone()[0])
        if n_norm == 0:
            conn.execute("DROP TABLE account_season")
            conn.execute(f'ALTER TABLE "{spaced}" RENAME TO account_season')

    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='account_season'"
    )
    if not cur.fetchone():
        return
    cur = conn.execute("PRAGMA table_info(account_season)")
    cols = {str(r[1]) for r in cur.fetchall()}
    if "bot_id" in cols and "account_id" not in cols:
        conn.execute("ALTER TABLE account_season RENAME COLUMN bot_id TO account_id")
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_account_season_account_id ON account_season(account_id)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_account_season_started ON account_season(started_at)"
    )


def _migrate_bot_profit_tables_to_tradingbot_profit_snapshots(conn: sqlite3.Connection) -> None:
    """
    统一到表 tradingbot_profit_snapshots：
    旧 bot_profit_snapshots、中间名 tradingbot_profit 合并或重命名；两中间态并存时合并后删空表。
    """
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN "
        "('bot_profit_snapshots', 'tradingbot_profit', 'tradingbot_profit_snapshots')"
    )
    names = {str(r[0]) for r in cur.fetchall()}
    t_final = "tradingbot_profit_snapshots"
    t_mid = "tradingbot_profit"
    t_old = "bot_profit_snapshots"
    if t_mid in names and t_final in names:
        n_new = int(conn.execute(f"SELECT COUNT(*) FROM {t_final}").fetchone()[0])
        n_mid = int(conn.execute(f"SELECT COUNT(*) FROM {t_mid}").fetchone()[0])
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
        names.discard(t_mid)
    elif t_mid in names and t_final not in names:
        conn.execute(f"ALTER TABLE {t_mid} RENAME TO {t_final}")
        names.discard(t_mid)
        names.add(t_final)
    if t_old not in names:
        return
    if t_final not in names:
        conn.execute(f"ALTER TABLE {t_old} RENAME TO {t_final}")
        return
    n_new = int(conn.execute(f"SELECT COUNT(*) FROM {t_final}").fetchone()[0])
    n_old = int(conn.execute(f"SELECT COUNT(*) FROM {t_old}").fetchone()[0])
    if n_new == 0 and n_old > 0:
        conn.execute(f"DROP TABLE {t_final}")
        conn.execute(f"ALTER TABLE {t_old} RENAME TO {t_final}")
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


def _migrate_bot_seasons_to_account_season(conn: sqlite3.Connection) -> None:
    """旧库：bot_seasons 重命名为 account_season，列 bot_id 改为 account_id（须在 CREATE 之前执行）。"""
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('bot_seasons', 'account_season')"
    )
    names = {str(r[0]) for r in cur.fetchall()}
    if "bot_seasons" not in names or "account_season" in names:
        return
    conn.execute("ALTER TABLE bot_seasons RENAME TO account_season")
    conn.execute("ALTER TABLE account_season RENAME COLUMN bot_id TO account_id")
    conn.execute("DROP INDEX IF EXISTS idx_bot_seasons_bot_id")
    conn.execute("DROP INDEX IF EXISTS idx_bot_seasons_started")
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_account_season_account_id ON account_season(account_id)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_account_season_started ON account_season(started_at)"
    )


def _ensure_account_list_columns(conn: sqlite3.Connection) -> None:
    """account_list 补列（旧 account_meta 三列或缺字段时）。"""
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='account_list'"
    )
    if not cur.fetchone():
        return
    cur = conn.execute("PRAGMA table_info(account_list)")
    cols = {str(r[1]) for r in cur.fetchall()}
    specs = [
        ("account_name", "ALTER TABLE account_list ADD COLUMN account_name TEXT"),
        ("exchange_account", "ALTER TABLE account_list ADD COLUMN exchange_account TEXT"),
        ("symbol", "ALTER TABLE account_list ADD COLUMN symbol TEXT"),
        ("trading_strategy", "ALTER TABLE account_list ADD COLUMN trading_strategy TEXT"),
        ("account_key_file", "ALTER TABLE account_list ADD COLUMN account_key_file TEXT"),
        ("script_file", "ALTER TABLE account_list ADD COLUMN script_file TEXT"),
        ("enabled", "ALTER TABLE account_list ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1"),
    ]
    for col, sql in specs:
        if col not in cols:
            conn.execute(sql)


def _ensure_users_profile_columns(conn: sqlite3.Connection) -> None:
    """users 表补列：全名、手机号（与登录 username 独立）。"""
    cur = conn.execute("PRAGMA table_info(users)")
    cols = {str(r[1]) for r in cur.fetchall()}
    if "full_name" not in cols:
        conn.execute("ALTER TABLE users ADD COLUMN full_name TEXT")
    if "phone" not in cols:
        conn.execute("ALTER TABLE users ADD COLUMN phone TEXT")


def _seed_users_from_json(conn: sqlite3.Connection | PgConnectionWrapper) -> None:
    """仅当 users 表为空时从 server/users.json 一次性导入；正式用户数据以 DB 为准。"""
    users_json = SERVER_DIR / "users.json"
    if not users_json.exists():
        return
    try:
        data = json.loads(users_json.read_text(encoding="utf-8"))
        if not isinstance(data, list):
            return
        ins_sql = (
            "INSERT INTO users (username, password_hash) VALUES (?, ?) ON CONFLICT (username) DO NOTHING"
            if IS_POSTGRES
            else "INSERT OR IGNORE INTO users (username, password_hash) VALUES (?, ?)"
        )
        for u in data:
            username = u.get("username")
            password_hash = u.get("password_hash")
            if username and password_hash:
                conn.execute(
                    ins_sql,
                    (username.strip(), password_hash),
                )
        conn.commit()
    except Exception:
        pass


def init_db() -> None:
    """创建表（若不存在）。首次启动时若 users 表为空且存在 users.json 则一次性导入默认用户；之后用户管理以 DB 为准。"""
    conn = get_conn()
    try:
        if IS_POSTGRES:
            pg_run_init(conn)
            cur = conn.execute("SELECT COUNT(*) FROM users")
            row = cur.fetchone()
            if row is not None and int(row[0]) == 0:
                _seed_users_from_json(conn)
            _run_user_migrations(conn)
            return
        _migrate_account_meta_to_account_list(conn)
        _migrate_account_snapshots_to_account_balance_snapshots(conn)
        _migrate_account_daily_close_performance_to_account_daily_performance(conn)
        _migrate_account_season_spaced_name_and_bot_id(conn)
        _migrate_bot_seasons_to_account_season(conn)
        _migrate_bot_profit_tables_to_tradingbot_profit_snapshots(conn)
        conn.commit()
        try:
            conn.execute("DROP TABLE IF EXISTS config")
            conn.commit()
        except DB_OPERATIONAL_ERRORS:
            conn.rollback()
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT UNIQUE NOT NULL,
                password_hash TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
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
            CREATE TABLE IF NOT EXISTS tradingbot_profit_snapshots (
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
            CREATE INDEX IF NOT EXISTS idx_tradingbot_profit_snapshots_bot_id ON tradingbot_profit_snapshots(bot_id);
            CREATE INDEX IF NOT EXISTS idx_tradingbot_profit_snapshots_snapshot_at ON tradingbot_profit_snapshots(snapshot_at);
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
            CREATE TABLE IF NOT EXISTS account_season (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id TEXT NOT NULL,
                started_at TEXT NOT NULL,
                stopped_at TEXT,
                initial_balance REAL NOT NULL DEFAULT 0,
                initial_cash REAL,
                final_balance REAL,
                final_cash REAL,
                profit_amount REAL,
                profit_percent REAL,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_account_season_account_id ON account_season(account_id);
            CREATE INDEX IF NOT EXISTS idx_account_season_started ON account_season(started_at);
            CREATE TABLE IF NOT EXISTS tradingbot_mgr (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id TEXT NOT NULL,
                started_at TEXT NOT NULL,
                stopped_at TEXT,
                recorded_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_tradingbot_mgr_account ON tradingbot_mgr(account_id);
            CREATE INDEX IF NOT EXISTS idx_tradingbot_mgr_started ON tradingbot_mgr(started_at);
            CREATE TABLE IF NOT EXISTS account_list (
                account_id TEXT PRIMARY KEY,
                account_name TEXT,
                exchange_account TEXT,
                symbol TEXT,
                initial_capital REAL NOT NULL DEFAULT 0,
                trading_strategy TEXT,
                account_key_file TEXT,
                script_file TEXT,
                enabled INTEGER NOT NULL DEFAULT 1,
                updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE TABLE IF NOT EXISTS account_balance_snapshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id TEXT NOT NULL,
                snapshot_at TEXT NOT NULL,
                cash_balance REAL NOT NULL DEFAULT 0,
                equity_usdt REAL NOT NULL DEFAULT 0,
                profit_amount REAL NOT NULL DEFAULT 0,
                profit_percent REAL NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_account_balance_snapshots_account ON account_balance_snapshots(account_id);
            CREATE INDEX IF NOT EXISTS idx_account_balance_snapshots_at ON account_balance_snapshots(snapshot_at);
            CREATE TABLE IF NOT EXISTS account_month_open (
                account_id TEXT NOT NULL,
                year_month TEXT NOT NULL,
                open_equity REAL NOT NULL,
                open_cash REAL,
                recorded_at TEXT NOT NULL,
                PRIMARY KEY (account_id, year_month)
            );
            CREATE TABLE IF NOT EXISTS account_positions_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id TEXT NOT NULL,
                okx_pos_id TEXT NOT NULL,
                inst_id TEXT NOT NULL DEFAULT '',
                inst_type TEXT,
                pos_side TEXT,
                mgn_mode TEXT,
                open_avg_px REAL,
                close_avg_px REAL,
                open_max_pos TEXT,
                close_total_pos TEXT,
                pnl REAL,
                realized_pnl REAL,
                fee REAL,
                funding_fee REAL,
                close_type TEXT,
                c_time_ms TEXT,
                u_time_ms TEXT NOT NULL,
                raw_json TEXT NOT NULL,
                synced_at TEXT NOT NULL,
                UNIQUE(account_id, okx_pos_id, u_time_ms)
            );
            CREATE INDEX IF NOT EXISTS idx_aph_account ON account_positions_history(account_id);
            CREATE INDEX IF NOT EXISTS idx_aph_utime ON account_positions_history(u_time_ms);
            CREATE TABLE IF NOT EXISTS account_open_positions_snapshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id TEXT NOT NULL,
                inst_id TEXT NOT NULL,
                snapshot_at TEXT NOT NULL,
                last_px REAL NOT NULL DEFAULT 0,
                long_pos_size REAL NOT NULL DEFAULT 0,
                short_pos_size REAL NOT NULL DEFAULT 0,
                mark_px REAL NOT NULL DEFAULT 0,
                long_upl REAL NOT NULL DEFAULT 0,
                short_upl REAL NOT NULL DEFAULT 0,
                total_upl REAL NOT NULL DEFAULT 0,
                open_leg_count INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_aops_account_at ON account_open_positions_snapshots(account_id, snapshot_at);
            CREATE INDEX IF NOT EXISTS idx_aops_account_inst ON account_open_positions_snapshots(account_id, inst_id);
            CREATE TABLE IF NOT EXISTS account_daily_performance (
                account_id TEXT NOT NULL,
                day TEXT NOT NULL,
                net_realized_pnl REAL NOT NULL DEFAULT 0,
                close_count INTEGER NOT NULL DEFAULT 0,
                equity_base REAL,
                pnl_pct REAL,
                benchmark_inst_id TEXT NOT NULL DEFAULT '',
                market_tr REAL,
                efficiency_ratio REAL,
                updated_at TEXT NOT NULL DEFAULT (datetime('now')),
                PRIMARY KEY (account_id, day)
            );
            CREATE INDEX IF NOT EXISTS idx_adp_account ON account_daily_performance(account_id);
            CREATE INDEX IF NOT EXISTS idx_adp_day ON account_daily_performance(day);
            CREATE TABLE IF NOT EXISTS market_daily_bars (
                inst_id TEXT NOT NULL,
                day TEXT NOT NULL,
                open REAL NOT NULL,
                high REAL NOT NULL,
                low REAL NOT NULL,
                close REAL NOT NULL,
                tr REAL NOT NULL,
                updated_at TEXT NOT NULL DEFAULT (datetime('now')),
                PRIMARY KEY (inst_id, day)
            );
            CREATE INDEX IF NOT EXISTS idx_market_daily_bars_inst_day ON market_daily_bars(inst_id, day);
        """)
        conn.commit()
        _ensure_account_schema_columns(conn)
        _ensure_users_profile_columns(conn)
        _ensure_account_list_columns(conn)
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


def user_create(
    username: str,
    password_hash: str,
    *,
    role: str = "trader",
    linked_account_ids: list[str] | None = None,
    full_name: str | None = None,
    phone: str | None = None,
) -> bool:
    """创建用户，成功返回 True，用户名已存在返回 False。role 须为合法枚举。"""
    rr = str(role).strip().lower()
    if rr not in _VALID_USER_ROLES:
        return False
    links = linked_account_ids if linked_account_ids is not None else []
    links_json = json.dumps(links, ensure_ascii=False)
    fn = (full_name or "").strip()
    ph = (phone or "").strip()
    conn = get_conn()
    try:
        try:
            conn.execute(
                "INSERT INTO users (username, password_hash, role, linked_account_ids, full_name, phone) VALUES (?, ?, ?, ?, ?, ?)",
                (username.strip(), password_hash, rr, links_json, fn, ph),
            )
        except DB_OPERATIONAL_ERRORS:
            try:
                conn.execute(
                    "INSERT INTO users (username, password_hash, role, linked_account_ids) VALUES (?, ?, ?, ?)",
                    (username.strip(), password_hash, rr, links_json),
                )
            except DB_OPERATIONAL_ERRORS:
                conn.execute(
                    "INSERT INTO users (username, password_hash) VALUES (?, ?)",
                    (username.strip(), password_hash),
                )
        conn.commit()
        return True
    except DB_INTEGRITY_ERRORS:
        return False
    finally:
        conn.close()


def user_delete(user_id: int) -> bool:
    """按 id 删除用户，成功返回 True。"""
    conn = get_conn()
    try:
        cur = conn.execute("DELETE FROM users WHERE id = ?", (user_id,))
        conn.commit()
        return cur.rowcount > 0
    finally:
        conn.close()


def user_id_by_username(username: str) -> int | None:
    conn = get_conn()
    try:
        cur = conn.execute(
            "SELECT id FROM users WHERE LOWER(TRIM(username)) = LOWER(?)",
            (username.strip(),),
        )
        row = cur.fetchone()
        return int(row[0]) if row else None
    finally:
        conn.close()


_VALID_USER_ROLES = frozenset(
    {"customer", "trader", "admin", "strategy_analyst"}
)


def user_count_with_role(role: str) -> int:
    """统计指定 role 的用户数；表无 role 列时返回 0。"""
    rr = str(role).strip().lower()
    if rr not in _VALID_USER_ROLES:
        return 0
    conn = get_conn()
    try:
        cur = conn.execute(
            "SELECT COUNT(*) FROM users WHERE LOWER(TRIM(COALESCE(role, ''))) = ?",
            (rr,),
        )
        row = cur.fetchone()
        return int(row[0]) if row else 0
    except DB_OPERATIONAL_ERRORS:
        return 0
    finally:
        conn.close()


def user_get_role(username: str) -> str:
    """返回 customer / trader / admin / strategy_analyst；未知或缺列时默认 trader。"""
    conn = get_conn()
    try:
        cur = conn.execute(
            "SELECT role FROM users WHERE LOWER(TRIM(username)) = LOWER(?)",
            (username.strip(),),
        )
        row = cur.fetchone()
        if not row or row[0] is None:
            return "trader"
        r = str(row[0]).strip().lower()
        return r if r in _VALID_USER_ROLES else "trader"
    except DB_OPERATIONAL_ERRORS:
        return "trader"
    finally:
        conn.close()


def user_get_linked_account_ids(username: str) -> list[str]:
    """客户可访问的 account_id / tradingbot_id 列表；解析 linked_account_ids JSON。"""
    conn = get_conn()
    try:
        cur = conn.execute(
            "SELECT linked_account_ids FROM users WHERE LOWER(TRIM(username)) = LOWER(?)",
            (username.strip(),),
        )
        row = cur.fetchone()
        if not row or row[0] is None or str(row[0]).strip() == "":
            return []
        raw = str(row[0]).strip()
        try:
            data = json.loads(raw)
        except (TypeError, json.JSONDecodeError):
            return []
        if not isinstance(data, list):
            return []
        out: list[str] = []
        for x in data:
            if x is None:
                continue
            s = str(x).strip()
            if s:
                out.append(s)
        return out
    except DB_OPERATIONAL_ERRORS:
        return []
    finally:
        conn.close()


def user_list() -> list[dict]:
    """返回用户列表（不含 password_hash），含 role、linked_account_ids、full_name、phone。"""
    conn = get_conn()
    try:
        try:
            cur = conn.execute(
                "SELECT id, username, created_at, role, linked_account_ids, full_name, phone FROM users ORDER BY id"
            )
            rows = cur.fetchall()
            wide = True
        except DB_OPERATIONAL_ERRORS:
            wide = False
            try:
                cur = conn.execute(
                    "SELECT id, username, created_at, role, linked_account_ids FROM users ORDER BY id"
                )
                rows = cur.fetchall()
            except DB_OPERATIONAL_ERRORS:
                cur = conn.execute(
                    "SELECT id, username, created_at FROM users ORDER BY id"
                )
                rows = cur.fetchall()
                return [
                    {
                        "id": r[0],
                        "username": r[1],
                        "created_at": r[2],
                        "role": "trader",
                        "linked_account_ids": [],
                        "full_name": "",
                        "phone": "",
                    }
                    for r in rows
                ]
        out: list[dict] = []
        for r in rows:
            role = str(r[3] or "trader").strip().lower()
            if role not in _VALID_USER_ROLES:
                role = "trader"
            links: list[str] = []
            if r[4]:
                try:
                    parsed = json.loads(str(r[4]))
                    if isinstance(parsed, list):
                        links = [str(x).strip() for x in parsed if str(x).strip()]
                except (TypeError, json.JSONDecodeError):
                    links = []
            fn = str(r[5] or "").strip() if wide else ""
            ph = str(r[6] or "").strip() if wide else ""
            out.append(
                {
                    "id": r[0],
                    "username": r[1],
                    "created_at": r[2],
                    "role": role,
                    "linked_account_ids": links,
                    "full_name": fn,
                    "phone": ph,
                }
            )
        return out
    finally:
        conn.close()


def user_get_by_id(user_id: int) -> dict | None:
    conn = get_conn()
    try:
        try:
            cur = conn.execute(
                "SELECT id, username, created_at, role, linked_account_ids, full_name, phone FROM users WHERE id = ?",
                (user_id,),
            )
            r = cur.fetchone()
            if not r:
                return None
            role = str(r[3] or "trader").strip().lower()
            if role not in _VALID_USER_ROLES:
                role = "trader"
            links: list[str] = []
            if r[4]:
                try:
                    parsed = json.loads(str(r[4]))
                    if isinstance(parsed, list):
                        links = [str(x).strip() for x in parsed if str(x).strip()]
                except (TypeError, json.JSONDecodeError):
                    links = []
            return {
                "id": r[0],
                "username": r[1],
                "created_at": r[2],
                "role": role,
                "linked_account_ids": links,
                "full_name": str(r[5] or "").strip(),
                "phone": str(r[6] or "").strip(),
            }
        except DB_OPERATIONAL_ERRORS:
            pass
        try:
            cur = conn.execute(
                "SELECT id, username, created_at, role, linked_account_ids FROM users WHERE id = ?",
                (user_id,),
            )
            r = cur.fetchone()
        except DB_OPERATIONAL_ERRORS:
            cur = conn.execute(
                "SELECT id, username, created_at FROM users WHERE id = ?",
                (user_id,),
            )
            r = cur.fetchone()
            if not r:
                return None
            return {
                "id": r[0],
                "username": r[1],
                "created_at": r[2],
                "role": "trader",
                "linked_account_ids": [],
                "full_name": "",
                "phone": "",
            }
        if not r:
            return None
        role = str(r[3] or "trader").strip().lower()
        if role not in _VALID_USER_ROLES:
            role = "trader"
        links: list[str] = []
        if r[4]:
            try:
                parsed = json.loads(str(r[4]))
                if isinstance(parsed, list):
                    links = [str(x).strip() for x in parsed if str(x).strip()]
            except (TypeError, json.JSONDecodeError):
                links = []
        return {
            "id": r[0],
            "username": r[1],
            "created_at": r[2],
            "role": role,
            "linked_account_ids": links,
            "full_name": "",
            "phone": "",
        }
    finally:
        conn.close()


def user_update_profile(
    user_id: int,
    *,
    role: str | None = None,
    linked_account_ids: list[str] | None = None,
    full_name: str | None = None,
    phone: str | None = None,
) -> bool:
    """更新角色、客户可见账户、全名、手机；role 须为合法枚举。无有效变更时返回 False。"""
    conn = get_conn()
    try:
        fields: list[str] = []
        args: list[Any] = []
        if role is not None:
            rr = str(role).strip().lower()
            if rr not in _VALID_USER_ROLES:
                return False
            fields.append("role = ?")
            args.append(rr)
        if linked_account_ids is not None:
            fields.append("linked_account_ids = ?")
            args.append(json.dumps(linked_account_ids, ensure_ascii=False))
        if full_name is not None:
            fields.append("full_name = ?")
            args.append(str(full_name).strip())
        if phone is not None:
            fields.append("phone = ?")
            args.append(str(phone).strip())
        if not fields:
            return False
        args.append(user_id)
        cur = conn.execute(
            f"UPDATE users SET {', '.join(fields)} WHERE id = ?",
            args,
        )
        conn.commit()
        return cur.rowcount > 0
    except DB_OPERATIONAL_ERRORS:
        return False
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


# ---------- 机器人盈利快照（表 tradingbot_profit_snapshots；旧名 bot_profit_snapshots / tradingbot_profit） ----------
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
            """INSERT INTO tradingbot_profit_snapshots
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
               FROM tradingbot_profit_snapshots WHERE bot_id = ? ORDER BY snapshot_at ASC LIMIT ?""",
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
               FROM tradingbot_profit_snapshots WHERE bot_id = ? ORDER BY snapshot_at DESC LIMIT 1""",
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


def bot_profit_query_by_bot_since(
    bot_id: str, *, since_snapshot_at: str, max_rows: int = 40000
) -> list[dict]:
    """自 since_snapshot_at（含）起按 snapshot_at 升序，供策略能效与 account_balance_snapshots 口径对齐。"""
    cap = max(100, min(100000, int(max_rows)))
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT id, bot_id, snapshot_at, initial_balance, current_balance, equity_usdt,
                      profit_amount, profit_percent, created_at
               FROM tradingbot_profit_snapshots
               WHERE bot_id = ? AND snapshot_at >= ?
               ORDER BY snapshot_at ASC
               LIMIT ?""",
            ((bot_id or "").strip(), (since_snapshot_at or "").strip(), cap),
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


# ---------- 策略启停区间（表 tradingbot_mgr：序号、账户、启动/结束/记录时间） ----------
def tradingbot_mgr_session_start(account_id: str, started_at: str, recorded_at: str) -> int:
    """记录一次策略启动；返回行 id。"""
    aid = (account_id or "").strip()
    conn = get_conn()
    try:
        if IS_POSTGRES:
            cur = conn.execute(
                """INSERT INTO tradingbot_mgr (account_id, started_at, recorded_at)
                   VALUES (?, ?, ?) RETURNING id""",
                (aid, started_at, recorded_at),
            )
            row = cur.fetchone()
            conn.commit()
            return int(row[0]) if row else 0
        cur = conn.execute(
            """INSERT INTO tradingbot_mgr (account_id, started_at, recorded_at)
               VALUES (?, ?, ?)""",
            (aid, started_at, recorded_at),
        )
        conn.commit()
        return int(cur.lastrowid or 0)
    finally:
        conn.close()


def tradingbot_mgr_session_stop(account_id: str, stopped_at: str, recorded_at: str) -> None:
    """结束该账户当前未闭合的一条运行区间（stopped_at IS NULL 中 id 最大者）。"""
    aid = (account_id or "").strip()
    conn = get_conn()
    try:
        conn.execute(
            """UPDATE tradingbot_mgr SET stopped_at = ?, recorded_at = ?
               WHERE id = (
                 SELECT id FROM tradingbot_mgr
                 WHERE account_id = ? AND stopped_at IS NULL
                 ORDER BY id DESC LIMIT 1
               )""",
            (stopped_at, recorded_at, aid),
        )
        conn.commit()
    finally:
        conn.close()


# ---------- 策略启停事件（手动/自动、时间、类型） ----------
def strategy_event_insert(
    bot_id: str,
    event_type: str,
    trigger_type: str,
    username: str | None = None,
) -> None:
    """记录策略/赛季事件。event_type: start|stop|restart|season_start|season_stop；trigger_type: manual|auto|script。"""
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


# ---------- 赛季（表 account_season：账户策略启停周期，初期权益/现金、盈利） ----------
def account_season_insert(
    account_id: str,
    started_at: str,
    initial_balance: float = 0,
    *,
    initial_cash: float | None = None,
) -> int:
    """插入一条赛季记录（通常由 account_season_roll_forward 统一写入），返回 id。"""
    conn = get_conn()
    try:
        if IS_POSTGRES:
            cur = conn.execute(
                """INSERT INTO account_season (account_id, started_at, initial_balance, initial_cash)
                   VALUES (?, ?, ?, ?) RETURNING id""",
                (account_id, started_at, initial_balance, initial_cash),
            )
            row = cur.fetchone()
            conn.commit()
            return int(row[0]) if row else 0
        cur = conn.execute(
            """INSERT INTO account_season (account_id, started_at, initial_balance, initial_cash)
               VALUES (?, ?, ?, ?)""",
            (account_id, started_at, initial_balance, initial_cash),
        )
        conn.commit()
        return cur.lastrowid or 0
    finally:
        conn.close()


def account_season_update_on_stop(
    account_id: str,
    stopped_at: str,
    final_balance: float,
    final_cash: float | None = None,
) -> None:
    """更新最近一条未结束赛季：写入停止时间与期末权益/现金（停止策略或赛季结束）。"""
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT id, initial_balance, initial_cash FROM account_season
               WHERE account_id = ? AND stopped_at IS NULL
               ORDER BY started_at DESC LIMIT 1""",
            (account_id,),
        )
        row = cur.fetchone()
        if not row:
            return
        sid, initial = row[0], float(row[1])
        init_cash_v = row[2]
        init_cash = float(init_cash_v) if init_cash_v is not None else None
        profit_amount = final_balance - initial
        profit_percent = (profit_amount / initial * 100.0) if initial else 0.0
        conn.execute(
            """UPDATE account_season SET stopped_at = ?, final_balance = ?, final_cash = ?,
                      profit_amount = ?, profit_percent = ?
               WHERE id = ?""",
            (stopped_at, final_balance, final_cash, profit_amount, profit_percent, sid),
        )
        conn.commit()
    finally:
        conn.close()


def account_season_roll_forward(
    account_id: str,
    ts: str,
    equity_usdt: float,
    cash_usdt: float,
) -> int:
    """
    启动新盈利赛季：将所有未结束赛季的 stopped_at 设为 ts（与新赛季 started_at 同一时刻，前后衔接），
    再以同一快照写入新赛季的 initial_balance / initial_cash。
    """
    bid = (account_id or "").strip()
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT id, initial_balance, initial_cash FROM account_season
               WHERE account_id = ? AND stopped_at IS NULL
               ORDER BY started_at ASC""",
            (bid,),
        )
        for row in cur.fetchall():
            sid, initial = int(row[0]), float(row[1] or 0)
            ic_raw = row[2]
            init_cash = float(ic_raw) if ic_raw is not None else 0.0
            profit_amount = float(equity_usdt) - initial
            profit_percent = (profit_amount / initial * 100.0) if initial else 0.0
            conn.execute(
                """UPDATE account_season SET stopped_at = ?, final_balance = ?, final_cash = ?,
                          profit_amount = ?, profit_percent = ?
                   WHERE id = ?""",
                (ts, equity_usdt, cash_usdt, profit_amount, profit_percent, sid),
            )
        if IS_POSTGRES:
            cur2 = conn.execute(
                """INSERT INTO account_season (account_id, started_at, initial_balance, initial_cash)
                   VALUES (?, ?, ?, ?) RETURNING id""",
                (bid, ts, float(equity_usdt), float(cash_usdt)),
            )
            row2 = cur2.fetchone()
            conn.commit()
            return int(row2[0]) if row2 else 0
        cur2 = conn.execute(
            """INSERT INTO account_season (account_id, started_at, initial_balance, initial_cash)
               VALUES (?, ?, ?, ?)""",
            (bid, ts, float(equity_usdt), float(cash_usdt)),
        )
        conn.commit()
        return int(cur2.lastrowid or 0)
    finally:
        conn.close()


def account_season_list_by_account(account_id: str, limit: int = 50) -> list[dict]:
    """按 account_id 查询赛季列表，按 started_at 降序。"""
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT id, account_id, started_at, stopped_at, initial_balance, initial_cash,
                      final_balance, final_cash, profit_amount, profit_percent, created_at
               FROM account_season WHERE account_id = ? ORDER BY started_at DESC LIMIT ?""",
            (account_id, limit),
        )
        return [
            {
                "id": r[0],
                "account_id": r[1],
                "started_at": r[2],
                "stopped_at": r[3],
                "initial_balance": r[4],
                "initial_cash": float(r[5]) if r[5] is not None else None,
                "final_balance": r[6],
                "final_cash": float(r[7]) if r[7] is not None else None,
                "profit_amount": r[8],
                "profit_percent": r[9],
                "created_at": r[10],
            }
            for r in cur.fetchall()
        ]
    finally:
        conn.close()


def account_season_get_by_id(account_id: str, season_id: int) -> dict | None:
    """按 account_id + 主键 id 取单条赛季（用于区间汇总等）。"""
    bid = (account_id or "").strip()
    try:
        sid = int(season_id)
    except (TypeError, ValueError):
        return None
    if not bid:
        return None
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT id, account_id, started_at, stopped_at, initial_balance, initial_cash,
                      final_balance, final_cash, profit_amount, profit_percent, created_at
               FROM account_season WHERE account_id = ? AND id = ?""",
            (bid, sid),
        )
        r = cur.fetchone()
        if not r:
            return None
        return {
            "id": r[0],
            "account_id": r[1],
            "started_at": r[2],
            "stopped_at": r[3],
            "initial_balance": r[4],
            "initial_cash": float(r[5]) if r[5] is not None else None,
            "final_balance": r[6],
            "final_cash": float(r[7]) if r[7] is not None else None,
            "profit_amount": r[8],
            "profit_percent": r[9],
            "created_at": r[10],
        }
    finally:
        conn.close()


def account_positions_history_aggregate_u_time_range(
    account_id: str,
    u_time_start_ms: int,
    u_time_end_ms: int,
) -> dict[str, Any]:
    """
    在 u_time_ms（平仓/更新时间，毫秒）闭区间内汇总历史仓位：笔数、净盈亏（pnl+fee+funding_fee）。
    """
    aid = (account_id or "").strip()
    conn = get_conn()
    try:
        cur = conn.execute(
            """
            SELECT COUNT(*),
                   SUM(COALESCE(pnl, 0) + COALESCE(fee, 0) + COALESCE(funding_fee, 0))
            FROM account_positions_history
            WHERE account_id = ?
              AND CAST(u_time_ms AS INTEGER) >= ?
              AND CAST(u_time_ms AS INTEGER) <= ?
            """,
            (aid, int(u_time_start_ms), int(u_time_end_ms)),
        )
        r = cur.fetchone()
        cnt = int(r[0] or 0)
        net = float(r[1] or 0.0)
        return {"close_count": cnt, "net_realized_pnl_usdt": net}
    finally:
        conn.close()


# ---------- account_list（静态账户行，与 Account_List.json 同步）· account_balance_snapshots（余额时点快照）· account_open_positions_snapshots（每合约一行，open_leg_count 多空腿数）----------
# 余额相关函数仍命名为 account_snapshot_*，SQL 一律指向表 account_balance_snapshots。
def account_list_upsert(
    account_id: str,
    initial_capital: float,
    *,
    account_name: str = "",
    exchange_account: str = "",
    symbol: str = "",
    trading_strategy: str = "",
    account_key_file: str = "",
    script_file: str = "",
    enabled: bool = True,
) -> None:
    """写入或更新账户行（表：account_list；与 Account_List.json 字段一致；enabled 对应 JSON 的 enbaled/enabled）。"""
    aid = account_id.strip()
    en = 1 if enabled else 0
    conn = get_conn()
    try:
        conn.execute(
            """INSERT INTO account_list (
                   account_id, account_name, exchange_account, symbol, initial_capital,
                   trading_strategy, account_key_file, script_file, enabled, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
               ON CONFLICT(account_id) DO UPDATE SET
                 account_name = excluded.account_name,
                 exchange_account = excluded.exchange_account,
                 symbol = excluded.symbol,
                 initial_capital = excluded.initial_capital,
                 trading_strategy = excluded.trading_strategy,
                 account_key_file = excluded.account_key_file,
                 script_file = excluded.script_file,
                 enabled = excluded.enabled,
                 updated_at = datetime('now')""",
            (
                aid,
                account_name or "",
                exchange_account or "",
                symbol or "",
                float(initial_capital),
                trading_strategy or "",
                account_key_file or "",
                script_file or "",
                en,
            ),
        )
        conn.commit()
    finally:
        conn.close()


def account_list_get(account_id: str) -> dict | None:
    """按 account_id 读一行（表：account_list）。"""
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT account_id, account_name, exchange_account, symbol, initial_capital,
                      trading_strategy, account_key_file, script_file, enabled, updated_at
               FROM account_list WHERE account_id = ?""",
            (account_id.strip(),),
        )
        r = cur.fetchone()
        if not r:
            return None
        en = r[8]
        enabled_bool = bool(int(en)) if en is not None else True
        return {
            "account_id": r[0],
            "account_name": str(r[1] or ""),
            "exchange_account": str(r[2] or ""),
            "symbol": str(r[3] or ""),
            "initial_capital": float(r[4]),
            "trading_strategy": str(r[5] or ""),
            "account_key_file": str(r[6] or ""),
            "script_file": str(r[7] or ""),
            "enabled": enabled_bool,
            "updated_at": r[9],
        }
    finally:
        conn.close()


def account_list_prune_except(keep_account_ids: set[str]) -> None:
    """删除 account_list 中不在 keep_account_ids 内的行（与 Account_List.json 账户集合对齐）。"""
    conn = get_conn()
    try:
        cur = conn.execute("SELECT account_id FROM account_list")
        for (aid,) in cur.fetchall():
            if aid not in keep_account_ids:
                conn.execute("DELETE FROM account_list WHERE account_id = ?", (aid,))
        conn.commit()
    finally:
        conn.close()


def account_snapshot_insert(
    account_id: str,
    snapshot_at: str,
    cash_balance: float,
    equity_usdt: float,
    profit_amount: float,
    profit_percent: float,
) -> None:
    """插入一条余额快照行（表：account_balance_snapshots）。盈亏相对 account_list.initial_capital，由调用方预计算。"""
    conn = get_conn()
    try:
        conn.execute(
            """INSERT INTO account_balance_snapshots
               (account_id, snapshot_at, cash_balance, equity_usdt,
                profit_amount, profit_percent)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (
                account_id.strip(),
                snapshot_at,
                cash_balance,
                equity_usdt,
                profit_amount,
                profit_percent,
            ),
        )
        conn.commit()
    finally:
        conn.close()


def account_snapshot_latest_by_account(account_id: str) -> dict | None:
    """该账户最新一条快照（表：account_balance_snapshots）。"""
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT id, account_id, snapshot_at, cash_balance, equity_usdt,
                      profit_amount, profit_percent, created_at
               FROM account_balance_snapshots WHERE account_id = ? ORDER BY snapshot_at DESC LIMIT 1""",
            (account_id.strip(),),
        )
        r = cur.fetchone()
        if not r:
            return None
        return {
            "id": r[0],
            "account_id": r[1],
            "snapshot_at": r[2],
            "cash_balance": r[3],
            "equity_usdt": r[4],
            "profit_amount": r[5],
            "profit_percent": r[6],
            "created_at": r[7],
        }
    finally:
        conn.close()


def account_snapshot_query_by_account(account_id: str, limit: int = 500) -> list[dict]:
    """按时间升序，最多 limit 条（表：account_balance_snapshots）。"""
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT id, account_id, snapshot_at, cash_balance, equity_usdt,
                      profit_amount, profit_percent, created_at
               FROM account_balance_snapshots WHERE account_id = ? ORDER BY snapshot_at ASC LIMIT ?""",
            (account_id.strip(), limit),
        )
        return [
            {
                "id": r[0],
                "account_id": r[1],
                "snapshot_at": r[2],
                "cash_balance": r[3],
                "equity_usdt": r[4],
                "profit_amount": r[5],
                "profit_percent": r[6],
                "created_at": r[7],
            }
            for r in cur.fetchall()
        ]
    finally:
        conn.close()


def account_snapshot_query_by_account_since(
    account_id: str, *, since_snapshot_at: str, max_rows: int = 40000
) -> list[dict]:
    """按 snapshot_at 升序返回自 since_snapshot_at（含）起的快照（表：account_balance_snapshots），用于按日汇总现金变化。"""
    cap = max(100, min(100000, int(max_rows)))
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT id, account_id, snapshot_at, cash_balance, equity_usdt,
                      profit_amount, profit_percent, created_at
               FROM account_balance_snapshots
               WHERE account_id = ? AND snapshot_at >= ?
               ORDER BY snapshot_at ASC
               LIMIT ?""",
            (account_id.strip(), (since_snapshot_at or "").strip(), cap),
        )
        return [
            {
                "id": r[0],
                "account_id": r[1],
                "snapshot_at": r[2],
                "cash_balance": r[3],
                "equity_usdt": r[4],
                "profit_amount": r[5],
                "profit_percent": r[6],
                "created_at": r[7],
            }
            for r in cur.fetchall()
        ]
    finally:
        conn.close()


def account_snapshot_exists_on_utc_date(account_id: str, day_yyyy_mm_dd: str) -> bool:
    """该 account 在 UTC 自然日 day 是否已有任意一条 account_balance_snapshots（date 与 SQLite date() 对齐）。"""
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT 1 FROM account_balance_snapshots
               WHERE account_id = ? AND date(snapshot_at) = date(?)
               LIMIT 1""",
            (account_id.strip(), (day_yyyy_mm_dd or "").strip()[:10]),
        )
        return cur.fetchone() is not None
    finally:
        conn.close()


def account_snapshot_last_before_instant(
    account_id: str, instant_iso: str
) -> dict | None:
    """snapshot_at 严格早于 instant_iso 的最后一条（表：account_balance_snapshots；用于账单补全前取权益/现金比例）。"""
    inst = (instant_iso or "").strip()
    if not inst:
        return None
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT id, account_id, snapshot_at, cash_balance, equity_usdt,
                      profit_amount, profit_percent, created_at
               FROM account_balance_snapshots
               WHERE account_id = ? AND snapshot_at < ?
               ORDER BY snapshot_at DESC
               LIMIT 1""",
            (account_id.strip(), inst),
        )
        r = cur.fetchone()
        if not r:
            return None
        return {
            "id": r[0],
            "account_id": r[1],
            "snapshot_at": r[2],
            "cash_balance": r[3],
            "equity_usdt": r[4],
            "profit_amount": r[5],
            "profit_percent": r[6],
            "created_at": r[7],
        }
    finally:
        conn.close()


# ---------- account_open_positions_snapshots（OKX 当前持仓：每合约一行，含 open_leg_count） ----------


def _open_leg_count_from_sizes(long_sz: float, short_sz: float) -> int:
    """同一合约一行内：多、空各有一条持仓腿时计 2（双向），仅一侧计 1。"""
    eps = 1e-12
    return (1 if float(long_sz) > eps else 0) + (1 if float(short_sz) > eps else 0)


def account_open_positions_snapshots_insert_batch(
    account_id: str,
    snapshot_at: str,
    rows: list[dict],
) -> int:
    """写入当前持仓快照：每合约一行（多/空张数、腿数 open_leg_count、最新价、标记价、多/空未实现盈亏与合计）。"""
    aid = (account_id or "").strip()
    ts = (snapshot_at or "").strip()
    if not aid or not ts or not rows:
        return 0
    conn = get_conn()
    n = 0
    try:
        for r in rows:
            inst = str(r.get("inst_id") or "").strip()
            if not inst:
                continue
            lp = float(r.get("long_pos_size") or 0)
            sp = float(r.get("short_pos_size") or 0)
            leg = r.get("open_leg_count")
            if leg is None:
                leg_i = _open_leg_count_from_sizes(lp, sp)
            else:
                leg_i = max(0, min(2, int(leg)))
            conn.execute(
                """INSERT INTO account_open_positions_snapshots
                   (account_id, inst_id, snapshot_at, last_px, long_pos_size, short_pos_size,
                    mark_px, long_upl, short_upl, total_upl, open_leg_count)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    aid,
                    inst,
                    ts,
                    float(r.get("last_px") or 0),
                    lp,
                    sp,
                    float(r.get("mark_px") or 0),
                    float(r.get("long_upl") or 0),
                    float(r.get("short_upl") or 0),
                    float(r.get("total_upl") or 0),
                    leg_i,
                ),
            )
            n += 1
        conn.commit()
    finally:
        conn.close()
    return n


def account_open_positions_snapshots_query_by_account(
    account_id: str,
    *,
    limit: int = 500,
    inst_id: str | None = None,
) -> list[dict]:
    """按 snapshot_at 降序返回入库快照；可选 inst_id 过滤。最多 limit 条。"""
    aid = (account_id or "").strip()
    if not aid:
        return []
    cap = max(1, min(int(limit), 2000))
    inst_f = (inst_id or "").strip()
    conn = get_conn()
    try:
        if inst_f:
            cur = conn.execute(
                """SELECT id, account_id, inst_id, snapshot_at, last_px, long_pos_size,
                          short_pos_size, mark_px, long_upl, short_upl, total_upl,
                          open_leg_count, created_at
                   FROM account_open_positions_snapshots
                   WHERE account_id = ? AND inst_id = ?
                   ORDER BY snapshot_at DESC, id DESC
                   LIMIT ?""",
                (aid, inst_f, cap),
            )
        else:
            cur = conn.execute(
                """SELECT id, account_id, inst_id, snapshot_at, last_px, long_pos_size,
                          short_pos_size, mark_px, long_upl, short_upl, total_upl,
                          open_leg_count, created_at
                   FROM account_open_positions_snapshots
                   WHERE account_id = ?
                   ORDER BY snapshot_at DESC, id DESC
                   LIMIT ?""",
                (aid, cap),
            )
        return [
            {
                "id": r[0],
                "account_id": r[1],
                "inst_id": r[2],
                "snapshot_at": r[3],
                "last_px": r[4],
                "long_pos_size": r[5],
                "short_pos_size": r[6],
                "mark_px": r[7],
                "long_upl": r[8],
                "short_upl": r[9],
                "total_upl": r[10],
                "open_leg_count": r[11],
                "created_at": r[12],
            }
            for r in cur.fetchall()
        ]
    finally:
        conn.close()


def account_month_open_get(account_id: str, year_month: str) -> dict | None:
    """year_month 形如 2026-04。"""
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT account_id, year_month, open_equity, open_cash, recorded_at
               FROM account_month_open WHERE account_id = ? AND year_month = ?""",
            (account_id.strip(), year_month.strip()),
        )
        r = cur.fetchone()
        if not r:
            return None
        oc = r[3]
        return {
            "account_id": r[0],
            "year_month": r[1],
            "open_equity": float(r[2]),
            "open_cash": float(oc) if oc is not None else None,
            "recorded_at": r[4],
        }
    finally:
        conn.close()


def account_month_open_insert_if_absent(
    account_id: str,
    year_month: str,
    open_equity: float,
    recorded_at: str,
    *,
    open_cash: float | None = None,
) -> None:
    """每月仅第一条记录生效（月初首次快照时写入权益与现金）。"""
    conn = get_conn()
    try:
        if IS_POSTGRES:
            conn.execute(
                """INSERT INTO account_month_open
                   (account_id, year_month, open_equity, open_cash, recorded_at)
                   VALUES (?, ?, ?, ?, ?)
                   ON CONFLICT (account_id, year_month) DO NOTHING""",
                (
                    account_id.strip(),
                    year_month.strip(),
                    open_equity,
                    open_cash,
                    recorded_at,
                ),
            )
        else:
            conn.execute(
                """INSERT OR IGNORE INTO account_month_open
                   (account_id, year_month, open_equity, open_cash, recorded_at)
                   VALUES (?, ?, ?, ?, ?)""",
                (
                    account_id.strip(),
                    year_month.strip(),
                    open_equity,
                    open_cash,
                    recorded_at,
                ),
            )
        conn.commit()
    finally:
        conn.close()


def account_month_open_upsert(
    account_id: str,
    year_month: str,
    open_equity: float,
    recorded_at: str,
    *,
    open_cash: float | None = None,
) -> None:
    """写入或覆盖当月 account_month_open（UTC 月初定时任务，幂等）。"""
    conn = get_conn()
    try:
        if IS_POSTGRES:
            conn.execute(
                """INSERT INTO account_month_open
                   (account_id, year_month, open_equity, open_cash, recorded_at)
                   VALUES (?, ?, ?, ?, ?)
                   ON CONFLICT (account_id, year_month) DO UPDATE SET
                     open_equity = EXCLUDED.open_equity,
                     open_cash = EXCLUDED.open_cash,
                     recorded_at = EXCLUDED.recorded_at""",
                (
                    account_id.strip(),
                    year_month.strip(),
                    open_equity,
                    open_cash,
                    recorded_at,
                ),
            )
        else:
            conn.execute(
                """INSERT INTO account_month_open
                   (account_id, year_month, open_equity, open_cash, recorded_at)
                   VALUES (?, ?, ?, ?, ?)
                   ON CONFLICT(account_id, year_month) DO UPDATE SET
                     open_equity = excluded.open_equity,
                     open_cash = excluded.open_cash,
                     recorded_at = excluded.recorded_at""",
                (
                    account_id.strip(),
                    year_month.strip(),
                    open_equity,
                    open_cash,
                    recorded_at,
                ),
            )
        conn.commit()
    finally:
        conn.close()


def account_month_open_list_since(account_id: str, min_year_month: str) -> dict[str, dict]:
    """返回 year_month >= min_year_month（YYYY-MM 字典序）的 account_month_open 行。"""
    aid = account_id.strip()
    lo = (min_year_month or "").strip()
    if not aid:
        return {}
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT year_month, open_equity, open_cash, recorded_at
               FROM account_month_open
               WHERE account_id = ? AND year_month >= ?
               ORDER BY year_month""",
            (aid, lo),
        )
        out: dict[str, dict] = {}
        for r in cur.fetchall():
            ym = str(r[0] or "")
            oc = r[2]
            out[ym] = {
                "open_equity": float(r[1]),
                "open_cash": float(oc) if oc is not None else None,
                "recorded_at": str(r[3] or ""),
            }
        return out
    finally:
        conn.close()


def _fnum(v: object) -> float | None:
    if v is None or v == "":
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def account_positions_history_max_u_time_ms(account_id: str) -> int | None:
    """该账户在库中已入库历史仓位的最大 uTime（毫秒）；无记录返回 None。"""
    aid = (account_id or "").strip()
    if not aid:
        return None
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT MAX(CAST(u_time_ms AS INTEGER)) FROM account_positions_history
               WHERE account_id = ?""",
            (aid,),
        )
        r = cur.fetchone()
        if not r or r[0] is None:
            return None
        v = int(r[0])
        return v if v > 0 else None
    finally:
        conn.close()


def account_positions_history_insert_batch(
    account_id: str,
    rows: list[dict],
    synced_at: str,
) -> int:
    """写入 OKX positions-history 行；按 (account_id, okx_pos_id, u_time_ms) 去重。返回新插入行数。"""
    aid = account_id.strip()
    conn = get_conn()
    inserted = 0
    try:
        for r in rows:
            if not isinstance(r, dict):
                continue
            pid = str(r.get("posId") or "").strip()
            ut = str(r.get("uTime") or "").strip()
            if not pid or not ut:
                continue
            inst = str(r.get("instId") or "").strip()
            if IS_POSTGRES:
                ins_ph = """INSERT INTO account_positions_history
                   (account_id, okx_pos_id, inst_id, inst_type, pos_side, mgn_mode,
                    open_avg_px, close_avg_px, open_max_pos, close_total_pos,
                    pnl, realized_pnl, fee, funding_fee, close_type,
                    c_time_ms, u_time_ms, raw_json, synced_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT (account_id, okx_pos_id, u_time_ms) DO NOTHING"""
            else:
                ins_ph = """INSERT OR IGNORE INTO account_positions_history
                   (account_id, okx_pos_id, inst_id, inst_type, pos_side, mgn_mode,
                    open_avg_px, close_avg_px, open_max_pos, close_total_pos,
                    pnl, realized_pnl, fee, funding_fee, close_type,
                    c_time_ms, u_time_ms, raw_json, synced_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"""
            cur = conn.execute(
                ins_ph,
                (
                    aid,
                    pid,
                    inst,
                    (str(r.get("instType") or "").strip() or None),
                    (str(r.get("posSide") or r.get("direction") or "").strip() or None),
                    (str(r.get("mgnMode") or "").strip() or None),
                    _fnum(r.get("openAvgPx")),
                    _fnum(r.get("closeAvgPx")),
                    str(r.get("openMaxPos") or "") or None,
                    str(r.get("closeTotalPos") or "") or None,
                    _fnum(r.get("pnl")),
                    _fnum(r.get("realizedPnl")),
                    _fnum(r.get("fee")),
                    _fnum(r.get("fundingFee")),
                    str(r.get("type") or "").strip() or None,
                    str(r.get("cTime") or "").strip() or None,
                    ut,
                    json.dumps(r, ensure_ascii=False),
                    synced_at,
                ),
            )
            if cur.rowcount and cur.rowcount > 0:
                inserted += 1
        conn.commit()
        return inserted
    finally:
        conn.close()


def account_positions_history_query_by_account(
    account_id: str,
    limit: int = 500,
    *,
    before_utime_ms: int | None = None,
    since_utime_ms: int | None = None,
) -> list[dict]:
    """按 u_time_ms 倒序返回历史仓位（解析常用字段 + raw_json）。

    before_utime_ms: 仅返回 u_time 严格小于该值的记录（分页游标）。
    since_utime_ms: 仅返回 u_time 大于等于该值的记录（可选时间下界）。
    """
    aid = account_id.strip()
    lim = max(1, int(limit))
    clauses = ["account_id = ?"]
    params: list = [aid]
    if before_utime_ms is not None:
        clauses.append("CAST(u_time_ms AS INTEGER) < ?")
        params.append(int(before_utime_ms))
    if since_utime_ms is not None:
        clauses.append("CAST(u_time_ms AS INTEGER) >= ?")
        params.append(int(since_utime_ms))
    where_sql = " AND ".join(clauses)
    params.append(lim)
    conn = get_conn()
    try:
        cur = conn.execute(
            f"""SELECT id, account_id, okx_pos_id, inst_id, inst_type, pos_side, mgn_mode,
                      open_avg_px, close_avg_px, open_max_pos, close_total_pos,
                      pnl, realized_pnl, fee, funding_fee, close_type,
                      c_time_ms, u_time_ms, raw_json, synced_at
               FROM account_positions_history
               WHERE {where_sql}
               ORDER BY CAST(u_time_ms AS INTEGER) DESC
               LIMIT ?""",
            tuple(params),
        )
        out: list[dict] = []
        for r in cur.fetchall():
            raw = r[18]
            try:
                parsed = json.loads(raw) if raw else {}
            except (TypeError, json.JSONDecodeError):
                parsed = {}
            if not isinstance(parsed, dict):
                parsed = {}
            lev = parsed.get("lever")
            lev_s = str(lev).strip() if lev is not None and str(lev).strip() else None
            pnl_ratio = parsed.get("pnlRatio")
            pr_s = (
                str(pnl_ratio).strip()
                if pnl_ratio is not None and str(pnl_ratio).strip()
                else None
            )
            out.append(
                {
                    "id": r[0],
                    "account_id": r[1],
                    "okx_pos_id": r[2],
                    "inst_id": r[3],
                    "inst_type": r[4],
                    "pos_side": r[5],
                    "mgn_mode": r[6],
                    "open_avg_px": r[7],
                    "close_avg_px": r[8],
                    "open_max_pos": r[9],
                    "close_total_pos": r[10],
                    "pnl": r[11],
                    "realized_pnl": r[12],
                    "fee": r[13],
                    "funding_fee": r[14],
                    "close_type": r[15],
                    "c_time_ms": r[16],
                    "u_time_ms": r[17],
                    "lever": lev_s,
                    "pnl_ratio": pr_s,
                    "raw": parsed,
                    "synced_at": r[19],
                }
            )
        return out
    finally:
        conn.close()


def account_positions_daily_realized(
    account_id: str, year: int, month: int
) -> list[dict[str, Any]]:
    """
    按 UTC 自然日汇总历史平仓盈亏与笔数。
    单笔净盈亏 = COALESCE(pnl,0) + COALESCE(fee,0) + COALESCE(funding_fee,0)（与 OKX 费用字段一致）。
    """
    from datetime import datetime, timezone

    aid = (account_id or "").strip()
    if not aid or year < 2000 or year > 2100 or month < 1 or month > 12:
        return []
    try:
        start = datetime(year, month, 1, tzinfo=timezone.utc)
    except ValueError:
        return []
    if month == 12:
        end = datetime(year + 1, 1, 1, tzinfo=timezone.utc)
    else:
        end = datetime(year, month + 1, 1, tzinfo=timezone.utc)
    start_ms = int(start.timestamp() * 1000)
    end_ms = int(end.timestamp() * 1000)

    conn = get_conn()
    try:
        if IS_POSTGRES:
            cur = conn.execute(
                """
                SELECT to_char(
                         timezone('UTC', to_timestamp((u_time_ms::bigint) / 1000.0)),
                         'YYYY-MM-DD'
                       ) AS d,
                       SUM(COALESCE(pnl, 0) + COALESCE(fee, 0) + COALESCE(funding_fee, 0)) AS net_pnl,
                       COUNT(*) AS close_count
                FROM account_positions_history
                WHERE account_id = ?
                  AND (u_time_ms::bigint) >= ?
                  AND (u_time_ms::bigint) < ?
                GROUP BY 1
                ORDER BY 1
                """,
                (aid, start_ms, end_ms),
            )
        else:
            cur = conn.execute(
                """
                SELECT strftime('%Y-%m-%d',
                       datetime(CAST(u_time_ms AS INTEGER) / 1000, 'unixepoch')) AS d,
                       SUM(COALESCE(pnl, 0) + COALESCE(fee, 0) + COALESCE(funding_fee, 0)) AS net_pnl,
                       COUNT(*) AS close_count
                FROM account_positions_history
                WHERE account_id = ?
                  AND CAST(u_time_ms AS INTEGER) >= ?
                  AND CAST(u_time_ms AS INTEGER) < ?
                GROUP BY d
                ORDER BY d
                """,
                (aid, start_ms, end_ms),
            )
        return [
            {
                "day": str(r[0]),
                "net_pnl": float(r[1] or 0),
                "close_count": int(r[2] or 0),
            }
            for r in cur.fetchall()
            if r[0]
        ]
    finally:
        conn.close()


def account_ids_for_daily_performance_rebuild() -> list[str]:
    """
    参与 account_daily_performance 重建的账户 id：account_list 全量 ∪
    account_positions_history 中出现过的 account_id（去重、排序）。
    """
    conn = get_conn()
    try:
        ids: set[str] = set()
        cur = conn.execute(
            "SELECT DISTINCT account_id FROM account_positions_history "
            "WHERE account_id IS NOT NULL AND TRIM(account_id) != ''"
        )
        for r in cur.fetchall():
            s = str(r[0] or "").strip()
            if s:
                ids.add(s)
        cur = conn.execute("SELECT account_id FROM account_list")
        for r in cur.fetchall():
            s = str(r[0] or "").strip()
            if s:
                ids.add(s)
        return sorted(ids)
    finally:
        conn.close()


def account_daily_performance_query_month(
    account_id: str, year: int, month: int
) -> list[dict[str, Any]]:
    """读库表 account_daily_performance（UTC 自然日）。"""
    from datetime import datetime, timezone

    aid = (account_id or "").strip()
    if not aid or year < 2000 or year > 2100 or month < 1 or month > 12:
        return []
    try:
        start = datetime(year, month, 1, tzinfo=timezone.utc)
    except ValueError:
        return []
    if month == 12:
        end = datetime(year + 1, 1, 1, tzinfo=timezone.utc)
    else:
        end = datetime(year, month + 1, 1, tzinfo=timezone.utc)
    start_s = start.strftime("%Y-%m-%d")
    end_s = end.strftime("%Y-%m-%d")

    conn = get_conn()
    try:
        cur = conn.execute(
            """
            SELECT day, net_realized_pnl, close_count, equity_base, pnl_pct,
                   benchmark_inst_id, market_tr, efficiency_ratio, updated_at
            FROM account_daily_performance
            WHERE account_id = ? AND day >= ? AND day < ?
            ORDER BY day
            """,
            (aid, start_s, end_s),
        )
        return [
            {
                "day": str(r[0]),
                "net_pnl": float(r[1] or 0),
                "close_count": int(r[2] or 0),
                "equity_base": float(r[3]) if r[3] is not None else None,
                "pnl_pct": float(r[4]) if r[4] is not None else None,
                "benchmark_inst_id": str(r[5] or ""),
                "market_tr": float(r[6]) if r[6] is not None else None,
                "efficiency_ratio": float(r[7]) if r[7] is not None else None,
                "updated_at": str(r[8] or ""),
            }
            for r in cur.fetchall()
        ]
    finally:
        conn.close()


def account_daily_performance_rebuild_for_accounts(
    account_ids: list[str],
    benchmark_inst_by_account: dict[str, str],
    *,
    default_benchmark_inst: str = "PEPE-USDT-SWAP",
) -> None:
    """
    按 account_positions_history 按日汇总平仓净盈亏，写入 account_daily_performance。
    equity_base：该 UTC 日 00:00 前最后一笔 account_balance_snapshots.equity_usdt；无快照则用 account_list.initial_capital。
    pnl_pct = net / equity_base * 100（权益为 0 或缺失则为 NULL）。
    efficiency_ratio：与 strategy_efficiency 一致，net / (market_tr * 1e9)，无 TR 则为 NULL。
    """
    from datetime import datetime, timezone

    from strategy_efficiency import close_pnl_efficiency_ratio

    def _day_boundary_iso(day_yyyy_mm_dd: str) -> str:
        d = (day_yyyy_mm_dd or "").strip()
        return f"{d}T00:00:00.000Z" if d else ""

    conn = get_conn()
    try:
        now_s = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        for aid_raw in account_ids:
            aid = (aid_raw or "").strip()
            if not aid:
                continue
            bench = (
                (benchmark_inst_by_account.get(aid) or "").strip()
                or default_benchmark_inst
            )
            meta = account_list_get(aid)
            initial = float(meta["initial_capital"]) if meta else 0.0

            if IS_POSTGRES:
                cur = conn.execute(
                    """
                    SELECT d, net_pnl, close_count FROM (
                        SELECT to_char(
                                 timezone('UTC', to_timestamp((u_time_ms::bigint) / 1000.0)),
                                 'YYYY-MM-DD'
                               ) AS d,
                               SUM(COALESCE(pnl, 0) + COALESCE(fee, 0) + COALESCE(funding_fee, 0)) AS net_pnl,
                               COUNT(*) AS close_count
                        FROM account_positions_history
                        WHERE account_id = ?
                        GROUP BY 1
                    ) t
                    WHERE d IS NOT NULL AND d <> ''
                    ORDER BY d
                    """,
                    (aid,),
                )
            else:
                cur = conn.execute(
                    """
                    SELECT strftime('%Y-%m-%d',
                           datetime(CAST(u_time_ms AS INTEGER) / 1000, 'unixepoch')) AS d,
                           SUM(COALESCE(pnl, 0) + COALESCE(fee, 0) + COALESCE(funding_fee, 0)) AS net_pnl,
                           COUNT(*) AS close_count
                    FROM account_positions_history
                    WHERE account_id = ?
                    GROUP BY d
                    HAVING d IS NOT NULL AND d != ''
                    ORDER BY d
                    """,
                    (aid,),
                )
            day_rows = [(str(r[0]), float(r[1] or 0), int(r[2] or 0)) for r in cur.fetchall()]
            conn.execute(
                "DELETE FROM account_daily_performance WHERE account_id = ?",
                (aid,),
            )
            if not day_rows:
                continue

            cur_sn = conn.execute(
                """
                SELECT snapshot_at, equity_usdt
                FROM account_balance_snapshots
                WHERE account_id = ?
                ORDER BY snapshot_at ASC
                """,
                (aid,),
            )
            snaps = [(str(r[0]), float(r[1] or 0.0)) for r in cur_sn.fetchall()]

            days_list = [d for d, _, _ in day_rows]
            tr_map: dict[str, float] = {}
            if days_list and bench:
                placeholders = ",".join("?" * len(days_list))
                cur_tr = conn.execute(
                    f"""
                    SELECT day, tr FROM market_daily_bars
                    WHERE inst_id = ? AND day IN ({placeholders})
                    """,
                    (bench, *days_list),
                )
                for r in cur_tr.fetchall():
                    tr_map[str(r[0])] = float(r[1] or 0.0)

            si = 0
            last_eq_before: float | None = None
            for day, net_pnl, close_count in day_rows:
                boundary = _day_boundary_iso(day)
                while si < len(snaps) and snaps[si][0] < boundary:
                    last_eq_before = snaps[si][1]
                    si += 1
                if last_eq_before is not None and last_eq_before > 0:
                    equity_base = last_eq_before
                elif initial > 0:
                    equity_base = initial
                else:
                    equity_base = None

                pnl_pct: float | None = None
                if equity_base is not None and float(equity_base) > 0:
                    pnl_pct = float(net_pnl) / float(equity_base) * 100.0

                mtr = tr_map.get(day)
                market_tr_v = float(mtr) if mtr is not None else None
                eff = (
                    close_pnl_efficiency_ratio(net_pnl, market_tr_v)
                    if market_tr_v is not None
                    else None
                )

                conn.execute(
                    """
                    INSERT INTO account_daily_performance
                    (account_id, day, net_realized_pnl, close_count, equity_base, pnl_pct,
                     benchmark_inst_id, market_tr, efficiency_ratio, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        aid,
                        day,
                        net_pnl,
                        close_count,
                        equity_base,
                        pnl_pct,
                        bench,
                        market_tr_v,
                        eff,
                        now_s,
                    ),
                )
            conn.commit()
    finally:
        conn.close()


# ---------- 策略能效：全站共用 OKX 日线缓存（market_daily_bars） ----------


def market_daily_bars_has_day(inst_id: str, day: str) -> bool:
    conn = get_conn()
    try:
        cur = conn.execute(
            "SELECT 1 FROM market_daily_bars WHERE inst_id = ? AND day = ? LIMIT 1",
            ((inst_id or "").strip(), (day or "").strip()),
        )
        return cur.fetchone() is not None
    finally:
        conn.close()


def market_daily_bars_upsert_many(
    rows: list[
        tuple[str, str, float, float, float, float, float]
    ],
) -> None:
    """
    批量写入 OKX 日线缓存，单连接单事务，减轻 SQLite 并发锁竞争。
    每项为 (inst_id, day, open, high, low, close, tr)。
    """
    if not rows:
        return
    conn = get_conn()
    try:
        if IS_POSTGRES:
            sql_pg = """INSERT INTO market_daily_bars
                   (inst_id, day, "open", "high", "low", "close", tr, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                   ON CONFLICT (inst_id, day) DO UPDATE SET
                     "open" = EXCLUDED."open",
                     "high" = EXCLUDED."high",
                     "low" = EXCLUDED."low",
                     "close" = EXCLUDED."close",
                     tr = EXCLUDED.tr,
                     updated_at = CURRENT_TIMESTAMP"""
            for inst_id, day, open_v, high_v, low_v, close_v, tr_v in rows:
                conn.execute(
                    sql_pg,
                    (
                        (inst_id or "").strip(),
                        (day or "").strip(),
                        float(open_v),
                        float(high_v),
                        float(low_v),
                        float(close_v),
                        float(tr_v),
                    ),
                )
        else:
            sql_l = """INSERT INTO market_daily_bars
                   (inst_id, day, open, high, low, close, tr, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))
                   ON CONFLICT(inst_id, day) DO UPDATE SET
                     open = excluded.open,
                     high = excluded.high,
                     low = excluded.low,
                     close = excluded.close,
                     tr = excluded.tr,
                     updated_at = datetime('now')"""
            for inst_id, day, open_v, high_v, low_v, close_v, tr_v in rows:
                conn.execute(
                    sql_l,
                    (
                        (inst_id or "").strip(),
                        (day or "").strip(),
                        float(open_v),
                        float(high_v),
                        float(low_v),
                        float(close_v),
                        float(tr_v),
                    ),
                )
        conn.commit()
    finally:
        conn.close()


def market_daily_bars_upsert(
    inst_id: str,
    day: str,
    open_v: float,
    high_v: float,
    low_v: float,
    close_v: float,
    tr_v: float,
) -> None:
    market_daily_bars_upsert_many(
        [
            (
                (inst_id or "").strip(),
                (day or "").strip(),
                float(open_v),
                float(high_v),
                float(low_v),
                float(close_v),
                float(tr_v),
            )
        ]
    )


def market_daily_bars_list_since(inst_id: str, min_day: str) -> list[dict[str, Any]]:
    """UTC 日历日 day >= min_day，按 day 升序。项与 OKX merge 用字段一致。"""
    conn = get_conn()
    try:
        if IS_POSTGRES:
            cur = conn.execute(
                """SELECT day, "open", "high", "low", "close", tr
                   FROM market_daily_bars
                   WHERE inst_id = ? AND day >= ?
                   ORDER BY day ASC""",
                ((inst_id or "").strip(), (min_day or "").strip()),
            )
        else:
            cur = conn.execute(
                """SELECT day, open, high, low, close, tr
                   FROM market_daily_bars
                   WHERE inst_id = ? AND day >= ?
                   ORDER BY day ASC""",
                ((inst_id or "").strip(), (min_day or "").strip()),
            )
        return [
            {
                "day": str(r[0]),
                "open": float(r[1] or 0.0),
                "high": float(r[2] or 0.0),
                "low": float(r[3] or 0.0),
                "close": float(r[4] or 0.0),
                "tr": float(r[5] or 0.0),
            }
            for r in cur.fetchall()
        ]
    finally:
        conn.close()
