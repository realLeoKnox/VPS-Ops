# VPS Ops Toolkit (`ops.sh`)

单文件 Linux VPS 运维工具箱（v1.1.0），将常用初始化、清理、网络测速与代理/DDNS 管理整合到一个交互式脚本中，支持交互菜单、子命令直达和 `curl ... | bash` 管道执行。

## 功能列表

| 编号 | 子命令 | 说明 |
| ---: | :--- | :--- |
| 1 | `hostname` | 修改主机名（RFC 校验、同步 `/etc/hosts` 中 `127.0.1.1` 及 `127.0.0.1` 旧名、兼容 `cloud-init`） |
| 2 | `slim` | 系统瘦身拳（`journald` 限额、`apt/dnf/yum/apk` 清理、轮转日志、`-mtime + -atime` 安全清 `/tmp`、Docker 清理与一键日志轮转配置） |
| 3 | `bbr` | 开启并持久化 TCP BBR + `fq`（自动检测容器虚拟化与内核支持） |
| 4 | `swap` | Swap 交互式管理（自定义大小如 `512M`/`2G`、Btrfs 自动 `chattr +C`、磁盘与 OOM 预检、调整 `vm.swappiness`、删除） |
| 5 | `speedtest` | Ookla SpeedTest CLI（默认**临时下载测完即删，无需 root**；也支持永久安装到 `/usr/local/bin/speedtest` 或卸载，自动识别架构） |
| 6 | `gost` | GOST 实例管理器（可自定义版本默认 `3.3.0`、SHA256 校验、默认低权限 `gost` 用户运行、PID 级监听校验、防火墙提醒、可选本机实测、备份/回滚/卸载） |
| 7 | `mirror` | 调用 LinuxMirrors 一键换源（含连接超时保护） |
| 8 | `ddns` | Cloudflare DDNS（`curl -K -` 隐藏 Token、**API 自动拉取域名列表选择**、**当前主机名作默认子域前缀 + 智能补全**、本地缓存防盲打 API、`proxied` 变更检测、`--force` 强制同步、systemd timer） |
| 9 | `proxy` | 终端代理引导式配置 v3.1（凭据独立 `chmod 600` 落盘、识别 `sudo` 原用户、动态脱敏 `proxy_status`、准确测代理 v4/v6 出口、一键清理） |
| 10 | `docker` | 官方脚本安装 Docker、启用服务，并可选一键配置 `/etc/docker/daemon.json` 全局日志轮转 |
| 11 | `nodequality` | 运行 NodeQuality 综合测试（含连接超时保护） |
| 12 | `status` | 系统信息与状态速查（OS/内核/BBR/内存/Swap/磁盘/相关服务/可选公网 IP 查询） |
| 13 | `install-self` | 安装脚本到 `/usr/local/bin/ops`，之后任意目录输入 `ops` 即可使用 |

## 快速使用

### 一键远程运行（无需克隆）

```bash
# 打开交互式运维菜单
curl -fsSL https://raw.githubusercontent.com/realLeoKnox/VPS-Ops/main/ops.sh | sudo bash

# 直接执行单个子命令（示例：瘦身拳 / 临时测速）
curl -fsSL https://raw.githubusercontent.com/realLeoKnox/VPS-Ops/main/ops.sh | sudo bash -s -- slim
curl -fsSL https://raw.githubusercontent.com/realLeoKnox/VPS-Ops/main/ops.sh | bash -s -- speedtest

# 一键安装为全局命令 ops（后续直接输入 ops 即可）
curl -fsSL https://raw.githubusercontent.com/realLeoKnox/VPS-Ops/main/ops.sh | sudo bash -s -- install-self
```

### 本地克隆 / 安装后使用

```bash
git clone https://github.com/realLeoKnox/VPS-Ops.git
cd VPS-Ops
chmod +x ops.sh

# 进入交互式菜单
sudo ./ops.sh

# 或直接调用子命令
sudo ./ops.sh hostname
sudo ./ops.sh swap
sudo ./ops.sh bbr
./ops.sh speedtest   # 临时测速模式无需 root，测完自动删除
./ops.sh proxy
./ops.sh status

# 安装或从 GitHub 更新全局命令 ops
sudo ./ops.sh install-self
sudo ops update
```

## 本地测试

```bash
bash tests/test_ops.sh
```
