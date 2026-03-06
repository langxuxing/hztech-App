# 部署到 AWS

## 配置

- `server/deploy-aws.json`：主机 54.66.108.150、端口 22、密钥 `res/aws-sydney/hztech.pem`、远程目录 `/home/ec2-user/mobileapp`。

## Ops 一键部署（构建 + 上传 + 重启）

三步合一：构建 Flutter APK → 同步 webserver/APK 到 AWS → 重启后台服务。

```bash
# 在项目根目录执行
./server/ops_deploy.sh
```

## 一键：编译 APK + 部署服务端 + 上传 APK

```bash
# 在项目根目录执行
./server/build_and_deploy.sh
```

或分步：

```bash
# 1) 仅编译 APK（需已存在 gradlew 与 gradle/wrapper/gradle-wrapper.jar）
python3 server/server_mgr.py build

# 2) 仅部署服务端到 AWS（不编译；若有 static/apk/*.apk 会一并上传）
python3 server/server_mgr.py deploy

# 3) 先编译 APK 再部署（推荐）
python3 server/server_mgr.py deploy --build
```

## 首次没有 Gradle Wrapper 时

若项目没有 `gradlew` 或 `gradle/wrapper/gradle-wrapper.jar`：

1. 用 **Android Studio** 打开项目根目录，菜单 **File → Sync Project with Gradle Files**，会自动生成 `gradlew` 与 `gradle/wrapper/`。
2. 或在已安装 Gradle 的机器上在项目根执行：`gradle wrapper`。
3. 然后执行 `./server/build_and_deploy.sh` 或 `python3 server/server_mgr.py deploy --build`。

## 无法连接 Web(9000) / API(9001) 时

当前服务端为 HTTP（Flask 直连）。连不上时按下面排查。

1. **AWS 安全组（最常见）**  
   EC2 控制台 → 该实例 → 安全组 → 入站规则：需有 **TCP 端口 9000（Web）** 和 **TCP 端口 9001（API）**，来源 `0.0.0.0/0`（或你的 IP）。若只有 22，外网访问 9000/9001 会被拦掉。

2. **确认服务在跑**  
   SSH 上 EC2 后执行：
   ```bash
   pgrep -f "server/app.py"
   curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9000/
   curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9001/
   ```
   若有 2 个 PID 且两个 curl 都返回 200，说明本机正常，问题在安全组或网络。

3. **若进程没起来**  
   看日志：`cat /home/ec2-user/mobileapp/server_web.log`、`server_api.log`。若是 `_sqlite3` 等错误，按下一节处理。然后重新执行：  
   `cd /home/ec2-user/mobileapp && bash server/install_on_aws.sh`

## 若出现 No module named '_sqlite3'

当前端使用 pyenv 安装的 Python 且未带 SQLite 支持时会报此错。两种做法任选其一：

1. **推荐**：安装 SQLite 开发包后重装当前 Python（如 Amazon Linux 2：`sudo yum install sqlite-devel`，然后 `pyenv install --force 3.14.0`）。
2. **无需改环境**：项目已依赖 `pysqlite3-binary`，`db` 会在缺少 `_sqlite3` 时自动使用它，直接 `pip install -r server/requirements.txt` 后启动即可。

## 首次在 AWS 上安装（可选）

若在 EC2 上直接克隆或拷贝了项目，可在服务器上执行一次依赖安装并启动：

```bash
cd /home/ec2-user/mobileapp && bash server/install_on_aws.sh
```

会安装 `server/requirements.txt`、创建 `apk`/`res` 目录并后台启动 Flask 服务。

## 部署后测试

在本地（需能访问 AWS 公网 IP）执行：

```bash
./server/test_server.sh
```

或指定地址：`BASE_URL=http://54.66.108.150:9001 ./server/test_server.sh`

会请求首页、`/api/strategy/status`、`/api/login` 及登录后的 `/api/account-profit`。

## 部署后

- Web（浏览器）：`http://54.66.108.150:9000`
- API（App 后端）：`http://54.66.108.150:9001`
- APK 下载：Web 首页或 `http://54.66.108.150:9000/download/apk/禾正量化-release.apk`
- 若需 HTTPS：在 EC2 前加 Nginx/Caddy 做 SSL 终结，再在 `deploy-aws.json` 中把 `scheme` 改为 `https`。
- 日志：`python3 server/server_mgr.py shell` 登录后 `cat /home/ec2-user/mobileapp/server_web.log` 或 `server_api.log`
