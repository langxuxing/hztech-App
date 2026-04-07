# -*- coding: utf-8 -*-
"""
OKX 交易所 API：配置加载、账户余额/持仓/行情，基于 ccxt 实现。
与 accounts/testapi.py 行为一致（优先 api 子对象、沙盒请求头）。
"""
from __future__ import annotations

import base64
import hmac
import json
import logging
import os
import threading
import time
from typing import Any
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

import ccxt
import requests

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
    if '"1010"' in err_body or "'1010'" in err_body:
        return True
    el = (err_body or "").lower()
    if "1010" in err_body and (
        "error code" in el or "code: 1010" in el or "code 1010" in el
    ):
        return True
    return False


def _okx_sorted_query(params: dict) -> str:
    """GET 查询串：键按字母序，与 QTrader-web account_tester._okx_api_call 一致。"""
    items = sorted(
        (str(k), str(v)) for k, v in params.items() if v is not None
    )
    return urlencode(items) if items else ""


def _okx_error_code_hint(code: object) -> str:
    """OKX 常见业务码的简短中文说明（msg 为空时便于排查）。"""
    c = str(code).strip() if code is not None else ""
    hints = {
        "50014": "必填参数缺失或为空（例如 leverage-info 须带 mgnMode=cross|isolated）",
    }
    return hints.get(c, "")


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
    base = f"OKX 业务错误 code={code!r} msg={msg or '未知'}"
    hint = _okx_error_code_hint(code)
    return f"{base}（{hint}）" if hint else base


def okx_public_get(
    request_path: str,
    params: dict[str, str] | None = None,
    *,
    timeout: float = 20.0,
) -> tuple[dict | None, str | None]:
    """OKX 公开 GET（无需签名），如 /api/v5/market/candles。"""
    path = request_path.split("?")[0]
    if params:
        path = path + "?" + urlencode(params)
    url = "https://www.okx.com" + path
    try:
        req = Request(url, headers={"User-Agent": "hztech-okx-public/1"})
        with urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode())
            if isinstance(data, dict) and data.get("code") != "0":
                return None, _okx_business_error_detail(data)
            return data, None
    except HTTPError as e:
        err_body = ""
        try:
            raw = e.fp.read() if getattr(e, "fp", None) else b""
            err_body = raw.decode("utf-8", errors="replace")[:500]
        except Exception:
            err_body = ""
        _, show_msg = _parse_okx_http_error_body(err_body)
        return None, show_msg or f"HTTP {e.code}"
    except (URLError, json.JSONDecodeError, OSError) as e:
        logger.warning("OKX public GET error: %s -> %s", path[:120], e)
        return None, str(e) or "public request failed"


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
    """解析默认 OKX 配置路径并设为模块默认。config_dir 一般为 server/accounts。"""
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
    """从 JSON 加载 OKX 配置（与 accounts/testapi.py 一致，优先 api 子对象）。
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


_CCXT_OKX_LOCK = threading.Lock()
# 密钥文件绝对路径 -> (mtime, ccxt.okx)；mtime 变化则重建（换钥/覆盖文件）
_CCXT_OKX_CACHE: dict[str, tuple[float, Any]] = {}


def get_ccxt_okx_exchange(config_path: Path | None) -> Any | None:
    """按密钥文件路径复用单个 ccxt.okx 实例，避免每次请求 new。无效路径或配置返回 None。

    与 accounts.AccountMgr.get_okx_ccxt_exchange_for_config_path 为同一缓存。
    """
    path = _resolve_path(config_path)
    if path is None or not path.is_file():
        return None
    try:
        key = str(path.resolve())
        mtime = path.stat().st_mtime
    except OSError:
        return None
    with _CCXT_OKX_LOCK:
        ent = _CCXT_OKX_CACHE.get(key)
        if ent is not None and ent[0] == mtime:
            return ent[1]
        cfg = load_okx_config(path)
        if not cfg or not (cfg.get("key") and cfg.get("secret")):
            return None
        ex = _create_exchange(cfg)
        _CCXT_OKX_CACHE[key] = (mtime, ex)
        return ex


def invalidate_ccxt_okx_exchange_cache(config_path: Path | None = None) -> None:
    """清除 ccxt 连接缓存：config_path 为 None 时清空全部；否则只移除对应密钥文件。"""
    with _CCXT_OKX_LOCK:
        if config_path is None:
            _CCXT_OKX_CACHE.clear()
            return
        path = _resolve_path(config_path)
        if path is None:
            return
        try:
            k = str(path.resolve())
        except OSError:
            return
        _CCXT_OKX_CACHE.pop(k, None)


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
    """OKX 私有接口签名请求（与 QTrader-web accounts/account_tester._okx_api_call 对齐）。

    - GET：查询参数按键名排序后 urlencode，拼入 requestPath（含 ``?``），与官方文档示例一致；
      使用 ``requests`` 与 ``User-Agent: python-requests/...``，避免 urllib 默认 UA 被边缘策略拦截。
    - 时间戳：与 QTrader 一致使用 ``datetime.utcnow()`` 毫秒 ISO + Z。
    返回 (data, error)。error 非空表示 HTTP 或配置错误（如 403）。
    """
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
    base = (cfg.get("base_url") or "https://www.okx.com").rstrip("/")
    path_only = (request_path or "").split("?")[0]
    if not path_only.startswith("/"):
        path_only = "/" + path_only
    m = method.upper()
    query = _okx_sorted_query(params) if params else ""
    sign_path = path_only + (("?" + query) if query else "")
    # QTrader 对 GET 将排序后的查询串接在 path 后参与签名；官方文档为 path?query，body 为空
    ts = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    sign_payload = body if m != "GET" else ""
    prehash = ts + m + sign_path + sign_payload
    sign = base64.b64encode(
        hmac.new(secret.encode(), prehash.encode(), "sha256").digest()
    ).decode()
    url = base + sign_path
    headers = {
        "OK-ACCESS-KEY": key,
        "OK-ACCESS-SIGN": sign,
        "OK-ACCESS-TIMESTAMP": ts,
        "OK-ACCESS-PASSPHRASE": passphrase,
        "Content-Type": "application/json",
        "User-Agent": "python-requests/2.32.5",
    }
    if cfg.get("sandbox"):
        headers["x-simulated-trading"] = "1"
    try:
        resp = None
        last_net_err: BaseException | None = None
        for attempt in range(3):
            try:
                if m == "GET":
                    resp = requests.get(url, headers=headers, timeout=30)
                elif m == "POST":
                    resp = requests.post(
                        url,
                        headers=headers,
                        data=body.encode() if body else None,
                        timeout=30,
                    )
                else:
                    return (None, f"不支持的 HTTP 方法: {method}")
                last_net_err = None
                break
            except (requests.exceptions.SSLError, requests.exceptions.ConnectionError) as e:
                last_net_err = e
                if attempt < 2:
                    time.sleep(0.35 * (attempt + 1))
                    continue
                logger.warning(
                    "OKX request network error after retries: %s %s -> %s",
                    m,
                    sign_path,
                    e,
                )
                return (None, str(e) or "SSL/connection failed")
        if resp is None:
            return (
                None,
                str(last_net_err) if last_net_err else "request failed",
            )
        if resp.status_code >= 400:
            err_body = (resp.text or "")[:500]
            primary_code, show_msg = _parse_okx_http_error_body(err_body)
            is_1010 = resp.status_code == 403 and _okx_code_is_1010(
                primary_code, err_body
            )
            egress: str | None = None
            if is_1010:
                egress = get_public_egress_ip()
            raw_log = err_body or "(无响应体)"
            logger.warning(
                "OKX请求失败 %s %s config=%s | HTTP状态=%s OKX业务码=%r OKX原因=%r | 响应体=%s%s",
                m,
                sign_path,
                config_name,
                resp.status_code,
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
            hint = _okx_error_code_hint(primary_code)
            if hint and not (show_msg or "").strip():
                reason = f"{reason} {hint}"
            detail = (
                f"HTTP {resp.status_code} OKX业务码={primary_code!r} "
                f"原因={reason} 原始响应={raw_log!r}"
            )
            if is_1010:
                detail += f" 本机出口IP={egress or '未知'}"
            return (None, detail)
        data = resp.json()
        if _DEBUG_POSITIONS:
            code = data.get("code") if isinstance(data, dict) else "N/A"
            logger.info(
                "[持仓-OKX] OKX 响应: %s %s code=%s", m, sign_path, code
            )
        return (data, None)
    except (requests.RequestException, json.JSONDecodeError, ValueError) as e:
        logger.warning("OKX request error: %s %s -> %s", m, sign_path, e)
        return (None, str(e) or "request failed")


def _okx_safe_float(x: object) -> float:
    try:
        if x is None or x == "":
            return 0.0
        return float(x)
    except (TypeError, ValueError):
        return 0.0


def _okx_usdt_cash_from_account_details(account_row: dict) -> float | None:
    """无标准 USDT 行解析时的兜底：从 details 里找 USDT 行的 availBal/availEq/cashBal。"""
    details = account_row.get("details")
    if not isinstance(details, list):
        return None
    for row in details:
        if not isinstance(row, dict):
            continue
        if str(row.get("ccy") or "").upper() != "USDT":
            continue
        for key in ("availBal", "availEq", "cashBal"):
            raw = row.get(key)
            if raw is None or str(raw).strip() == "":
                continue
            v = _okx_safe_float(raw)
            return v
    return None


def _okx_sum_details_eq_avail_like_qtrader(account: dict) -> tuple[float, float]:
    """与 QTrader-web ``account_tester`` 一致：按各币种 ``eq`` 与 ``availEq``（缺省 ``availBal``）累加。"""
    total = 0.0
    available = 0.0
    for detail in account.get("details") or []:
        if not isinstance(detail, dict):
            continue
        equity = _okx_safe_float(detail.get("eq"))
        avail_default = detail.get("availBal", "0")
        try:
            available_amt = float(detail.get("availEq", avail_default))
        except (TypeError, ValueError):
            available_amt = _okx_safe_float(avail_default)
        if equity > 0:
            total += equity
            available += available_amt
    return total, available


def _okx_usdt_detail_metrics(usdt: dict, account: dict) -> tuple[float, float, float, float]:
    """USDT 行：eq 全仓权益、cashBal 资产余额、availEq 可用保证金、占用（frozenBal 或 eq−avail）。"""
    equity = _okx_safe_float(usdt.get("eq"))
    cash_bal = _okx_safe_float(usdt.get("cashBal"))
    avail_default = usdt.get("availBal", "0")
    try:
        avail_eq = float(usdt.get("availEq", avail_default))
    except (TypeError, ValueError):
        avail_eq = _okx_safe_float(avail_default)
    frozen = _okx_safe_float(usdt.get("frozenBal"))
    if equity <= 0:
        te = _okx_safe_float(account.get("totalEq"))
        if te > 0:
            equity = te
    if frozen > 1e-12:
        used_margin = frozen
    else:
        used_margin = max(0.0, equity - avail_eq)
    return equity, cash_bal, avail_eq, used_margin


def _okx_aggregate_balance_from_payload(data: dict) -> tuple[float, float, float, float, float]:
    """从 /api/v5/account/balance 聚合：权益、USDT 资产余额 cashBal、可用保证金 availEq、占用保证金、upl。"""
    rows = data.get("data") or []
    if not rows or not isinstance(rows[0], dict):
        return 0.0, 0.0, 0.0, 0.0, 0.0
    account = rows[0]
    upl = _okx_safe_float(account.get("upl"))

    details_list = account.get("details")
    details = details_list if isinstance(details_list, list) else []

    usdt = next(
        (
            d
            for d in details
            if isinstance(d, dict) and str(d.get("ccy") or "").upper() == "USDT"
        ),
        None,
    )

    if usdt is not None:
        equity, cash_bal, avail_eq, used_m = _okx_usdt_detail_metrics(usdt, account)
        return equity, cash_bal, avail_eq, used_m, upl

    total_d, avail_d = _okx_sum_details_eq_avail_like_qtrader(account)
    if total_d > 0:
        cash_b = 0.0
        for d in details:
            if not isinstance(d, dict):
                continue
            if str(d.get("ccy") or "").upper() == "USDT":
                cash_b = _okx_safe_float(d.get("cashBal"))
                break
        if cash_b <= 1e-12:
            cash_b = avail_d
        used_m = max(0.0, total_d - avail_d)
        return total_d, cash_b, avail_d, used_m, upl

    total_eq = _okx_safe_float(account.get("totalEq"))
    avail_eq = _okx_safe_float(account.get("availEq"))
    if avail_eq <= 0:
        fb = _okx_usdt_cash_from_account_details(account)
        if fb is not None:
            avail_eq = fb
    if avail_eq == 0 and total_eq != 0:
        avail_eq = total_eq
    cash_bal = avail_eq
    used_m = max(0.0, total_eq - avail_eq) if total_eq > 1e-12 else 0.0
    return total_eq, cash_bal, avail_eq, used_m, upl


def _okx_fetch_balance_fallback(
    config_path: Path | None,
) -> tuple[dict | None, str | None]:
    """余额：原生签名请求 /api/v5/account/balance（不经过 ccxt，避免 load_markets 解析 preopen 等标的异常）。"""
    data, err = okx_request("GET", "/api/v5/account/balance", config_path=config_path)
    if data is None:
        return None, err or "请求失败或无有效 JSON（参见同时间点 OKX request 日志）"
    if data.get("code") != "0":
        return None, _okx_business_error_detail(data)
    if not isinstance(data, dict):
        return None, "invalid balance response"
    total_eq, cash_bal, avail_eq, used_m, upl = _okx_aggregate_balance_from_payload(data)
    return _okx_balance_dict(total_eq, cash_bal, avail_eq, used_m, upl, raw=data), None


def _okx_balance_dict(
    total_eq: float,
    cash_bal: float,
    avail_eq: float,
    used_margin: float,
    upl: float,
    *,
    raw: object,
) -> dict:
    """聚合结果：cash_balance=USDT 资产余额(cashBal)；available_margin=可用保证金(availEq)；与旧版 avail 误作 cash 区分。"""
    return {
        "total_eq": total_eq,
        "avail_eq": avail_eq,
        "equity_usdt": total_eq,
        "cash_balance": cash_bal,
        "available_margin": avail_eq,
        "used_margin": used_margin,
        "upl": upl,
        "raw": raw,
    }


def okx_fetch_balance(config_path: Path | None = None) -> dict | None:
    """OKX 账户余额：``cash_balance``=USDT ``cashBal``（资产余额），``available_margin``=``availEq``（可用保证金），``used_margin``=占用。

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


def okx_fetch_account_bills_archive_usdt(
    config_path: Path | None,
    *,
    begin_ms: int,
    end_ms: int,
    max_pages: int = 400,
) -> tuple[list[dict], str | None]:
    """分页拉取 OKX `/api/v5/account/bills-archive`（近 3 个月）中 USDT 账单，用于按日还原余额走势。

    返回的 ``bal`` 为账单时刻账户层 USDT 余额，与 ``/account/balance`` 的 totalEq（含浮盈）在持仓时可能不一致；
    上层可结合最近一条真实快照的 equity/cash 比例估算权益。
    """
    if begin_ms > end_ms:
        return [], "begin_ms > end_ms"
    pages = max(1, min(800, int(max_pages)))
    out: list[dict] = []
    seen: set[str] = set()
    after: str | None = None
    for _ in range(pages):
        params: dict[str, str] = {
            "ccy": "USDT",
            "limit": "100",
            "begin": str(int(begin_ms)),
            "end": str(int(end_ms)),
        }
        if after:
            params["after"] = after
        data, err = okx_request(
            "GET",
            "/api/v5/account/bills-archive",
            config_path=config_path,
            params=params,
        )
        if data is None:
            return out, err or "bills-archive 请求失败"
        if data.get("code") != "0":
            return out, _okx_business_error_detail(data)
        rows = data.get("data")
        if not isinstance(rows, list) or not rows:
            break
        page_new = 0
        for r in rows:
            if not isinstance(r, dict):
                continue
            bid = str(r.get("billId") or "")
            if not bid or bid in seen:
                continue
            seen.add(bid)
            out.append(r)
            page_new += 1
        if page_new == 0:
            break
        last_id = rows[-1].get("billId") if isinstance(rows[-1], dict) else None
        after = str(last_id) if last_id else None
        if after is None or len(rows) < 100:
            break
        time.sleep(0.45)
    return out, None


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


def okx_normalize_swap_inst_id(symbol_or_inst: str) -> str:
    """将多种写法规范为永续 instId（与 qtraderweb K 线 symbol 解析思路一致）。

    支持：PEPE-USDT-SWAP、PEPE-USDT、PEPE/USDT、PEPE/USDT:USDT。
    """
    s = (symbol_or_inst or "").strip()
    if not s:
        return s
    up = s.upper()
    if "-SWAP" in up:
        return s
    if "/" in s and ":" in s:
        return _ccxt_symbol_to_inst_id(s)
    if "/" in s:
        return f"{s.replace('/', '-')}-SWAP"
    parts = s.split("-")
    if len(parts) == 2 and parts[0] and parts[1]:
        return f"{parts[0]}-{parts[1]}-SWAP"
    return s


def _okx_fetch_public_ohlc_rows(
    request_path: str,
    inst_id: str,
    *,
    bar: str = "1D",
    limit: int = 100,
    after_ms: int | None = None,
    before_ms: int | None = None,
) -> tuple[list[list[str]], str | None]:
    """OKX 公开 K 线类接口：candles / mark-price-candles / history-mark-price-candles 等。"""
    inst = okx_normalize_swap_inst_id(inst_id)
    if not inst:
        return [], "empty inst_id"
    lim = max(1, min(300, int(limit)))
    params: dict[str, str] = {
        "instId": inst,
        "bar": bar,
        "limit": str(lim),
    }
    if after_ms is not None:
        params["after"] = str(int(after_ms))
    if before_ms is not None:
        params["before"] = str(int(before_ms))
    data, err = okx_public_get(request_path, params)
    if err:
        return [], err
    if not isinstance(data, dict):
        return [], "invalid response"
    raw = data.get("data")
    if not isinstance(raw, list):
        return [], "empty or invalid candles"
    out: list[list[str]] = []
    for row in raw:
        if isinstance(row, list) and len(row) >= 5:
            out.append([str(x) for x in row])
    return out, None


def okx_fetch_market_candles(
    inst_id: str,
    *,
    bar: str = "1D",
    limit: int = 100,
    after_ms: int | None = None,
    before_ms: int | None = None,
) -> tuple[list[list[str]], str | None]:
    """
    公开 K 线：GET /api/v5/market/candles（不经过 ccxt）。
    返回 data 中行列表，每行 OKX 格式 [ts,o,h,l,c,vol,...] 字符串数组。
    """
    return _okx_fetch_public_ohlc_rows(
        "/api/v5/market/candles",
        inst_id,
        bar=bar,
        limit=limit,
        after_ms=after_ms,
        before_ms=before_ms,
    )


def okx_fetch_mark_price_candles(
    inst_id: str,
    *,
    bar: str = "1m",
    limit: int = 100,
    after_ms: int | None = None,
    before_ms: int | None = None,
    use_history: bool = False,
) -> tuple[list[list[str]], str | None]:
    """
    标记价格 K 线：/api/v5/market/mark-price-candles；
    历史更长区间可用 history-mark-price-candles（use_history=True）。
    """
    path = (
        "/api/v5/market/history-mark-price-candles"
        if use_history
        else "/api/v5/market/mark-price-candles"
    )
    return _okx_fetch_public_ohlc_rows(
        path,
        inst_id,
        bar=bar,
        limit=limit,
        after_ms=after_ms,
        before_ms=before_ms,
    )


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
    inst_id: str,
    *,
    limit: int = 120,
    start_day: str | None = None,
    end_day: str | None = None,
    max_pages: int = 10,
) -> tuple[list[dict[str, float | str]], str | None]:
    """
    OKX 公开 K 线：日线 OHLC（REST /api/v5/market/candles，与 qtraderweb 历史读取思路一致：
    原生接口 + 时间范围过滤），并计算当日价格波动（非负）。
    波动 = |high − low|（当日最高与最低之差的绝对值，恒 ≥ 0）。
    为兼容既有 API / App，结果中仍使用字段名 tr，由 merge 得到 tr_pct。
    inst_id 支持 PEPE-USDT-SWAP、PEPE/USDT:USDT 等（见 okx_normalize_swap_inst_id）。
    start_day / end_day：可选，UTC 日历日 YYYY-MM-DD，与 qtraderweb K 线 starttime/endtime 对应。
    返回 (bars, error)，bars 按时间升序，项含 day、open/high/low/close/tr。
    """
    lim = max(2, min(2000, int(limit)))
    start_ts: int | None = None
    end_ts: int | None = None
    if start_day:
        try:
            start_ts = int(
                datetime.strptime(start_day.strip(), "%Y-%m-%d")
                .replace(tzinfo=timezone.utc)
                .timestamp()
                * 1000
            )
        except ValueError:
            return [], f"invalid start_day: {start_day!r}"
    if end_day:
        try:
            end_dt = datetime.strptime(end_day.strip(), "%Y-%m-%d").replace(
                tzinfo=timezone.utc
            )
            end_ts = int((end_dt.timestamp() + 86400) * 1000)
        except ValueError:
            return [], f"invalid end_day: {end_day!r}"

    merged: list[tuple[int, float, float, float, float]] = []
    after_cursor: int | None = None
    pages = max(1, min(50, int(max_pages)))
    per_page = 300

    for _ in range(pages):
        if len(merged) >= lim:
            break
        page_limit = min(per_page, max(lim - len(merged) + 5, 1))
        batch, err = okx_fetch_market_candles(
            inst_id,
            bar="1D",
            limit=page_limit,
            after_ms=after_cursor,
        )
        if err:
            return [], err
        if not batch:
            break
        batch_ts_ms: list[int] = []
        for row in batch:
            try:
                ts_ms = int(float(row[0]))
                o, h, l, c = float(row[1]), float(row[2]), float(row[3]), float(row[4])
            except (TypeError, ValueError, IndexError):
                continue
            batch_ts_ms.append(ts_ms)
            if start_ts is not None and ts_ms < start_ts:
                continue
            if end_ts is not None and ts_ms >= end_ts:
                continue
            merged.append((ts_ms, o, h, l, c))
        if not batch_ts_ms:
            break
        next_after = min(batch_ts_ms)
        if after_cursor is not None and next_after >= after_cursor:
            break
        after_cursor = next_after
        if len(batch) < page_limit:
            break

    if not merged:
        return [], "empty ohlcv"

    merged.sort(key=lambda x: x[0])
    by_ts: dict[int, tuple[float, float, float, float]] = {}
    for ts_ms, o, h, l, c in merged:
        by_ts[ts_ms] = (o, h, l, c)
    dedup_sorted = sorted(by_ts.items(), key=lambda x: x[0])
    if len(dedup_sorted) > lim:
        dedup_sorted = dedup_sorted[-lim:]

    out: list[dict[str, float | str]] = []
    for ts_ms, (o, h, l, c) in dedup_sorted:
        day_range = abs(float(h) - float(l))
        day = datetime.fromtimestamp(ts_ms / 1000.0, tz=timezone.utc).strftime(
            "%Y-%m-%d"
        )
        out.append(
            {
                "day": day,
                "open": float(o),
                "high": h,
                "low": l,
                "close": c,
                "tr": float(day_range),
            }
        )
    return out, None


def _ccxt_symbol_to_inst_id(symbol: str) -> str:
    """ccxt 统一符号 (BTC/USDT:USDT) -> OKX instId (BTC-USDT-SWAP)。

    右侧结算币种与左侧计价币相同时不再重复拼接（避免 PEPE-USDT-USDT-SWAP）。
    """
    if ":" in symbol:
        left, settle_raw = symbol.split(":", 1)
        settle = settle_raw.strip()
        base_quote_hyphen = left.replace("/", "-")
        left_parts = left.split("/")
        quote_ccy = left_parts[1].strip().upper() if len(left_parts) >= 2 else ""
        if quote_ccy and settle.upper() == quote_ccy:
            return f"{base_quote_hyphen}-SWAP"
        return f"{base_quote_hyphen}-{settle}-SWAP"
    return symbol.replace("/", "-")


def okx_fetch_positions(config_path: Path | None = None) -> tuple[list[dict], str | None]:
    """调用 OKX 持仓（ccxt fetch_positions）；返回 (positions, error)。ccxt 实例按密钥文件路径复用。"""
    path = _resolve_path(config_path)
    if _DEBUG_POSITIONS and path:
        logger.info("[持仓] 开始拉取 OKX 持仓 config=%s", path.name)
    exchange = get_ccxt_okx_exchange(path)
    if exchange is None:
        return ([], "OKX 配置文件不存在或格式无效")
    try:
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


def _positions_history_row_utime_ms(row: dict) -> int:
    try:
        return int(str(row.get("uTime") or "0").strip() or 0)
    except (TypeError, ValueError, AttributeError):
        return 0


def okx_fetch_positions_history(
    config_path: Path | None = None,
    *,
    inst_type: str = "SWAP",
    limit_per_page: int = 100,
    max_pages: int = 500,
    min_u_time_ms: int | None = None,
) -> tuple[list[dict], str | None]:
    """
    历史仓位：GET /api/v5/account/positions-history（近约 3 个月，按 uTime 倒序）。
    官方字段：cTime 开仓创建时间，uTime 仓位更新时间（平仓记录上即平仓相关更新；分页 after/before 均基于 uTime）。
    分页拉取多页后合并为列表；用于定时入库去重。
    max_pages 默认 500（每页最多 100 条），直至接口返回不足一页或无数据。

    min_u_time_ms：若给定，仅保留 uTime ≥ 该值的行；首请求带 ``before=min-1`` 以只拉较新数据，
    并在分页遇到更旧数据时提前结束，减少重复拉取（与库内最大 uTime 配合做增量）。
    """
    path = _resolve_path(config_path)
    cfg = load_okx_config(path) if path else None
    if not cfg or not (cfg.get("key") and cfg.get("secret")):
        return ([], "OKX 配置文件不存在或格式无效")
    lim = max(1, min(100, int(limit_per_page)))
    pages = max(1, min(2000, int(max_pages)))
    merged: list[dict] = []
    after_ms: str | None = None
    min_lo = int(min_u_time_ms) if min_u_time_ms is not None else None

    for _ in range(pages):
        params: dict[str, str] = {"limit": str(lim)}
        if inst_type:
            params["instType"] = inst_type
        if after_ms:
            params["after"] = after_ms
        elif min_lo is not None and min_lo > 0:
            # OKX：before = 返回 uTime **newer than** 该时间戳；故用 min_lo-1 等价于 uTime ≥ min_lo
            params["before"] = str(min_lo - 1)
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
        api_batch = data.get("data") or []
        if not api_batch:
            break
        raw_uts: list[int] = []
        for r in api_batch:
            u = _positions_history_row_utime_ms(r)
            if u:
                raw_uts.append(u)
        if min_lo is not None and raw_uts and min(raw_uts) < min_lo:
            merged.extend(
                r
                for r in api_batch
                if _positions_history_row_utime_ms(r) >= min_lo
            )
            break
        to_add = api_batch
        if min_lo is not None:
            to_add = [r for r in api_batch if _positions_history_row_utime_ms(r) >= min_lo]
        merged.extend(to_add)
        if len(api_batch) < lim:
            break
        if not raw_uts:
            break
        after_ms = str(min(raw_uts))
    return (merged, None)


def okx_fetch_positions_history_contracts(
    config_path: Path | None = None,
    *,
    inst_types: tuple[str, ...] = ("SWAP", "FUTURES"),
    limit_per_page: int = 100,
    max_pages: int = 500,
    min_u_time_ms: int | None = None,
) -> tuple[list[dict], str | None]:
    """
    合并永续与交割合约的历史仓位（分别请求 positions-history），
    按 (posId, uTime) 去重。任一分支报错且无合并结果时返回错误信息。
    min_u_time_ms 传给各 instType 请求，见 okx_fetch_positions_history。
    """
    seen: set[tuple[str, str]] = set()
    out: list[dict] = []
    last_err: str | None = None
    any_ok = False
    for it in inst_types:
        it_s = (it or "").strip().upper()
        if not it_s:
            continue
        batch, err = okx_fetch_positions_history(
            config_path,
            inst_type=it_s,
            limit_per_page=limit_per_page,
            max_pages=max_pages,
            min_u_time_ms=min_u_time_ms,
        )
        if err:
            last_err = err
            continue
        any_ok = True  # 该 instType 请求成功（可无平仓记录）
        for r in batch:
            if not isinstance(r, dict):
                continue
            pid = str(r.get("posId") or "").strip()
            ut = str(r.get("uTime") or "").strip()
            if not pid or not ut:
                continue
            key = (pid, ut)
            if key in seen:
                continue
            seen.add(key)
            out.append(r)
    if not out:
        if any_ok:
            return ([], None)
        return ([], last_err or "无历史仓位数据")
    return (out, None)


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


def _parse_okx_lever_value(value: object) -> float | None:
    try:
        return float(value) if value is not None and str(value).strip() != "" else None
    except (TypeError, ValueError):
        return None


def _okx_swap_instrument_supported(inst_id: str) -> tuple[bool | None, str | None]:
    """公开接口查询 SWAP 合约是否存在且可交易。返回 (是否支持, 需写入 warnings 的说明)。"""
    want = (inst_id or "").strip()
    if not want.upper().endswith("-SWAP"):
        return False, None
    data, err = okx_public_get(
        "/api/v5/public/instruments",
        {"instType": "SWAP", "instId": want},
    )
    if err:
        return None, f"SWAP 合约可交易性检查失败: {err}"
    rows = data.get("data") if isinstance(data, dict) else None
    if not isinstance(rows, list) or not rows:
        return False, f"OKX 未返回 SWAP 合约 {want}（代码错误或已下线）"
    r0 = rows[0]
    if not isinstance(r0, dict):
        return False, "合约数据格式异常"
    state = (r0.get("state") or "").strip().lower()
    if state in ("live", "preopen"):
        return True, None
    if state in ("suspend", "expired"):
        return False, f"合约 {want} 状态为 {state}，当前不可交易"
    if not state:
        return True, None
    return False, f"合约 {want} 状态为 {state}，请确认是否可交易"


def _okx_infer_mgn_mode_cross_ok(
    inst_id: str,
    account_mgn_mode: str,
    rows: list[dict] | None,
) -> tuple[bool | None, str | None]:
    """是否全仓 cross：优先账户配置 mgnMode；为空时根据杠杆/持仓行的 mgnMode 推断。"""
    want = inst_id.strip()
    cfg = (account_mgn_mode or "").strip().lower()
    if cfg == "cross":
        return True, None
    if cfg == "isolated":
        return False, "账户保证金模式为逐仓（isolated），策略要求全仓 cross"
    if not rows:
        return None, "无法判定全仓：无杠杆/持仓数据且账户配置未返回 mgnMode"
    modes: list[str] = []
    for item in rows:
        if not isinstance(item, dict):
            continue
        if (item.get("instId") or "").strip() != want:
            continue
        mm = (item.get("mgnMode") or "").strip().lower()
        if mm:
            modes.append(mm)
    if not modes:
        return None, "无法判定全仓：接口返回数据未包含 mgnMode"
    if all(m == "cross" for m in modes):
        return True, None
    if any(m == "isolated" for m in modes):
        return False, "该合约杠杆/持仓为逐仓（isolated），策略要求全仓 cross"
    return None, f"无法判定全仓：mgnMode={modes!r}"


def _okx_get_leverage_info_rows(
    config_path: Path | None,
    inst_id: str,
    preferred_mgn_mode: str,
) -> tuple[list[dict] | None, dict | None, str | None]:
    """按官方文档调用 leverage-info：须带 instId + mgnMode（不再传 instType）。

    优先使用账户配置中的全仓/逐仓；若无则依次尝试 cross、isolated。
    返回 (data 列表, 最后一次 JSON 响应, 错误文案)。
    """
    want = inst_id.strip()
    modes: list[str] = []
    pm = (preferred_mgn_mode or "").strip().lower()
    if pm in ("cross", "isolated"):
        modes.append(pm)
    for m in ("cross", "isolated"):
        if m not in modes:
            modes.append(m)

    last_raw: dict | None = None
    last_err: str | None = None
    for mgn in modes:
        raw, err = okx_request(
            "GET",
            "/api/v5/account/leverage-info",
            config_path=config_path,
            params={"instId": want, "mgnMode": mgn},
        )
        if isinstance(raw, dict):
            last_raw = raw
        if err:
            last_err = err
            continue
        if not isinstance(raw, dict) or raw.get("code") != "0":
            last_err = (
                _okx_business_error_detail(raw)
                if isinstance(raw, dict)
                else "leverage-info 返回异常"
            )
            continue
        rows_in = raw.get("data")
        if not isinstance(rows_in, list):
            continue
        matched = [
            r
            for r in rows_in
            if isinstance(r, dict) and (r.get("instId") or "").strip() == want
        ]
        if matched:
            return matched, raw, None
        last_err = None
    return None, last_raw, last_err


def _okx_leverage_from_positions_api(
    config_path: Path | None,
    inst_id: str,
) -> tuple[list[dict], str | None]:
    """QTrader 思路：从持仓接口读取 lever/posSide（无持仓时可能无行，仅作补充）。"""
    want = inst_id.strip()
    data, err = okx_request(
        "GET",
        "/api/v5/account/positions",
        config_path=config_path,
        params={"instType": "SWAP", "instId": want},
    )
    if err:
        return ([], err)
    if data is None or data.get("code") != "0":
        if isinstance(data, dict):
            return ([], _okx_business_error_detail(data))
        return ([], "positions 接口返回异常")
    raw_list = data.get("data") or []
    out: list[dict] = []
    for d in raw_list:
        if not isinstance(d, dict):
            continue
        if (d.get("instId") or "").strip() != want:
            continue
        lv = _parse_okx_lever_value(d.get("lever"))
        if lv is None:
            continue
        ps = (d.get("posSide") or "net").strip().lower()
        out.append({
            "instId": want,
            "posSide": ps,
            "lever": str(int(lv)) if lv == int(lv) else str(lv),
            "mgnMode": (d.get("mgnMode") or "").strip(),
        })
    return (out, None)


def okx_test_account_full(
    config_path: Path | None,
    symbol_for_inst: str,
    *,
    target_leverage: float = 50.0,
) -> dict[str, Any]:
    """测连并检查交易配置（账户 config、SWAP 代码与可交易性、余额、全仓 cross、双向持仓、目标杠杆）。

    - ``success``：余额接口成功（密钥可用）。
    - ``configuration_ok``：下列检查项均为 True——SWAP 格式与合约状态、权益>0、全仓 cross、
      双向持仓、多空杠杆等于目标（任一项无法判定为 True 则整体为 False，并见 warnings）。
    """
    inst_id = okx_normalize_swap_inst_id(symbol_for_inst)
    swap_format_ok = inst_id.upper().endswith("-SWAP")

    swap_inst_ok: bool | None
    swap_inst_warn: str | None
    if swap_format_ok:
        swap_inst_ok, swap_inst_warn = _okx_swap_instrument_supported(inst_id)
    else:
        swap_inst_ok = False
        swap_inst_warn = None

    out: dict[str, Any] = {
        "success": False,
        "message": "",
        "balance_summary": None,
        "account_config": {},
        "leverage_info": None,
        "inst_id_checked": inst_id,
        "target_leverage": target_leverage,
        "configuration_ok": False,
        "configuration_warnings": [],
        "checks": {
            "swap_symbol_format": swap_format_ok,
            "swap_instrument_ok": swap_inst_ok,
            "balance_ok": None,
            "mgn_mode_cross_ok": None,
            "pos_mode_long_short": None,
            "leverage_long_ok": None,
            "leverage_short_ok": None,
        },
    }
    if swap_inst_warn:
        out["configuration_warnings"].append(swap_inst_warn)

    bal, bal_err = _okx_fetch_balance_fallback(config_path)
    if bal is None:
        out["message"] = bal_err or "OKX 余额请求失败"
        out["checks"]["balance_ok"] = False
        if not swap_format_ok:
            out["configuration_warnings"].append(
                "交易对应 symbol 未规范为永续 SWAP instId（应以 -SWAP 结尾）"
            )
        return out

    out["success"] = True
    out["balance_summary"] = bal
    out["message"] = "OKX 连接成功"
    try:
        total_eq = float(bal.get("total_eq") or 0)
    except (TypeError, ValueError):
        total_eq = 0.0
    balance_positive = total_eq > 0
    out["checks"]["balance_ok"] = balance_positive
    if not balance_positive:
        out["configuration_warnings"].append(
            "账户总权益为 0 或无法解析，请确认资金已划入交易账户"
        )

    cfg_raw, cfg_err = okx_request(
        "GET", "/api/v5/account/config", config_path=config_path
    )
    pos_mode = ""
    if cfg_err:
        out["configuration_warnings"].append(f"账户配置接口失败: {cfg_err}")
    elif isinstance(cfg_raw, dict) and cfg_raw.get("code") == "0":
        data = cfg_raw.get("data")
        if isinstance(data, list) and data and isinstance(data[0], dict):
            c0 = data[0]
            out["account_config"] = {
                "uid": c0.get("uid", ""),
                "settle_ccy": c0.get("settleCcy", ""),
                "pos_mode": c0.get("posMode", ""),
                "mgn_mode": c0.get("mgnMode", ""),
                "acct_lv": c0.get("acctLv", ""),
            }
            pos_mode = (c0.get("posMode") or "").strip()
            long_short = pos_mode == "long_short_mode"
            out["checks"]["pos_mode_long_short"] = long_short
            if not long_short:
                out["configuration_warnings"].append(
                    "持仓模式须为双向持仓（OKX posMode=long_short_mode），"
                    "请在 OKX 交易设置中切换为双向持仓"
                )
    else:
        if isinstance(cfg_raw, dict):
            out["configuration_warnings"].append(
                _okx_business_error_detail(cfg_raw)
            )
        else:
            out["configuration_warnings"].append("账户配置接口返回异常")

    if not swap_format_ok:
        out["configuration_warnings"].append(
            "Account_List 中 symbol 建议为永续 instId，例如 PEPE-USDT-SWAP"
        )

    acfg = out.get("account_config") or {}
    cfg_mgn_for_lever = str(acfg.get("mgn_mode") or "")

    lev_rows, _, lev_err = _okx_get_leverage_info_rows(
        config_path, inst_id, cfg_mgn_for_lever
    )
    pos_rows: list[dict] = []
    pos_err: str | None = None
    if not lev_rows:
        pos_rows, pos_err = _okx_leverage_from_positions_api(
            config_path, inst_id
        )

    if lev_rows:
        out["leverage_info"] = lev_rows
    elif pos_rows:
        out["leverage_info"] = pos_rows
        if lev_err:
            out["configuration_warnings"].append(
                f"已改用持仓接口读取杠杆（leverage-info 不可用: {lev_err}）"
            )
    else:
        out["leverage_info"] = None
        if lev_err:
            out["configuration_warnings"].append(f"杠杆查询失败: {lev_err}")
        elif pos_err:
            out["configuration_warnings"].append(
                f"持仓接口补充查询失败: {pos_err}"
            )
        elif not lev_err and not pos_err:
            out["configuration_warnings"].append(
                "杠杆接口未返回该合约多空杠杆（可能尚未开仓或需在 OKX 将 "
                f"{inst_id} 多空均设为 {target_leverage:g}x 双向持仓）"
            )

    rows_for_check = lev_rows if lev_rows else pos_rows
    long_lev: float | None = None
    short_lev: float | None = None
    if rows_for_check:
        want = inst_id.strip()
        for item in rows_for_check:
            if not isinstance(item, dict):
                continue
            if (item.get("instId") or "").strip() != want:
                continue
            ps = (item.get("posSide") or "net").strip().lower()
            lv = _parse_okx_lever_value(item.get("lever"))
            if lv is None:
                continue
            if ps == "long":
                long_lev = lv
            elif ps == "short":
                short_lev = lv
            elif ps == "net":
                long_lev = short_lev = lv
    tol = 0.01
    if long_lev is not None:
        ok_l = abs(long_lev - target_leverage) <= tol
        out["checks"]["leverage_long_ok"] = ok_l
        if not ok_l:
            out["configuration_warnings"].append(
                f"多仓杠杆为 {long_lev}，目标为 {target_leverage:g}x"
            )
    if short_lev is not None:
        ok_s = abs(short_lev - target_leverage) <= tol
        out["checks"]["leverage_short_ok"] = ok_s
        if not ok_s:
            out["configuration_warnings"].append(
                f"空仓杠杆为 {short_lev}，目标为 {target_leverage:g}x"
            )

    if rows_for_check and long_lev is None and short_lev is None:
        out["configuration_warnings"].append(
            "已拉取杠杆相关数据但未解析到有效 lever 字段，请确认 API 权限与合约代码"
        )

    acfg_final = out.get("account_config") or {}
    cross_ok, cross_msg = _okx_infer_mgn_mode_cross_ok(
        inst_id,
        str(acfg_final.get("mgn_mode") or ""),
        rows_for_check,
    )
    out["checks"]["mgn_mode_cross_ok"] = cross_ok
    if cross_msg:
        out["configuration_warnings"].append(cross_msg)

    chk = out["checks"]
    out["configuration_ok"] = bool(
        swap_format_ok
        and chk.get("swap_instrument_ok") is True
        and chk.get("balance_ok") is True
        and chk.get("mgn_mode_cross_ok") is True
        and chk.get("pos_mode_long_short") is True
        and chk.get("leverage_long_ok") is True
        and chk.get("leverage_short_ok") is True
    )
    return out


def _okx_leverage_str_for_api(target_leverage: float) -> str:
    try:
        x = float(target_leverage)
    except (TypeError, ValueError):
        x = 50.0
    if abs(x - round(x)) < 1e-9:
        return str(int(round(x)))
    return f"{x}".rstrip("0").rstrip(".")


def okx_apply_strategy_trading_defaults(
    config_path: Path | None,
    symbol_for_inst: str,
    *,
    target_leverage: float = 50.0,
) -> dict[str, Any]:
    """调用 OKX 私有接口，将账户对齐策略默认：永续 SWAP 标的、双向持仓、全仓 cross、多空杠杆。

    - 持仓模式：``POST /api/v5/account/set-position-mode`` → ``long_short_mode``（已处于该模式则跳过）。
    - 杠杆：``POST /api/v5/account/set-leverage``，对 ``instId`` 的 ``long`` / ``short`` 各设 ``mgnMode=cross``。

    需要 API Key 具备交易/账户类写权限；存在未平仓位或委托时，OKX 可能拒绝切换持仓模式。

    返回 ``ok``、``steps``（每步 name/ok/detail）、``errors``（汇总失败说明）；``inst_id`` 为规范化后的 SWAP 代码。
    """
    inst_id = okx_normalize_swap_inst_id(symbol_for_inst)
    lev_s = _okx_leverage_str_for_api(target_leverage)
    out: dict[str, Any] = {
        "ok": False,
        "inst_id": inst_id,
        "target_leverage": target_leverage,
        "leverage_str": lev_s,
        "steps": [],
        "errors": [],
    }

    def add_step(name: str, ok: bool, detail: str) -> None:
        out["steps"].append({"name": name, "ok": ok, "detail": detail})
        if not ok and detail:
            out["errors"].append(f"{name}: {detail}")

    if not inst_id.upper().endswith("-SWAP"):
        add_step(
            "validate_swap_inst",
            False,
            "symbol 须为永续 SWAP instId（以 -SWAP 结尾），例如 PEPE-USDT-SWAP",
        )
        return out

    cfg_raw, cfg_err = okx_request(
        "GET", "/api/v5/account/config", config_path=config_path
    )
    if cfg_err:
        add_step("get_account_config", False, cfg_err)
        return out
    if not isinstance(cfg_raw, dict) or cfg_raw.get("code") != "0":
        msg = (
            _okx_business_error_detail(cfg_raw)
            if isinstance(cfg_raw, dict)
            else "config 返回异常"
        )
        add_step("get_account_config", False, msg)
        return out

    pos_mode = ""
    data = cfg_raw.get("data")
    if isinstance(data, list) and data and isinstance(data[0], dict):
        pos_mode = (data[0].get("posMode") or "").strip()

    if pos_mode == "long_short_mode":
        add_step("set_position_mode", True, "已是双向持仓 long_short_mode，跳过")
    else:
        body = json.dumps({"posMode": "long_short_mode"})
        raw, err = okx_request(
            "POST",
            "/api/v5/account/set-position-mode",
            body=body,
            config_path=config_path,
        )
        if err:
            add_step("set_position_mode", False, err)
            return out
        if not isinstance(raw, dict) or raw.get("code") != "0":
            add_step(
                "set_position_mode",
                False,
                _okx_business_error_detail(raw)
                if isinstance(raw, dict)
                else "set-position-mode 返回异常",
            )
            return out
        add_step("set_position_mode", True, "已设为双向持仓 long_short_mode")

    for side in ("long", "short"):
        payload = {
            "instId": inst_id,
            "lever": lev_s,
            "mgnMode": "cross",
            "posSide": side,
        }
        body = json.dumps(payload)
        raw, err = okx_request(
            "POST",
            "/api/v5/account/set-leverage",
            body=body,
            config_path=config_path,
        )
        step = f"set_leverage_{side}"
        if err:
            add_step(step, False, err)
            continue
        if not isinstance(raw, dict) or raw.get("code") != "0":
            add_step(
                step,
                False,
                _okx_business_error_detail(raw)
                if isinstance(raw, dict)
                else "set-leverage 返回异常",
            )
            continue
        add_step(
            step,
            True,
            f"全仓 cross {side} 杠杆已设为 {lev_s}x（{inst_id}）",
        )

    out["ok"] = all(s.get("ok") for s in out["steps"])
    return out
