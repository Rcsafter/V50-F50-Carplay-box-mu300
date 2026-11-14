#!/bin/sh
# 40-traffic.sh —— 可选：开机自动发「查流量」短信，省得手动翻营业厅 App
#
# 注意：发短信是要钱的（按运营商资费，通常 0.1 元/条）。所以做了两层去重：
#   1. 距上次查询不足 6 小时就跳过；
#   2. 只在开机后触发一次，不是定时轮询。
# 不想用了：/etc/init.d/traffic-boot disable
set -u
BASE=$(cd "$(dirname "$0")/.." && pwd)
. "$BASE/lib/common.sh"

PHONE=${TRAFFIC_PHONE:-10001}
TEXT=${TRAFFIC_TEXT:-查流量}
GAP=${TRAFFIC_GAP:-21600}
DELAY=${TRAFFIC_DELAY:-240}
STAMP=/etc/mu300/last-traffic-query
LOG=/tmp/traffic-boot.log

step "找发短信的工具"
SMS=""
for c in /usr/bin/mu300-sms /usr/bin/sms_tool /usr/bin/sms-send /usr/sbin/sms_tool; do
	[ -x "$c" ] && { SMS=$c; break; }
done
if [ -z "$SMS" ]; then
	warn "没找到短信发送工具"
	warn "常见候选：mu300-sms、sms_tool、sms-send"
	warn "各家镜像不一样，先手动发一条确认工具和参数，再用 SMS_CMD 环境变量指过来："
	warn "  SMS_CMD='/usr/bin/mu300-sms send 10001' sh install.sh --module traffic"
fi

step "写入触发脚本 /usr/bin/traffic-boot-query"
TMP=/tmp/.tbq.$$
cat > "$TMP" <<'SCRIPT'
#!/bin/sh
# 开机后延迟一会儿再查（等网络注册完成，太早发不出去）
LOG=/tmp/traffic-boot.log
STAMP=/etc/mu300/last-traffic-query
GAP=${TRAFFIC_GAP:-21600}
PHONE=${TRAFFIC_PHONE:-10001}
TEXT=${TRAFFIC_TEXT:-查流量}
SMS=${SMS_CMD:-$(cat /etc/mu300/sms-tool 2>/dev/null)}
DELAY=${TRAFFIC_DELAY:-240}

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

log "scheduled, delay ${DELAY}s"
sleep "$DELAY"

now=$(date +%s)
if [ -f "$STAMP" ]; then
	last=$(cat "$STAMP" 2>/dev/null)
	case "$last" in
		''|*[!0-9]*) last=0 ;;
	esac
	if [ $((now - last)) -lt "$GAP" ]; then
		log "skip: queried $(( (now - last) / 60 )) min ago"
		exit 0
	fi
fi

if [ -z "$SMS" ] || [ ! -x "$(echo "$SMS" | awk '{print $1}')" ]; then
	log "fail: no sms tool"
	exit 1
fi

if $SMS "$PHONE" "$TEXT" >>"$LOG" 2>&1; then
	echo "$now" > "$STAMP"
	log "sent: $TEXT -> $PHONE"
else
	log "fail: send error"
fi
SCRIPT
if [ -f /usr/bin/traffic-boot-query ] && cmp -s "$TMP" /usr/bin/traffic-boot-query; then
	rm -f "$TMP"; ok "脚本没变化"
else
	if [ "$DRY" = 1 ]; then
		info "(dry) 写入 /usr/bin/traffic-boot-query"
		rm -f "$TMP"
	else
		cat "$TMP" > /usr/bin/traffic-boot-query; chmod 755 /usr/bin/traffic-boot-query; rm -f "$TMP"
		ok "已写入"
	fi
fi

step "挂到开机（rc.local）"
# 用 procd 的 service 更干净，但 rc.local 在多数镜像里更可靠、也好删除。
LINE="( sleep 5; /usr/bin/traffic-boot-query ) &"
if append_once /etc/rc.local "$LINE"; then
	[ "$DRY" = 1 ] || ok "已加入 rc.local"
else
	ok "rc.local 里已有"
fi

step "记录短信工具"
if [ -n "$SMS" ]; then
	if [ "$DRY" != 1 ]; then
		mkdir -p /etc/mu300
		printf '%s\n' "$SMS" > /etc/mu300/sms-tool
	fi
	ok "用 $SMS"
fi

step "试发一条（现在就要花钱，非 dry-run 才会问）"
if [ "$DRY" = 1 ]; then
	info "(dry) 不发"
	exit 0
fi
if [ -n "$SMS" ] && confirm "现在试发一条到 $PHONE？会扣短信费"; then
	if $SMS "$PHONE" "$TEXT" >>"$LOG" 2>&1; then
		date +%s > "$STAMP"
		ok "已发送，看回复：logread | tail"
	else
		bad "发送失败，看 $LOG"
	fi
else
	info "跳过。下次开机 4 分钟后会自动查（距上次超过 6 小时才发）"
fi

echo
info "查看记录：cat $LOG"
info "关掉：删掉 rc.local 里那行，或 /etc/init.d/traffic-boot disable"
