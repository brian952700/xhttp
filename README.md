# xy：VLESS + xHTTP + TLS 管理脚本

保留原脚本的安装/更新、添加用户、删除用户、查看用户及链接、彻底卸载、退出六项菜单。首次运行且不存在配置时自动进入安装流程。

主要适配目标是 Debian 13（trixie）、systemd、普通 Linux VPS。也保留 apt、dnf/yum 分支，但其他发行版未实机验证。不能在 Windows、未运行 systemd 的容器或 OpenWrt 上直接安装。

## 一键安装

在 Debian 13 的 SSH 终端中复制执行：

```bash
bash -o pipefail -c 'curl -fsSL https://raw.githubusercontent.com/brian952700/xhttp/main/install.sh | bash'
```

支持 root 用户直接运行；普通用户需要 sudo 权限，安装时会提示输入密码。安装入口会下载并检查 `xy.sh`，安装到 `/usr/local/bin/xy`，然后自动打开交互菜单。

若最小化安装的 Debian 尚未安装 curl，请先以 root 执行 `apt-get update && apt-get install -y ca-certificates curl`。

安装后打开管理菜单：

```bash
sudo xy
```

root 用户直接输入 `xy` 即可。再次执行一键安装命令会更新管理脚本并打开菜单，不会清空用户；如需安装/更新 Xray 环境，在菜单选择 1。

[查看安装入口 install.sh](https://github.com/brian952700/xhttp/blob/main/install.sh) · [查看主脚本 xy.sh](https://github.com/brian952700/xhttp/blob/main/xy.sh)

### 手动安装（可选）

也可以将 `xy.sh` 上传到服务器，在文件所在目录执行：

```bash
bash -n xy.sh
sudo install -o root -g root -m 0755 xy.sh /usr/local/bin/xy
sudo /usr/local/bin/xy
```

如果已经是 root，可省略 `sudo`。文件是 UTF-8、LF 换行；不要用 `sh xy.sh`。主脚本 `xy.sh` 需要交互输入，不能直接通过管道执行；上面的一键安装入口 `install.sh` 已单独将菜单连接到终端。

首次安装填写域名、监听端口和 xHTTP 路径，默认端口 443，默认路径 `/`。初始用户仍为 `admin`，UUID 从 Linux 内核随机 UUID 接口获取。安装后将输出的 `vless://` 链接导入支持 VLESS、xHTTP、TLS 的客户端。

域名 A/AAAA 记录需正确指向服务器；有 AAAA 记录时，IPv6 也必须可达。安全组和防火墙需允许公网 TCP 80（证书申请及续期）以及选定的节点 TCP 端口。脚本不会自动修改防火墙。80 端口不能用作节点监听端口，因为 standalone 证书验证需要它。服务器还需能够访问 Debian 软件源、GitHub 和证书签发服务。

## 旧脚本升级

覆盖 `/usr/local/bin/xy` 后打开菜单，选择 1。已有的域名、端口、路径、用户和 UUID 都保留；选择 1 不再重置全部用户。

兼容原来的 `/usr/local/etc/xray/config.json`、`/etc/xray-cert/server.crt`、`server.key` 和 `domain.txt`。如果 root 的 `/root/.acme.sh` 中已有当前域名的证书，会复用它并迁移该域名的证书安装路径与重载回调。其他结构的自定义、多入口或 DynamicUser 服务会停止处理，避免错误覆盖。

首次安装使用独立 ACME 目录 `/etc/xray-cert/acme`，通过 `/etc/cron.d/xy-acme` 每日检查续期。旧安装复用其原有 ACME 定时任务。证书尚未到期时不会强制重新签发。保留 acme.sh 自动升级行为。

## 修复内容

- 使用 `xray run -test -config` 校验配置。
- 使用 `jq --arg` 处理用户名、UUID、路径，避免把输入拼成 jq 程序或 sed 替换表达式。
- 配置先生成候选文件，检查通过后替换；服务启动失败时恢复原配置/证书并尝试恢复先前服务状态。
- 续期先写暂存证书；验证有效期、域名和公私钥匹配，并用实际 Xray 服务身份检查配置读取权限。
- 证书目录由 root 持有；读取组按 systemd 实际服务身份确定，不再假定 `nobody:nogroup`。
- 用私有临时文件和操作锁，防止两次管理操作同时覆盖配置。
- 不吞掉配置检查错误；只有检查和服务状态检查均成功才报告部署完成。
- 保留至少一个用户；连接链接的路径、SNI、用户名备注进行 URL 编码。
- 卸载删除 Xray 配置和本脚本的专用证书环境，保留共享的 `/root/.acme.sh`。对复用的旧 ACME 环境只停止当前域名续期，证书存档保留在共享目录中。

## 日志与验证

安装后可运行：

```bash
sudo xray run -test -config /usr/local/etc/xray/config.json
sudo systemctl status xray --no-pager
sudo journalctl -u xray -n 50 --no-pager
```

续期回调日志在 `/var/log/xray_cron_error.log`；专用 ACME 任务日志在 `/var/log/xy-acme.log`。首次安装或升级选择 1 后，可添加一个临时用户，用客户端验证实际连接，再删除该用户验证管理流程。

历史验证记录：2026-09-13 已通过 GitHub Actions 安装与集成验证（第 2 次尝试）。该记录来自迁移前的仓库，不代表本仓库当前版本的验证结果。测试版本为 `6fda876`，环境为 Debian 13 amd64 容器、真实 systemd PID 1，实际下载并运行 Xray 26.3.27。

验证覆盖：

- Bash 语法和 ShellCheck 错误级检查；公开安装链接下载内容与提交一致。
- 在交互终端执行本页的一键安装命令，验证 root 安装及普通用户通过 sudo 打开菜单。
- 真实 Xray 服务启动、开机启用、独立续期 cron 创建。
- 特殊字符用户名添加/删除、至少保留一个用户、更新保留已有设置和 UUID。
- 通过真实 Xray 客户端与服务端完成本地 VLESS + xHTTP + TLS 代理传输。
- 拒绝非法配置；端口冲突导致启动失败时，恢复原配置和服务。测试发现并修复了 systemd 启动限流导致回滚无法启动的问题。
- 续期回调部署新证书、拒绝不匹配的公私钥，并再次验证代理传输。
- 卸载清理脚本、配置、证书与专用 cron，同时保留共享 ACME 目录。

证书测试使用自签名证书和 ACME 测试替身，**未验证公网 ACME 签发、真实定时续期、域名解析或 VPS 防火墙**。首次正式部署仍需使用自己的域名完成证书申请和外部客户端连接验证。CI 中普通用户使用免密 sudo；未覆盖交互输入 sudo 密码。

后续修改脚本或测试文件会自动触发验证，也可在 [Actions 页面](https://github.com/brian952700/xhttp/actions/workflows/debian13.yml) 手动运行。刚推送后 GitHub Raw 缓存可能短暂返回旧脚本，此时版本一致性检查会失败；待缓存更新后重新运行，检查仍会严格核对下载内容。

回滚范围是本脚本部署的配置和证书，不包括 apt/dnf 软件包、Xray 核心二进制或 acme.sh 升级。服务重启会短暂中断连接；检查通过不等于零中断。多文件替换无法保证突然断电或 SIGKILL 时完整回滚；若自动恢复失败，脚本会显示并保留备份目录。健康检查验证启动后服务仍在运行，不替代客户端端到端验证。

脚本继续使用上游最新版安装器和 acme.sh，因此后续上游变化需要重新验证。

## 核对依据

- Xray 的测试参数属于 run 子命令：[Xray run.go](https://github.com/XTLS/Xray-core/blob/main/main/run.go)。
- Xray 官方服务用户、安装/卸载方式：[Xray-install](https://github.com/XTLS/Xray-install)。
- acme.sh 支持自定义 home、独立部署证书、续期后执行 reloadcmd：[安装文档](https://github.com/acmesh-official/acme.sh/wiki/How-to-install)、[项目说明](https://github.com/acmesh-official/acme.sh)。
- Debian 13 软件包：[cron](https://packages.debian.org/trixie/cron)、[util-linux](https://packages.debian.org/trixie/util-linux)。
