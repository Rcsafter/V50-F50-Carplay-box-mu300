#!/bin/sh
# 50-dashplay.sh —— DashPlay 投屏（可选）
#
# DashPlay 主体由抖音「一只小黑狗」（yizhixiaoheigou）提供：投屏、车机页面、设置页都是他的作品。
# 本模块只做两件轻活：确认它在、按你的选择决定开机自不自启、把状态查给你看。
# 不修改 DashPlay 本体。
set -u
BASE=$(cd "$(dirname "$0")/.." && pwd)
. "$BASE/lib/common.sh"

step "检测 DashPlay"
if [ ! -d /opt/dashplay ]; then
	warn "这个镜像没带 DashPlay（/opt/dashplay 不存在）"
	info "DashPlay 主体由抖音「一只小黑狗」提供，需要刷带它的 OpenWrt 镜像"
	info "跳过不影响其他模块；换了镜像再跑一次这个模块就行"
	exit 0
fi
ok "找到 /opt/dashplay"

SVC=""
for s in /etc/init.d/dashplay /etc/init.d/v50gw /etc/init.d/dashplay-core; do
	[ -x "$s" ] && { SVC=$s; break; }
done
if [ -z "$SVC" ]; then
	warn "没找到 DashPlay 的启动脚本（/etc/init.d/dashplay 之类）"
	info "可能这个镜像用别的方式拉起，跳过启停设置"
else
	ok "启动脚本 $SVC"
fi

if [ -n "$SVC" ]; then
	step "是否开机自启"
	cur=$(uci -q get dashplay.main.enabled 2>/dev/null)
	info "当前 dashplay.main.enabled=${cur:-未设置}"
	if [ "$DRY" = 1 ]; then
		info "(dry) 询问用户是否自启"
	elif confirm "设成开机自启（车机一上车就能投屏）？"; then
		uciset dashplay main.enabled "1"
		run "$SVC enable"
		run "$SVC restart"
		ok "已设为自启并重启"
	else
		info "保持关闭。要用时手动开：$SVC start"
	fi
fi

step "校验"
if [ "$DRY" = 1 ]; then
	info "dry-run 结束"; exit 0
fi
ip=$(lan_ip)
sleep 2
if port_up 18443; then
	ok "投屏页面 https://$ip:18443/ 可访问"
else
	warn "18443 没起来：$SVC status / logread | tail -30"
fi
if port_up 18080; then
	ok "设置页 http://$ip:18080/ 可访问"
else
	info "设置页 18080 没开（有些版本只在需要时启动）"
fi
echo
info "开关命令：dashplay-switch on|off|status"
info "车机浮窗开关另见模块 hover"
