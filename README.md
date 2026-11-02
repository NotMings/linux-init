# linux-init

Debian / Ubuntu 服务器初始化脚本，默认更新软件包并配置 UFW。系统升级、Fail2ban、Docker 和 Caddy 默认关闭，两种脚本的参数相同。

```bash
# 根据系统选择脚本，自动检测 SSH 端口
sudo bash debian/init.sh
sudo bash ubuntu/init.sh

# 指定多个 SSH 端口，并安装可选组件
sudo bash ubuntu/init.sh --ssh 22 2222 --with-fail2ban --with-docker --with-caddy-cloudflare

# 按官方路径升级发行版
sudo bash ubuntu/init.sh --upgrade-system

# 查看帮助
bash ubuntu/init.sh --help
```

| 参数 | 说明 |
| --- | --- |
| `--ssh PORT [PORT ...]` | 设置 SSH 监听端口，支持空格、逗号和重复参数；省略时只自动检测 |
| `--upgrade-system` | 按发行版官方路径升级 |
| `--with-fail2ban` | 安装并配置 Fail2ban |
| `--with-docker` | 安装 Docker Engine、Buildx 和 Compose |
| `--with-caddy` | 从官网下载 Caddy 标准版 |
| `--with-caddy-MODULE` | 下载带模块的 Caddy，可重复传入；短名称对应 `github.com/caddy-dns/MODULE`，也支持完整包路径 |
| `--help` | 显示帮助 |

- UFW 放行 SSH 端口；选择安装 Caddy 时额外放行 80 和 443 端口。
- 软件包安装、升级使用非交互模式，配置文件冲突优先保留现有文件；`needrestart` 仅报告待重启服务。
- 指定 `--ssh` 时在原位置替换有效或注释的 `Port` 配置，全部不存在时才补充；修改前备份并校验，兼容 `ssh.socket`，重启后生效，同时放行当前端口。两套脚本共用 `helpers/ssh.sh`。
- 脚本结束时询问是否重启，默认不重启；非交互环境跳过询问，由调用方安排重启。重启逻辑共用 `helpers/reboot.sh`。
- Debian 12 起支持相邻大版本升级。Ubuntu 使用官方 `do-release-upgrade`：LTS 升到下一版 LTS，普通版沿正常升级路径前进；当前版本更新要求重启时，需先重启再重跑。
- 升级前备份业务数据。APT 配置备份至 `/var/backups/linux-init/`，旧软件源及第三方源会停用。
- 两套脚本共用 [config_files/caddy.service](config_files/caddy.service)。Caddy 站点配置位于 `/etc/caddy/Caddyfile`，环境变量位于 `/etc/caddy/.env`；重复执行保留配置，重新安装时需指定全部额外模块。

GitHub Actions 使用官方 amd64 云镜像验证实际安装和相邻版本升级：[Debian](.github/workflows/debian.yml) 选择仍处于官方安全支持或 LTS 期内的版本，[Ubuntu](.github/workflows/ubuntu.yml) 选择仍处于标准支持期内的版本。升级验证仅使用官方已开放的路径。
