# AWS 双机运维（BaasAPI + Flutter 静态）

配置来源：**`baasapi/deploy-aws.json`**（与 `server_mgr.target_config` 一致）。

## 一键脚本

```bash
chmod +x ops/aws_ops.sh ops/read_deploy_config.py

# 监控（HTTP）：默认两台都测
./ops/aws_ops.sh status
./ops/aws_ops.sh status api
./ops/aws_ops.sh status web

# 远程启停（SSH）
./ops/aws_ops.sh stop|start|restart api|web|all
```

| 目标 | 含义 |
|------|------|
| `api` | `baasapi` 段主机，`python3 baasapi/main.py`，端口见 `baasapi_port` |
| `web` | `flutterapp` 段主机，`serve_web_static.py`，端口见 `flutterapp_port` |
| `all` | 先 API 再 Web（与 `server_mgr` 双机顺序一致） |

`restart all` 结束后会再跑一次 `status all`。

## 辅助

```bash
# 登录某台机（可跟远程命令）
./ops/aws_ops.sh ssh api
./ops/aws_ops.sh ssh web 'tail -n 40 web_static.log'

# 只看 JSON 配置
python3 ops/read_deploy_config.py --json --role baasapi
python3 ops/read_deploy_config.py --json --role flutterapp
```

## 注意

- **停进程**：按 **TCP 端口** `fuser -k`，勿在单行 SSH 里用 `pkill -f baasapi/main.py`（可能匹配到 `bash -c` 自身，SSH 255）。
- **代码同步 / 远端 pip**：仍用 `python3 baasapi/server_mgr.py deploy` 或 `restart`。
- **账户列表解析**：运行时依赖 `baasapi/accounts/account_key_util.py`（会随 `deploy` 同步）；`test_account_key.py` 仅为本机/服务器上手测 OKX 连接的 CLI，可按需部署。
