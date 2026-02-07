# VPS Debian 12 重装脚本说明

推荐脚本名：
- `vps-dd-debian12.sh`

该脚本会写入一次性 GRUB 启动项，并在下次重启进入 Debian Installer（Bookworm）进行无人值守重装，适用于通用 VPS 场景。

## 重要风险提示

- 会清空目标磁盘数据。
- 重启前请确认你有服务商控制台/VNC 访问权限。
- 强烈建议先做快照或备份。

## 功能

- 目标系统为 Debian 12（bookworm）
- 从 Debian 官方源下载 installer 的 `linux` 与 `initrd.gz`
- 使用 `SHA256SUMS` 做完整性校验
- 自动探测当前 IPv4 网络信息（网卡/IP/掩码/网关/DNS）
- 生成并注入 `preseed.cfg` 到 `initrd.gz`
- 自动写入 GRUB 菜单并设置下一次启动进入安装器

## 运行要求

- 需要 root 权限
- VPS 使用 GRUB 引导
- 可访问 `https://deb.debian.org`

## 使用方法

1. 赋予执行权限：

```bash
chmod +x vps-dd-debian12.sh
```

2. 交互模式（推荐）：

```bash
./vps-dd-debian12.sh
```

3. 非交互示例：

```bash
./vps-dd-debian12.sh --yes --password 'YourStrongPassword' --disk /dev/vda --reboot
```

## 参数说明

- `--yes` 跳过确认
- `--reboot` 准备完成后自动重启
- `--password <pass>` 设置 Debian root 密码
- `--disk <device>` 指定目标磁盘（如 `/dev/vda`）
- `--hostname <name>` 安装后主机名（默认 `debian12`）
- `--timezone <tz>` 安装后时区（默认 `UTC`）

## GitHub Raw 使用方法

仓库地址：
- `https://github.com/blueinx/vps-system-reinstall`

建议先下载再执行：

```bash
curl -fL -o vps-dd-debian12.sh \
  https://raw.githubusercontent.com/blueinx/vps-system-reinstall/main/vps-dd-debian12.sh
chmod +x vps-dd-debian12.sh
sudo ./vps-dd-debian12.sh
```

`wget` 下载方式：

```bash
wget -O vps-dd-debian12.sh \
  https://raw.githubusercontent.com/blueinx/vps-system-reinstall/main/vps-dd-debian12.sh
chmod +x vps-dd-debian12.sh
sudo ./vps-dd-debian12.sh
```

完整 GitHub Raw 非交互示例（下载 + 执行）：

```bash
curl -fL -o /tmp/vps-dd-debian12.sh \
  https://raw.githubusercontent.com/blueinx/vps-system-reinstall/main/vps-dd-debian12.sh
chmod +x /tmp/vps-dd-debian12.sh
sudo /tmp/vps-dd-debian12.sh \
  --yes --password 'YourStrongPassword' --disk /dev/vda --reboot
```

## VPS 提示

- 常见 KVM 系统盘是 `/dev/vda`，建议明确传入 `--disk`。
- 若网络为 `/32`，脚本会自动写入 `pointopoint`。
- 安装完成后建议立即修改 root 密码并加固 SSH。

## 故障排查

- 重启后未进入安装器：
- 在控制台/VNC 查看 GRUB 菜单是否有 `Debian 12 Reinstall (VPS)`。
- 检查 `/etc/grub.d/09_dd_debian12` 是否存在。
- 重新执行脚本并查看 GRUB 更新输出。

- 重装后无法联网：
- 通过控制台/VNC 进入系统检查网卡配置和路由。
- 核对 IP/网关/DNS 是否与服务商分配一致。
