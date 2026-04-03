# -*- coding: utf-8 -*-
"""
OKX 交易所 API：配置加载、账户余额/持仓/行情，基于 ccxt 实现。
与 Accounts/testapi.py 行为一致（优先 api 子对象、沙盒请求头）。
"""
from __future__ import annotations

import base64
import hmac
import json
import logging
import os
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

import ccxt

logger = logging.getLogger(__name__)
_DEBUG_POSITIONS = os.environ.get("DEBUG_POSITIONS", "0") == "1"


def _parse_okx_http_error_body(err_body: str) -> tuple[object | None, str]:
    """解析 OKX HTTP 错误响应 JSON：返回 (业务码, 展示用原因文案)。

    优先使用 data[0] 的 sCode/sMsg（OKX 常见嵌套结构），否则用顶层 code/msg。
    非 JSON 时业务码为 None，第二项为截断的原始文本。
    """
    raw = (err_body or "").strip()
    if not raw:
        return None, ""
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return None, raw[:400]
    if not isinstance(parsed, dict):
        return None, raw[:400]
    top_code = parsed.get("code")
    top_msg = (parsed.get("msg") or "").strip()
    data = parsed.get("data")
    nested_code: object | None = None
    nested_msg = ""
    if isinstance(data, list) and data and isinstance(data[0], dict):
        d0 = data[0]
        nested_code = d0.get("sCode")
        if nested_code is None or nested_code == "":
            nested_code = d0.get("code")
        nested_msg = (d0.get("sMsg") or d0.get("msg") or "").strip()
    if nested_code is not None and nested_code != "":
        primary_code = nested_code
    else:
        primary_code = top_code
    show_msg = nested_msg or top_msg
    return primary_code, show_msg


def _okx_code_is_1010(code: object, err_body: str) -> bool:
    if code is not None and str(code).strip() == "1010":
        return True
    if code == 1010:
        return True
    # 解析失败时仅从 JSON 形态匹配，避免误匹配纯文本中的数字
    return '"1010"' in err_body or "'1010'" in err_body


def _okx_business_error_detail(data: dict) -> str:
    """HTTP 200 且 JSON code != '0'：用 OKX 返回的真实 code/msg（含 data[0] sCode/sMsg）。"""
    code: object = data.get("code")
    msg = (data.get("msg") or "").strip()
    dlist = data.get("data")
    if isinstance(dlist, list) and dlist and isinstance(dlist[0], dict):
        d0 = dlist[0]
        nc = d0.get("sCode")
        if nc is None or nc == "":
            nc = d0.get("code")
        nm = (d0.get("sMsg") or d0.get("msg") or "").strip()
        if nc is not None and nc != "":
            code = nc
        if nm:
            msg = nm
    return f"OKX 业务错误 code={code!r} msg={msg or '未知'}"


def get_public_egress_ip(timeout: float = 2.5) -> str | None:
    """探测本机访问公网时的出口 IP（与 OKX 侧看到的来源 IP 一致，用于 1010 白名单排查）。"""
    for url in (
        "https://api.ipify.org",
        "https://ifconfig.me/ip",
    ):
        try:
            req = Request(url, headers={"User-Agent": "hztech-okx-debug/1"})
            with urlopen(req, timeout=timeout) as resp:
                text = resp.read().decode("utf-8", errors="replace").strip()
                if text and len(text) < 45:
                    return text.split()[0]
        except Exception:
            continue
    return None


def okx_debug_snapshot(config_path: Path | None) -> dict[str, object]:
    """供 API 在 1010 等场景返回：出口 IP、所用配置文件名、脱敏 key，便于与手工 curl 对比。"""
    path = _resolve_path(config_path)
    out: dict[str, object] = {
        "note": (
            "请以 OKX 接口返回的 code/msg 及官方文档为准排查。"
            " 若确认为 IP 白名单问题，请将发起请求的服务器公网出口 IP（非浏览器 IP）"
            " 加入该 API Key 的白名单。"
        ),
    }
    if path:
        out["config_file"] = path.name
    cfg = load_okx_config(path) if path else None
    if cfg:
        key = (cfg.get("key") or "").strip()
        out["apikey_masked"] = f"****{key[-4:]}" if len(key) >= 4 else "****"
        out["sandbox"] = bool(cfg.get("sandbox"))
    out["server_egress_ip"] = get_public_egress_ip()
    return out


# 默认配置文件路径（由 get_default_config_path 设置，config_path=None 时使用）
_default_config_path: Path | None = None


def get_default_config_path(config_dir: Path) -> Path:
    """解析默认 OKX 配置路径并设为模块默认。config_dir 一般为 server/Accounts。"""
    global _default_config_path
    path = Path(os.environ.get("OKX_CONFIG", str(config_dir / "okx.json")))
    if not path.exists():
        path = config_dir / "account_api.json"
    _default_config_path = path
    return path


def _resolve_path(config_path: Path | None) -> Path | None:
    return config_path if config_path is not None else _default_config_path


def _parse_sandbox(value: object) -> bool:
    """解析 sandbox 配置：仅 True/\"true\"/1/\"1\" 为沙盒。"""
    if value is True or value == 1:
        return True
    if value is False or value is None or value == 0:
        return False
    if isinstance(value, str):
        return value.strip().lower() in ("true", "1", "yes")
    return False


def _read_key_secret_passphrase(obj: dict) -> tuple[str, str, str]:
    """从 dict 读 key/secret/passphrase，兼容 key 与 apikey、secret 与 secretkey/secret_key。"""
    key = (obj.get("apikey") or obj.get("key") or "").strip()
    secret = (
        obj.get("secretkey") or obj.get("secret_key") or obj.get("secret") or ""
    ).strip()
    passphrase = (obj.get("passphrase") or "").strip()
    return key, secret, passphrase


def load_okx_config(path: Path | None) -> dict | None:
    """从 JSON 加载 OKX 配置（与 Accounts/testapi.py 一致，优先 api 子对象）。
    支持格式：
    1) 新格式：{"api": {"name", "key", "secret", "passphrase", "base_url", "sandbox"}}
    2) 中间格式：{"api": {"apikey", "secretkey", "passphrase", ...}}（api 内用旧键名）
    3) 旧格式：顶层 apikey/key, secretkey/secret, passphrase, base_url, sandbox
    返回统一结构：name, key, secret, passphrase, base_url, sandbox。
    path 为 None 时使用 get_default_config_path 设置的默认路径。
    """
    resolved = _resolve_path(path)
    if not resolved or not resolved.exists():
        return None
    try:
        with open(resolved, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        return None
    if not isinstance(data, dict):
        return None
    api = data.get("api") if isinstance(data.get("api"), dict) else None
    if api:
        sandbox = _parse_sandbox(api.get("sandbox"))
        base_url = (api.get("base_url") or "https://www.okx.com").rstrip("/")
        if sandbox:
            base_url = "https://www.okx.com"
        key, secret, passphrase = _read_key_secret_passphrase(api)
        return {
            "name": api.get("name") or resolved.stem,
            "key": key,
            "secret": secret,
            "passphrase": passphrase,
            "base_url": base_url,
            "sandbox": sandbox,
        }
    key, secret, passphrase = _read_key_secret_passphrase(data)
    sandbox = _parse_sandbox(data.get("sandbox"))
    base_url = (
        (data.get("base_url") or "https://www.okx.com").strip().rstrip("/")
        or "https://www.okx.com"
    )
    if sandbox:
        base_url = "https://www.okx.com"

    return {
        "name": resolved.stem,
        "key": key,
        "secret": secret,
        "passphrase": passphrase,
        "base_url": base_url,
        "sandbox": sandbox,
    }


def _create_exchange(cfg: dict):
    """从统一配置构建 ccxt.okx 实例（沙盒通过 set_sandbox_mode 区分）。"""
    key = (cfg.get("key") or "").strip()
    secret = (cfg.get("secret") or "").strip()
    passphrase = (cfg.get("passphrase") or "").strip()
    base_url = (cfg.get("base_url") or "https://www.okx.com").rstrip("/")
    sandbox = bool(cfg.get("sandbox"))
    options = {"defaultType": "swap"}
    # ccxt okx: password 即 OKX 的 passphrase
    exchange = ccxt.okx(
        {
            "apiKey": key,
            "secret": secret,
            "password": passphrase,
            "options": options,
            "timeout": 15000,
            "enableRateLimit": True,
        }
    )
    exchange.set_sandbox_mode(sandbox)
    return exchange


def okx_info_safe(config_path: Path | None = None) -> dict | None:
    """读取 OKX 配置并脱敏返回（key 后四位，不返回 secret）。config_path 为 None 用默认。"""
    cfg = load_okx_config(config_path)
    if not cfg:
        return None
    key = cfg.get("key") or ""
    return {
        "apikey_masked": f"****{key[-4:]}" if len(key) >= 4 else "****",
        "has_passphrase": bool(cfg.get("passphrase")),
        "has_secretkey": bool(cfg.get("secret")),
    }


def okx_request(
    method: str,
    request_path: str,
    body: str = "",
    config_path: Path | None = None,
    params: dict | None = None,
) -> tuple[dict | None, str | None]:
    """OKX 私有接口签名请求（与 Accounts/testapi.py 一致）。
    返回 (data, error)。error 非空表示 HTTP 或配置错误（如 403）。"""
    path = _resolve_path(config_path)
    config_name = path.name if path else "default"
    if _DEBUG_POSITIONS:
        logger.info(
            "[持仓-OKX] 准备请求 OKX: %s %s config=%s",
            method, request_path, config_name,
        )
    cfg = load_okx_config(path) if path else None
    if not cfg:
        if _DEBUG_POSITIONS and path:
            logger.warning("[持仓-OKX] 配置文件不存在或格式无效: %s", path)
        return (None, "OKX 配置文件不存在或格式无效")
    key = cfg.get("key") or ""
    secret = cfg.get("secret") or ""
    passphrase = cfg.get("passphrase") or ""
    if not key or not secret:
        return (None, "OKX 配置缺少 key 或 secret")
    base = cfg.get("base_url") or "https://www.okx.com"
    if params and method.upper() == "GET":
        request_path = request_path.split("?")[0] + "?" + urlencode(params)
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    prehash = ts + method.upper() + request_path + body
    sign = base64.b64encode(
        hmac.new(secret.encode(), prehash.encode(), "sha256").digest()
    ).decode()
    url = base + request_path
    headers = {
        "OK-ACCESS-KEY": key,
        "OK-ACCESS-SIGN": sign,
        "OK-ACCESS-TIMESTAMP": ts,
        "OK-ACCESS-PASSPHRASE": passphrase,
        "Content-Type": "application/json",
    }
    if cfg.get("sandbox"):
        headers["x-simulated-trading"] = "1"
    try:
        req = Request(
            url,
            headers=headers,
            method=method,
            data=body.encode() if body else None,
        )
        with urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode())
            if _DEBUG_POSITIONS:
                code = data.get("code") if isinstance(data, dict) else "N/A"
                logger.info("[持仓-OKX] OKX 响应: %s %s code=%s", method, request_path, code)
            return (data, None)
    except HTTPError as e:
        err_body = ""
        try:
            raw = e.fp.read() if getattr(e, "fp", None) else b""
            err_body = raw.decode("utf-8", errors="replace")[:500]
        except Exception:
            err_body = ""
        primary_code, show_msg = _parse_okx_http_error_body(err_body)
        is_1010 = e.code == 403 and _okx_code_is_1010(primary_code, err_body)
        egress: str | None = None
        if is_1010:
            egress = get_public_egress_ip()
        raw_log = (err_body[:500] if err_body else "") or "(无响应体)"
        logger.warning(
            "OKX请求失败 %s %s config=%s | HTTP状态=%s OKX业务码=%r OKX原因=%r | 响应体=%s%s",
            method,
            request_path,
            config_name,
            e.code,
            primary_code,
            show_msg or "(空)",
            raw_log,
            (
                f" | 本机出口IP={egress or '未知'}(与OKX白名单比对)"
                if is_1010
                else ""
            ),
        )
        reason = show_msg or "(OKX 响应体未解析出 msg)"
        detail = (
            f"HTTP {e.code} OKX业务码={primary_code!r} 原因={reason} 原始响应={raw_log!r}"
        )
        if is_1010:
            detail += f" 本机出口IP={egress or '未知'}"
        return (None, detail)
    except (URLError, json.JSONDecodeError, OSError, KeyError) as e:
        logger.warning("OKX request error: %s %s -> %s", method, request_path, e)
        return (None, None)


def _okx_fetch_balance_fallback(
    config_path: Path | None,
) -> tuple[dict | None, str | None]:
    """余额：原生签名请求 /api/v5/account/balance（不经过 ccxt，避免 load_markets 解析 preopen 等标的异常）。"""
    data, err = okx_request("GET", "/api/v5/account/balance", config_path=config_path)
    if data is None:
        return None, err or "请求失败或无有效 JSON（参见同时间点 OKX request 日志）"
    if data.get("code") != "0":
        return None, _okx_business_error_detail(data)
    total_eq = 0.0
    avail_eq = 0.0
    upl = 0.0
    for d in (data.get("data") or []):
        try:
            total_eq += float(d.get("totalEq", 0) or 0)
            avail_eq += float(d.get("availEq", 0) or 0)
            upl += float(d.get("upl", 0) or 0)
        except (TypeError, ValueError):
            pass
    if avail_eq == 0 and total_eq != 0:
        avail_eq = total_eq
    return _okx_balance_dict(total_eq, avail_eq, upl, raw=data), None


def _okx_balance_dict(
    total_eq: float, avail_eq: float, upl: float, *, raw: object
) -> dict:
    """OKX /api/v5/account/balance 口径：权益 totalEq、可用权益 availEq（作现金余额展示）。"""
    return {
        "total_eq": total_eq,
        "avail_eq": avail_eq,
        "equity_usdt": total_eq,
        "cash_balance": avail_eq,
        "upl": upl,
        "raw": raw,
    }


def okx_fetch_balance(config_path: Path | None = None) -> dict | None:
    """OKX 账户：权益 totalEq、现金余额口径 availEq（见 cash_balance / equity_usdt 字段）。

    仅走 OKX v5 REST，不调用 ccxt.fetch_balance（否则会 load_markets，ccxt 对 preopen 等标的解析可能 TypeError: NoneType + str）。
    """
    path = _resolve_path(config_path)
    cfg = load_okx_config(path) if path else None
    if not cfg or not (cfg.get("key") and cfg.get("secret")):
        return None
    out, err_detail = _okx_fetch_balance_fallback(path)
    if out is not None:
        return out
    cfg_name = path.name if path else "default"
    logger.warning(
        "OKX fetch_balance [%s]: /api/v5/account/balance 未返回有效数据 — %s",
        cfg_name,
        err_detail or "请检查 API 权限、网络与配置",
    )
    return None


def _okx_fetch_positions_fallback(config_path: Path | None) -> tuple[list[dict], str | None]:
    """持仓获取回退：用原生签名请求 /api/v5/account/positions?instType=SWAP（避免 ccxt 解析时 None+str 等异常）。"""
    data, err = okx_request(
        "GET",
        "/api/v5/account/positions",
        config_path=config_path,
        params={"instType": "SWAP"},
    )
    if err:
        return ([], err)
    if data is None or data.get("code") != "0":
        if isinstance(data, dict):
            return ([], _okx_business_error_detail(data))
        return ([], "OKX 持仓接口返回异常")
    raw_list = data.get("data") or []
    out = []
    for d in raw_list:
        try:
            inst_id = (d.get("instId") or "").strip()
            if not inst_id or "-SWAP" not in inst_id.upper():
                continue
            pos_str = d.get("pos") or "0"
            contracts = float(pos_str)
            if contracts == 0:
                continue
            pos_side = (d.get("posSide") or d.get("side") or "long").lower()
            if pos_side not in ("long", "short"):
                pos_side = "long" if contracts >= 0 else "short"
            pos_f = contracts if pos_side == "long" else -abs(contracts)
            mark_px = float(d.get("markPx") or 0)
            last_px = okx_fetch_ticker(inst_id) if inst_id else None
            if last_px is None:
                last_px = mark_px
            avg_px = float(d.get("avgPx") or 0)
            upl = float(d.get("upl") or 0)
            out.append({
                "inst_id": inst_id,
                "pos": pos_f,
                "pos_side": pos_side,
                "avg_px": avg_px,
                "mark_px": mark_px,
                "last_px": last_px,
                "upl": upl,
            })
        except (TypeError, ValueError, KeyError):
            continue
    return (out, None)


def _inst_id_to_ccxt_symbol(inst_id: str) -> str:
    """OKX instId (BTC-USDT-SWAP) -> ccxt 统一符号 (BTC/USDT:USDT)。"""
    if "-SWAP" in inst_id.upper():
        a = inst_id.upper().replace("-SWAP", "").split("-")
        if len(a) >= 2:
            return f"{a[0]}/{a[1]}:{a[1]}"
    return inst_id.replace("-", "/")


def okx_fetch_ticker(inst_id: str) -> float | None:
    """OKX 公开接口：获取合约最新价（ccxt fetch_ticker）。成功返回 last 价格，失败返回 None。"""
    try:
        exchange = ccxt.okx({"enableRateLimit": True, "timeout": 5000})
        symbol = _inst_id_to_ccxt_symbol(inst_id)
        ticker = exchange.fetch_ticker(symbol)
        if ticker and ticker.get("last") is not None:
            return float(ticker["last"])
        return None
    except Exception:
        return None


def okx_fetch_daily_ohlcv_with_tr(
    inst_id: str, *, limit: int = 120
) -> tuple[list[dict[str, float | str]], str | None]:
    """
    OKX 公开 K 线：日线 OHLC，并计算当日 True Range（TR）。
    TR = max(H-L, |H-昨收|, |L-昨收|)；首根 K 线无前收时 TR = H-L。
    inst_id 示例：PEPE-USDT-SWAP（与持仓 instId 一致）。
    返回 (bars, error)，bars 项含 day(UTC 日期 YYYY-MM-DD)、open/high/low/close/tr。
    """
    lim = max(2, min(500, int(limit)))
    try:
        exchange = ccxt.okx({"enableRateLimit": True, "timeout": 20000})
        symbol = _inst_id_to_ccxt_symbol(inst_id)
        ohlcv = exchange.fetch_ohlcv(symbol, "1d", limit=lim)
    except Exception as e:
        return [], str(e) or "fetch_ohlcv failed"
    if not ohlcv:
        return [], "empty ohlcv"
    out: list[dict[str, float | str]] = []
    prev_close: float | None = None
    for row in ohlcv:
        try:
            ts_ms, o, h, l, c = int(row[0]), float(row[1]), float(row[2]), float(row[3]), float(row[4])
        except (TypeError, ValueError, IndexError):
            continue
        if prev_close is None:
            tr = h - l
        else:
            pc = float(prev_close)
            tr = max(h - l, abs(h - pc), abs(l - pc))
        prev_close = c
        day = datetime.fromtimestamp(ts_ms / 1000.0, tz=timezone.utc).strftime("%Y-%m-%d")
        out.append(
            {
                "day": day,
                "open": float(o),
                "high": h,
                "low": l,
                "close": c,
                "tr": float(tr),
            }
        )
    return out, None


def _ccxt_symbol_to_inst_id(symbol: str) -> str:
    """ccxt 统一符号 (BTC/USDT:USDT) -> OKX instId (BTC-USDT-SWAP)。"""
    if ":" in symbol:
        base_quote = symbol.split(":")[0]
        quote = symbol.split(":")[1] if ":" in symbol else "USDT"
        return f"{base_quote.replace('/', '-')}-{quote}-SWAP"
    return symbol.replace("/", "-")


def okx_fetch_positions(config_path: Path | None = None) -> tuple[list[dict], str | None]:
    """调用 OKX 持仓（ccxt fetch_positions）；返回 (positions, error)。"""
    path = _resolve_path(config_path)
    if _DEBUG_POSITIONS and path:
        logger.info("[持仓] 开始拉取 OKX 持仓 config=%s", path.name)
    cfg = load_okx_config(path) if path else None
    if not cfg or not (cfg.get("key") and cfg.get("secret")):
        return ([], "OKX 配置文件不存在或格式无效")
    try:
        exchange = _create_exchange(cfg)
        raw_list = exchange.fetch_positions()
    except TypeError as e:
        if "NoneType" in str(e) and "+" in str(e) and "str" in str(e):
            logger.warning(
                "OKX fetch_positions: ccxt 解析报错（多为 preopen 标的空字段），使用原生 API 回退。错误: %s",
                e,
            )
            return _okx_fetch_positions_fallback(path)
        logger.warning("OKX fetch_positions error: %s", e)
        return ([], str(e) or "无法获取持仓，请检查 OKX 配置或网络")
    except Exception as e:
        logger.warning("OKX fetch_positions error: %s", e)
        return ([], str(e) or "无法获取持仓，请检查 OKX 配置或网络")
    out = []
    for p in raw_list:
        try:
            info = p.get("info") or {}
            if info.get("instType") and info.get("instType") != "SWAP":
                continue
            symbol = p.get("symbol") or ""
            if symbol and ":USDT" not in symbol and "-SWAP" not in str(info.get("instId", "")):
                continue
            contracts = float(p.get("contracts") or p.get("contractSize") or 0)
            side = (p.get("side") or "long").lower()
            if side not in ("long", "short"):
                side = "long" if contracts >= 0 else "short"
            pos_f = contracts if side == "long" else -abs(contracts)
            if pos_f == 0:
                continue
            inst_id = info.get("instId") or _ccxt_symbol_to_inst_id(symbol)
            mark_px = float(info.get("markPx") or p.get("markPrice") or 0)
            last_px = okx_fetch_ticker(inst_id) if inst_id else None
            if last_px is None:
                last_px = mark_px
            avg_px = float(info.get("avgPx") or p.get("entryPrice") or 0)
            upl = float(info.get("upl") or p.get("unrealizedPnl") or 0)
            out.append({
                "inst_id": inst_id,
                "pos": pos_f,
                "pos_side": side,
                "avg_px": avg_px,
                "mark_px": mark_px,
                "last_px": last_px,
                "upl": upl,
            })
        except (TypeError, ValueError, AttributeError, KeyError):
            continue
    if not out and raw_list:
        logger.info("OKX positions: %d raw items, all pos=0 or parse failed", len(raw_list))
    return (out, None)


def okx_fetch_positions_history(
    config_path: Path | None = None,
    *,
    inst_type: str = "SWAP",
    limit_per_page: int = 100,
    max_pages: int = 5,
) -> tuple[list[dict], str | None]:
    """
    历史仓位：GET /api/v5/account/positions-history（近约 3 个月，按 uTime 倒序）。
    分页拉取多页后合并为列表；用于定时入库去重。
    """
    path = _resolve_path(config_path)
    cfg = load_okx_config(path) if path else None
    if not cfg or not (cfg.get("key") and cfg.get("secret")):
        return ([], "OKX 配置文件不存在或格式无效")
    lim = max(1, min(100, int(limit_per_page)))
    pages = max(1, int(max_pages))
    merged: list[dict] = []
    after_ms: str | None = None
    for _ in range(pages):
        params: dict[str, str] = {"limit": str(lim)}
        if inst_type:
            params["instType"] = inst_type
        if after_ms:
            params["after"] = after_ms
        data, err = okx_request(
            "GET",
            "/api/v5/account/positions-history",
            config_path=config_path,
            params=params,
        )
        if err:
            return (merged, err) if merged else ([], err)
        if data is None or data.get("code") != "0":
            msg = (
                _okx_business_error_detail(data)
                if isinstance(data, dict)
                else "positions-history 异常"
            )
            return (merged, msg) if merged else ([], msg)
        batch = data.get("data") or []
        if not batch:
            break
        merged.extend(batch)
        if len(batch) < lim:
            break
        uts: list[int] = []
        for r in batch:
            try:
                u = int(str(r.get("uTime") or "0").strip() or 0)
                if u:
                    uts.append(u)
            except (TypeError, ValueError, AttributeError):
                continue
        if not uts:
            break
        after_ms = str(min(uts))
    return (merged, None)


def okx_fetch_pending_orders(
    config_path: Path | None = None,
    *,
    inst_type: str = "SWAP",
) -> tuple[list[dict], str | None]:
    """
    当前委托（未成交）：GET /api/v5/trade/orders-pending。
    返回 (订单列表简化字段, error)。不入库，仅供实时查询。
    """
    data, err = okx_request(
        "GET",
        "/api/v5/trade/orders-pending",
        config_path=config_path,
        params={"instType": inst_type},
    )
    if err:
        return ([], err)
    if data is None or data.get("code") != "0":
        if isinstance(data, dict):
            msg = _okx_business_error_detail(data)
        else:
            msg = "orders-pending 异常"
        return ([], msg)
    raw_list = data.get("data") or []
    out: list[dict] = []
    for o in raw_list:
        if not isinstance(o, dict):
            continue
        try:
            out.append({
                "inst_id": (o.get("instId") or "").strip(),
                "ord_id": (o.get("ordId") or "").strip(),
                "side": (o.get("side") or "").strip(),
                "pos_side": (o.get("posSide") or "").strip(),
                "ord_type": (o.get("ordType") or "").strip(),
                "state": (o.get("state") or "").strip(),
                "px": o.get("px"),
                "sz": o.get("sz"),
                "fill_sz": o.get("fillSz"),
                "u_time": o.get("uTime") or o.get("cTime"),
            })
        except (TypeError, ValueError):
            continue
    return (out, None)
