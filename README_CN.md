# VPS Debian 重装脚本重构版

这是 `vps-dd-debian.sh` 的重构版，保持单文件执行方式，用 GRUB 启动 Debian netboot installer，并通过内置 preseed 完成自动安装。

目标 GitHub Raw 地址：

```text
https://raw.githubusercontent.com/blueinx/vps-system-reinstall/main/debian.sh
```

## 严重警告

脚本会清空目标磁盘。运行前必须确认：

- VPS 控制台/VNC 可用。
- 已创建快照或备份。
- 目标磁盘路径正确，例如 `/dev/vda`。
- 当前系统使用 GRUB 引导。

## 支持范围

- Debian 12 `bookworm`
- Debian 13 `trixie`
- `amd64`、`arm64`
- BIOS 或 UEFI 的 GRUB VPS
- IPv4 静态网络，或当前系统可探测到可复用的 IPv4、网关、DNS

不支持 IPv6-only、OpenVZ/LXC/Docker 容器、非 GRUB 引导、无法从 Debian 镜像下载 installer 的环境。

## 快速开始

```bash
curl -fL -o /tmp/debian.sh \
  https://raw.githubusercontent.com/blueinx/vps-system-reinstall/main/debian.sh
chmod +x /tmp/debian.sh

sudo /tmp/debian.sh --dry-run
```

确认检测结果无误后再执行：

```bash
sudo /tmp/debian.sh
```

## 推荐无人值守方式

```bash
install -m 600 /dev/null /root/dd-root-pass.txt
cat >/root/dd-root-pass.txt <<'EOF'
ReplaceWithAStrongPassword
EOF

curl -fL -o /tmp/debian.sh \
  https://raw.githubusercontent.com/blueinx/vps-system-reinstall/main/debian.sh
chmod +x /tmp/debian.sh

sudo /tmp/debian.sh \
  --debian-version 13 \
  --yes \
  --password-file /root/dd-root-pass.txt \
  --disk /dev/vda \
  --gpg-verify auto \
  --reboot
```

## 网络探测不准时

```bash
sudo /tmp/debian.sh \
  --debian-version 12 \
  --yes \
  --password-file /root/dd-root-pass.txt \
  --disk /dev/vda \
  --interface auto \
  --ip-cidr 203.0.113.10/24 \
  --gateway 203.0.113.1 \
  --dns 1.1.1.1,8.8.8.8 \
  --reboot
```

## 参数

| 参数 | 说明 |
| --- | --- |
| `--debian-version <12|13>` | 目标 Debian 版本，默认 `12`。 |
| `--yes` | 跳过危险操作确认，无人值守必须使用。 |
| `--reboot` | 准备完成后自动重启。 |
| `--password-file <file>` | 从文件首行读取 root 密码，推荐。 |
| `--password-stdin` | 从 stdin 首行读取 root 密码。 |
| `--password <pass>` | 直接传入密码，不推荐。 |
| `--disk <device>` | 目标磁盘，例如 `/dev/vda`。 |
| `--hostname <name>` | 安装后的主机名。 |
| `--timezone <tz>` | 时区，默认 `UTC`。 |
| `--interface <name|auto>` | Debian Installer 使用的网卡，默认 `auto`。 |
| `--ip-cidr <addr/prefix>` | 静态 IPv4，例如 `203.0.113.10/24`。 |
| `--gateway <addr|none>` | 网关地址，或 `none`。 |
| `--dns <addr[,addr]...>` | DNS 地址。 |
| `--mirror <https-url>` | 下载 installer 的 Debian 镜像。 |
| `--installer-mirror-protocol <http|https>` | Installer 安装软件包使用的协议，默认 `http`。 |
| `--gpg-verify <auto|required|off>` | Debian `InRelease` 签名验证策略，默认 `auto`。 |
| `--dry-run` | 只打印执行计划，不写系统。 |
| `--self-test` | 运行内置逻辑检查。 |

## 重构版加固点

- 运行前检查 Bash 版本和容器环境。
- 拒绝可移动磁盘和异常 `/dev` 路径。
- 下载 `linux` / `initrd.gz` 后做最小尺寸检查和 SHA256 校验。
- 可选验证 Debian `InRelease` 签名。
- 写入 GRUB 后确认最终 `grub.cfg` 存在目标启动项。
- 覆盖已有非自管 GRUB snippet 前自动备份。
- 显式密码源为空时直接失败。

## 安装后建议

安装完成后请立即：

- 修改 root 密码。
- 改用 SSH key 登录。
- 禁用 root 密码登录或限制来源 IP。
- 更新系统并检查 `/var/log/installer/`。
