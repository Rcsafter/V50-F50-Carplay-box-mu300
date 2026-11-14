#!/bin/sh
# 00-check.sh —— 体检（只读）。不写任何配置，不重启任何服务。
set -u
BASE=$(cd "$(dirname "$0")/.." && pwd)
. "$BASE/lib/common.sh"

echo
printf '\033[1m%s\033[0m\n' "V50 车载盒子 · 体检报告"
printf '%s\n' "时间 $(date '+%F %T')　主机 $(cat /proc/sys/kernel/hostname 2>/dev/null)"

step "系统"
if [ -f /etc/openwrt_release ]; then
	. /etc/openwrt_release
	ok "OpenWrt $DISTRIB_RELEASE ($DISTRIB_ARCH)  $DISTRIB_REVISION"
else
	bad "未检测到 OpenWrt"
fi
up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
[ -n "${up:-}" ] && info "已运行 $((up / 3600)) 小时 $(((up % 3600) / 60)) 分"
tz=$(uci -q get system.@system[0].zonename 2>/dev/null)
if [ "$tz" = "Asia/Shanghai" ]; then
	ok "时区 $tz"
else
	warn "时区是 ${tz:-未设置}，建议改成 Asia/Shanghai（模块 base）"
fi

step "资源"
if [ -r /proc/meminfo ]; then
	mem=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%d / %d MB", (t-a)/1024, t/1024}' /proc/meminfo)
	ok "内存占用 $mem"
fi
d=$(disk_root)
line=$(df -h "$d" 2>/dev/null | tail -1)
avail=$(echo "$line" | awk '{print $4}')
cap=$(echo "$line" | awk '{print $5}')
if [ -n "$avail" ]; then
	ok "数据盘 $d 剩余 $avail（已用 $cap）"
else
	warn "读不到 $d 的剩余空间"
fi

step "网络"
lan=$(lan_ip)
if [ -n "$lan" ]; then ok "局域网地址 $lan"; else bad "找不到 br-lan 地址"; fi
if ubus call network.interface.wan status >/tmp/.v50wan 2>/dev/null; then
	if grep -q '"up": true' /tmp/.v50wan; then
		ip4=$(sed -n 's/.*"address": "\([0-9.]*\)".*/\1/p' /tmp/.v50wan | head -1)
		ok "4G/WAN 已连接 ${ip4:-}"
	else
		warn "WAN 未连接（不影响本地投屏/共享）"
	fi
	rm -f /tmp/.v50wan
else
	warn "读不到 WAN 状态（可能不是 OpenWrt 网络栈）"
fi
if ping -c1 -W2 223.5.5.5 >/dev/null 2>&1; then ok "外网可达"; else warn "外网不通（4G 未连接或没有 SIM）"; fi

step "服务"
if [ -d /opt/dashplay ]; then
	ok "DashPlay 已安装（投屏 / 设置）"
	[ "$(uci -q get dashplay.main.enabled)" = "1" ] && ok "DashPlay 开机自启" || warn "DashPlay 当前未启用（uci dashplay.main.enabled=0）"
else
	warn "没有 /opt/dashplay —— 这个镜像不带投屏，本仓库只配周边功能"
fi

p() { # p <端口> <名字>
	if port_up "$1"; then ok "$2　端口 $1 在听"; else bad "$2　端口 $1 没起来"; fi
}
p 80    "LuCI 路由后台"
p 443   "LuCI HTTPS"
p 8082  "手机控制台"
p 8080  "车内共享"
p 8443  "车内共享 HTTPS"
[ -d /opt/dashplay ] && p 18443 "投屏页面"

step "蓝牙"
# 车机 CarPlay / 蓝牙音频都依赖它。镜像自带的蓝牙经常是关的或没初始化。
if [ -d /sys/class/bluetooth ] && [ -n "$(ls -A /sys/class/bluetooth 2>/dev/null)" ]; then
	hci=$(ls /sys/class/bluetooth 2>/dev/null | head -1)
	ok "控制器 $hci 存在"
	st=$(hciconfig "$hci" 2>/dev/null | head -3)
	case "$st" in
		*RUNNING*) ok "状态 UP RUNNING（正常）" ;;
		*UP*)      warn "UP 但没 RUNNING，可能缺固件/未初始化：/etc/init.d/bluetooth restart" ;;
		*)         warn "存在但没 UP：hciconfig $hci up 再试" ;;
	esac
else
	warn "没有蓝牙控制器（/sys/class/bluetooth 为空）"
fi
bd=$(uci -q get bluetooth.@[0].disabled 2>/dev/null)
[ "$bd" = "1" ] && warn "uci 里 bluetooth 被禁用（disabled=1）"
have btmgmt && info "$(btmgmt info 2>/dev/null | head -2 | tr '\n' ' ')"

step "证书"
acme=$(ls /opt/dashplay/state/acme/certs/*/fullchain.cer 2>/dev/null | head -1)
if [ -n "$acme" ]; then ok "找到 Let's Encrypt 证书：$acme"; else warn "没有 ACME 证书，只能自签（模块 tls 会处理）"; fi
if [ -e /etc/uhttpd.crt ]; then
	subj=$(openssl x509 -in /etc/uhttpd.crt -noout -subject 2>/dev/null | sed 's/subject=//')
	ends=$(openssl x509 -in /etc/uhttpd.crt -noout -enddate 2>/dev/null | sed 's/notAfter=//')
	ok "uhttpd 证书：${subj:-?}（到期 ${ends:-?}）"
else
	warn "uhttpd 没有证书，HTTPS 起不来"
fi

step "可选功能"
if [ -x /etc/init.d/share-web ]; then ok "共享服务已注册开机自启"; else info "共享服务未安装（模块 share）"; fi
if grep -q traffic-boot-query /etc/rc.local 2>/dev/null; then
	ok "开机查流量已挂载"
	[ -f /etc/mu300/last-traffic-query ] && info "上次查询：$(date -d "@$(cat /etc/mu300/last-traffic-query)" '+%F %T' 2>/dev/null)"
else
	info "开机查流量未启用（模块 traffic，可选）"
fi
if [ -x /usr/bin/mu300-sms ] || [ -d /opt/mu300 ]; then ok "短信组件存在"; else warn "没有短信组件，流量短信用不了"; fi

echo
printf '\033[2m%s\033[0m\n' "报告只读，没有修改任何配置。"
exit 0
