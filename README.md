# linux-init

Debian 服务器初始化脚本，默认更新软件包并配置 UFW。系统升级、Fail2ban、Docker 和 Caddy 默认关闭。

```bash
# 基础初始化，自动检测 SSH 端口
sudo bash debian/init.sh

# 指定多个 SSH 端口，并安装可选组件
sudo bash debian/init.sh --ssh 22 2222 --with-fail2ban --with-docker --witch-caddy-cloudflare

# 升级到最新 Debian 稳定版
sudo bash debian/init.sh --upgrade-system

# 查看帮助
bash debian/init.sh --help
```

| 参数 | 说明 |
| --- | --- |
| `--ssh PORT [PORT ...]` | 指定 SSH 端口，支持空格、逗号和重复参数；省略时自动检测，不修改 SSH 服务配置 |
| `--upgrade-system` | 升级到最新稳定版，仅支持 Debian 12 起的相邻大版本升级，如 12 → 13 |
| `--with-fail2ban` | 安装并配置 Fail2ban |
| `--with-docker` | 安装 Docker Engine、Buildx 和 Compose |
| `--with-caddy` | 从官网下载 Caddy 标准版 |
| `--witch-caddy-MODULE` | 下载带模块的 Caddy，可重复传入；短名称对应 `github.com/caddy-dns/MODULE`，也支持完整包路径 |
| `--help` | 显示帮助 |

- UFW 放行 SSH、80 和 443 端口。
- 升级前备份业务数据。APT 配置备份至 `/var/backups/linux-init/`，旧软件源及第三方源会停用，完成后需手动重启。
- Caddy 配置位于 `/etc/caddy/Caddyfile`，环境变量位于 `/etc/caddy/.env`；重复执行保留配置，重新安装时需指定全部额外模块。

[GitHub Actions](.github/workflows/debian.yml) 使用仍处于 Debian 官方安全支持或 LTS 期内的 amd64 虚拟机，验证实际安装和相邻版本升级。
