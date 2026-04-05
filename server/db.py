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
            CREATE TABLE IF NOT EXISTS account_meta (
                account_id TEXT PRIMARY KEY,
                initial_capital REAL NOT NULL DEFAULT 0,
                updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE TABLE IF NOT EXISTS account_snapshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id TEXT NOT NULL,
                snapshot_at TEXT NOT NULL,
                cash_balance REAL NOT NULL DEFAULT 0,
                equity_usdt REAL NOT NULL DEFAULT 0,
                initial_capital REAL NOT NULL DEFAULT 0,
                profit_amount REAL NOT NULL DEFAULT 0,
                profit_percent REAL NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_account_snapshots_account ON account_snapshots(account_id);
            CREATE INDEX IF NOT EXISTS idx_account_snapshots_at ON account_snapshots(snapshot_at);
            CREATE TABLE IF NOT EXISTS account_month_open (
                account_id TEXT NOT NULL,
                year_month TEXT NOT NULL,
                open_equity REAL NOT NULL,
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
            CREATE TABLE IF NOT EXISTS account_daily_close_performance (
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
            CREATE INDEX IF NOT EXISTS idx_adcp_account ON account_daily_close_performance(account_id);
            CREATE INDEX IF NOT EXISTS idx_adcp_day ON account_daily_close_performance(day);
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
) -> bool:
    """创建用户，成功返回 True，用户名已存在返回 False。role 须为合法枚举。"""
    rr = str(role).strip().lower()
    if rr not in _VALID_USER_ROLES:
        return False
    links = linked_account_ids if linked_account_ids is not None else []
    links_json = json.dumps(links, ensure_ascii=False)
    conn = get_conn()
    try:
        try:
            conn.execute(
                "INSERT INTO users (username, password_hash, role, linked_account_ids) VALUES (?, ?, ?, ?)",
                (username.strip(), password_hash, rr, links_json),
            )
        except sqlite3.OperationalError:
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
    except sqlite3.OperationalError:
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
    except sqlite3.OperationalError:
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
    except sqlite3.OperationalError:
        return []
    finally:
        conn.close()


def user_list() -> list[dict]:
    """返回用户列表（不含 password_hash），含 role、linked_account_ids。"""
    conn = get_conn()
    try:
        try:
            cur = conn.execute(
                "SELECT id, username, created_at, role, linked_account_ids FROM users ORDER BY id"
            )
            rows = cur.fetchall()
        except sqlite3.OperationalError:
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
            out.append(
                {
                    "id": r[0],
                    "username": r[1],
                    "created_at": r[2],
                    "role": role,
                    "linked_account_ids": links,
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
                "SELECT id, username, created_at, role, linked_account_ids FROM users WHERE id = ?",
                (user_id,),
            )
            r = cur.fetchone()
        except sqlite3.OperationalError:
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
        }
    finally:
        conn.close()


def user_update_profile(
    user_id: int,
    *,
    role: str | None = None,
    linked_account_ids: list[str] | None = None,
) -> bool:
    """更新角色与/或客户可见账户；role 须为合法枚举。无有效变更时返回 False。"""
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
        if not fields:
            return False
        args.append(user_id)
        cur = conn.execute(
            f"UPDATE users SET {', '.join(fields)} WHERE id = ?",
            args,
        )
        conn.commit()
        return cur.rowcount > 0
    except sqlite3.OperationalError:
        return False
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


def bot_profit_query_by_bot_since(
    bot_id: str, *, since_snapshot_at: str, max_rows: int = 40000
) -> list[dict]:
    """自 since_snapshot_at（含）起按 snapshot_at 升序，供策略能效与 account_snapshots 口径对齐。"""
    cap = max(100, min(100000, int(max_rows)))
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT id, bot_id, snapshot_at, initial_balance, current_balance, equity_usdt,
                      profit_amount, profit_percent, created_at
               FROM bot_profit_snapshots
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


# ---------- Account_List 账户（AccountMgr 定时快照、月初权益） ----------
def account_meta_upsert(account_id: str, initial_capital: float) -> None:
    """写入或更新账户初始资金（来自 Account_List.json 的 Initial_capital）。"""
    conn = get_conn()
    try:
        conn.execute(
            """INSERT INTO account_meta (account_id, initial_capital, updated_at)
               VALUES (?, ?, datetime('now'))
               ON CONFLICT(account_id) DO UPDATE SET
                 initial_capital = excluded.initial_capital,
                 updated_at = datetime('now')""",
            (account_id.strip(), float(initial_capital)),
        )
        conn.commit()
    finally:
        conn.close()


def account_meta_get(account_id: str) -> dict | None:
    conn = get_conn()
    try:
        cur = conn.execute(
            "SELECT account_id, initial_capital, updated_at FROM account_meta WHERE account_id = ?",
            (account_id.strip(),),
        )
        r = cur.fetchone()
        if not r:
            return None
        return {
            "account_id": r[0],
            "initial_capital": float(r[1]),
            "updated_at": r[2],
        }
    finally:
        conn.close()


def account_meta_prune_except(keep_account_ids: set[str]) -> None:
    """删除 account_meta 中不在 keep_account_ids 内的行（与 Account_List.json 账户集合对齐）。"""
    conn = get_conn()
    try:
        cur = conn.execute("SELECT account_id FROM account_meta")
        for (aid,) in cur.fetchall():
            if aid not in keep_account_ids:
                conn.execute("DELETE FROM account_meta WHERE account_id = ?", (aid,))
        conn.commit()
    finally:
        conn.close()


def account_snapshot_insert(
    account_id: str,
    snapshot_at: str,
    cash_balance: float,
    equity_usdt: float,
    initial_capital: float,
    profit_amount: float,
    profit_percent: float,
) -> None:
    conn = get_conn()
    try:
        conn.execute(
            """INSERT INTO account_snapshots
               (account_id, snapshot_at, cash_balance, equity_usdt, initial_capital,
                profit_amount, profit_percent)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (
                account_id.strip(),
                snapshot_at,
                cash_balance,
                equity_usdt,
                initial_capital,
                profit_amount,
                profit_percent,
            ),
        )
        conn.commit()
    finally:
        conn.close()


def account_snapshot_latest_by_account(account_id: str) -> dict | None:
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT id, account_id, snapshot_at, cash_balance, equity_usdt, initial_capital,
                      profit_amount, profit_percent, created_at
               FROM account_snapshots WHERE account_id = ? ORDER BY snapshot_at DESC LIMIT 1""",
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
            "initial_capital": r[5],
            "profit_amount": r[6],
            "profit_percent": r[7],
            "created_at": r[8],
        }
    finally:
        conn.close()


def account_snapshot_query_by_account(account_id: str, limit: int = 500) -> list[dict]:
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT id, account_id, snapshot_at, cash_balance, equity_usdt, initial_capital,
                      profit_amount, profit_percent, created_at
               FROM account_snapshots WHERE account_id = ? ORDER BY snapshot_at ASC LIMIT ?""",
            (account_id.strip(), limit),
        )
        return [
            {
                "id": r[0],
                "account_id": r[1],
                "snapshot_at": r[2],
                "cash_balance": r[3],
                "equity_usdt": r[4],
                "initial_capital": r[5],
                "profit_amount": r[6],
                "profit_percent": r[7],
                "created_at": r[8],
            }
            for r in cur.fetchall()
        ]
    finally:
        conn.close()


def account_snapshot_query_by_account_since(
    account_id: str, *, since_snapshot_at: str, max_rows: int = 40000
) -> list[dict]:
    """按 snapshot_at 升序返回自 since_snapshot_at（含）起的快照，用于按日汇总现金变化。"""
    cap = max(100, min(100000, int(max_rows)))
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT id, account_id, snapshot_at, cash_balance, equity_usdt, initial_capital,
                      profit_amount, profit_percent, created_at
               FROM account_snapshots
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
                "initial_capital": r[5],
                "profit_amount": r[6],
                "profit_percent": r[7],
                "created_at": r[8],
            }
            for r in cur.fetchall()
        ]
    finally:
        conn.close()


def account_snapshot_exists_on_utc_date(account_id: str, day_yyyy_mm_dd: str) -> bool:
    """该 account 在 UTC 自然日 day 是否已有任意一条 account_snapshots（date 与 SQLite date() 对齐）。"""
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT 1 FROM account_snapshots
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
    """snapshot_at 严格早于 instant_iso 的最后一条（用于账单补全前取权益/现金比例）。"""
    inst = (instant_iso or "").strip()
    if not inst:
        return None
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT id, account_id, snapshot_at, cash_balance, equity_usdt, initial_capital,
                      profit_amount, profit_percent, created_at
               FROM account_snapshots
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
            "initial_capital": r[5],
            "profit_amount": r[6],
            "profit_percent": r[7],
            "created_at": r[8],
        }
    finally:
        conn.close()


def account_month_open_get(account_id: str, year_month: str) -> dict | None:
    """year_month 形如 2026-04。"""
    conn = get_conn()
    try:
        cur = conn.execute(
            """SELECT account_id, year_month, open_equity, recorded_at
               FROM account_month_open WHERE account_id = ? AND year_month = ?""",
            (account_id.strip(), year_month.strip()),
        )
        r = cur.fetchone()
        if not r:
            return None
        return {
            "account_id": r[0],
            "year_month": r[1],
            "open_equity": float(r[2]),
            "recorded_at": r[3],
        }
    finally:
        conn.close()


def account_month_open_insert_if_absent(
    account_id: str,
    year_month: str,
    open_equity: float,
    recorded_at: str,
) -> None:
    """每月仅第一条记录生效（月初首次快照时写入）。"""
    conn = get_conn()
    try:
        conn.execute(
            """INSERT OR IGNORE INTO account_month_open
               (account_id, year_month, open_equity, recorded_at)
               VALUES (?, ?, ?, ?)""",
            (account_id.strip(), year_month.strip(), open_equity, recorded_at),
        )
        conn.commit()
    finally:
        conn.close()


def _fnum(v: object) -> float | None:
    if v is None or v == "":
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


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
            cur = conn.execute(
                """INSERT OR IGNORE INTO account_positions_history
                   (account_id, okx_pos_id, inst_id, inst_type, pos_side, mgn_mode,
                    open_avg_px, close_avg_px, open_max_pos, close_total_pos,
                    pnl, realized_pnl, fee, funding_fee, close_type,
                    c_time_ms, u_time_ms, raw_json, synced_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
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


def account_daily_close_performance_query_month(
    account_id: str, year: int, month: int
) -> list[dict[str, Any]]:
    """读库表 account_daily_close_performance（UTC 自然日）。"""
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
            FROM account_daily_close_performance
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


def account_daily_close_performance_rebuild_for_accounts(
    account_ids: list[str],
    benchmark_inst_by_account: dict[str, str],
    *,
    default_benchmark_inst: str = "PEPE-USDT-SWAP",
) -> None:
    """
    按 account_positions_history 按日汇总平仓净盈亏，写入 account_daily_close_performance。
    equity_base：该 UTC 日 00:00 前最后一笔 account_snapshots.equity_usdt；无快照则用 account_meta.initial_capital。
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
            meta = account_meta_get(aid)
            initial = float(meta["initial_capital"]) if meta else 0.0

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
                "DELETE FROM account_daily_close_performance WHERE account_id = ?",
                (aid,),
            )
            if not day_rows:
                continue

            cur_sn = conn.execute(
                """
                SELECT snapshot_at, equity_usdt
                FROM account_snapshots
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
                    INSERT INTO account_daily_close_performance
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


def market_daily_bars_upsert(
    inst_id: str,
    day: str,
    open_v: float,
    high_v: float,
    low_v: float,
    close_v: float,
    tr_v: float,
) -> None:
    conn = get_conn()
    try:
        conn.execute(
            """INSERT INTO market_daily_bars
               (inst_id, day, open, high, low, close, tr, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))
               ON CONFLICT(inst_id, day) DO UPDATE SET
                 open = excluded.open,
                 high = excluded.high,
                 low = excluded.low,
                 close = excluded.close,
                 tr = excluded.tr,
                 updated_at = datetime('now')""",
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


def market_daily_bars_list_since(inst_id: str, min_day: str) -> list[dict[str, Any]]:
    """UTC 日历日 day >= min_day，按 day 升序。项与 OKX merge 用字段一致。"""
    conn = get_conn()
    try:
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
