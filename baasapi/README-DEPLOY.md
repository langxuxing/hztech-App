# 部署到 AWS

## 配置

- `baasapi/deploy-aws.json`：定义两台应用（可同机或分服务器）
  - **FlutterApp**：`flutterapp` 段（`host`、`remote_path`、密钥等），监听 **`flutterapp_port`**（默认 9000），托管 `serve_web_static`。
  - **BaasAPI**：`baasapi` 段，监听 **`baasapi_port`**（默认 9001），运行 `baasapi/main.py`。
  - 兼容旧键 `web` / `app_port` / `web_port`。
- 每段可设 **`app_name`**（展示用）：如 `"app_name": "FlutterApp"`、`"BaasAPI"`。

## Ops 一键部署（构建 + 上传 + 重启）

使用项目根目录 **`./deploy2AWS.sh`**（或 `python3 baasapi/server_mgr.py deploy ...`）。

## 一键：编译 APK + 部署服务端 + 上传 APK

```bash
# 在项目根目录执行
./baasapi/build_and_deploy.sh
```

或分步：

```bash
# 1) 仅编译 APK（需已存在 gradlew 与 gradle/wrapper/gradle-wrapper.jar）
python3 baasapi/server_mgr.py build

# 2) 仅部署服务端到 AWS（不编译；若有 static/apk/*.apk 会一并上传）
python3 baasapi/server_mgr.py deploy

# 3) 先编译 APK 再部署（推荐）
python3 baasapi/server_mgr.py deploy --build
```

## 首次没有 Gradle Wrapper 时

若项目没有 `gradlew` 或 `gradle/wrapper/gradle-wrapper.jar`：

1. 用 **Android Studio** 打开项目根目录，菜单 **File → Sync Project with Gradle Files**，会自动生成 `gradlew` 与 `gradle/wrapper/`。
2. 或在已安装 Gradle 的机器上在项目根执行：`gradle wrapper`。
3. 然后执行 `./baasapi/build_and_deploy.sh` 或 `python3 baasapi/server_mgr.py deploy --build`。

## 无法连接 FlutterApp(9000) / BaasAPI(9001) 时

当前服务端为 HTTP（Flask 直连）。连不上时按下面排查。

1. **AWS 安全组（最常见）**  
   两台 EC2 各自安全组：FlutterApp 实例放行 **`flutterapp_port`**（如 9000），BaasAPI 实例放行 **`baasapi_port`**（如 9001）。来源按团队策略（如 `0.0.0.0/0` 或固定 IP）。

2. **确认服务在跑**  
   SSH 上 EC2 后执行：
   ```bash
   pgrep -af "baasapi/main.py"
   pgrep -af "baasapi/serve_web_static.py"
   curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9000/
   curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9001/
   ```
   BaasAPI 根路径 `/` 应返回 200（JSON）；FlutterApp `/` 在已同步 `flutter build web` 时为 200，未构建时为 503。

3. **若进程没起来**  
   看日志：`cat /home/ec2-user/hztechapp/server.log`、`web_static.log`。若是 `_sqlite3` 等错误，按下一节处理。然后重新执行：  
   `cd /home/ec2-user/hztechapp && bash baasapi/install_on_aws.sh`

## 若出现 No module named '_sqlite3'

当前端使用 pyenv 安装的 Python 且未带 SQLite 支持时会报此错。两种做法任选其一：

1. **推荐**：安装 SQLite 开发包后重装当前 Python（如 Amazon Linux 2：`sudo yum install sqlite-devel`，然后 `pyenv install --force 3.14.0`）。
2. **无需改环境**：项目已依赖 `pysqlite3-binary`，`db` 会在缺少 `_sqlite3` 时自动使用它，直接 `pip install -r baasapi/requirements.txt` 后启动即可。

数据库文件路径为 `baasapi/sqlite/tradingbots.db`（首次启动时自动创建目录与表）。

## 首次在 AWS 上安装（可选）

若在 EC2 上直接克隆或拷贝了项目，可在服务器上执行一次依赖安装并启动：

```bash
cd /home/ec2-user/hztechapp && bash baasapi/install_on_aws.sh
```

会安装依赖、创建 `apk` 等目录，并后台启动 **BaasAPI**（`main.py`）与 **FlutterApp 静态**（`serve_web_static.py`）两个进程（单机示例）。

## 部署后测试

在本地（需能访问 AWS 公网 IP）执行：

```bash
./baasapi/test_server.sh
```

或指定地址：`BASE_URL=http://54.252.181.151:9001 ./baasapi/test_server.sh`

会请求 FlutterApp 根、BaasAPI 根（JSON）、`/api/strategy/status`、`/api/login` 等。

## 部署后（地址以 `deploy-aws.json` 为准）

- **FlutterApp**（浏览器静态页）：`flutterapp.host` + `flutterapp_port` 示例 `http://54.252.181.151:9000`
- **BaasAPI**（App / 前端调用的后端）：`baasapi.host` + `baasapi_port` 示例 `http://54.66.108.150:9001`
- APK 下载（当前由 BaasAPI 提供）：`http://<baasapi.host>:<baasapi_port>/download/apk/禾正量化-release.apk`
- HTTPS：在实例前加 Nginx/Caddy，并把 `scheme` 改为 `https`。
- 日志：BaasAPI `server.log`；FlutterApp `web_static.log`（路径为各段 `remote_path` 下）。控制台每行带 **`[BaasAPI]`** / **`[FlutterApp]`** 前缀；可用环境变量 **`HZTECH_SERVICE_LOG_TAG`** 覆盖默认标签（两进程分别设置）。
