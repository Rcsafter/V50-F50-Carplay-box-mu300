#!/bin/sh
# 15-bluetooth.sh —— 蓝牙体检与修复（MU300 / DashPlay 这套 UART 方案）
#
# 这套镜像的蓝牙不是标准 bluez 服务，是四段拼起来的：
#   1. mu300-bt-run     modprobe wcn_bsp/sprdbt_tty → 灌 Marlin3 固件 → btattach 挂 /dev/ttyBT0
#   2. btup             等 hci0 出现后 hciconfig up + bluetoothctl power on（开机兜底）
#   3. bluetoothd       守护进程
#   4. linux-bt-bridge  DashPlay 把真实 MAC 桥接给系统
#
# 三个已知坑，写在最前面免得下次再踩：
#   · 新固件的 btmgmt 发不出 mgmt 命令 —— 提权只能用 hciconfig up + bluetoothctl power on
#   · hci0 被 btattach 创建后默认被 rfkill 挡住 —— 必须把 soft 写 0
#   · 车机记的是 BDADDR —— 地址一变就得在车机上删掉旧配对重新连
set -u
BASE=$(cd "$(dirname "$0")/.." && pwd)
. "$BASE/lib/common.sh"

need_root

BT_CONF=/etc/mu300/bluetooth.conf
BT_ADDR_FILE=/var/lib/mu300/bdaddr
BT_RUN=/usr/bin/mu300-bt-run
ADDR_OVERRIDE=${BT_ADDR:-}

running() { ps w 2>/dev/null | grep -v grep | grep -q "$1"; }

wait_hci() { # 等 hci0 出现，最多 $1 秒
	n=0
	while [ "$n" -lt "${1:-20}" ]; do
		[ -e /sys/class/bluetooth/hci0 ] && return 0
		sleep 1
		n=$((n + 1))
	done
	return 1
}

rf_soft() { # 蓝牙 rfkill 的 soft 值：0 正常，1 被挡，空=没有节点
	for r in /sys/class/rfkill/rfkill*; do
		[ -e "$r" ] || continue
		[ "$(cat "$r/type" 2>/dev/null)" = bluetooth ] || continue
		cat "$r/soft" 2>/dev/null
	done | head -1
}

rf_unblock() {
	for r in /sys/class/rfkill/rfkill*; do
		[ -e "$r" ] || continue
		[ "$(cat "$r/type" 2>/dev/null)" = bluetooth ] || continue
		[ "$(cat "$r/soft" 2>/dev/null)" = 1 ] || continue
		run "echo 0 > $r/soft"
	done
}

bt_addr() {
	# 投屏跑起来时 bridge 会把真实 MAC 桥过去，优先用它
	a=$(ps w 2>/dev/null | grep -v grep | sed -n 's/.*bridge\.py .*--address \([0-9A-Fa-f:]\{17\}\).*/\1/p' | head -1)
	[ -n "$a" ] || a=$(sed -n 's/^BDADDR=\([0-9A-Fa-f:]\{17\}\)$/\1/p' "$BT_CONF" 2>/dev/null | tail -n1)
	[ -n "$a" ] || a=$(cat "$BT_ADDR_FILE" 2>/dev/null)
	[ -n "$a" ] || a=$(hciconfig hci0 2>/dev/null | sed -n 's/.*BD Address: \([0-9A-Fa-f:]*\).*/\1/p' | head -1)
	echo "${a:-未知}"
}

up_now() { # hci0 是否 UP RUNNING
	[ -e /sys/class/bluetooth/hci0 ] || return 1
	hciconfig hci0 2>/dev/null | grep -q "UP RUNNING"
}

# ---------------- 认方案 ----------------
step "蓝牙：先认一下这是哪套方案"
if [ ! -f "$BT_RUN" ] && [ ! -x /etc/init.d/mu300-bt ]; then
	warn "没找到 $BT_RUN，也不是 mu300-bt 这套"
	info "说明你的镜像用标准 bluez，跟这个脚本不搭。手动试这两条："
	info "  /etc/init.d/bluetooth enable && /etc/init.d/bluetooth restart"
	info "  hciconfig -a        # 看有没有 UP RUNNING"
	exit 0
fi
ok "确认是 MU300 / DashPlay 的四段式方案"

# ---------------- 体检 ----------------
step "逐段体检"

miss_mod=""
for m in wcn_bsp sprdbt_tty; do
	grep -q "^$m " /proc/modules || miss_mod="$miss_mod $m"
done
if [ -n "$miss_mod" ]; then
	bad "缺内核模块：$miss_mod"
else
	ok "内核模块在位（wcn_bsp / sprdbt_tty）"
fi

if [ -c /dev/ttyBT0 ]; then
	ok "/dev/ttyBT0 存在"
else
	bad "/dev/ttyBT0 不存在，蓝牙串口没起来"
fi

if running btattach; then
	ok "btattach 在跑（UART → H4）"
else
	bad "btattach 没跑，hci0 就是靠它创建的"
fi

if [ -e /sys/class/bluetooth/hci0 ]; then
	if up_now; then
		ok "hci0 状态 UP RUNNING"
		st=up
	else
		bad "hci0 存在但没起来（DOWN）"
		st=down
	fi
else
	bad "hci0 不存在"
	st=none
fi

soft=$(rf_soft)
if [ "$soft" = 1 ]; then
	bad "蓝牙被 rfkill 挡住（soft=1）"
elif [ -n "$soft" ]; then
	ok "rfkill 没挡（soft=$soft）"
else
	ok "没有蓝牙 rfkill 节点"
fi

if running bluetoothd; then
	ok "bluetoothd 在跑"
else
	bad "bluetoothd 没跑，没有它没法配对"
fi

if running linux-bt-bridge; then
	ok "DashPlay 蓝牙桥在跑"
else
	info "DashPlay 蓝牙桥没在跑——它由投屏运行时按需拉起，不是开机常驻，这是正常状态"
fi

addr=$(bt_addr)
info "当前 BDADDR：$addr"
if [ "$addr" = "02:00:00:96:00:01" ]; then
	info "这是镜像的默认地址，车机记住的就是它，一般不用改"
	info "只有两台盒子地址撞车时才需要固定成别的：BT_ADDR=xx:xx:xx:xx:xx:xx 重跑本脚本"
fi

# ---------------- 修复 ----------------
step "按环节修复，只动有问题的那几处"

fixed=0
need_wait=0

if [ -n "$miss_mod" ]; then
	for m in $miss_mod; do
		if run "modprobe $m"; then ok "已加载 $m"; fixed=1; fi
	done
fi

if [ ! -c /dev/ttyBT0 ] || ! running btattach; then
	if [ -x /etc/init.d/mu300-bt ]; then
		info "重启 mu300-bt（会重灌固件，约 10 秒）"
		run "/etc/init.d/mu300-bt restart"
	else
		run "$BT_RUN &"
	fi
	fixed=1
	need_wait=1
fi

if [ "$st" = none ] || [ "$need_wait" = 1 ]; then
	if wait_hci 20; then
		ok "hci0 已出现"
	else
		bad "等了 20 秒还是没有 hci0"
		info "多半是固件没灌进去。手动前台跑一遍看报错：$BT_RUN"
	fi
fi

# 先解 rfkill 再提权，顺序反了 up 会失败
rf_unblock

if [ -e /sys/class/bluetooth/hci0 ] && ! up_now; then
	info "拉起 hci0"
	run "hciconfig hci0 up"
	sleep 1
	rf_unblock
	run "timeout 8 bluetoothctl power on >/dev/null 2>&1 || true"
	fixed=1
fi

if ! running bluetoothd; then
	if [ -x /etc/init.d/bluetoothd ]; then
		run "/etc/init.d/bluetoothd restart"
	else
		run "bluetoothd -n >/dev/null 2>&1 &"
	fi
	sleep 1
	fixed=1
fi

# 桥接进程不自动重启：它归 dashplay 管，强起可能打断正在投屏的画面
if ! running linux-bt-bridge; then
	info "投屏连不上车机时，再重启投屏让它重新拉起桥接：/etc/init.d/dashplay restart"
fi

# ---------------- 改地址（可选） ----------------
if [ -n "$ADDR_OVERRIDE" ]; then
	case "$ADDR_OVERRIDE" in
		[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) ;;
		*) die "BT_ADDR 格式不对，要像 60:81:10:F1:AC:B3 这样" ;;
	esac
	step "固定蓝牙地址为 $ADDR_OVERRIDE"
	info "改完要在车机上删掉旧的 DashPlay 配对，重新搜一次"
	if [ "$DRY" = 1 ]; then
		printf '  (dry) 写 %s 与 %s\n' "$BT_CONF" "$BT_ADDR_FILE"
	else
		backup_file "$BT_CONF"
		mkdir -p "$(dirname "$BT_CONF")" /var/lib/mu300
		if grep -q '^BDADDR=' "$BT_CONF" 2>/dev/null; then
			sed -i "s|^BDADDR=.*|BDADDR=$ADDR_OVERRIDE|" "$BT_CONF"
		else
			printf 'BDADDR=%s\n' "$ADDR_OVERRIDE" >> "$BT_CONF"
		fi
		echo "$ADDR_OVERRIDE" > "$BT_ADDR_FILE"
		ok "已写入，重启蓝牙生效：/etc/init.d/mu300-bt restart"
	fi
fi

# ---------------- 复验 ----------------
step "复验"

sleep 2
if up_now; then
	ok "hci0 现在 UP RUNNING"
	[ "$fixed" = 1 ] && ok "本次动过配置，已修好"
else
	bad "hci0 还是没起来"
	info "下一步排查："
	info "  1) dmesg | grep -iE 'bt|wcn|sprd' | tail -20"
	info "  2) logread | grep -i btup"
	info "  3) ls /lib/firmware/bt_configure_*.ini     # 固件参数文件在不在"
fi

running bluetoothd && ok "bluetoothd 在跑"
info "当前 BDADDR：$(bt_addr)"

step "车机上怎么连"
info "1. 车机蓝牙里搜「DashPlay」，地址 $(bt_addr)"
info "2. 连不上就先在车机上删掉旧的 DashPlay 记录，再重新搜"
info "3. 还不行就重启盒子 —— mu300-bt 是开机自启的，重启能顺便验证它可不可靠"
info "音频走 A2DP，投屏画面走网络，两条路互不影响"
