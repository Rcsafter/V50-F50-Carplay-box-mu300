#!/bin/sh
# 70-tunnel.sh —— 外网访问隧道（可选，自开发功能）
#
# 用 cloudflared 把盒子上的页面挂到公网域名，人在外地也能看控制台、看车机画面。
# 不占用公网端口，不需要公网 IP，适合 CPE 这种 NAT 后面的设备。
#
# 注意：这会把这个盒子暴露到互联网。必须有鉴权，且不要直接挂 80 端口——
# /www/cgi-bin/cgi-exec 能执行任意命令，裸奔等于把机器交出去。
set -u
BASE=$(cd "$(dirname "$0")/.." && pwd)
. "$BASE/lib/common.sh"

CONF_DIR=/etc/cloudflared
CONF=$CONF_DIR/config.yml
BIN=""

step "检查 cloudflared"
for b in /usr/bin/cloudflared /usr/sbin/cloudflared /opt/cloudflared/cloudflared; do
	[ -x "$b" ] && { BIN=$b; break; }
done
if [ -z "$BIN" ]; then
	warn "没装 cloudflared"
	info "先去 Cloudflare Zero Trust 建一个 tunnel，拿到 token 或凭据 json"
	info "然后把对应架构的 cloudflared 放到 /usr/bin/cloudflared 并 chmod 755"
	info "（也可以 apk add cloudflared / opkg install cloudflared，看你源里有没有）"
	info "装好后再跑一次本模块，剩下的我配"
	exit 0
fi
ok "$BIN"

step "检查配置"
if [ ! -f "$CONF" ]; then
	warn "没有 $CONF"
	info "这个文件里有你的 tunnel 凭据和域名，必须你自己填，我不能替你编"
	if [ "$DRY" != 1 ]; then
		mkdir -p "$CONF_DIR"
		cat > "$CONF.example" <<'EOF'
# 复制成 config.yml 后改这几处：
tunnel: <你的-tunnel-UUID>
credentials-file: /etc/cloudflared/<你的-tunnel-UUID>.json

ingress:
  # 控制台
  - hostname: box.example.com
    service: http://127.0.0.1:8082
  # 车内共享
  - hostname: share.example.com
    service: http://127.0.0.1:8082
  # 没匹配到的一律 404
  - service: http_status:404
EOF
		chmod 600 "$CONF.example"
		ok "已生成模板 $CONF.example，照着填好改名为 config.yml"
	fi
	info "填好后重跑：sh install.sh --module tunnel"
	exit 0
fi
ok "配置存在：$CONF"
chmod 600 "$CONF" 2>/dev/null

step "凭据文件"
cred=$(sed -n 's/^credentials-file: *//p' "$CONF" | head -1)
if [ -n "$cred" ] && [ -f "$cred" ]; then
	chmod 600 "$cred" 2>/dev/null
	ok "凭据 $(basename "$cred")（权限已收紧到 600）"
else
	warn "配置里写的凭据文件不存在：${cred:-未配置}"
	info "从 Cloudflare 后台下载凭据 json 放到该路径"
	exit 0
fi

step "启动脚本 /etc/init.d/cloudflared"
# 这个服务的启动顺序很关键：它一起来就要查 dnsmasq 解析 argotunnel.com。
# 如果 dnsmasq 还没监听，查询直接 connection refused，cloudflared 会退出——
# 表现为「重启后外网全断，手动 restart 一下又好了」。所以启动前必须等 DNS 就绪。
SVC=/etc/init.d/cloudflared
TMP=/tmp/.cf.init.$$
cat > "$TMP" <<EOF
#!/bin/sh /etc/rc.common
# 由 v50-box 生成
START=99
USE_PROCD=1

wait_dns() {
	# 最多等 40 秒，直到本机 dnsmasq 能解析
	i=0
	while [ \$i -lt 20 ]; do
		if nslookup argotunnel.com 127.0.0.1 >/dev/null 2>&1; then
			return 0
		fi
		i=\$((i + 1))
		sleep 2
	done
	return 1
}

start_service() {
	wait_dns || logger -t cloudflared "dnsmasq 未就绪，仍然尝试启动"
	procd_open_instance
	procd_set_param command $BIN tunnel --config $CONF run
	procd_set_param respawn 3600 5 10
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}
EOF
if [ -f "$SVC" ] && cmp -s "$TMP" "$SVC"; then
	rm -f "$TMP"; ok "启动脚本没变化"
else
	if [ "$DRY" = 1 ]; then
		info "(dry) 写入 $SVC"
		rm -f "$TMP"
	else
		backup_file "$SVC"
		cat "$TMP" > "$SVC"; chmod 755 "$SVC"; rm -f "$TMP"
		ok "已写入（含 DNS 就绪等待）"
	fi
fi

step "开机自启"
run "$SVC enable"
run "$SVC restart"

if [ "$DRY" = 1 ]; then
	info "dry-run 结束"; exit 0
fi

step "校验"
i=0
while [ $i -lt 15 ]; do
	if ps w | grep -q "[c]loudflared tunnel"; then break; fi
	sleep 2
	i=$((i + 1))
done
if ps w | grep -q "[c]loudflared tunnel"; then
	ok "进程在跑"
	if logread 2>/dev/null | grep -q "Registered tunnel connection"; then
		ok "已连上 Cloudflare（Registered tunnel connection）"
	else
		warn "进程在跑但还没注册上，再等十几秒：logread | grep -i cloudflared | tail"
	fi
else
	warn "进程没起来：$SVC start 后看 logread | grep cloudflared"
fi

echo
info "域名在 Cloudflare 后台的 DNS 里指向这个 tunnel 才能访问"
info "别把 80 端口直接挂上来：/www/cgi-bin/cgi-exec 可执行任意命令"
