#!/bin/sh
# 60-hover.sh —— 车机画面悬浮视频窗（可选，自开发功能）
#
# 在 DashPlay 的车机页面上加一个可拖动的圆钮：点开能在小窗里看网页视频（B站等）
# 或共享目录里的本地视频，圆钮可拖动、位置会记住。
#
# 依赖 DashPlay 的注入机制（playport-video-inject）。DashPlay 主体不是本仓库的，
# 本模块只做「补丁 + 开关 + 定时注入」这三件叠加的事，不改它的投屏逻辑。
set -u
BASE=$(cd "$(dirname "$0")/.." && pwd)
. "$BASE/lib/common.sh"

SW=/usr/bin/dashplay-switch
INJ=/usr/bin/playport-video-inject
HUD=/etc/dashplay-hud
CRON_LINE="*/5 * * * * $INJ >/dev/null 2>&1"

step "检查前提"
if [ ! -d /opt/dashplay ]; then
	warn "没有 DashPlay，这个功能无处可挂"
	info "先装模块 dashplay，或换带 DashPlay 的镜像"
	exit 0
fi
if [ ! -x "$INJ" ]; then
	warn "找不到注入器 $INJ"
	info "悬浮窗靠它把代码注入车机页面。你的镜像可能版本不同："
	info "  在盒子上执行 ls /usr/bin/playport-* 看看实际名字，告诉作者加适配"
	exit 0
fi
ok "注入器 $INJ"
[ -x "$SW" ] && ok "开关脚本 $SW" || warn "没有 $SW，只能靠 UCI 开关"

step "给 dashplay-switch 补 video-* 子命令"
if [ -x "$SW" ] && grep -q "video-status" "$SW" 2>/dev/null; then
	ok "已支持 video-on / video-off / video-status"
elif [ -x "$SW" ]; then
	have python3 || die "需要 python3 打补丁：apk add python3-light"
	if [ "$DRY" = 1 ]; then
		info "(dry) 运行 dashplay-video-patch.py"
	else
		cp -f "$BASE/scripts/files/dashplay-video-patch.py" /tmp/.dvv.py
		if python3 /tmp/.dvv.py; then ok "补丁完成"; else warn "补丁失败（版本结构不同），不影响已有功能"; fi
		rm -f /tmp/.dvv.py
	fi
else
	info "跳过（没有 dashplay-switch）"
fi

step "素材"
if [ -d "$HUD" ] && [ -f "$HUD/markup.html" ]; then
	ok "$HUD 已有素材"
else
	if [ "$DRY" = 1 ]; then
		info "(dry) 复制 video-parts -> $HUD"
	else
		mkdir -p "$HUD"
		cp -f "$BASE/scripts/files/video-parts/"*.html "$HUD"/ 2>/dev/null
		ok "已放入 $HUD（markup / style / script）"
		# 注入器在 /etc/dashplay-hud 丢失时会从持久分区自愈，这里同步备一份
		if [ -d /mnt/mu300-disk ]; then
			cp -rf "$HUD" /mnt/mu300-disk/dashplay-hud.d 2>/dev/null && info "已备份到 /mnt/mu300-disk/dashplay-hud.d"
		fi
	fi
fi

step "开关（UCI dashplay.main.video_pane）"
cur=$(uci -q get dashplay.main.video_pane 2>/dev/null)
if [ "$cur" = "1" ]; then
	ok "当前为开"
else
	if [ "$DRY" = 1 ]; then
		info "(dry) 询问用户是否开启"
	elif confirm "现在就开启车机悬浮视频窗？"; then
		uciset dashplay main.video_pane "1"
		ok "已开启"
	else
		uciset dashplay main.video_pane "0"
		info "保持关闭。以后开：dashplay-switch video-on"
	fi
fi

step "定时注入"
# 车机页面每隔几分钟会被 DashPlay 重写一次，注入要跟着补，否则圆钮会消失。
if crontab -l 2>/dev/null | grep -Fq "$INJ"; then
	ok "cron 已有注入任务"
else
	if [ "$DRY" = 1 ]; then
		info "(dry) 加 cron：$CRON_LINE"
	else
		( crontab -l 2>/dev/null; echo "$CRON_LINE" ) | crontab -
		/etc/init.d/cron restart >/dev/null 2>&1
		ok "已加 cron（每 5 分钟补齐一次）"
	fi
fi

step "立即注入一次"
run "$INJ >/dev/null 2>&1"

if [ "$DRY" = 1 ]; then
	info "dry-run 结束"; exit 0
fi
sleep 1

step "校验"
if [ -f /opt/dashplay/dist/hud-video.json ]; then
	ok "状态文件：$(cat /opt/dashplay/dist/hud-video.json)"
else
	warn "没生成 hud-video.json —— 注入器没跑成功，看：$INJ 的输出"
fi
if [ -x "$SW" ]; then
	info "开关状态：$($SW video-status 2>/dev/null || echo '?')（1=开，0=关）"
fi
echo
info "车机页面打开 https://$(lan_ip):18443/ ，右下角应出现 ▶ 圆钮"
info "没出现就刷新一次车机页面；仍没有说明素材文件名和注入器期望的不一致"
