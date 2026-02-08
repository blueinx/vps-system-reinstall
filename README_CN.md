# VPS Debian 重装脚本（Debian 12 / Debian 13）

主脚本：
- `vps-dd-debian.sh`

该脚本会写入 GRUB 启动项，并在下次重启进入 Debian Installer 进行无人值守重装。

## 重要风险提示

- 会清空目标磁盘数据。
- 请提前确认可用服务商控制台/VNC。
- 强烈建议先做快照或备份。

## 功能特性

- 支持 Debian 12（`bookworm`）和 Debian 13（`trixie`）
- 仅使用 Debian 官方源：`https://deb.debian.org/debian`
- 下载 installer 的 `linux`、`initrd.gz` 并使用 `SHA256SUMS` 校验
- 自动探测 IPv4 网络参数（网卡/IP/掩码/网关/DNS）
- 自动生成 `preseed.cfg` 并注入到 installer `initrd.gz`
- 写入 GRUB 菜单并设置下一次启动进入安装器

## 运行要求

- 需要 root 权限
- VPS 使用 GRUB 引导
- 能访问 `https://deb.debian.org`

## 使用方法

1. 赋予执行权限：

```bash
chmod +x vps-dd-debian.sh
```

2. 交互安装（默认 Debian 12）：

```bash
sudo ./vps-dd-debian.sh
```

3. 指定安装 Debian 13：

```bash
sudo ./vps-dd-debian.sh --debian-version 13
```

4. 非交互示例：

```bash
sudo ./vps-dd-debian.sh \
  --debian-version 13 \
  --yes \
  --password-file /root/dd-root-pass.txt \
  --disk /dev/vda \
  --reboot
```

## 参数说明

- `--debian-version <12|13>` 目标 Debian 版本
- `--yes` 跳过确认提示
- `--reboot` 准备完成后自动重启
- `--password <pass>` 直接传入 root 密码（有历史记录泄漏风险）
- `--password-file <file>` 从文件首行读取 root 密码
- `--disk <device>` 指定目标磁盘（如 `/dev/vda`）
- `--hostname <name>` 安装后主机名（默认 `debian12` / `debian13`）
- `--timezone <tz>` 安装后时区（默认 `UTC`）
- `--self-test` 运行内置自检后退出

## GitHub Raw 使用方法

仓库地址：
- `https://github.com/blueinx/vps-system-reinstall`

使用 `curl` 下载并执行：

```bash
curl -fL -o vps-dd-debian.sh \
  https://raw.githubusercontent.com/blueinx/vps-system-reinstall/main/vps-dd-debian.sh
chmod +x vps-dd-debian.sh
sudo ./vps-dd-debian.sh --debian-version 13
```

使用 `wget` 下载并执行：

```bash
wget -O vps-dd-debian.sh \
  https://raw.githubusercontent.com/blueinx/vps-system-reinstall/main/vps-dd-debian.sh
chmod +x vps-dd-debian.sh
sudo ./vps-dd-debian.sh --debian-version 12
```

完整 GitHub Raw 非交互示例：

```bash
cat >/tmp/dd-root-pass.txt <<'EOF'
YourStrongPassword
EOF

curl -fL -o /tmp/vps-dd-debian.sh \
  https://raw.githubusercontent.com/blueinx/vps-system-reinstall/main/vps-dd-debian.sh
chmod +x /tmp/vps-dd-debian.sh
sudo bash /tmp/vps-dd-debian.sh \
  --debian-version 13 \
  --yes \
  --password-file /tmp/dd-root-pass.txt \
  --disk /dev/vda \
  --reboot
```

## VPS 提示

- KVM 常见系统盘是 `/dev/vda`，建议显式传入 `--disk`。
- `/32` 网络会自动写入 `pointopoint`。
- 重装完成后建议立即更换凭据并加固 SSH。

## 故障排查

- 重启后未进入安装器：
- 在 GRUB 菜单确认是否有 `Debian 12 Reinstall (VPS)` 或 `Debian 13 Reinstall (VPS)`。
- 检查 `/etc/grub.d/09_dd_debian` 是否存在。
- 重新执行脚本并检查 GRUB 更新输出。

- 重装后无法联网：
- 通过控制台/VNC 核对 IP/网关/DNS 是否与服务商分配一致。
- 检查网卡名与路由配置是否正确。
