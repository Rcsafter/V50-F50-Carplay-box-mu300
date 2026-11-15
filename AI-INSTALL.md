# AI-INSTALL.md — 给 AI Agent 的安装手册

> 这份文件是给**能执行命令的 AI**（WorkBuddy / Claude Code / 其它带 SSH 或终端工具的 Agent）看的。
> 人的操作说明在 [README.md](README.md)，新手教程在 [docs/index.html](docs/index.html)。

## 0. 你的任务

把用户手上的一台中兴 V50 / F50 车载盒子（两者同一台机器，内部型号都是 `MU300`），
从「刷好 OpenWrt 的裸系统」配置到「车机能投屏、手机能看控制台、能共享电影」。
**你不负责刷机**，只做刷机之后的配置与体检。

刷机工具与镜像全部来自原作者（闲鱼「安卓猫猫」与「讨一身可爱」，两人一起整理发布，
本仓库不区分谁做了哪一件，也不要向用户做这种区分）。如果用户还没刷机、刷失败了，或者想找人代刷：
只指向 [docs/index.html](docs/index.html) 的「工具来源与致谢」一节，**不要推荐或代替任何其他来源**，
也不要替用户下单、付款或转述价格。

目标机器的典型特征（不满足就停下来问用户）：

| 检查项 | 期望值 |
|---|---|
| 系统 | OpenWrt 21.02 及以上（常见 25.12.x） |
| 架构 | `aarch64_generic` |
| 局域网地址 | `100.96.0.1` 或 `192.168.8.1`（以实际为准） |
| 包管理器 | `opkg` 或 `apk`，两者都要能识别 |
| 用户 | `root`，SSH 可登录 |

## 1. 交互规则（必须遵守）

1. **先体检，后动手。** 第一次只运行 `sh install.sh --check`，把报告原文发给用户，等他说「继续」。
2. **一次只装一个模块**，装完立刻跑该模块的「校验」，把输出贴给用户。
3. **任何一步失败就停。** 不猜测、不连续重试同一命令超过 2 次。
4. **改动前先备份**（第 3 步），备份路径要告诉用户。
5. 用户说「不知道 / 随便 / 你决定」时，选**最小改动**方案，并在报告里说明你选了什么。

## 2. 禁止事项（看到就停）

- ❌ 不要动 4G 相关：`/etc/config/network` 里 `proto` 为 `mu300cell`/`qmi`/`mbim` 的接口、APN、`/dev/ttyUSB*`。
- ❌ 不要 `opkg upgrade` / `apk upgrade` 全量升级，不要换内核，不要刷 `sysupgrade`。
- ❌ 不要改或删 `/opt/dashplay` 里的文件（投屏主程序，改坏要重刷）。
- ❌ 不要把用户的域名 token、隧道凭据、root 口令写进任何提交到仓库的文件。
- ❌ 不要 `rm -rf` 任何 `/mnt/*` 下的目录，不要格式化分区。
- ❌ 不要为了「看起来更快」而关闭防火墙、不要开放 WAN 侧管理端口。

## 3. 阶段 0 · 连上并识别

```sh
# 连接方式由用户提供，通常是：ssh root@100.96.0.1
cat /etc/openwrt_release          # 确认 OpenWrt 版本、架构
cat /proc/uptime                  # 运行时长
df -h / /mnt/* 2>/dev/null        # 剩余空间（安装只需 <5MB）
ls /opt/dashplay 2>/dev/null | head    # 有内容说明镜像是带 DashPlay 的
```

判定：
- 有 `/opt/dashplay` → 投屏能力已就绪，只需要配周边。
- 没有 → 告诉用户「这台机器的镜像不带 DashPlay，仓库只能配共享/控制台/证书」，不要尝试自行安装投屏。

## 4. 阶段 1 · 备份（必做，2 分钟）

```sh
B=/root/v50-box-backup
mkdir -p "$B"
T=$B/etc-$(date +%Y%m%d-%H%M).tgz
tar czf "$T" /etc 2>/dev/null
ls -lh "$T"
```

（`base` 模块也会自动打一份同名规则的备份，保留最近 5 份，两处路径一致，别搞混。）

把 `$T` 路径记下来，最后报告里回填。**回滚**：

```sh
sh install.sh --rollback "$T"          # 解回 / 并重启
```

## 5. 阶段 2 · 体检

```sh
sh install.sh --check
```

输出是一张表，形如：

```
[✓] 系统 OpenWrt 25.12.5 (aarch64_generic)
[✓] 内存 2.1G / 剩余 1.6G
[✓] 内置盘 /mnt/mu300-disk 剩余 21.4G
[!] 4G 未连接（不影响本地功能）
[✓] DashPlay 存在（18443 投屏端口）
[✗] 8080 共享未安装
```

规则：`[✗]` 是「可装但没装」，`[!]` 是「提醒，不影响」，`[✓]` 正常。
把表格原样发给用户，然后**让他自己挑要装哪些功能**，不要替他决定。

## 6. 阶段 3 · 分模块安装

先把这张表发给用户，让他逐项选：

| 模块 | 功能 | 谁做的 | 成本 / 依赖 |
|---|---|---|---|
| `base` | 时区、日志、主机名、`/etc` 备份 | 本仓库 | 建议必装 |
| `domain` | 免费域名 + 本地解析 + Let's Encrypt 证书 | 本仓库 | **需要一个免费 DuckDNS token；车机能否打开全靠它** |
| `share` | 车内共享，手机车机播盘里的电影 | 本仓库 | 需要 python3 |
| `tls` | 把证书接到路由后台/共享，HTTPS 不再告警 | 本仓库 | 跟在 `domain` 之后装 |
| `dashplay` | 投屏主体，这里只设开机自启 | **抖音「一只小黑狗」**（主体非本仓库） | 镜像需自带 `/opt/dashplay` |
| `bluetooth` | 蓝牙分段体检与修复（车机连不上/总掉线时） | 本仓库 | 只适用 DashPlay 这套 UART 方案 |
| `hover` | 车机画面悬浮视频窗 | 本仓库（叠加在 DashPlay 上） | 依赖 DashPlay 的注入器 |
| `traffic` | 开机自动查流量短信 | 本仓库 | **约 0.1 元/条**，6 小时去重 |
| `tunnel` | 外网隧道（cloudflared） | 本仓库 | 需要用户自己的 tunnel 凭据 |
| `ai` | 助手进程与密钥健康检查 | 本仓库 | 镜像需自带助手 |

默认建议 `base,domain,share,tls`（顺序不能变：`domain` 必须在 `tls` 前面签出证书）；
`dashplay`、`hover`、`bluetooth` 问一句要不要；`traffic`、`tunnel`、`ai` 必须先讲清成本与前提，得到明确同意再装。

```sh
sh install.sh --list                 # 列出全部功能与说明
sh install.sh --module base          # 一次一个模块，装完立刻校验
sh install.sh --module domain        # 需要 DUCKDNS_SUB / DUCKDNS_TOKEN，见 6.2
sh install.sh --module share
sh install.sh --module tls
sh install.sh --module dashplay      # 用户说要才装
sh install.sh --module hover         # 用户说要才装
sh install.sh --module bluetooth     # 车机连不上蓝牙时的分段修复
sh install.sh --module traffic       # 用户同意付费才装
```

**不要跑不带参数的 `sh install.sh`**：它会进交互问答，在 AI 的非交互终端里会卡住。
**也不要为了省事跑 `--all`**：那等于替用户勾了选项。

### 6.1 base — 基础

做的事：时区改 `Asia/Shanghai`、关掉 dnsmasq 查询日志（否则日志环被刷满）、
设主机名、可选设置 root 口令。

校验：

```sh
date                                    # 应显示 CST，与北京时间一致
uci get system.@system[0].zonename      # Asia/Shanghai
uci get dhcp.@dnsmasq[0].logqueries     # 0
```

### 6.2 domain — 免费域名（特斯拉能不能打开页面，全看这一步）

**先跟用户讲清原因**：特斯拉车机不认 `192.168.x.x` / `100.96.x.x` 这类私网地址，
而且 Let's Encrypt 不给私网 IP 签证书 —— 不用域名，车机大概率打不开，浏览器也永远提示「不安全」。

要用户提供两样东西（都免费）：

1. DuckDNS 没有独立账号，**是借 GitHub 登录的**：先让用户准备一个 GitHub 账号（用邮箱在
   `https://github.com/signup` 注册即可），再到 `https://www.duckdns.org/` 点 `sign in with GitHub` 授权。
2. 回到首页，在 `subdomain` 框里填一个没被占的前缀（例如 `v50car`），点 `add domain`。
3. 列表里那串 `token=xxxxxxxx-xxxx-xxxx-...` 复制出来（首页顶部一直显示，随时能再看）。

**不要替用户注册**，也不要让用户把 token 发到群里。拿到后这样跑：

```sh
DUCKDNS_SUB=v50car DUCKDNS_TOKEN=<token> sh install.sh --module domain
```

模块做的事（每步都会打印结果）：

| 动作 | 说明 |
|---|---|
| 写 `/etc/v50-box/domain.conf` | 权限 600，只存子域名和 token |
| 调 DuckDNS 更新 A 记录 | 指向盒子当前局域网地址；返回 `OK` 才算成功 |
| `dnsmasq` 加 `address=/域名/盒子IP` | 车内解析不依赖外部 DNS |
| `dnsmasq` 加 `server=/域名/` | 屏蔽上游 AAAA，避免手机先试 IPv6 卡顿 |
| `acme.sh --issue --dns dns_duckdns` | DNS-01 验证，不占 80 端口、不需要公网 IP |
| 生成 `/etc/v50-box/ddns-update.sh` + 每天 04:17 的 cron | 换网段自动跟上；顺便保活（DuckDNS 30 天不更新会删域名） |

校验：

```sh
nslookup <子域名>.duckdns.org              # 应返回盒子自己的地址，不是公网 IP
cat /etc/v50-box/domain.conf | grep -c TOKEN   # 有内容即可，不要打印 token 本身
ls -l /etc/v50-box-tls/fullchain.cer        # 软链存在说明签好了
openssl x509 -in /etc/v50-box-tls/fullchain.cer -noout -subject -dates
```

**没有 token 或签发失败时**：脚本会让域名解析先生效（`nslookup` 能通），但证书留空，
后面 `tls` 模块会退回自签。此时要如实告诉用户「能打开，但浏览器仍会提示不安全」，
并给出补签方式：拿到 token 后重跑 `--module domain` 再 `--module tls`。

**不要**为了签证书去开 80 端口、不要动防火墙、不要让用户把域名指向公网 IP —— DNS-01 不需要这些。

### 6.3 share — 车内共享

做的事：建目录树、部署 `/usr/bin/share_web.py`、注册 procd 服务并开机自启。

校验：

```sh
/etc/init.d/share-web status
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/     # 200
```

给用户的用法：把电影拷到 `/mnt/mu300-disk/share/视频`，手机浏览器打开
`http://<盒子IP>:8080/` 点播放，可拖动进度条。

### 6.4 tls — HTTPS

做的事：按顺序找证书 —— `/etc/v50-box-tls`（6.2 签的）→ `/opt/dashplay/state/acme/certs/*` →
`/root/.acme.sh/*` → 都没有才用 `openssl` 自签（SAN 含盒子 IP 与主机名）。
装到 uhttpd（LuCI/443），再重启共享服务让 8443 用同一张。

校验：

```sh
echo | openssl s_client -connect 127.0.0.1:443 -servername "$(uci get system.@system[0].hostname)" 2>/dev/null \
  | openssl x509 -noout -subject -dates
curl -k -s -o /dev/null -w '%{http_code}\n' https://127.0.0.1/    # 200
```

⚠️ 自签证书浏览器仍会提示「不安全」，这是正常的，要彻底消除必须用自有域名 + Let's Encrypt。
告诉用户这个区别，不要承诺「自签也能无提示」。

### 6.5 traffic — 开机查流量（可选）

做的事：装 `/usr/bin/traffic-boot-query`，挂到 `/etc/rc.local`，开机 4 分钟后发「查流量」到 10001，
6 小时内查过就跳过。

校验：

```sh
grep -c traffic-boot-query /etc/rc.local        # ≥1
TRAFFIC_DELAY=0 /usr/bin/traffic-boot-query     # 手动跑一次，看 /tmp/traffic-boot.log
tail -5 /tmp/traffic-boot.log
```

失败常见原因：SIM 未插/未激活、短信中心号不对、运营商不支持 10001 这个指令。
**不要反复发**，一次没回就先停，告诉用户手动发一条短信试试。

### 6.6 dashplay — 投屏（主体不是本仓库的）

做的事很少：确认 `/opt/dashplay` 在、按用户意愿设开机自启、校验 18443 能不能开。

**DashPlay 主体由抖音「一只小黑狗」提供**，投屏、车机页面、设置页都是他的作品。
**不要修改它的任何文件、不要改它的页面、不要"优化"它的配置。**

校验：

```sh
ls -d /opt/dashplay
uci get dashplay.main.enabled          # 1 = 自启
/usr/bin/dashplay-switch status        # 有输出即可
netstat -lnt | grep -E ':(18443|18080) '
```

特殊情况：如果体检时发现它是**故意关着的**（`enabled=0` 且进程没跑），
装之前先问用户「你自己关的吗？要打开吗」，不要顺手启动。用户说关着就保持关着。

### 6.7 bluetooth — 蓝牙（车机连不上 / 总掉线时用）

**先判断是不是这套方案**：`ls /usr/bin/mu300-bt-run /etc/init.d/mu300-bt`。
两个都不存在，说明是标准 bluez 镜像——别用本模块，改用 `/etc/init.d/bluetooth restart`。

这套镜像的蓝牙是四段拼的，任何一段没起来都表现为「车机搜不到」或「连上就掉」：

| 段 | 进程 / 文件 | 作用 |
|---|---|---|
| 1 | `mu300-bt-run` | modprobe `wcn_bsp` / `sprdbt_tty`，灌 Marlin3 固件，`btattach -B /dev/ttyBT0 -P h4` |
| 2 | `/etc/init.d/btup` | 等 `hci0` 出现后 `hciconfig up` + `bluetoothctl power on`（开机兜底） |
| 3 | `bluetoothd` | 守护进程，没有它无法配对 |
| 4 | `linux-bt-bridge/bridge.py` | 投屏跑起来时按需拉起，把真实 MAC 桥给系统（不常驻是正常的） |

跑法：

```sh
sh install.sh --module bluetooth
```

**这个模块是安全的**：蓝牙健康时它一个服务都不重启（实测跑前跑后 PID 完全不变），只在检测到某段挂了才动手，且只重启那一段。

三个必须知道的坑，不要试图用别的办法绕过：

1. **`btmgmt` 在这版固件上不可用** —— `btmgmt power on` 会报 `Operation not supported`，不是权限问题。提权只能先 `hciconfig hci0 up`，再 `bluetoothctl power on`。
2. **rfkill 顺序不能反** —— `hci0` 被 `btattach` 创建后默认 `soft=1`（被挡）。必须先写 `echo 0 > /sys/class/rfkill/rfkillN/soft`，再 `hciconfig up`；顺序反了永远起不来。
3. **BDADDR 是车机的配对依据** —— 默认 `02:00:00:96:00:01`，一般不用改。真要改得同时写 `/etc/mu300/bluetooth.conf` 和 `/var/lib/mu300/bdaddr`，改完必须在车机上删掉旧的 DashPlay 记录重新配对。

校验：

```sh
hciconfig hci0 | grep "UP RUNNING"    # 必须 grep 得到
ps w | grep -c "[b]luetoothd"         # 至少 1
```

连不上的排查顺序：车机删旧记录重搜 → `/etc/init.d/mu300-bt restart` → 重启盒子（顺便验证开机自启可靠不可靠）。

### 6.8 hover — 车机悬浮视频窗

做的事：给 `dashplay-switch` 补 `video-on/off/status`、把三个素材文件放进 `/etc/dashplay-hud`、
写 UCI `dashplay.main.video_pane`、加 cron 每 5 分钟补注入一次。

校验：

```sh
/usr/bin/dashplay-switch video-status        # 1=开 0=关
cat /opt/dashplay/dist/hud-video.json        # {"on":1}
crontab -l | grep playport-video-inject
```

失败时的判断顺序（不要瞎试）：

1. `ls /usr/bin/playport-*` —— 注入器叫别的名字，说明镜像版本不同，停下告诉用户；
2. 素材没被读 —— `/etc/dashplay-hud` 里的文件名和注入器期望的不一致，同上；
3. 车机页面已经有圆钮但用户说没看到 —— 让他刷新车机页面。

**不要自己编素材、不要直接改 DashPlay 的车机页面文件**，那是原作者的东西。

### 6.9 tunnel — 外网隧道

做的事：生成 `/etc/init.d/cloudflared`（`START=99`，启动前轮询 dnsmasq 直到能解析
`argotunnel.com`）、把配置和凭据权限收到 600、启动并校验有没有 `Registered tunnel connection`。

前提：用户**自己**已经建好 tunnel 并拿到凭据 json。没有的话脚本只会生成
`config.yml.example` 让用户填，不要替用户注册、也不要问他要 token。

```sh
ps w | grep '[c]loudflared tunnel'
logread | grep -i cloudflared | tail
```

硬性要求：

- **凭据内容不许出现在对话、日志、提交里**，只报路径和权限；
- 必须提醒用户「不要把 80 端口直接挂到隧道」，`/www/cgi-bin/cgi-exec` 能执行任意命令；
- 域名解析在 Cloudflare 后台配置，不归脚本管。

### 6.10 ai — 助手健康检查

做的事：把 `/etc/picoclaw/.security.yml` 收紧到 600、确认里面配了 api_key、启动并看进程。

**只报"配了没配"，绝对不要读取、输出、复制密钥内容。**
用户把 key 贴到对话里要立刻提醒他撤回并重置。

```sh
ls -l /etc/picoclaw/.security.yml     # -rw------- 才是对的
ps w | grep -c '[p]icoclaw'
tail -c 800 /root/.picoclaw/logs/gateway.log
```

## 7. 阶段 4 · 交付报告

装完给用户这样一份总结（照抄结构）：

```
已完成
- 基础：时区 CST-8、日志已精简
- 共享：http://100.96.0.1:8080/  （目录 /mnt/mu300-disk/share）
- HTTPS：https://100.96.0.1/    （证书：自签，浏览器会提示）
未安装
- 流量短信（需要的话说一声）
备份位置
- /mnt/mu300-disk/box-backup-20261115-0800
下一步
- 手机浏览器打开控制台 → 设口令 → 存桌面图标
```

## 8. 故障处理

| 现象 | 先查 | 处理 |
|---|---|---|
| SSH 连不上 | `ping <IP>`、端口 22 | 换网线/USB 网卡，或让用户确认盒子 LaN 地址 |
| `share-web` 起不来 | `logread \| grep share`、`lsof -i:8080` | 端口被占就改 `/etc/config/share-web` 的端口 |
| HTTPS 打不开但 HTTP 正常 | `openssl s_client` 报错 | 证书链不完整，换 `fullchain.cer` |
| 装完网页打不开 | `netstat -lntp` | 防火墙未放行时用 `uci show firewall` 检查，不要直接关防火墙 |
| 用户说变卡/断网 | `logread -l 100` | **先回滚** `etc.tgz`，再分析，不要在车上试错 |

## 9. 命令速查

```sh
sh install.sh --check                  # 只体检（只读）
sh install.sh --list                   # 列出全部可选功能
sh install.sh --module base            # 装一个模块（推荐逐个来）
sh install.sh --module tls --dry-run   # 只打印将执行的操作
sh install.sh --rollback /root/v50-box-backup/etc-20261115-0800.tgz
```

模块名：`base` `share` `tls` `traffic` `dashplay` `hover` `tunnel` `ai`
