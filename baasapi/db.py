# -*- coding: utf-8 -*-
"""持久化：默认 PostgreSQL；可通过 database_config.json 或环境变量切换 SQLite（见 db_backend）。"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any

# 从项目根执行「from baasapi.db import …」时，须将本目录加入 path，才能解析同目录的 db_backend
_server_dir = str(Path(__file__).resolve().parent)
if _server_dir not in sys.path:
    sys.path.insert(0, _server_dir)

from db_backend import (
    DB_DIR,
    DB_INTEGRITY_ERRORS,
    DB_OPERATIONAL_ERRORS,
    DB_PATH,
    IS_POSTGRES,
    PG_SCHEMA,
    PgConnectionWrapper,
    SERVER_DIR,
    get_connection,
    pg_run_init,
)

# 仅 SQLite 模式需要；PostgreSQL（如 AWS）上 Python 可能无 _sqlite3，须在确认 backend 后再加载。
sqlite3: Any = None


def _ensure_sqlite3() -> Any:
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


if not IS_POSTGRES:
    _ensure_sqlite3()

# 与 SQLite 类型注解兼容：PostgreSQL 时使用封装连接
def get_conn() -> Any:
    return get_connection()


def _run_user_migrations_pg(conn: PgConnectionWrapper) -> None:
    """PostgreSQL：执行 add_user_*.sql（INSERT 转为 ON CONFLICT；ALTER 失败则忽略）。"""
    try:
        import psycopg2
    except ImportError:
        psycopg2 = None  # type: ignore[misc, assignment]
    # 新库已由 PG_INIT 含 full_name/phone 等列时，ALTER 会报 DuplicateColumn（ProgrammingError）
    _pg_alter_errors: tuple[type[BaseException], ...] = DB_OPERATIONAL_ERRORS
    if psycopg2 is not None:
        _pg_alter_errors = (*DB_OPERATIONAL_ERRORS, psycopg2.ProgrammingError)

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
                except _pg_alter_errors:
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
    """执行 baasapi/migrations/add_user_*.sql，将用户同步到当前数据库（含 AWS 部署）。"""
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
    # account_season 列名迁移见 _ensure_account_season_equity_balance_column_names


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


def _drop_legacy_bot_profit_tables(conn: sqlite3.Connection) -> None:
    """废弃旧 bot 盈利快照表；收益与策略效能已统一使用 account_balance_snapshots。"""
    for t in ("tradingbot_profit_snapshots", "tradingbot_profit", "bot_profit_snapshots"):
        conn.execute(f"DROP TABLE IF EXISTS {t}")


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


def _ensure_account_open_positions_avg_columns(
    conn: sqlite3.Connection | PgConnectionWrapper,
) -> None:
    """account_open_positions_snapshots 补列：多/空加权成本线（与 OKX avgPx 一致）。"""
    if IS_POSTGRES:
        try:
            cur = conn.execute(
                """
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = %s
                  AND table_name = 'account_open_positions_snapshots'
                """
                , (PG_SCHEMA,)
            )
            cols = {str(r[0]) for r in cur.fetchall()}
            if "long_avg_px" not in cols:
                conn.execute(
                    "ALTER TABLE account_open_positions_snapshots "
                    "ADD COLUMN long_avg_px DOUBLE PRECISION NOT NULL DEFAULT 0"
                )
            if "short_avg_px" not in cols:
                conn.execute(
                    "ALTER TABLE account_open_positions_snapshots "
                    "ADD COLUMN short_avg_px DOUBLE PRECISION NOT NULL DEFAULT 0"
                )
            conn.commit()
        except Exception:
            conn.rollback()
        return
    if not isinstance(conn, sqlite3.Connection):
        return
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='account_open_positions_snapshots'"
    )
    if not cur.fetchone():
        return
    cur = conn.execute("PRAGMA table_info(account_open_positions_snapshots)")
    cols = {str(r[1]) for r in cur.fetchall()}
    if "long_avg_px" not in cols:
        conn.execute(
            "ALTER TABLE account_open_positions_snapshots "
            "ADD COLUMN long_avg_px REAL NOT NULL DEFAULT 0"
        )
    if "short_avg_px" not in cols:
        conn.execute(
            "ALTER TABLE account_open_positions_snapshots "
            "ADD COLUMN short_avg_px REAL NOT NULL DEFAULT 0"
        )


def _ensure_account_open_positions_liq_columns(
    conn: sqlite3.Connection | PgConnectionWrapper,
) -> None:
    """account_open_positions_snapshots 补列：OKX liqPx 聚合后的多/空预估强平价。"""
    if IS_POSTGRES:
        try:
            cur = conn.execute(
                """
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = %s
                  AND table_name = 'account_open_positions_snapshots'
                """,
                (PG_SCHEMA,),
            )
            cols = {str(r[0]) for r in cur.fetchall()}
            if "long_liq_px" not in cols:
                conn.execute(
                    "ALTER TABLE account_open_positions_snapshots "
                    "ADD COLUMN long_liq_px DOUBLE PRECISION NOT NULL DEFAULT 0"
                )
            if "short_liq_px" not in cols:
                conn.execute(
                    "ALTER TABLE account_open_positions_snapshots "
                    "ADD COLUMN short_liq_px DOUBLE PRECISION NOT NULL DEFAULT 0"
                )
            conn.commit()
        except Exception:
            conn.rollback()
        return
    if not isinstance(conn, sqlite3.Connection):
        return
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='account_open_positions_snapshots'"
    )
    if not cur.fetchone():
        return
    cur = conn.execute("PRAGMA table_info(account_open_positions_snapshots)")
    cols = {str(r[1]) for r in cur.fetchall()}
    if "long_liq_px" not in cols:
        conn.execute(
            "ALTER TABLE account_open_positions_snapshots "
            "ADD COLUMN long_liq_px REAL NOT NULL DEFAULT 0"
        )
    if "short_liq_px" not in cols:
        conn.execute(
            "ALTER TABLE account_open_positions_snapshots "
            "ADD COLUMN short_liq_px REAL NOT NULL DEFAULT 0"
        )


def _ensure_account_balance_snapshots_margin_columns(
    conn: sqlite3.Connection | PgConnectionWrapper,
) -> None:
    """补列 available_margin / used_margin；旧行将原 cash_balance（实为 availEq）迁至 available_margin 后 cash_balance 置 0 待新同步。"""
    if IS_POSTGRES:
        try:
            cur = conn.execute(
                """
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = %s
                  AND table_name = 'account_balance_snapshots'
                """
                , (PG_SCHEMA,)
            )
            cols = {str(r[0]) for r in cur.fetchall()}
            need_migrate = False
            if "available_margin" not in cols:
                conn.execute(
                    "ALTER TABLE account_balance_snapshots "
                    "ADD COLUMN available_margin DOUBLE PRECISION NOT NULL DEFAULT 0"
                )
                need_migrate = True
            if "used_margin" not in cols:
                conn.execute(
                    "ALTER TABLE account_balance_snapshots "
                    "ADD COLUMN used_margin DOUBLE PRECISION NOT NULL DEFAULT 0"
                )
                need_migrate = True
            if need_migrate:
                conn.execute(
                    "UPDATE account_balance_snapshots SET available_margin = cash_balance "
                    "WHERE COALESCE(available_margin, 0) = 0"
                )
                conn.execute("UPDATE account_balance_snapshots SET cash_balance = 0")
            conn.commit()
        except Exception:
            conn.rollback()
        return
    if not isinstance(conn, sqlite3.Connection):
        return
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='account_balance_snapshots'"
    )
    if not cur.fetchone():
        return
    cur = conn.execute("PRAGMA table_info(account_balance_snapshots)")
    cols = {str(r[1]) for r in cur.fetchall()}
    need_migrate = False
    if "available_margin" not in cols:
        conn.execute(
            "ALTER TABLE account_balance_snapshots ADD COLUMN available_margin "
            "REAL NOT NULL DEFAULT 0"
        )
        need_migrate = True
    if "used_margin" not in cols:
        conn.execute(
            "ALTER TABLE account_balance_snapshots ADD COLUMN used_margin "
            "REAL NOT NULL DEFAULT 0"
        )
        need_migrate = True
    if need_migrate:
        conn.execute(
            "UPDATE account_balance_snapshots SET available_margin = cash_balance "
            "WHERE IFNULL(available_margin, 0) = 0"
        )
        conn.execute("UPDATE account_balance_snapshots SET cash_balance = 0")


def _rename_account_balance_snapshots_cash_profit_to_balance_profit(
    conn: sqlite3.Connection | PgConnectionWrapper,
) -> None:
    """cash_profit_amount / cash_profit_percent → balance_profit_*（幂等）。"""
    if IS_POSTGRES:
        try:
            cur = conn.execute(
                """
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = %s
                  AND table_name = 'account_balance_snapshots'
                """,
                (PG_SCHEMA,),
            )
            cols = {str(r[0]) for r in cur.fetchall()}
            if not cols:
                return
            if (
                "balance_profit_amount" not in cols
                and "cash_profit_amount" in cols
            ):
                conn.execute(
                    "ALTER TABLE account_balance_snapshots "
                    "RENAME COLUMN cash_profit_amount TO balance_profit_amount"
                )
            if (
                "balance_profit_percent" not in cols
                and "cash_profit_percent" in cols
            ):
                conn.execute(
                    "ALTER TABLE account_balance_snapshots "
                    "RENAME COLUMN cash_profit_percent TO balance_profit_percent"
                )
            conn.commit()
        except Exception:
            conn.rollback()
        return
    if not isinstance(conn, sqlite3.Connection):
        return
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='account_balance_snapshots'"
    )
    if not cur.fetchone():
        return
    cur = conn.execute("PRAGMA table_info(account_balance_snapshots)")
    cols = {str(r[1]) for r in cur.fetchall()}
    if "balance_profit_amount" not in cols and "cash_profit_amount" in cols:
        conn.execute(
            "ALTER TABLE account_balance_snapshots RENAME COLUMN "
            "cash_profit_amount TO balance_profit_amount"
        )
    if "balance_profit_percent" not in cols and "cash_profit_percent" in cols:
        conn.execute(
            "ALTER TABLE account_balance_snapshots RENAME COLUMN "
            "cash_profit_percent TO balance_profit_percent"
        )


def _ensure_account_balance_snapshots_balance_profit_columns(
    conn: sqlite3.Connection | PgConnectionWrapper,
) -> None:
    """补列 balance_profit_amount / balance_profit_percent（相对 account_list.initial_capital 的 USDT 资产余额口径）。"""
    if IS_POSTGRES:
        try:
            cur = conn.execute(
                """
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = %s
                  AND table_name = 'account_balance_snapshots'
                """
                ,
                (PG_SCHEMA,),
            )
            cols = {str(r[0]) for r in cur.fetchall()}
            if not cols:
                return
            if "balance_profit_amount" not in cols:
                conn.execute(
                    "ALTER TABLE account_balance_snapshots "
                    "ADD COLUMN balance_profit_amount DOUBLE PRECISION NOT NULL DEFAULT 0"
                )
            if "balance_profit_percent" not in cols:
                conn.execute(
                    "ALTER TABLE account_balance_snapshots "
                    "ADD COLUMN balance_profit_percent DOUBLE PRECISION NOT NULL DEFAULT 0"
                )
            conn.commit()
        except Exception:
            conn.rollback()
        return
    if not isinstance(conn, sqlite3.Connection):
        return
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='account_balance_snapshots'"
    )
    if not cur.fetchone():
        return
    cur = conn.execute("PRAGMA table_info(account_balance_snapshots)")
    cols = {str(r[1]) for r in cur.fetchall()}
    if "balance_profit_amount" not in cols:
        conn.execute(
            "ALTER TABLE account_balance_snapshots ADD COLUMN balance_profit_amount "
            "REAL NOT NULL DEFAULT 0"
        )
    if "balance_profit_percent" not in cols:
        conn.execute(
            "ALTER TABLE account_balance_snapshots ADD COLUMN balance_profit_percent "
            "REAL NOT NULL DEFAULT 0"
        )


def _ensure_account_balance_snapshots_equity_profit_column_rename(
    conn: sqlite3.Connection | PgConnectionWrapper,
) -> None:
    """profit_amount / profit_percent → equity_profit_amount / equity_profit_percent（仅 account_balance_snapshots）。"""
    if IS_POSTGRES:
        try:
            cur = conn.execute(
                """
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = %s
                  AND table_name = 'account_balance_snapshots'
                """,
                (PG_SCHEMA,),
            )
            cols = {str(r[0]) for r in cur.fetchall()}
            if not cols:
                return
            if (
                "equity_profit_amount" in cols
                and "equity_profit_percent" in cols
            ):
                return
            if (
                "equity_profit_amount" not in cols
                and "profit_amount" in cols
            ):
                conn.execute(
                    "ALTER TABLE account_balance_snapshots "
                    "RENAME COLUMN profit_amount TO equity_profit_amount"
                )
            if (
                "equity_profit_percent" not in cols
                and "profit_percent" in cols
            ):
                conn.execute(
                    "ALTER TABLE account_balance_snapshots "
                    "RENAME COLUMN profit_percent TO equity_profit_percent"
                )
            conn.commit()
        except Exception:
            conn.rollback()
        return
    if not isinstance(conn, sqlite3.Connection):
        return
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='account_balance_snapshots'"
    )
    if not cur.fetchone():
        return
    cur = conn.execute("PRAGMA table_info(account_balance_snapshots)")
    cols = {str(r[1]) for r in cur.fetchall()}
    if "equity_profit_amount" in cols and "equity_profit_percent" in cols:
        return
    if "equity_profit_amount" not in cols and "profit_amount" in cols:
        conn.execute(
            "ALTER TABLE account_balance_snapshots RENAME COLUMN "
            "profit_amount TO equity_profit_amount"
        )
    if "equity_profit_percent" not in cols and "profit_percent" in cols:
        conn.execute(
            "ALTER TABLE account_balance_snapshots RENAME COLUMN "
            "profit_percent TO equity_profit_percent"
        )


def _drop_account_daily_performance_realized_chain_columns(
    conn: sqlite3.Connection | PgConnectionWrapper,
) -> None:
    """移除 account_daily_performance 链式已实现列（已不再使用）。"""
    if IS_POSTGRES:
        try:
            conn.execute(
                "ALTER TABLE account_daily_performance "
                "DROP COLUMN IF EXISTS equity_base_realized_chain"
            )
            conn.execute(
                "ALTER TABLE account_daily_performance "
                "DROP COLUMN IF EXISTS pnl_pct_realized_chain"
            )
            conn.commit()
        except Exception:
            conn.rollback()
        return
    if not isinstance(conn, sqlite3.Connection):
        return
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='account_daily_performance'"
    )
    if not cur.fetchone():
        return
    cur = conn.execute("PRAGMA table_info(account_daily_performance)")
    cols = {str(r[1]) for r in cur.fetchall()}
    for col in ("equity_base_realized_chain", "pnl_pct_realized_chain"):
        if col not in cols:
            continue
        try:
            conn.execute(
                f"ALTER TABLE account_daily_performance DROP COLUMN {col}"
            )
        except (sqlite3.OperationalError, OSError):
            pass


def _ensure_account_month_balance_baseline_table_rename(
    conn: sqlite3.Connection | PgConnectionWrapper,
) -> None:
    """历史表 account_month_open 重命名为 account_month_balance_baseline（新名已存在则跳过）。"""
    new_t = "account_month_balance_baseline"
    old_t = "account_month_open"
    if IS_POSTGRES:
        try:
            cur = conn.execute(
                """
                SELECT table_name FROM information_schema.tables
                WHERE table_schema = %s
                  AND table_name IN (%s, %s)
                """,
                (PG_SCHEMA, new_t, old_t),
            )
            names = {str(r[0]) for r in cur.fetchall()}
            if new_t in names:
                return
            if old_t in names:
                conn.execute(f'ALTER TABLE "{old_t}" RENAME TO "{new_t}"')
                conn.commit()
        except Exception:
            conn.rollback()
        return
    if not isinstance(conn, sqlite3.Connection):
        return
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN (?, ?)",
        (new_t, old_t),
    )
    have = {str(r[0]) for r in cur.fetchall()}
    if new_t in have:
        return
    if old_t in have:
        conn.execute(f"ALTER TABLE {old_t} RENAME TO {new_t}")


def _ensure_account_month_balance_baseline_initial_balance(
    conn: sqlite3.Connection | PgConnectionWrapper,
) -> None:
    """open_cash 列更名为 initial_balance。"""
    if IS_POSTGRES:
        try:
            cur = conn.execute(
                """
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = %s
                  AND table_name = 'account_month_balance_baseline'
                """
                , (PG_SCHEMA,)
            )
            cols = {str(r[0]) for r in cur.fetchall()}
            if "initial_balance" in cols:
                return
            if "open_cash" in cols:
                conn.execute(
                    "ALTER TABLE account_month_balance_baseline "
                    "RENAME COLUMN open_cash TO initial_balance"
                )
            else:
                conn.execute(
                    "ALTER TABLE account_month_balance_baseline "
                    "ADD COLUMN initial_balance DOUBLE PRECISION"
                )
            conn.commit()
        except Exception:
            conn.rollback()
        return
    if not isinstance(conn, sqlite3.Connection):
        return
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='account_month_balance_baseline'"
    )
    if not cur.fetchone():
        return
    cur = conn.execute("PRAGMA table_info(account_month_balance_baseline)")
    cols = {str(r[1]) for r in cur.fetchall()}
    if "initial_balance" in cols:
        return
    if "open_cash" in cols:
        conn.execute(
            "ALTER TABLE account_month_balance_baseline "
            "RENAME COLUMN open_cash TO initial_balance"
        )
    else:
        conn.execute(
            "ALTER TABLE account_month_balance_baseline "
            "ADD COLUMN initial_balance REAL"
        )


def _ensure_account_month_balance_baseline_open_equity_to_initial_equity(
    conn: sqlite3.Connection | PgConnectionWrapper,
) -> None:
    """open_equity / 误拼 open_equlity 列更名为 initial_equity。"""
    if IS_POSTGRES:
        try:
            cur = conn.execute(
                """
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = %s
                  AND table_name = 'account_month_balance_baseline'
                """,
                (PG_SCHEMA,),
            )
            cols = {str(r[0]) for r in cur.fetchall()}
            if not cols:
                return
            if "initial_equity" in cols:
                return
            if "open_equity" in cols:
                conn.execute(
                    "ALTER TABLE account_month_balance_baseline "
                    "RENAME COLUMN open_equity TO initial_equity"
                )
            elif "open_equlity" in cols:
                conn.execute(
                    "ALTER TABLE account_month_balance_baseline "
                    "RENAME COLUMN open_equlity TO initial_equity"
                )
            else:
                conn.execute(
                    "ALTER TABLE account_month_balance_baseline "
                    "ADD COLUMN initial_equity DOUBLE PRECISION NOT NULL DEFAULT 0"
                )
            conn.commit()
        except Exception:
            conn.rollback()
        return
    if not isinstance(conn, sqlite3.Connection):
        return
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='account_month_balance_baseline'"
    )
    if not cur.fetchone():
        return
    cur = conn.execute("PRAGMA table_info(account_month_balance_baseline)")
    cols = {str(r[1]) for r in cur.fetchall()}
    if "initial_equity" in cols:
        return
    if "open_equity" in cols:
        conn.execute(
            "ALTER TABLE account_month_balance_baseline "
            "RENAME COLUMN open_equity TO initial_equity"
        )
    elif "open_equlity" in cols:
        conn.execute(
            "ALTER TABLE account_month_balance_baseline "
            "RENAME COLUMN open_equlity TO initial_equity"
        )
    else:
        conn.execute(
            "ALTER TABLE account_month_balance_baseline "
            "ADD COLUMN initial_equity REAL NOT NULL DEFAULT 0"
        )


def _ensure_account_season_equity_balance_column_names(
    conn: sqlite3.Connection | PgConnectionWrapper,
) -> None:
    """account_season：权益列 → initial_equity/final_equity；USDT 余额（原 cash）→ initial_balance/final_balance。

    旧表可能为 (initial_balance, final_balance 表示权益 + initial_cash/final_cash)，
    或仅权益两列；迁移后与新库 CREATE 一致。
    """
    if IS_POSTGRES:
        try:
            cur = conn.execute(
                """
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = %s
                  AND table_name = 'account_season'
                """,
                (PG_SCHEMA,),
            )
            cols = {str(r[0]) for r in cur.fetchall()}
            if not cols or "initial_equity" in cols:
                return
            if "initial_cash" in cols:
                conn.execute(
                    "ALTER TABLE account_season RENAME COLUMN initial_balance TO initial_equity"
                )
                conn.execute(
                    "ALTER TABLE account_season RENAME COLUMN final_balance TO final_equity"
                )
                conn.execute(
                    "ALTER TABLE account_season RENAME COLUMN initial_cash TO initial_balance"
                )
                conn.execute(
                    "ALTER TABLE account_season RENAME COLUMN final_cash TO final_balance"
                )
            elif "initial_balance" in cols:
                conn.execute(
                    "ALTER TABLE account_season RENAME COLUMN initial_balance TO initial_equity"
                )
                conn.execute(
                    "ALTER TABLE account_season RENAME COLUMN final_balance TO final_equity"
                )
                cur2 = conn.execute(
                    """
                    SELECT column_name FROM information_schema.columns
                    WHERE table_schema = %s
                      AND table_name = 'account_season'
                    """,
                    (PG_SCHEMA,),
                )
                cols2 = {str(r[0]) for r in cur2.fetchall()}
                if "initial_balance" not in cols2:
                    conn.execute(
                        "ALTER TABLE account_season ADD COLUMN initial_balance DOUBLE PRECISION"
                    )
                if "final_balance" not in cols2:
                    conn.execute(
                        "ALTER TABLE account_season ADD COLUMN final_balance DOUBLE PRECISION"
                    )
            conn.commit()
        except Exception:
            conn.rollback()
        return
    if not isinstance(conn, sqlite3.Connection):
        return
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='account_season'"
    )
    if not cur.fetchone():
        return
    cur = conn.execute("PRAGMA table_info(account_season)")
    cols = {str(r[1]) for r in cur.fetchall()}
    if not cols or "initial_equity" in cols:
        return
    try:
        if "initial_cash" in cols:
            conn.execute(
                "ALTER TABLE account_season RENAME COLUMN initial_balance TO initial_equity"
            )
            conn.execute(
                "ALTER TABLE account_season RENAME COLUMN final_balance TO final_equity"
            )
            conn.execute(
                "ALTER TABLE account_season RENAME COLUMN initial_cash TO initial_balance"
            )
            conn.execute(
                "ALTER TABLE account_season RENAME COLUMN final_cash TO final_balance"
            )
        elif "initial_balance" in cols:
            conn.execute(
                "ALTER TABLE account_season RENAME COLUMN initial_balance TO initial_equity"
            )
            conn.execute(
                "ALTER TABLE account_season RENAME COLUMN final_balance TO final_equity"
            )
            cur = conn.execute("PRAGMA table_info(account_season)")
            cols2 = {str(r[1]) for r in cur.fetchall()}
            if "initial_balance" not in cols2:
                conn.execute(
                    "ALTER TABLE account_season ADD COLUMN initial_balance REAL"
                )
            if "final_balance" not in cols2:
                conn.execute(
                    "ALTER TABLE account_season ADD COLUMN final_balance REAL"
                )
        conn.commit()
    except Exception:
        conn.rollback()


def _drop_account_daily_performance_equity_base(
    conn: sqlite3.Connection | PgConnectionWrapper,
) -> None:
    """account_daily_performance 废弃列 equity_base（分母取自 account_month_balance_baseline，不落库）。"""
    if IS_POSTGRES:
        try:
            conn.execute(
                "ALTER TABLE account_daily_performance "
                "DROP COLUMN IF EXISTS equity_base"
            )
            conn.commit()
        except Exception:
            conn.rollback()
        return
    if not isinstance(conn, sqlite3.Connection):
        return
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='account_daily_performance'"
    )
    if not cur.fetchone():
        return
    cur = conn.execute("PRAGMA table_info(account_daily_performance)")
    cols = {str(r[1]) for r in cur.fetchall()}
    if "equity_base" not in cols:
        return
    try:
        conn.execute(
            "ALTER TABLE account_daily_performance DROP COLUMN equity_base"
        )
    except (sqlite3.OperationalError, OSError):
        pass


def _rename_account_daily_performance_legacy_columns(
    conn: sqlite3.Connection | PgConnectionWrapper,
) -> None:
    """account_daily_performance 旧列名 → 现行命名（幂等）。"""
    pairs = (
        ("close_count", "close_pos_count"),
        ("equity_change", "equlity_changed"),
        ("cash_change", "balance_changed"),
        ("cash_changed", "balance_changed"),
        ("benchmark_inst_id", "instrument_id"),
        ("market_tr", "market_truevolatility"),
    )
    if IS_POSTGRES:
        try:
            cur = conn.execute(
                """
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = %s
                  AND table_name = 'account_daily_performance'
                """,
                (PG_SCHEMA,),
            )
            cols = {str(r[0]) for r in cur.fetchall()}
            if not cols:
                return
            for old, new in pairs:
                if old in cols and new not in cols:
                    conn.execute(
                        f"ALTER TABLE account_daily_performance "
                        f"RENAME COLUMN {old} TO {new}"
                    )
            conn.commit()
        except Exception:
            conn.rollback()
        return
    if not isinstance(conn, sqlite3.Connection):
        return
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='account_daily_performance'"
    )
    if not cur.fetchone():
        return
    cur = conn.execute("PRAGMA table_info(account_daily_performance)")
    cols = {str(r[1]) for r in cur.fetchall()}
    for old, new in pairs:
        if old in cols and new not in cols:
            try:
                conn.execute(
                    f"ALTER TABLE account_daily_performance RENAME COLUMN {old} TO {new}"
                )
            except (sqlite3.OperationalError, OSError):
                pass


def _ensure_account_daily_performance_v3(
    conn: sqlite3.Connection | PgConnectionWrapper,
) -> None:
    """日绩效：补 equlity_changed/balance_changed；并移除已废弃列 equity_base。"""
    _drop_account_daily_performance_equity_base(conn)
    if IS_POSTGRES:
        try:
            cur = conn.execute(
                """
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = %s
                  AND table_name = 'account_daily_performance'
                """
                , (PG_SCHEMA,)
            )
            cols = {str(r[0]) for r in cur.fetchall()}
            if not cols:
                return
            if "equlity_changed" not in cols:
                conn.execute(
                    "ALTER TABLE account_daily_performance "
                    "ADD COLUMN equlity_changed DOUBLE PRECISION"
                )
            if "balance_changed" not in cols:
                conn.execute(
                    "ALTER TABLE account_daily_performance "
                    "ADD COLUMN balance_changed DOUBLE PRECISION"
                )
            conn.commit()
        except Exception:
            conn.rollback()
        return
    if not isinstance(conn, sqlite3.Connection):
        return
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='account_daily_performance'"
    )
    if not cur.fetchone():
        return
    cur = conn.execute("PRAGMA table_info(account_daily_performance)")
    cols = {str(r[1]) for r in cur.fetchall()}
    if "equlity_changed" not in cols:
        conn.execute(
            "ALTER TABLE account_daily_performance ADD COLUMN equlity_changed REAL"
        )
    if "balance_changed" not in cols:
        conn.execute(
            "ALTER TABLE account_daily_performance ADD COLUMN balance_changed REAL"
        )


def _ensure_account_daily_performance_balance_changed_pct(
    conn: sqlite3.Connection | PgConnectionWrapper,
) -> None:
    """account_daily_performance.balance_changed_pct：相对当月月初资金%（与重建逻辑一致）。"""
    if IS_POSTGRES:
        try:
            cur = conn.execute(
                """
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = %s
                  AND table_name = 'account_daily_performance'
                """,
                (PG_SCHEMA,),
            )
            cols = {str(r[0]) for r in cur.fetchall()}
            if not cols:
                return
            if "balance_changed_pct" not in cols:
                conn.execute(
                    "ALTER TABLE account_daily_performance "
                    "ADD COLUMN balance_changed_pct DOUBLE PRECISION"
                )
            conn.commit()
        except Exception:
            conn.rollback()
        return
    if not isinstance(conn, sqlite3.Connection):
        return
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='account_daily_performance'"
    )
    if not cur.fetchone():
        return
    cur = conn.execute("PRAGMA table_info(account_daily_performance)")
    cols = {str(r[1]) for r in cur.fetchall()}
    if "balance_changed_pct" not in cols:
        conn.execute(
            "ALTER TABLE account_daily_performance "
            "ADD COLUMN balance_changed_pct REAL"
        )


def _ensure_strategy_events_audit_columns(
    conn: sqlite3.Connection | PgConnectionWrapper,
) -> None:
    """strategy_events：补 success/detail/action_icon，供启停与赛季审计。"""
    if IS_POSTGRES:
        try:
            cur = conn.execute(
                """
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = %s
                  AND table_name = 'strategy_events'
                """,
                (PG_SCHEMA,),
            )
            cols = {str(r[0]) for r in cur.fetchall()}
            if not cols:
                return
            if "success" not in cols:
                conn.execute(
                    "ALTER TABLE strategy_events ADD COLUMN success INTEGER"
                )
            if "detail" not in cols:
                conn.execute("ALTER TABLE strategy_events ADD COLUMN detail TEXT")
            if "action_icon" not in cols:
                conn.execute(
                    "ALTER TABLE strategy_events ADD COLUMN action_icon TEXT"
                )
            conn.commit()
        except Exception:
            conn.rollback()
        return
    if not isinstance(conn, sqlite3.Connection):
        return
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='strategy_events'"
    )
    if not cur.fetchone():
        return
    cur = conn.execute("PRAGMA table_info(strategy_events)")
    cols = {str(r[1]) for r in cur.fetchall()}
    try:
        if "success" not in cols:
            conn.execute(
                "ALTER TABLE strategy_events ADD COLUMN success INTEGER"
            )
        if "detail" not in cols:
            conn.execute("ALTER TABLE strategy_events ADD COLUMN detail TEXT")
        if "action_icon" not in cols:
            conn.execute(
                "ALTER TABLE strategy_events ADD COLUMN action_icon TEXT"
            )
        conn.commit()
    except Exception:
        conn.rollback()


def _seed_users_from_json(conn: sqlite3.Connection | PgConnectionWrapper) -> None:
    """仅当 users 表为空时从 baasapi/users.json 一次性导入；正式用户数据以 DB 为准。"""
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
            _ensure_account_month_balance_baseline_table_rename(conn)
            pg_run_init(conn)
            _ensure_account_open_positions_avg_columns(conn)
            _ensure_account_open_positions_liq_columns(conn)
            _ensure_account_balance_snapshots_margin_columns(conn)
            _ensure_account_balance_snapshots_equity_profit_column_rename(conn)
            _rename_account_balance_snapshots_cash_profit_to_balance_profit(conn)
            _ensure_account_balance_snapshots_balance_profit_columns(conn)
            _drop_account_daily_performance_realized_chain_columns(conn)
            _ensure_account_month_balance_baseline_initial_balance(conn)
            _ensure_account_month_balance_baseline_open_equity_to_initial_equity(conn)
            _ensure_account_season_equity_balance_column_names(conn)
            _rename_account_daily_performance_legacy_columns(conn)
            _ensure_account_daily_performance_v3(conn)
            _ensure_account_daily_performance_balance_changed_pct(conn)
            _ensure_strategy_events_audit_columns(conn)
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
        _drop_legacy_bot_profit_tables(conn)
        conn.commit()
        try:
            conn.execute("DROP TABLE IF EXISTS config")
            conn.commit()
        except DB_OPERATIONAL_ERRORS:
            conn.rollback()
        _ensure_account_month_balance_baseline_table_rename(conn)
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
            CREATE TABLE IF NOT EXISTS strategy_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                bot_id TEXT NOT NULL,
                event_type TEXT NOT NULL,
                trigger_type TEXT NOT NULL,
                username TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                success INTEGER,
                detail TEXT,
                action_icon TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_strategy_events_bot_id ON strategy_events(bot_id);
            CREATE INDEX IF NOT EXISTS idx_strategy_events_created ON strategy_events(created_at);
            CREATE TABLE IF NOT EXISTS account_season (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id TEXT NOT NULL,
                started_at TEXT NOT NULL,
                stopped_at TEXT,
                initial_equity REAL NOT NULL DEFAULT 0,
                initial_balance REAL,
                final_equity REAL,
                final_balance REAL,
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
                available_margin REAL NOT NULL DEFAULT 0,
                used_margin REAL NOT NULL DEFAULT 0,
                equity_usdt REAL NOT NULL DEFAULT 0,
                equity_profit_amount REAL NOT NULL DEFAULT 0,
                equity_profit_percent REAL NOT NULL DEFAULT 0,
                balance_profit_amount REAL NOT NULL DEFAULT 0,
                balance_profit_percent REAL NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_account_balance_snapshots_account ON account_balance_snapshots(account_id);
            CREATE INDEX IF NOT EXISTS idx_account_balance_snapshots_at ON account_balance_snapshots(snapshot_at);
            CREATE TABLE IF NOT EXISTS account_month_balance_baseline (
                account_id TEXT NOT NULL,
                year_month TEXT NOT NULL,
                initial_equity REAL NOT NULL,
                initial_balance REAL,
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
                long_avg_px REAL NOT NULL DEFAULT 0,
                short_avg_px REAL NOT NULL DEFAULT 0,
                long_liq_px REAL NOT NULL DEFAULT 0,
                short_liq_px REAL NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_aops_account_at ON account_open_positions_snapshots(account_id, snapshot_at);
            CREATE INDEX IF NOT EXISTS idx_aops_account_inst ON account_open_positions_snapshots(account_id, inst_id);
            -- account_daily_performance：手工对照 migrations/add_account_daily_performance.sql；PG 见 *.postgresql.sql
            CREATE TABLE IF NOT EXISTS account_daily_performance (
                account_id TEXT NOT NULL,
                day TEXT NOT NULL,
                net_realized_pnl REAL NOT NULL DEFAULT 0,
                close_pos_count INTEGER NOT NULL DEFAULT 0,
                equlity_changed REAL,
                balance_changed REAL,
                balance_changed_pct REAL,
                pnl_pct REAL,
                instrument_id TEXT NOT NULL DEFAULT '',
                market_truevolatility REAL,
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
        _ensure_account_open_positions_avg_columns(conn)
        _ensure_account_open_positions_liq_columns(conn)
        _ensure_account_balance_snapshots_margin_columns(conn)
        _ensure_account_balance_snapshots_equity_profit_column_rename(conn)
        _rename_account_balance_snapshots_cash_profit_to_balance_profit(conn)
        _ensure_account_balance_snapshots_balance_profit_columns(conn)
        _drop_account_daily_performance_realized_chain_columns(conn)
        _ensure_account_month_balance_baseline_initial_balance(conn)
        _ensure_account_month_balance_baseline_open_equity_to_initial_equity(conn)
        _ensure_account_season_equity_balance_column_names(conn)
        _rename_account_daily_performance_legacy_columns(conn)
        _ensure_account_daily_performance_v3(conn)
        _ensure_account_daily_performance_balance_changed_pct(conn)
        _ensure_strategy_events_audit_columns(conn)
        _drop_legacy_bot_profit_tables(conn)
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
    """写入一条日志。level 建议: INFO, WARN, ERROR。

    SQLite 遇「database is locked」时会按 HZTECH_LOG_INSERT_MAX_ATTEMPTS（默认 8）
    与 HZTECH_LOG_INSERT_BACKOFF_SEC（默认 0.05，指数退避）重试，减轻与后台同步线程的竞争。
    """
    extra_str = json.dumps(extra, ensure_ascii=False) if extra else None
    max_attempts = int((os.environ.get("HZTECH_LOG_INSERT_MAX_ATTEMPTS") or "8").strip())
    if max_attempts < 1:
        max_attempts = 1
    backoff = float((os.environ.get("HZTECH_LOG_INSERT_BACKOFF_SEC") or "0.05").strip())
    if backoff < 0:
        backoff = 0.0
    for attempt in range(max_attempts):
        conn = get_conn()
        try:
            conn.execute(
                "INSERT INTO logs (level, message, source, extra) VALUES (?, ?, ?, ?)",
                (level, message, source or "app", extra_str),
            )
            conn.commit()
            return
        except DB_OPERATIONAL_ERRORS as e:
            try:
                conn.rollback()
            except DB_OPERATIONAL_ERRORS:
                pass
            locked_sqlite = (
                not IS_POSTGRES
                and isinstance(e, sqlite3.OperationalError)
                and "locked" in str(e).lower()
            )
            if locked_sqlite and attempt + 1 < max_attempts:
                time.sleep(backoff * (2**attempt))
                continue
            raise
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
    *,
    success: bool | None = None,
    detail: str | None = None,
    action_icon: str | None = None,
) -> None:
    """记录策略/赛季事件。event_type: start|stop|restart|season_start|season_stop；trigger_type: manual|auto|script。

    success/detail/action_icon 为审计扩展字段（旧库列缺省时按 NULL 写入，须已跑 _ensure_strategy_events_audit_columns）。
    """
    conn = get_conn()
    try:
        if success is None and detail is None and action_icon is None:
            conn.execute(
                """INSERT INTO strategy_events (bot_id, event_type, trigger_type, username)
                   VALUES (?, ?, ?, ?)""",
                (bot_id, event_type, trigger_type, username or None),
            )
        else:
            suc = 1 if success is True else (0 if success is False else None)
            conn.execute(
                """INSERT INTO strategy_events (
                       bot_id, event_type, trigger_type, username,
                       success, detail, action_icon)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (
                    bot_id,
                    event_type,
                    trigger_type,
                    username or None,
                    suc,
                    detail,
                    action_icon,
                ),
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
                """SELECT id, bot_id, event_type, trigger_type, username, created_at,
                          success, detail, action_icon
                   FROM strategy_events WHERE bot_id = ? ORDER BY created_at DESC LIMIT ?""",
                (bot_id, limit),
            )
        else:
            cur = conn.execute(
                """SELECT id, bot_id, event_type, trigger_type, username, created_at,
                          success, detail, action_icon
                   FROM strategy_events ORDER BY created_at DESC LIMIT ?""",
                (limit,),
            )
        out: list[dict] = []
        for r in cur.fetchall():
            suc_raw = r[6]
            suc: bool | None
            if suc_raw is None:
                suc = None
            elif suc_raw in (1, True):
                suc = True
            else:
                suc = False
            out.append(
                {
                    "id": r[0],
                    "bot_id": r[1],
                    "event_type": r[2],
                    "trigger_type": r[3],
                    "username": r[4],
                    "created_at": r[5],
                    "success": suc,
                    "detail": r[7],
                    "action_icon": r[8],
                }
            )
        return out
    finally:
        conn.close()


# ---------- 赛季（表 account_season：账户策略启停周期，初期权益/现金、盈利） ----------
def account_season_insert(
    account_id: str,
    started_at: str,
    initial_equity: float = 0,
    *,
    initial_balance: float | None = None,
) -> int:
    """插入一条赛季记录（通常由 account_season_roll_forward 统一写入），返回 id。"""
    conn = get_conn()
    try:
        if IS_POSTGRES:
            cur = conn.execute(
                """INSERT INTO account_season (account_id, started_at, initial_equity, initial_balance)
                   VALUES (?, ?, ?, ?) RETURNING id""",
                (account_id, started_at, initial_equity, initial_balance),
            )
            row = cur.fetchone()
            conn.commit()
            return int(row[0]) if row else 0
        cur = conn.execute(
            """INSERT INTO account_season (account_id, started_at, initial_equity, initial_balance)
               VALUES (?, ?, ?, ?)""",
            (account_id, started_at, initial_equity, initial_balance),
        )
        conn.commit()
        return cur.lastrowid or 0
    finally:
        conn.close()


def account_season_update_on_stop(
    account_id: str,
    stopped_at: str,
    final_equity: float,
    final_balance: float | None = None,
) -> None:
    """更新最近一条未结束赛季：写入停止时间与期末权益/USDT 余额（停止策略或赛季结束）。"""
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT id, initial_equity, initial_balance FROM account_season
               WHERE account_id = ? AND stopped_at IS NULL
               ORDER BY started_at DESC LIMIT 1""",
            (account_id,),
        )
        row = cur.fetchone()
        if not row:
            return
        sid, initial = row[0], float(row[1])
        profit_amount = final_equity - initial
        profit_percent = (profit_amount / initial * 100.0) if initial else 0.0
        conn.execute(
            """UPDATE account_season SET stopped_at = ?, final_equity = ?, final_balance = ?,
                      profit_amount = ?, profit_percent = ?
               WHERE id = ?""",
            (stopped_at, final_equity, final_balance, profit_amount, profit_percent, sid),
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
    再以同一快照写入新赛季的 initial_equity / initial_balance（USDT 余额）。
    """
    bid = (account_id or "").strip()
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT id, initial_equity, initial_balance FROM account_season
               WHERE account_id = ? AND stopped_at IS NULL
               ORDER BY started_at ASC""",
            (bid,),
        )
        for row in cur.fetchall():
            sid, initial = int(row[0]), float(row[1] or 0)
            profit_amount = float(equity_usdt) - initial
            profit_percent = (profit_amount / initial * 100.0) if initial else 0.0
            conn.execute(
                """UPDATE account_season SET stopped_at = ?, final_equity = ?, final_balance = ?,
                          profit_amount = ?, profit_percent = ?
                   WHERE id = ?""",
                (ts, equity_usdt, cash_usdt, profit_amount, profit_percent, sid),
            )
        if IS_POSTGRES:
            cur2 = conn.execute(
                """INSERT INTO account_season (account_id, started_at, initial_equity, initial_balance)
                   VALUES (?, ?, ?, ?) RETURNING id""",
                (bid, ts, float(equity_usdt), float(cash_usdt)),
            )
            row2 = cur2.fetchone()
            conn.commit()
            return int(row2[0]) if row2 else 0
        cur2 = conn.execute(
            """INSERT INTO account_season (account_id, started_at, initial_equity, initial_balance)
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
            """SELECT id, account_id, started_at, stopped_at, initial_equity, initial_balance,
                      final_equity, final_balance, profit_amount, profit_percent, created_at
               FROM account_season WHERE account_id = ? ORDER BY started_at DESC LIMIT ?""",
            (account_id, limit),
        )
        return [
            {
                "id": r[0],
                "account_id": r[1],
                "started_at": r[2],
                "stopped_at": r[3],
                "initial_equity": r[4],
                "initial_balance": float(r[5]) if r[5] is not None else None,
                "final_equity": r[6],
                "final_balance": float(r[7]) if r[7] is not None else None,
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
            """SELECT id, account_id, started_at, stopped_at, initial_equity, initial_balance,
                      final_equity, final_balance, profit_amount, profit_percent, created_at
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
            "initial_equity": r[4],
            "initial_balance": float(r[5]) if r[5] is not None else None,
            "final_equity": r[6],
            "final_balance": float(r[7]) if r[7] is not None else None,
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
    在 u_time_ms 闭区间内汇总历史仓位（与 OKX positions-history 一致）：
    时间轴用接口字段 uTime 入库的毫秒值（非 cTime 开仓时间）；
    单笔净盈亏优先 realized_pnl（对应 OKX realizedPnl），缺省时用 pnl+fee+funding_fee。
    """
    aid = (account_id or "").strip()
    conn = get_conn()
    try:
        cur = conn.execute(
            """
            SELECT COUNT(*),
                   SUM(COALESCE(realized_pnl,
                                 COALESCE(pnl, 0) + COALESCE(fee, 0) + COALESCE(funding_fee, 0)))
            FROM account_positions_history
            WHERE account_id = ?
              AND CAST(u_time_ms AS BIGINT) >= ?
              AND CAST(u_time_ms AS BIGINT) <= ?
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


def account_list_list_okx(*, enabled_only: bool = True) -> list[dict]:
    """列出表 account_list 中 OKX 且已配置密钥文件名的行；字段形状与 Account_List.json 单行一致，供交易机器人启停与 /api/tradingbots 使用。"""
    conn = get_conn()
    try:
        sql = """SELECT account_id, account_name, exchange_account, symbol, initial_capital,
                        trading_strategy, account_key_file, script_file, enabled, updated_at
                 FROM account_list
                 WHERE UPPER(TRIM(COALESCE(exchange_account, ''))) = 'OKX'
                   AND TRIM(COALESCE(account_key_file, '')) != ''"""
        if enabled_only:
            sql += " AND COALESCE(enabled, 1) = 1"
        sql += " ORDER BY account_id"
        cur = conn.execute(sql)
        out: list[dict] = []
        for r in cur.fetchall():
            en = r[8]
            enabled_bool = bool(int(en)) if en is not None else True
            out.append(
                {
                    "account_id": r[0],
                    "account_name": str(r[1] or ""),
                    "exchange_account": str(r[2] or ""),
                    "symbol": str(r[3] or ""),
                    "Initial_capital": float(r[4]),
                    "trading_strategy": str(r[5] or ""),
                    "account_key_file": str(r[6] or ""),
                    "script_file": str(r[7] or ""),
                    "enabled": enabled_bool,
                }
            )
        return out
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
    equity_profit_amount: float,
    equity_profit_percent: float,
    *,
    available_margin: float = 0.0,
    used_margin: float = 0.0,
    balance_profit_amount: float = 0.0,
    balance_profit_percent: float = 0.0,
) -> None:
    """插入一条余额快照行（表：account_balance_snapshots）。cash_balance=USDT 资产余额；available_margin=可用保证金；equity_profit_* 为权益相对 initial_capital；balance_profit_* 为资产余额相对 initial_capital。"""
    conn = get_conn()
    try:
        conn.execute(
            """INSERT INTO account_balance_snapshots
               (account_id, snapshot_at, cash_balance, available_margin, used_margin, equity_usdt,
                equity_profit_amount, equity_profit_percent, balance_profit_amount, balance_profit_percent)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                account_id.strip(),
                snapshot_at,
                cash_balance,
                available_margin,
                used_margin,
                equity_usdt,
                equity_profit_amount,
                equity_profit_percent,
                balance_profit_amount,
                balance_profit_percent,
            ),
        )
        conn.commit()
    finally:
        conn.close()


def account_balance_snapshots_recompute_profit() -> int:
    """按各行与当前 account_list.initial_capital 重算 equity_profit_*（权益）与 balance_profit_*（资产余额）。"""
    conn = get_conn()
    total_updated = 0
    try:
        cur = conn.execute(
            "SELECT DISTINCT account_id FROM account_balance_snapshots"
        )
        aids = [
            str(r[0]).strip()
            for r in cur.fetchall()
            if r and str(r[0] or "").strip()
        ]
        for aid in aids:
            cur_m = conn.execute(
                "SELECT initial_capital FROM account_list WHERE account_id = ?",
                (aid,),
            )
            row = cur_m.fetchone()
            initial = (
                float(row[0])
                if row is not None and row[0] is not None
                else 0.0
            )
            ex = conn.execute(
                """UPDATE account_balance_snapshots
                   SET equity_profit_amount = equity_usdt - ?,
                       equity_profit_percent = CASE WHEN ABS(?) > 1e-18
                         THEN (equity_usdt - ?) / ? * 100.0 ELSE 0.0 END,
                       balance_profit_amount = cash_balance - ?,
                       balance_profit_percent = CASE WHEN ABS(?) > 1e-18
                         THEN (cash_balance - ?) / ? * 100.0 ELSE 0.0 END
                   WHERE account_id = ?""",
                (
                    initial,
                    initial,
                    initial,
                    initial,
                    initial,
                    initial,
                    initial,
                    initial,
                    aid,
                ),
            )
            rc = getattr(ex, "rowcount", -1)
            if rc is not None and rc > 0:
                total_updated += int(rc)
        conn.commit()
    finally:
        conn.close()
    return total_updated


def account_snapshot_latest_by_account(account_id: str) -> dict | None:
    """该账户最新一条快照（表：account_balance_snapshots）。"""
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT id, account_id, snapshot_at, cash_balance, available_margin, used_margin, equity_usdt,
                      equity_profit_amount, equity_profit_percent, balance_profit_amount, balance_profit_percent, created_at
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
            "available_margin": r[4],
            "used_margin": r[5],
            "equity_usdt": r[6],
            "equity_profit_amount": r[7],
            "equity_profit_percent": r[8],
            "balance_profit_amount": r[9],
            "balance_profit_percent": r[10],
            "created_at": r[11],
        }
    finally:
        conn.close()


def account_snapshot_query_by_account(account_id: str, limit: int = 500) -> list[dict]:
    """按时间升序，最多 limit 条（表：account_balance_snapshots）。

    收益曲线请用 ``account_snapshot_query_by_account_since``，避免 ASC LIMIT 取到最旧一段。
    """
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT id, account_id, snapshot_at, cash_balance, available_margin, used_margin, equity_usdt,
                      equity_profit_amount, equity_profit_percent, balance_profit_amount, balance_profit_percent, created_at
               FROM account_balance_snapshots WHERE account_id = ? ORDER BY snapshot_at ASC LIMIT ?""",
            (account_id.strip(), limit),
        )
        return [
            {
                "id": r[0],
                "account_id": r[1],
                "snapshot_at": r[2],
                "cash_balance": r[3],
                "available_margin": r[4],
                "used_margin": r[5],
                "equity_usdt": r[6],
                "equity_profit_amount": r[7],
                "equity_profit_percent": r[8],
                "balance_profit_amount": r[9],
                "balance_profit_percent": r[10],
                "created_at": r[11],
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
            """SELECT id, account_id, snapshot_at, cash_balance, available_margin, used_margin, equity_usdt,
                      equity_profit_amount, equity_profit_percent, balance_profit_amount, balance_profit_percent, created_at
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
                "available_margin": r[4],
                "used_margin": r[5],
                "equity_usdt": r[6],
                "equity_profit_amount": r[7],
                "equity_profit_percent": r[8],
                "balance_profit_amount": r[9],
                "balance_profit_percent": r[10],
                "created_at": r[11],
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


def account_balance_snapshots_has_gap_in_recent_utc_days(
    account_id: str, days: int = 92
) -> bool:
    """最近 ``days`` 个 UTC 自然日（含今天）内是否至少有一天在 account_balance_snapshots 中无任何记录。

    用于定时任务在调用 OKX bills-archive 前先查库，避免无缺口时反复请求。
    ``days`` 限制在 1～92（与 bills-archive 补全窗口一致）。
    """
    from datetime import datetime, timedelta, timezone

    aid = (account_id or "").strip()
    if not aid:
        return False
    nd = max(1, min(92, int(days)))
    now = datetime.now(timezone.utc)
    end_d = now.date()
    start_d = end_d - timedelta(days=nd - 1)
    start_iso = f"{start_d.isoformat()}T00:00:00.000000Z"
    end_iso_excl = f"{(end_d + timedelta(days=1)).isoformat()}T00:00:00.000000Z"

    conn = get_conn()
    try:
        if IS_POSTGRES:
            cur = conn.execute(
                """
                SELECT DISTINCT substring(snapshot_at, 1, 10)
                FROM account_balance_snapshots
                WHERE account_id = ? AND snapshot_at >= ? AND snapshot_at < ?
                """,
                (aid, start_iso, end_iso_excl),
            )
        else:
            cur = conn.execute(
                """
                SELECT DISTINCT strftime('%Y-%m-%d', snapshot_at)
                FROM account_balance_snapshots
                WHERE account_id = ? AND snapshot_at >= ? AND snapshot_at < ?
                """,
                (aid, start_iso, end_iso_excl),
            )
        have = {str(r[0]) for r in cur.fetchall() if r and r[0]}
    finally:
        conn.close()

    expected: set[str] = set()
    walk = start_d
    while walk <= end_d:
        expected.add(walk.isoformat())
        walk += timedelta(days=1)
    return bool(expected - have)


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
            """SELECT id, account_id, snapshot_at, cash_balance, available_margin, used_margin, equity_usdt,
                      equity_profit_amount, equity_profit_percent, balance_profit_amount, balance_profit_percent, created_at
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
            "available_margin": r[4],
            "used_margin": r[5],
            "equity_usdt": r[6],
            "equity_profit_amount": r[7],
            "equity_profit_percent": r[8],
            "balance_profit_amount": r[9],
            "balance_profit_percent": r[10],
            "created_at": r[11],
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
    """写入当前持仓快照：每合约一行（多/空张数、腿数、最新价、标记价、多/空 UPL、多/空加权预估强平价）。"""
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
                    mark_px, long_upl, short_upl, total_upl, open_leg_count,
                    long_avg_px, short_avg_px, long_liq_px, short_liq_px)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
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
                    float(r.get("long_avg_px") or 0),
                    float(r.get("short_avg_px") or 0),
                    float(r.get("long_liq_px") or 0),
                    float(r.get("short_liq_px") or 0),
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
                          open_leg_count, long_avg_px, short_avg_px, long_liq_px, short_liq_px, created_at
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
                          open_leg_count, long_avg_px, short_avg_px, long_liq_px, short_liq_px, created_at
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
                "long_avg_px": r[12],
                "short_avg_px": r[13],
                "long_liq_px": r[14],
                "short_liq_px": r[15],
                "created_at": r[16],
            }
            for r in cur.fetchall()
        ]
    finally:
        conn.close()


def account_month_balance_baseline_get(account_id: str, year_month: str) -> dict | None:
    """year_month 形如 2026-04。"""
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT account_id, year_month, initial_equity, initial_balance, recorded_at
               FROM account_month_balance_baseline
               WHERE account_id = ? AND year_month = ?""",
            (account_id.strip(), year_month.strip()),
        )
        r = cur.fetchone()
        if not r:
            return None
        ib = r[3]
        return {
            "account_id": r[0],
            "year_month": r[1],
            "initial_equity": float(r[2]),
            "initial_balance": float(ib) if ib is not None else None,
            "recorded_at": r[4],
        }
    finally:
        conn.close()


def account_month_balance_baseline_insert_if_absent(
    account_id: str,
    year_month: str,
    initial_equity: float,
    recorded_at: str,
    *,
    initial_balance: float | None = None,
) -> None:
    """每月仅第一条记录生效（月初首次快照时写入权益与现金）。"""
    conn = get_conn()
    try:
        if IS_POSTGRES:
            conn.execute(
                """INSERT INTO account_month_balance_baseline
                   (account_id, year_month, initial_equity, initial_balance, recorded_at)
                   VALUES (?, ?, ?, ?, ?)
                   ON CONFLICT (account_id, year_month) DO NOTHING""",
                (
                    account_id.strip(),
                    year_month.strip(),
                    initial_equity,
                    initial_balance,
                    recorded_at,
                ),
            )
        else:
            conn.execute(
                """INSERT OR IGNORE INTO account_month_balance_baseline
                   (account_id, year_month, initial_equity, initial_balance, recorded_at)
                   VALUES (?, ?, ?, ?, ?)""",
                (
                    account_id.strip(),
                    year_month.strip(),
                    initial_equity,
                    initial_balance,
                    recorded_at,
                ),
            )
        conn.commit()
    finally:
        conn.close()


def account_month_balance_baseline_upsert(
    account_id: str,
    year_month: str,
    initial_equity: float,
    recorded_at: str,
    *,
    initial_balance: float | None = None,
) -> None:
    """写入或覆盖当月 account_month_balance_baseline（UTC 月初定时任务，幂等）。"""
    conn = get_conn()
    try:
        if IS_POSTGRES:
            conn.execute(
                """INSERT INTO account_month_balance_baseline
                   (account_id, year_month, initial_equity, initial_balance, recorded_at)
                   VALUES (?, ?, ?, ?, ?)
                   ON CONFLICT (account_id, year_month) DO UPDATE SET
                     initial_equity = EXCLUDED.initial_equity,
                     initial_balance = EXCLUDED.initial_balance,
                     recorded_at = EXCLUDED.recorded_at""",
                (
                    account_id.strip(),
                    year_month.strip(),
                    initial_equity,
                    initial_balance,
                    recorded_at,
                ),
            )
        else:
            conn.execute(
                """INSERT INTO account_month_balance_baseline
                   (account_id, year_month, initial_equity, initial_balance, recorded_at)
                   VALUES (?, ?, ?, ?, ?)
                   ON CONFLICT(account_id, year_month) DO UPDATE SET
                     initial_equity = excluded.initial_equity,
                     initial_balance = excluded.initial_balance,
                     recorded_at = excluded.recorded_at""",
                (
                    account_id.strip(),
                    year_month.strip(),
                    initial_equity,
                    initial_balance,
                    recorded_at,
                ),
            )
        conn.commit()
    finally:
        conn.close()


def account_month_balance_baseline_list_since(
    account_id: str, min_year_month: str
) -> dict[str, dict]:
    """返回 year_month >= min_year_month（YYYY-MM 字典序）的月初基准行。"""
    aid = account_id.strip()
    lo = (min_year_month or "").strip()
    if not aid:
        return {}
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT year_month, initial_equity, initial_balance, recorded_at
               FROM account_month_balance_baseline
               WHERE account_id = ? AND year_month >= ?
               ORDER BY year_month""",
            (aid, lo),
        )
        out: dict[str, dict] = {}
        for r in cur.fetchall():
            ym = str(r[0] or "")
            ib = r[2]
            out[ym] = {
                "initial_equity": float(r[1]),
                "initial_balance": float(ib) if ib is not None else None,
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
            """SELECT MAX(CAST(u_time_ms AS BIGINT)) FROM account_positions_history
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
    """按 u_time_ms（OKX uTime，与接口分页字段一致）倒序返回历史仓位（解析常用字段 + raw_json）。

    before_utime_ms: 仅返回 u_time 严格小于该值的记录（分页游标）。
    since_utime_ms: 仅返回 u_time 大于等于该值的记录（可选时间下界）。
    """
    aid = account_id.strip()
    lim = max(1, int(limit))
    clauses = ["account_id = ?"]
    params: list = [aid]
    if before_utime_ms is not None:
        clauses.append("CAST(u_time_ms AS BIGINT) < ?")
        params.append(int(before_utime_ms))
    if since_utime_ms is not None:
        clauses.append("CAST(u_time_ms AS BIGINT) >= ?")
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
               ORDER BY CAST(u_time_ms AS BIGINT) DESC
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
    按北京时间（Asia/Shanghai）自然日汇总历史平仓盈亏与笔数。
    筛选窗：当月北京 00:00 至次月北京 00:00 之间的 u_time_ms（OKX uTime，平仓时刻）。
    归属日：该瞬时对应的北京日历日；非 cTime。单笔净盈亏优先 realized_pnl（OKX realizedPnl）。
    """
    aid = (account_id or "").strip()
    if not aid or year < 2000 or year > 2100 or month < 1 or month > 12:
        return []
    bounds = _beijing_month_bounds_ms(year, month)
    if bounds is None:
        return []
    start_ms, end_ms = bounds

    conn = get_conn()
    try:
        if IS_POSTGRES:
            cur = conn.execute(
                """
                SELECT to_char(
                         timezone('Asia/Shanghai', to_timestamp((u_time_ms::bigint) / 1000.0)),
                         'YYYY-MM-DD'
                       ) AS d,
                       SUM(COALESCE(realized_pnl,
                                    COALESCE(pnl, 0) + COALESCE(fee, 0) + COALESCE(funding_fee, 0))) AS net_pnl,
                       COUNT(*) AS close_pos_count
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
                       datetime(CAST(u_time_ms AS BIGINT) / 1000, 'unixepoch', '+8 hours')) AS d,
                       SUM(COALESCE(realized_pnl,
                                    COALESCE(pnl, 0) + COALESCE(fee, 0) + COALESCE(funding_fee, 0))) AS net_pnl,
                       COUNT(*) AS close_pos_count
                FROM account_positions_history
                WHERE account_id = ?
                  AND CAST(u_time_ms AS BIGINT) >= ?
                  AND CAST(u_time_ms AS BIGINT) < ?
                GROUP BY d
                ORDER BY d
                """,
                (aid, start_ms, end_ms),
            )
        return [
            {
                "day": str(r[0]),
                "net_pnl": float(r[1] or 0),
                "close_pos_count": int(r[2] or 0),
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


def _parse_snapshot_at_utc(s: str):
    from datetime import datetime, timezone

    raw = (s or "").strip()
    if len(raw) < 10:
        return None
    try:
        if raw.endswith("Z"):
            return datetime.fromisoformat(raw.replace("Z", "+00:00"))
        if " " in raw and "T" not in raw:
            raw = raw.replace(" ", "T", 1)
        dt = datetime.fromisoformat(raw)
        if dt.tzinfo is None:
            return dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except ValueError:
        return None


def _snapshots_sorted_dt_equity_cash(
    rows: list[tuple[Any, Any, Any]],
) -> list[tuple[Any, float, float]]:
    out: list[tuple[Any, float, float]] = []
    for r in rows:
        sa = str(r[0] or "")
        eq = float(r[1] or 0.0)
        cash = float(r[2] or 0.0)
        dt = _parse_snapshot_at_utc(sa)
        if dt is not None:
            out.append((dt, eq, cash))
    out.sort(key=lambda x: x[0])
    return out


def _beijing_month_bounds_ms(year: int, month: int) -> tuple[int, int] | None:
    """北京时间当月 [start,end) 毫秒时间窗，用于按月筛选 u_time_ms。"""
    from datetime import datetime
    from zoneinfo import ZoneInfo

    sh = ZoneInfo("Asia/Shanghai")
    try:
        start = datetime(year, month, 1, 0, 0, 0, tzinfo=sh)
    except ValueError:
        return None
    if month == 12:
        end = datetime(year + 1, 1, 1, 0, 0, 0, tzinfo=sh)
    else:
        end = datetime(year, month + 1, 1, 0, 0, 0, tzinfo=sh)
    return int(start.timestamp() * 1000), int(end.timestamp() * 1000)


def _snapshot_iso_to_beijing_day(sa: str) -> str | None:
    from zoneinfo import ZoneInfo

    dt = _parse_snapshot_at_utc(sa)
    if dt is None:
        return None
    sh = ZoneInfo("Asia/Shanghai")
    bj = dt.astimezone(sh)
    return f"{bj.year:04d}-{bj.month:02d}-{bj.day:02d}"


def utc_bar_day_for_beijing_ledger_day(day: str) -> str:
    """北京日历日 → 策略效能 / market_daily_bars 使用的 UTC 日键（与 `_tr_lookup_day_from_beijing_ledger_day` 相同）。"""
    return _tr_lookup_day_from_beijing_ledger_day(day)


def _tr_lookup_day_from_beijing_ledger_day(day: str) -> str:
    """日绩效 `day` 为北京日历时，映射到 market_daily_bars.day（当前库为 K 线 UTC 日历日）的近似键。"""
    from datetime import datetime, timezone
    from zoneinfo import ZoneInfo

    parts_on = (day or "").strip().split("-")
    if len(parts_on) != 3:
        return (day or "").strip()
    try:
        y, m, d = int(parts_on[0]), int(parts_on[1]), int(parts_on[2])
    except ValueError:
        return (day or "").strip()
    sh = ZoneInfo("Asia/Shanghai")
    noon_bj = datetime(y, m, d, 12, 0, 0, tzinfo=sh)
    return noon_bj.astimezone(timezone.utc).strftime("%Y-%m-%d")


def _signed_equity_cash_delta_beijing_day(
    snaps: list[tuple[Any, float, float]], day: str
) -> tuple[float | None, float | None]:
    from datetime import datetime, timedelta, timezone
    from zoneinfo import ZoneInfo

    parts = (day or "").strip().split("-")
    if len(parts) != 3:
        return None, None
    try:
        y, m, d = int(parts[0]), int(parts[1]), int(parts[2])
    except ValueError:
        return None, None
    sh = ZoneInfo("Asia/Shanghai")
    day_start = datetime(y, m, d, 0, 0, 0, tzinfo=sh).astimezone(timezone.utc)
    day_end = day_start + timedelta(days=1)
    in_day = [(dt, eq, cash) for dt, eq, cash in snaps if day_start <= dt < day_end]
    if not in_day:
        return None, None
    last_eq, last_cash = in_day[-1][1], in_day[-1][2]
    first_eq, first_cash = in_day[0][1], in_day[0][2]
    sod_eq: float | None = None
    sod_cash: float | None = None
    for dt, eq, cash in snaps:
        if dt < day_start:
            sod_eq = eq
            sod_cash = cash
    if sod_eq is None:
        sod_eq = first_eq
    if sod_cash is None:
        sod_cash = first_cash
    return (float(last_eq) - float(sod_eq), float(last_cash) - float(sod_cash))


def _month_realized_denom_from_open(
    aid: str, year_month: str, initial_capital: float, cache: dict[str, dict | None]
) -> float | None:
    """当月 pnl_pct 分母：优先 account_month_balance_baseline.initial_balance（原 open_cash）；
    缺省或无效时依次 initial_equity、account_list.initial_capital。
    """
    if year_month not in cache:
        cache[year_month] = account_month_balance_baseline_get(aid, year_month)
    row = cache[year_month]
    if row:
        ib = row.get("initial_balance")
        if ib is not None and float(ib) > 0:
            return float(ib)
        oe = row.get("initial_equity")
        if oe is not None and float(oe) > 0:
            return float(oe)
    return float(initial_capital) if initial_capital > 0 else None


def account_daily_performance_query_month(
    account_id: str, year: int, month: int
) -> list[dict[str, Any]]:
    """读库表 account_daily_performance（day 为北京日历日 YYYY-MM-DD）。"""
    aid = (account_id or "").strip()
    if not aid or year < 2000 or year > 2100 or month < 1 or month > 12:
        return []
    try:
        start_s = f"{year:04d}-{month:02d}-01"
    except ValueError:
        return []
    if month == 12:
        end_s = f"{year + 1:04d}-01-01"
    else:
        end_s = f"{year:04d}-{month + 1:02d}-01"

    conn = get_conn()
    try:
        cur = conn.execute(
            """
            SELECT day, net_realized_pnl, close_pos_count, equlity_changed, balance_changed, balance_changed_pct, pnl_pct,
                   instrument_id, market_truevolatility, efficiency_ratio, updated_at
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
                "close_pos_count": int(r[2] or 0),
                "equlity_changed": float(r[3]) if r[3] is not None else None,
                "balance_changed": float(r[4]) if r[4] is not None else None,
                "balance_changed_pct": float(r[5]) if r[5] is not None else None,
                "pnl_pct": float(r[6]) if r[6] is not None else None,
                "instrument_id": str(r[7] or ""),
                "market_truevolatility": float(r[8]) if r[8] is not None else None,
                "efficiency_ratio": float(r[9]) if r[9] is not None else None,
                "updated_at": str(r[10] or ""),
            }
            for r in cur.fetchall()
        ]
    finally:
        conn.close()


def account_daily_performance_query_day_range(
    account_id: str, day_lo: str, day_hi: str
) -> list[dict[str, Any]]:
    """读 account_daily_performance（day 为北京日历日 YYYY-MM-DD），闭区间 [day_lo, day_hi]。"""
    aid = (account_id or "").strip()
    lo = (day_lo or "").strip()
    hi = (day_hi or "").strip()
    if not aid or not lo or not hi:
        return []
    conn = get_conn()
    try:
        cur = conn.execute(
            """
            SELECT day, net_realized_pnl, close_pos_count, equlity_changed, balance_changed, balance_changed_pct, pnl_pct,
                   instrument_id, market_truevolatility, efficiency_ratio, updated_at
            FROM account_daily_performance
            WHERE account_id = ? AND day >= ? AND day <= ?
            ORDER BY day
            """,
            (aid, lo, hi),
        )
        return [
            {
                "day": str(r[0]),
                "net_pnl": float(r[1] or 0),
                "close_pos_count": int(r[2] or 0),
                "equlity_changed": float(r[3]) if r[3] is not None else None,
                "balance_changed": float(r[4]) if r[4] is not None else None,
                "balance_changed_pct": float(r[5]) if r[5] is not None else None,
                "pnl_pct": float(r[6]) if r[6] is not None else None,
                "instrument_id": str(r[7] or ""),
                "market_truevolatility": float(r[8]) if r[8] is not None else None,
                "efficiency_ratio": float(r[9]) if r[9] is not None else None,
                "updated_at": str(r[10] or ""),
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
    写入 account_daily_performance（day = 北京日历日 YYYY-MM-DD）：
    自然日 = 平仓北京日 ∪ 余额快照北京日；
    net_realized_pnl/close_pos_count 来自 account_positions_history：按 u_time_ms（OKX uTime，平仓时刻）折算为
    Asia/Shanghai 当日，非 cTime；金额优先 realized_pnl（OKX realizedPnl）。
    pnl_pct 分母为当月月初基准表口径（_month_realized_denom_from_open）；
    equlity_changed、balance_changed 为北京日 00:00–次日 00:00（上海时区）内快照的 signed 差分；
    market_truevolatility：日绩效北京日映射到 market_daily_bars 当前使用的 UTC 日键作近似查询。
    """
    from datetime import datetime, timezone

    from strategy_efficiency import close_pnl_efficiency_ratio

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
                    SELECT d, net_pnl, close_pos_count FROM (
                        SELECT to_char(
                                 timezone('Asia/Shanghai', to_timestamp((u_time_ms::bigint) / 1000.0)),
                                 'YYYY-MM-DD'
                               ) AS d,
                               SUM(COALESCE(realized_pnl,
                                            COALESCE(pnl, 0) + COALESCE(fee, 0) + COALESCE(funding_fee, 0))) AS net_pnl,
                               COUNT(*) AS close_pos_count
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
                           datetime(CAST(u_time_ms AS BIGINT) / 1000, 'unixepoch', '+8 hours')) AS d,
                           SUM(COALESCE(realized_pnl,
                                        COALESCE(pnl, 0) + COALESCE(fee, 0) + COALESCE(funding_fee, 0))) AS net_pnl,
                           COUNT(*) AS close_pos_count
                    FROM account_positions_history
                    WHERE account_id = ?
                    GROUP BY d
                    HAVING d IS NOT NULL AND d != ''
                    ORDER BY d
                    """,
                    (aid,),
                )
            day_rows = [(str(r[0]), float(r[1] or 0), int(r[2] or 0)) for r in cur.fetchall()]

            cur_sn = conn.execute(
                """
                SELECT snapshot_at, equity_usdt, cash_balance
                FROM account_balance_snapshots
                WHERE account_id = ?
                ORDER BY snapshot_at ASC
                """,
                (aid,),
            )
            snap_rows = [
                (str(r[0]), float(r[1] or 0.0), float(r[2] or 0.0))
                for r in cur_sn.fetchall()
            ]
            snaps_dt = _snapshots_sorted_dt_equity_cash(snap_rows)

            day_set: set[str] = set(d for d, _, _ in day_rows)
            for sa, _, _ in snap_rows:
                bd = _snapshot_iso_to_beijing_day(sa)
                if bd:
                    day_set.add(bd)

            conn.execute(
                "DELETE FROM account_daily_performance WHERE account_id = ?",
                (aid,),
            )
            if not day_set:
                conn.commit()
                continue

            day_list = sorted(day_set)
            pnl_by_day: dict[str, tuple[float, int]] = {
                d: (float(n), int(c)) for d, n, c in day_rows
            }

            tr_map: dict[str, float] = {}
            if day_list and bench:
                tr_query_days = sorted(
                    {_tr_lookup_day_from_beijing_ledger_day(d) for d in day_list}
                    | set(day_list)
                )
                placeholders = ",".join("?" * len(tr_query_days))
                cur_tr = conn.execute(
                    f"""
                    SELECT day, tr FROM market_daily_bars
                    WHERE inst_id = ? AND day IN ({placeholders})
                    """,
                    (bench, *tr_query_days),
                )
                for r in cur_tr.fetchall():
                    tr_map[str(r[0])] = float(r[1] or 0.0)

            mo_cache: dict[str, dict | None] = {}

            for day in day_list:
                net_pnl, close_pos_count = pnl_by_day.get(day, (0.0, 0))
                eq_ch, cash_ch = _signed_equity_cash_delta_beijing_day(snaps_dt, day)

                ym = day[:7]
                month_denom = _month_realized_denom_from_open(
                    aid, ym, initial, mo_cache
                )

                pnl_pct: float | None = None
                if month_denom is not None and float(month_denom) > 0:
                    pnl_pct = float(net_pnl) / float(month_denom) * 100.0

                balance_changed_pct_v: float | None = None
                if (
                    month_denom is not None
                    and float(month_denom) > 0
                    and cash_ch is not None
                ):
                    balance_changed_pct_v = (
                        float(cash_ch) / float(month_denom) * 100.0
                    )

                tr_k = _tr_lookup_day_from_beijing_ledger_day(day)
                mtr = tr_map.get(tr_k)
                if mtr is None:
                    mtr = tr_map.get(day)
                market_truevolatility_v = float(mtr) if mtr is not None else None
                eff = (
                    close_pnl_efficiency_ratio(net_pnl, market_truevolatility_v)
                    if market_truevolatility_v is not None
                    else None
                )

                conn.execute(
                    """
                    INSERT INTO account_daily_performance
                    (account_id, day, net_realized_pnl, close_pos_count, equlity_changed, balance_changed, balance_changed_pct, pnl_pct,
                     instrument_id, market_truevolatility, efficiency_ratio, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        aid,
                        day,
                        net_pnl,
                        close_pos_count,
                        eq_ch,
                        cash_ch,
                        balance_changed_pct_v,
                        pnl_pct,
                        bench,
                        market_truevolatility_v,
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
