#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
将 SQLite（默认 baasapi/sqlite/tradingbots.db）数据导入到 PostgreSQL。

推荐步骤（在项目根 hztechApp 下）：
  1) 确认 PostgreSQL 可连（与日常 HZTECH_DB_BACKEND=postgresql 相同配置即可）
  2) 先 dry-run 看各表行数：
       python3 baasapi/migrate_sqlite_to_postgresql.py --dry-run
  3) 正式导入（必要时先对旧库做结构整理）：
       python3 baasapi/migrate_sqlite_to_postgresql.py
     或源库较旧时加：  --prepare-sqlite
     若目标库已有数据需整表覆盖：  --truncate-target（危险，会清空业务表）

也可：
  export DATABASE_URL=postgresql://user:pass@127.0.0.1:5432/dbname
  python3 baasapi/migrate_sqlite_to_postgresql.py

或使用分项环境变量（与 db_backend 一致）：POSTGRES_HOST、POSTGRES_PORT、POSTGRES_DB、POSTGRES_USER、POSTGRES_PASSWORD
连接串也可写在 baasapi/database_config.json（未设置的环境变量由配置文件补全）。

选项：
  --sqlite-path PATH   源 SQLite 文件（默认 baasapi/sqlite/tradingbots.db）
  --prepare-sqlite     先对源库执行 SQLite 版 init_db（合并旧表名等），再导出
  --dry-run            只打印各表行数，不写 PostgreSQL
  --truncate-target    清空目标库中下列业务表后再导入（危险，确认后再用）

说明：可重复执行；主键/唯一约束冲突时采用 UPSERT 或 DO NOTHING（见 _CONFLICT_SPECS）。
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Any, Sequence

BAASAPI_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = BAASAPI_DIR.parent
PG_SCHEMA = (os.environ.get("HZTECH_POSTGRES_SCHEMA") or "flutterapp").strip() or "flutterapp"


def _sqlite_table_columns(sq: Any, table: str) -> list[str]:
    cur = sq.execute(f'PRAGMA table_info("{table}")')
    return [str(r[1]) for r in cur.fetchall()]


def _pg_table_columns(pg: Any, table: str) -> set[str]:
    cur = pg.execute(
        """
        SELECT column_name FROM information_schema.columns
        WHERE table_schema = %s AND table_name = %s
        """,
        (PG_SCHEMA, table),
    )
    return {str(r[0]) for r in cur.fetchall()}


def _sqlite_has_table(sq: Any, table: str) -> bool:
    cur = sq.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
        (table,),
    )
    return cur.fetchone() is not None


def _reload_pg_db_modules() -> None:
    for name in list(sys.modules):
        if name == "db_backend" or name == "db" or name.startswith("db."):
            del sys.modules[name]
    import db_backend  # noqa: F401
    import db  # noqa: F401


def _prepare_sqlite_file(path: Path) -> None:
    """对指定 SQLite 文件跑一遍 init_db（迁移旧表名/列）。"""
    os.environ["HZTECH_DB_BACKEND"] = "sqlite"
    for k in ("DATABASE_URL", "POSTGRES_HOST", "POSTGRES_USER"):
        os.environ.pop(k, None)
    _reload_pg_db_modules()
    import db_backend
    import db

    db_backend.DB_PATH = path
    db_backend.DB_DIR = path.parent
    db.DB_PATH = path
    path.parent.mkdir(parents=True, exist_ok=True)
    db.init_db()


# (表名, 冲突子句)；冲突子句为 None 时用 ON CONFLICT (id) DO UPDATE（表须含 id 主键）
_CONFLICT_SPECS: list[tuple[str, str | None]] = [
    ("users", "ON CONFLICT (username) DO UPDATE SET password_hash = EXCLUDED.password_hash, created_at = EXCLUDED.created_at, role = EXCLUDED.role, linked_account_ids = EXCLUDED.linked_account_ids, full_name = EXCLUDED.full_name, phone = EXCLUDED.phone"),
    ("account_list", "ON CONFLICT (account_id) DO UPDATE SET account_name = EXCLUDED.account_name, exchange_account = EXCLUDED.exchange_account, symbol = EXCLUDED.symbol, initial_capital = EXCLUDED.initial_capital, trading_strategy = EXCLUDED.trading_strategy, account_key_file = EXCLUDED.account_key_file, script_file = EXCLUDED.script_file, enabled = EXCLUDED.enabled, updated_at = EXCLUDED.updated_at"),
    ("logs", None),
    ("strategy_events", None),
    ("account_season", None),
    ("tradingbot_mgr", None),
    ("account_balance_snapshots", None),
    ("account_month_balance_baseline", "ON CONFLICT (account_id, year_month) DO UPDATE SET initial_equity = EXCLUDED.initial_equity, initial_balance = EXCLUDED.initial_balance, recorded_at = EXCLUDED.recorded_at"),
    ("account_positions_history", "ON CONFLICT (account_id, okx_pos_id, u_time_ms) DO NOTHING"),
    ("account_open_positions_snapshots", None),
    ("account_daily_performance", "ON CONFLICT (account_id, day) DO UPDATE SET net_realized_pnl = EXCLUDED.net_realized_pnl, close_pos_count = EXCLUDED.close_pos_count, equlity_changed = EXCLUDED.equlity_changed, balance_changed = EXCLUDED.balance_changed, pnl_pct = EXCLUDED.pnl_pct, instrument_id = EXCLUDED.instrument_id, market_truevolatility = EXCLUDED.market_truevolatility, efficiency_ratio = EXCLUDED.efficiency_ratio, updated_at = EXCLUDED.updated_at"),
    ("market_daily_bars", 'ON CONFLICT (inst_id, day) DO UPDATE SET "open" = EXCLUDED."open", "high" = EXCLUDED."high", "low" = EXCLUDED."low", "close" = EXCLUDED."close", tr = EXCLUDED.tr, updated_at = EXCLUDED.updated_at'),
]


def _truncate_tables(pg: Any) -> None:
    names = [t for t, _ in _CONFLICT_SPECS]
    # 无 FK，逆序亦可；用 TRUNCATE RESTART IDENTITY
    quoted = ", ".join(f'"{n}"' for n in names)
    pg.execute(f"TRUNCATE TABLE {quoted} RESTART IDENTITY CASCADE")
    pg.commit()


def _default_upsert_set(cols: Sequence[str]) -> str:
    parts = []
    for c in cols:
        if c == "id":
            continue
        if c in ("open", "high", "low", "close"):
            parts.append(f'"{c}" = EXCLUDED."{c}"')
        else:
            parts.append(f"{c} = EXCLUDED.{c}")
    return ", ".join(parts)


def _copy_table(
    sq: Any,
    pg: Any,
    table: str,
    conflict: str | None,
    common_cols: list[str],
    *,
    select_sql: str | None = None,
    sqlite_table: str | None = None,
) -> int:
    if not common_cols:
        return 0
    # 当冲突键不是 id（例如 account_id/day 或 account_id+okx_pos_id+u_time_ms）时，
    # 不携带 SQLite 侧 id，避免与目标库既有 SERIAL 主键发生冲突。
    cols = list(common_cols)
    if conflict and "id" in cols and "(id)" not in conflict:
        cols = [c for c in cols if c != "id"]
    if not cols:
        return 0
    src = sqlite_table if sqlite_table is not None else table
    q = select_sql or f'SELECT * FROM "{src}"'
    rows = sq.execute(q).fetchall()
    if not rows:
        return 0
    col_sql = ", ".join(f'"{c}"' if c in ("open", "high", "low", "close") else c for c in cols)
    placeholders = ", ".join(["%s"] * len(cols))
    if conflict is None:
        if "id" not in cols:
            raise RuntimeError(f"表 {table} 无 ON CONFLICT 配置且不含 id 列")
        upd = _default_upsert_set(cols)
        tail = f"ON CONFLICT (id) DO UPDATE SET {upd}"
    else:
        tail = conflict
    sql = f"INSERT INTO {table} ({col_sql}) VALUES ({placeholders}) {tail}"
    n = 0
    for row in rows:
        vals = [row[c] for c in cols]
        try:
            pg.execute(sql, tuple(vals))
            n += 1
        except Exception as e:
            pg.rollback()
            raise RuntimeError(f"写入 {table} 失败: {e}; row={vals[:8]}...") from e
    pg.commit()
    return n


def _sync_serial_sequences(pg: Any) -> None:
    serial_tables = [
        "users",
        "logs",
        "strategy_events",
        "account_season",
        "tradingbot_mgr",
        "account_balance_snapshots",
        "account_positions_history",
        "account_open_positions_snapshots",
    ]
    for t in serial_tables:
        try:
            pg.execute(
                f"""
                SELECT setval(
                  pg_get_serial_sequence('{t}', 'id'),
                  COALESCE((SELECT MAX(id) FROM {t}), 1),
                  true
                )
                """
            )
        except Exception:
            pg.rollback()
        else:
            pg.commit()


def main() -> int:
    ap = argparse.ArgumentParser(description="SQLite → PostgreSQL 数据迁移")
    ap.add_argument(
        "--sqlite-path",
        default=str(BAASAPI_DIR / "sqlite" / "tradingbots.db"),
        help="源 SQLite 路径",
    )
    ap.add_argument(
        "--prepare-sqlite",
        action="store_true",
        help="迁移前先对 SQLite 执行 init_db（合并历史表名）",
    )
    ap.add_argument("--dry-run", action="store_true", help="只统计行数")
    ap.add_argument(
        "--truncate-target",
        action="store_true",
        help="导入前 TRUNCATE 目标库业务表（破坏性）",
    )
    ap.add_argument(
        "--database-url",
        default="",
        help="覆盖环境变量 DATABASE_URL",
    )
    args = ap.parse_args()
    sqlite_path = Path(args.sqlite_path).resolve()
    if not sqlite_path.is_file() and not args.prepare_sqlite:
        print(f"错误: 找不到 SQLite 文件: {sqlite_path}", file=sys.stderr)
        return 2

    if args.database_url:
        os.environ["DATABASE_URL"] = args.database_url.strip()

    try:
        import sqlite3
    except ModuleNotFoundError as e:
        if "_sqlite3" in str(e):
            import pysqlite3 as sqlite3  # type: ignore[no-redef]
        else:
            raise

    if args.prepare_sqlite:
        sqlite_path.parent.mkdir(parents=True, exist_ok=True)
        _prepare_sqlite_file(sqlite_path)

    if not sqlite_path.is_file():
        print(f"错误: 准备后仍无 SQLite 文件: {sqlite_path}", file=sys.stderr)
        return 2

    sq = sqlite3.connect(str(sqlite_path))
    sq.row_factory = sqlite3.Row

    if args.dry_run:
        print(f"源 SQLite: {sqlite_path}")
        for table, _ in _CONFLICT_SPECS:
            try:
                n = sq.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0]
            except sqlite3.OperationalError:
                n = "（无此表）"
            print(f"  {table}: {n}")
        sq.close()
        return 0

    # 与 db_backend 一致：从 database_config.json 补全 DATABASE_URL / POSTGRES_*（环境变量优先）
    if str(BAASAPI_DIR) not in sys.path:
        sys.path.insert(0, str(BAASAPI_DIR))
    os.chdir(PROJECT_ROOT)
    import db_backend  # noqa: F401 — 副作用：加载 database_config.json

    if not args.database_url and not (os.environ.get("DATABASE_URL") or "").strip():
        if not (os.environ.get("POSTGRES_HOST") or os.environ.get("POSTGRES_USER")):
            print(
                "错误: 请设置 DATABASE_URL 或 POSTGRES_*（或 --database-url），"
                "或在 baasapi/database_config.json 中配置 postgres_* / database_url",
                file=sys.stderr,
            )
            return 2

    os.environ["HZTECH_DB_BACKEND"] = "postgresql"
    _reload_pg_db_modules()
    import db_backend
    import db

    if db_backend.psycopg2 is None:
        print("错误: 未安装 psycopg2-binary", file=sys.stderr)
        return 2

    db.init_db()
    pg = db.get_conn()
    try:
        if args.truncate_target:
            _truncate_tables(pg)
        total = 0
        for table, conflict in _CONFLICT_SPECS:
            sqlite_src = table
            if table == "account_month_balance_baseline":
                if _sqlite_has_table(sq, "account_month_balance_baseline"):
                    sqlite_src = "account_month_balance_baseline"
                elif _sqlite_has_table(sq, "account_month_open"):
                    sqlite_src = "account_month_open"
            try:
                sq_cols = _sqlite_table_columns(sq, sqlite_src)
            except sqlite3.OperationalError:
                print(f"跳过（SQLite 无表）: {table}")
                continue
            if not sq_cols:
                print(f"跳过（无列）: {table}")
                continue
            pg_cols = _pg_table_columns(pg, table)
            if not pg_cols:
                print(f"跳过（PostgreSQL 无表）: {table}")
                continue
            common = [c for c in sq_cols if c in pg_cols]
            sel_sql: str | None = None
            sqlite_for_copy: str | None = (
                sqlite_src if sqlite_src != table else None
            )
            if table == "account_month_balance_baseline":
                if "open_cash" in common and "initial_balance" in common:
                    common = [c for c in common if c != "open_cash"]
                elif "open_cash" in sq_cols and "initial_balance" not in sq_cols:
                    eq_src = (
                        "open_equity"
                        if "open_equity" in sq_cols
                        else ("open_equlity" if "open_equlity" in sq_cols else None)
                    )
                    if eq_src:
                        common = [
                            c
                            for c in [
                                "account_id",
                                "year_month",
                                "initial_equity",
                                "initial_balance",
                                "recorded_at",
                            ]
                            if c in pg_cols
                        ]
                        sel_sql = (
                            f"SELECT account_id, year_month, {eq_src} AS initial_equity, "
                            "open_cash AS initial_balance, recorded_at "
                            f'FROM "{sqlite_src}"'
                        )
                elif (
                    sel_sql is None
                    and (
                        "open_equity" in sq_cols or "open_equlity" in sq_cols
                    )
                    and "initial_equity" not in sq_cols
                    and "initial_equity" in pg_cols
                ):
                    eq_src = (
                        "open_equity"
                        if "open_equity" in sq_cols
                        else "open_equlity"
                    )
                    common = [
                        c
                        for c in [
                            "account_id",
                            "year_month",
                            "initial_equity",
                            "initial_balance",
                            "recorded_at",
                        ]
                        if c in pg_cols
                    ]
                    sel_sql = (
                        f"SELECT account_id, year_month, {eq_src} AS initial_equity, "
                        "initial_balance, recorded_at "
                        f'FROM "{sqlite_src}"'
                    )
            n = _copy_table(
                sq,
                pg,
                table,
                conflict,
                common,
                select_sql=sel_sql,
                sqlite_table=sqlite_for_copy,
            )
            print(f"{table}: 写入 {n} 行（列: {', '.join(common)}）")
            total += n
        _sync_serial_sequences(pg)
        print(f"完成，共处理约 {total} 行插入/更新。")
    finally:
        pg.close()
        sq.close()
    return 0


if __name__ == "__main__":
    if str(BAASAPI_DIR) not in sys.path:
        sys.path.insert(0, str(BAASAPI_DIR))
    os.chdir(PROJECT_ROOT)
    raise SystemExit(main())
