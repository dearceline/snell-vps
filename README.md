# Snell VPS 管理脚本

为中国大陆 VPS 的下载环境重新开发的单文件中文安装管理脚本。菜单启动不联网、不检测公网 IP；只在安装、更新或手动官网检查时访问网络。

## 一键运行

使用 root 账号，或下载后通过 `sudo bash snell.sh` 运行。

```bash
(wget -T 8 -t 1 -O snell.sh https://cdn.jsdelivr.net/gh/dearceline/snell-vps@main/snell.sh || wget -T 8 -t 1 -O snell.sh https://raw.githubusercontent.com/dearceline/snell-vps/main/snell.sh) && chmod +x snell.sh && ./snell.sh
```

下载入口依次尝试 jsDelivr CDN 和 GitHub 原始文件。两者的大陆可达性随地区、运营商和时间变化；这是容错方案，不承诺每台大陆 VPS 都能访问。仓库发布后会提供固定提交及脚本 SHA-256 的校验命令。

## 支持环境与版本

- Linux + glibc + 正在运行的 systemd + Bash 4 及以上。建议 Debian 11/12/13、Ubuntu 22.04/24.04、Rocky/AlmaLinux 9。发行版覆盖以实际测试记录为准。
- amd64、i386、aarch64、armv7l。Snell v6 没有收录 armv7l 安装包。
- 内置校验目录：v4.1.1、v5.0.1（默认）、v6.0.0。官方当前文档仍将 v6 标记为测试阶段，选择前请确认客户端兼容性。
- Alpine/OpenRC、musl、未运行 systemd 的容器不在本版支持范围内。

官方版本说明：[Snell 发布说明](https://kb.nssurge.com/surge-knowledge-base/release-notes/snell)。客户端配置：[Surge Snell 手册](https://manual.nssurge.com/policies/snell.html)。

## 常用命令

```bash
# 默认 v5，自动生成 32 位随机 PSK；不指定端口时从空闲高位端口选择
./snell.sh install --name default --port 12345

# 添加第二个实例，可与第一个采用不同协议版本
./snell.sh install --name node2 --version 6 --port 23456

./snell.sh list
./snell.sh info --name default       # 显示 PSK 和 Surge 配置行
./snell.sh status --name default
./snell.sh logs --name default
./snell.sh start --name default
./snell.sh stop --name default
./snell.sh restart --name default

# 更新仅作用于这个实例，默认保持协议大版本，保留配置与停止状态
./snell.sh update --name default
./snell.sh configure --name default --port 34567
./snell.sh rollback --name default
./snell.sh uninstall --name node2    # 交互确认；非交互需添加 --yes

./snell.sh versions                 # 离线查看收录版本
./snell.sh check-online             # 手动查看官网版本，不自动安装未校验新版本
./snell.sh doctor                   # 离线环境检查
./snell.sh deps                     # 安装依赖，不替换系统软件源
```

使用自定义密钥：`SNELL_PSK='至少16位字母数字或_+-' ./snell.sh install --name default --port 12345`。配置菜单支持隐藏输入新密钥。`info` 的输出和备份包含密钥，请妥善保管。

`--bind` 可选 `0.0.0.0`（新实例默认）、`127.0.0.1`、`[::]`、`[::1]`。配置已有实例时省略 `--bind` 会保留原监听地址。IPv6 是否同时接收 IPv4 由系统决定。

请在 VPS 安全组和防火墙中按需放行对应 TCP/UDP 端口。脚本不修改防火墙、BBR、TCP Fast Open 或内核参数。

## 下载与校验

安装包按顺序尝试：

1. Gitee 现有备份 `ten/Others`（大陆优先）。
2. Surge 官方源 `dl.nssurge.com`。
3. GitHub 现有备份 `xOS/Others`。

每个源有 3 秒连接超时、25 秒总时限和低速检测。下载失败、HTML 拦截页或 SHA-256 不符都会切源；只缓存已通过校验的 ZIP。下一次操作会重新校验缓存。镜像可能缺少某些版本，官方源是主要回退来源。

可用 `SNELL_SOURCE_ORDER=official ./snell.sh install --name default --port 12345` 把官方源放在首位。

脚本内嵌固定 ZIP SHA-256，另见 [checksums.json](checksums.json)。这些值由维护者通过验证证书的官方 HTTPS 下载测得，**不是官方数字签名**。不会从同一个镜像动态下载校验值，也不会关闭证书校验。只提取 ZIP 中唯一的 `snell-server` 成员，并检查 ELF 标识、实际运行能力和报告版本。

未收录的新版本一律拒绝安装，维护者需先从官方核对安装包并更新校验目录。`check-online` 仅展示官网版本，不执行远端代码、不自动切到测试版。

## 已有实例保护

本脚本独立使用以下路径：

| 内容 | 路径 |
| --- | --- |
| 各实例程序 | `/opt/snell-vps/instances/<name>/snell-server` |
| 各实例配置 | `/etc/snell-vps/instances/<name>/snell.conf` |
| 管理标记、版本 | `/var/lib/snell-vps/instances/<name>/` |
| systemd 服务 | `snell-vps-<name>.service` |
| 更新/配置/卸载备份 | `/var/backups/snell-vps/<name>/` |
| 已校验下载缓存 | `/var/cache/snell-vps/` |

- 不修改原脚本的 `/etc/snell`、`/usr/local/bin/snell-server`、`snell.service` 或 `snell-server.service`。
- 安装遇到同名目录、符号链接或已有服务会拒绝覆盖。
- 检查 TCP/UDP 监听端口，并保留停止实例的端口，避免实例冲突。
- 更新、配置、回滚、卸载都要求匹配本脚本的管理标记；旧实例不会被自动接管。
- 程序以专用非登录账号 `snell-vps` 运行，配置权限 `640`，实例目录 `750`；备份与管理状态仅 root 可访问。
- 更新前下载和验证完整程序，再备份并在同一文件系统内替换；启动失败自动恢复程序、配置和版本记录。中断或其他错误也会尝试恢复，备份始终保留。
- 卸载只删除指定实例。备份、缓存和专用系统账号会保留，以便恢复其他实例或排查问题。
- 不自动跨协议大版本更新；需要 v6 时新建一个实例，验证客户端后再自行卸载旧实例。

## 测试

```bash
bash -n snell.sh
shellcheck -S warning snell.sh tests/unit.sh tests/integration.sh
bash tests/unit.sh
bash tests/transaction.sh
python3 tests/catalog.py
# 只在可丢弃的 Linux/systemd 测试机器上运行，会创建本项目的测试实例
sudo bash tests/integration.sh
```

GitHub Actions 包含离线回归与真实官方 v4/v5/v6 程序的 systemd 安装、更新、停止状态保持、多实例隔离、失败恢复、卸载和旧目录保护测试。各次运行结果以 Actions 页面为准。未在你自己的 VPS 上执行安装；没有 VPS 凭据也无法验证你的运营商链路或 Surge 客户端端到端连接。

当前已完成与待完成项目见 [TESTING.md](TESTING.md)。

## 原脚本检查记录

参考源：<https://gitee.com/ten/Snell/raw/master/Snell.sh>，2026-11-12 获取。原脚本约 116 KB、3165 行，版本 2.1.8，支持 v2–v6、安装更新卸载、端口/PSK/混淆/DNS 等配置、systemd/OpenRC 和菜单。原脚本启动菜单前会进行版本检查；这可能引入网络等待。

此项目重新实现核心安装管理流程，未复制原脚本代码。默认使用当前收录的稳定 v5，v4 用于兼容，v6 为主动选择；没有保留 v2/v3、OpenRC、内核调优或在线自覆盖脚本功能。高级配置可自行编辑各实例配置，再重启对应服务；`configure` 保留除监听地址和 PSK 以外的选项。

管理脚本采用 MIT 许可证；Snell 二进制由 Surge 官方或已有备份源下载，其权利归原厂商，本仓库不分发二进制。
