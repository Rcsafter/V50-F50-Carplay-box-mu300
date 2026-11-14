# AI-INSTALL.md — 给 AI Agent 的安装手册

> 这份文件是给**能执行命令的 AI**（WorkBuddy / Claude Code / 其它带 SSH 或终端工具的 Agent）看的。
> 人的操作说明在 [README.md](README.md)，新手教程在 [docs/index.html](docs/index.html)。

## 0. 你的任务

把用户手上的一台中兴 V50 / F50 车载盒子（两者同一台机器，内部型号都是 `MU300`），
从「刷好 OpenWrt 的裸系统」配置到「车机能投屏、手机能看控制台、能共享电影」。
**你不负责刷机**，只做刷机之后的配置与体检。

刷机工具与镜像全部来自原作者（闲鱼「安卓猫猫」提供分区备份工具与 OP 安装器，
「讨一身可爱」提供一键 Root 与 UFI 高级后台）。如果用户还没刷机、刷失败了，或者想找人代刷：
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
B=/mnt/mu300-disk/box-backup-$(date +%Y%m%d-%H%M)
mkdir -p "$B"
tar czf "$B/etc.tgz" /etc 2>/dev/null
cp -f /etc/config/* "$B"/ 2>/dev/null
ls -lh "$B"
```

把 `$B` 路径记下来，最后报告里回填。**回滚就是把 `etc.tgz` 解回 `/`**：

```sh
tar xzf "$B/etc.tgz" -C / && reboot
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
把表格原样发给用户，并给出建议：通常装 `base,share,tls` 三个就够。

## 6. 阶段 3 · 分模块安装

统一调用方式（幂等，重复执行安全）：

```sh
sh install.sh --module base
sh install.sh --module share
sh install.sh --module tls
sh install.sh --module traffic     # 可选，要花短信费
```

### 6.1 base — 基础

做的事：时区改 `Asia/Shanghai`、关掉 dnsmasq 查询日志（否则日志环被刷满）、
设主机名、可选设置 root 口令。

校验：

```sh
date                                    # 应显示 CST，与北京时间一致
uci get system.@system[0].zonename      # Asia/Shanghai
uci get dhcp.@dnsmasq[0].logqueries     # 0
```

### 6.2 share — 车内共享

做的事：建目录树、部署 `/usr/bin/share_web.py`、注册 procd 服务并开机自启。

校验：

```sh
/etc/init.d/share-web status
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/     # 200
```

给用户的用法：把电影拷到 `/mnt/mu300-disk/share/视频`，手机浏览器打开
`http://<盒子IP>:8080/` 点播放，可拖动进度条。

### 6.3 tls — HTTPS

做的事：优先复用镜像里已签好的 Let's Encrypt 证书（`/opt/dashplay/state/acme/certs/*/fullchain.cer`），
没有就用 `openssl` 自签一张（SAN 含盒子 IP 与主机名）。装到 uhttpd（LuCI/443）并可选装到共享服务。

校验：

```sh
echo | openssl s_client -connect 127.0.0.1:443 -servername "$(uci get system.@system[0].hostname)" 2>/dev/null \
  | openssl x509 -noout -subject -dates
curl -k -s -o /dev/null -w '%{http_code}\n' https://127.0.0.1/    # 200
```

⚠️ 自签证书浏览器仍会提示「不安全」，这是正常的，要彻底消除必须用自有域名 + Let's Encrypt。
告诉用户这个区别，不要承诺「自签也能无提示」。

### 6.4 traffic — 开机查流量（可选）

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
sh install.sh --check                  # 只体检
sh install.sh --all                    # base + share + tls
sh install.sh --module tls --dry-run   # 只打印将执行的操作
sh install.sh --rollback /mnt/mu300-disk/box-backup-xxx/etc.tgz
```
