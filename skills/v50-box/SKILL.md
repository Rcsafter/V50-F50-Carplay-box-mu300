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
   不要跳过这步。体检会暴露"时区错、没有数据盘、蓝牙没起来、外网不通"等问题，
   这些问题不解决，后面配了也用不了。

2. 用户确认后再装。默认三件套：
   ```sh
   sh install.sh --all --yes
   ```
   或按需：`--module base` / `share` / `tls` / `traffic`。
   每个模块幂等，失败重跑即可，不需要先清理。

3. 每装完一个模块，把脚本打印的校验结果转述给用户，不要只说"好了"。

## 硬性约束

- **不要碰刷机相关的东西**：分区、fastboot、`/dev/block/*`、面具。碰了会变砖。
- **不要动 dashplay 的启停**。用户可能故意关着它（`uci get dashplay.main.enabled`），
  看到 inactive 不要"顺手修好"，先问。
- **短信模块要花钱**（约 0.1 元/条）。装 `traffic` 前必须明确告知并征得同意。
- **不要外传**：域名 token、隧道凭据、root 口令、acme 私钥。
- 改 `/etc` 之前 base 模块会自动打 tar 备份，回滚用 `sh install.sh --rollback <路径>`。

## 常见"看起来是 bug 其实正常"

| 现象 | 说明 |
|---|---|
| 重启 dnsmasq 时打印 `udhcpc: no lease, failing` | init 脚本在探测接口类型，`-t 1` 超时即失败，不是断网 |
| 自签证书访问仍提示不安全 | 自签就是这样。要消除必须用域名 + Let's Encrypt |
| `https://<IP>:8443` 证书名不匹配 | 证书是签给域名的，用域名访问才对得上 |
| `IP:8082/cgi-bin/luci/` 恒 401 | 该前缀只反代控制台自己的 CGI，路由后台走 80 端口或域名 |

## 关键路径

```
/opt/dashplay              投屏与设置（镜像自带）
/opt/dashplay/state/acme   Let's Encrypt 证书（复用给全站）
/mnt/mu300-disk            数据盘，共享目录在这里
/etc/init.d/share-web      本仓库装的共享服务
/root/v50-box-backup       /etc 的 tar 备份
```

## 更多

- 完整流程与刷机教程：`docs/index.html`
- 给 AI 的操作手册（含禁止项、校验点）：`AI-INSTALL.md`
