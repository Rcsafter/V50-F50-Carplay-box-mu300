---
name: v50-box
description: 配置中兴 V50 / F50（MU300，展锐 UMS9620）刷好 OpenWrt 后的车载盒子功能。当用户提到"V50 盒子""车载盒子""mu300""dashplay""车内共享""查流量短信"或要求给这台盒子配时区/共享/HTTPS/短信时使用。
---

# v50-box

给**已经刷好 OpenWrt** 的中兴 V50 / F50（内部型号 `MU300`）配置车载娱乐功能。
刷机本身（USB、Root、装面具）不在这里做——那需要人在电脑前操作。

## 先判断状态，再动手

非 OpenWrt（没有 `/etc/openwrt_release`）→ **停下**，告诉用户"这台还是 Android，先刷机"，
把 `docs/index.html` 的刷机教程给他，不要尝试任何配置。

## 标准流程

1. **只做体检**，把报告原文贴给用户：
   ```sh
   sh install.sh --check
   ```
   不要跳过这步。体检会暴露"时区错、没有数据盘、蓝牙没起来、外网不通"等问题
   （蓝牙确实没起来就跑 `--module bluetooth`，别自己乱试 btmgmt），
   这些问题不解决，后面配了也用不了。

2. **让用户自己挑功能**，把这张表发给他，不要替他决定：

   | 模块 | 功能 | 归属 | 备注 |
   |---|---|---|---|
   | `base` | 时区/日志/备份 | 本仓库 | 建议必装 |
   | `domain` | 免费域名 + 证书 | 本仓库 | **车机能打开的前提**，见下 |
   | `share` | 车内共享 | 本仓库 | |
   | `tls` | 局域网 HTTPS | 本仓库 | 必须在 `domain` 之后 |
   | `dashplay` | 投屏，只设自启 | **抖音「一只小黑狗」** | 镜像需自带 |
   | `hover` | 车机悬浮视频窗 | 本仓库 | 依赖 DashPlay |
   | `traffic` | 开机查流量 | 本仓库 | 约 0.1 元/条 |
   | `tunnel` | 外网隧道 | 本仓库 | 需用户自己的凭据 |
   | `ai` | 助手健康检查 | 本仓库 | 镜像需自带助手 |

   然后逐个装：
   ```sh
   sh install.sh --module base
   sh install.sh --module share
   ```
   每个模块幂等，失败重跑即可，不需要先清理。
   `sh install.sh --list` 可随时列出清单。

   **不要跑不带参数的 `install.sh`**（会进交互问答，AI 环境里卡住），
   **也不要默认 `--all`**（等于替用户勾了选项）。

   `domain` 需要用户自己拿前缀和 token —— DuckDNS **没有独立账号，是借 GitHub 登录的**
   （先有 GitHub 账号，再 `sign in with GitHub`）。**不要代注册、不要代登录**：
   ```sh
   DUCKDNS_SUB=<前缀> DUCKDNS_TOKEN=<token> sh install.sh --module domain
   ```
   特斯拉车机不认 `192.168.x.x` / `100.96.x.x`，且证书签不给 IP —— 用户说"车机打不开"
   或"浏览器提示不安全"时，先检查这一步做没做。

3. 每装完一个模块，把脚本打印的校验结果转述给用户，不要只说"好了"。

## 硬性约束

- **不要碰刷机相关的东西**：分区、fastboot、`/dev/block/*`、面具。碰了会变砖。
- **不要改 DashPlay 本体**。投屏、车机页面、设置页是抖音「一只小黑狗」的作品，
  本仓库只在它上面叠加功能（`hover`）和设开关。也不要动它的启停：
  用户可能故意关着（`uci get dashplay.main.enabled`），看到 inactive 先问，别"顺手修好"。
- **短信模块要花钱**（约 0.1 元/条）。装 `traffic` 前必须明确告知并征得同意。
- **不要外传**：域名 token、隧道凭据、root 口令、acme 私钥、AI 助手 api key。
- 改 `/etc` 之前 base 模块会自动打 tar 备份，回滚用 `sh install.sh --rollback <路径>`。

## 常见"看起来是 bug 其实正常"

| 现象 | 说明 |
|---|---|
| 重启 dnsmasq 时打印 `udhcpc: no lease, failing` | init 脚本在探测接口类型，`-t 1` 超时即失败，不是断网 |
| 自签证书访问仍提示不安全 | 自签就是这样。要消除必须跑 `--module domain` 签 Let's Encrypt |
| 车机输 IP 打不开 / 弹警告 | 特斯拉不认私网 IP。用 DuckDNS 域名访问，别再用 IP |
| 域名解析很慢或超时 | 该域名的上游 AAAA 没屏蔽；`--module domain` 会加 `server=/域名/` |
| `https://<IP>:8443` 证书名不匹配 | 证书是签给域名的，用域名访问才对得上 |
| `IP:8082/cgi-bin/luci/` 恒 401 | 该前缀只反代控制台自己的 CGI，路由后台走 80 端口或域名 |
| 用户说"切不回 Android" | 「系统切换器」插件只在 **Android 侧**；OpenWrt → Android 要用系统自带的切换功能，别让用户在插件里找 |

## 关键路径

```
/opt/dashplay              投屏与设置（镜像自带）
/opt/dashplay/state/acme   Let's Encrypt 证书（镜像自带，可复用给全站）
/etc/v50-box/domain.conf   域名 + DuckDNS token（600，别打印内容）
/etc/v50-box/ddns-update.sh 每天更新 A 记录 + 保活（cron 04:17）
/etc/v50-box-tls           本仓库签下来的证书，30-tls.sh 从这里取
/mnt/mu300-disk            数据盘，共享目录在这里
/etc/init.d/share-web      本仓库装的共享服务
/root/v50-box-backup       /etc 的 tar 备份
```

## 更多

- 完整流程与刷机教程：`docs/index.html`
- 给 AI 的操作手册（含禁止项、校验点）：`AI-INSTALL.md`
