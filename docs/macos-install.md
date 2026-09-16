# macOS / Linux 安装排障

入口 `agentdock` 在 Git 中以可执行文件保存；从项目外运行也会定位到正确脚本。解压 ZIP 或旧版 checkout 没有执行权限时，可先用 `bash ./agentdock install`。

## 更新后重试

在仓库目录执行：

```bash
git -c core.fileMode=false pull --ff-only origin main
./agentdock install
./agentdock start
```

`core.fileMode=false` 只对本次 pull 生效，用于忽略之前手动 chmod 造成的纯权限修改。它不会丢弃内容修改；如 Git 报本地内容冲突，先保存并处理冲突，不要用 `reset --hard`。

不用删除 `.runtime/` 或重填 `config.yaml`。其中可能包含已有配置、令牌和运行状态。

## 新下载流程

macOS / Linux 下载器使用 Python 3.8+ 标准库解析 JSON、校验 SHA-256、读取 ZIP/tar，无需额外 Python 包。需要 `python3` 和 `curl` 可用：

```bash
python3 --version
curl --version
```

没有 Python 3 时会明确报错，请先安装 Python 3。下载器不再通过 `grep | cut | head` 解析 GitHub JSON，不受响应格式化或单行 JSON 的影响。

正常阶段输出：

```text
==> Preparing tunnel-client
==> tunnel-client platform: darwin/arm64
==> Querying GitHub release ...
==> Downloading ...
SHA-256 OK
Installed tunnel-client: ...
==> Checking configuration
==> Selecting deployment mode
==> Pulling AgentDock Docker image
Installed in docker mode. Default workspace: ...
```

已有可运行的 tunnel-client 会直接复用，不联网。`help/status/stop/logs` 不触发下载。

## 网络失败时

查询 GitHub API 的默认单次上限为 45 秒，建立连接为 10 秒；二进制下载单次上限为 600 秒。临时网络错误最多重试一次。超时、403/429、错误 JSON、找不到架构对应文件、校验失败都会明确报错。它不能修复被网络或公司策略阻止的 GitHub 访问。

终端需要代理时，请使用自己实际的代理地址，不要盲目复制别人端口。下载器继承 `HTTPS_PROXY` / `ALL_PROXY`，不会读取或发送配置中的 OpenAI API Key 给 GitHub。不要关闭 TLS 证书校验。

可选：临时提高下载上限（不修改配置文件）：

```bash
AGENTDOCK_DOWNLOAD_TIMEOUT=1200 ./agentdock install
```

可选：固定上游 Release（依然需要访问 GitHub；不会替换健康缓存）：

```bash
TUNNEL_CLIENT_VERSION=v0.0.14 ./agentdock install
```

强制重新下载 tunnel-client（先停止正在运行的服务）：

```bash
./agentdock stop
python3 scripts/download-release.py tunnel-client .runtime/bin/tunnel-client --force
./agentdock start
```

失败不会覆盖原有二进制；成功后才原子替换。不执行压缩包中的任意文件，只提取匹配的可执行文件，校验通过后检查 `--version`。

安装成功不等于端到端 MCP 已验证。启动后仍需在 ChatGPT 中调用一次只读工具验证连接。不要对读取 Key 的主脚本使用 `bash -x` 后把完整输出发到聊天或 issue。

## 本地回归测试（不联网、不需要真实 Key/Docker）

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
```
