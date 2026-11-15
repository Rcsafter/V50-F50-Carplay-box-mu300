#!/bin/sh
# 20-share.sh —— 车内共享（手机/车机直接播盘里的电影，支持拖进度条）
# 装一个 python3 小服务 + 一个 procd 服务，开机自启。
set -u
BASE=$(cd "$(dirname "$0")/.." && pwd)
. "$BASE/lib/common.sh"

SRC="$BASE/scripts/files"
SHARE_DIR=${SHARE_DIR:-$(disk_root)/share}
PORT=8080
PORT_TLS=8443

step "检查依赖"
if ! have python3; then
	warn "没有 python3，尝试安装"
	pkg_add python3-light
	have python3 || die "装不上 python3，请先 opkg/apk install python3"
fi
ok "python3 $(python3 -V 2>&1 | awk '{print $2}')"

step "共享目录"
if [ -d "$SHARE_DIR" ]; then
	ok "$SHARE_DIR 已存在（$(ls -1 "$SHARE_DIR" 2>/dev/null | wc -l) 个条目）"
else
	if [ "$DRY" = 1 ]; then
		info "(dry) mkdir -p $SHARE_DIR"
	else
		mkdir -p "$SHARE_DIR" && ok "已创建 $SHARE_DIR"
	fi
fi

step "安装服务文件"
for f in share-web share-app.html; do
	[ -f "$SRC/$f" ] || die "仓库里缺 $SRC/$f，请重新拉一次代码"
done
if [ "$DRY" = 1 ]; then
	info "(dry) 复制 share-web -> /usr/bin/，share-app.html -> /www/"
else
	cp -f "$SRC/share-web" /usr/bin/share-web && chmod 755 /usr/bin/share-web
	cp -f "$SRC/share-app.html" /www/share-app.html
	ok "/usr/bin/share-web　/www/share-app.html"
fi

step "证书（有就用，没有只跑明文）"
CERT=""
KEY=""
for d in /etc/v50-box-tls /opt/dashplay/state/acme/certs/* /etc/share-web; do
	[ -d "$d" ] || continue
	c=$(ls "$d"/fullchain.cer "$d"/fullchain.pem "$d"/cert.pem 2>/dev/null | head -1)
	k=$(ls "$d"/*.key "$d"/privkey.pem "$d"/key.pem 2>/dev/null | head -1)
	[ -n "$c" ] && [ -n "$k" ] && { CERT=$c; KEY=$k; break; }
done
if [ -n "$CERT" ]; then
	ok "用 $CERT"
else
	warn "没找到现成证书：只开 8080 明文。跑完 30-tls.sh 后重启服务即可开 8443"
fi

step "procd 服务 /etc/init.d/share-web"
SVC=/etc/init.d/share-web
TMP=/tmp/.share-web.init.$$
cat > "$TMP" <<EOF
#!/bin/sh /etc/rc.common
# 车内共享 · 由 v50-box 生成
START=96
USE_PROCD=1

start_service() {
	procd_open_instance
	procd_set_param command /usr/bin/python3 /usr/bin/share-web
	procd_set_param env SHARE_ROOT=$SHARE_DIR SHARE_PORT=$PORT
	procd_set_param env SHARE_PORT_TLS=$PORT_TLS
	procd_set_param env SHARE_CERT=$CERT SHARE_KEY=$KEY
	procd_set_param respawn 3600 5 5
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}
EOF
if [ -f "$SVC" ] && cmp -s "$TMP" "$SVC"; then
	rm -f "$TMP"; ok "服务文件没变化"
else
	if [ "$DRY" = 1 ]; then
		info "(dry) 写入 $SVC"
		rm -f "$TMP"
	else
		backup_file "$SVC"
		cat "$TMP" > "$SVC"; chmod 755 "$SVC"; rm -f "$TMP"
		ok "已写入 $SVC"
	fi
fi

step "启动并设为开机自启"
run "$SVC enable"
run "$SVC restart"
if [ "$DRY" = 1 ]; then
	info "dry-run 结束"; exit 0
fi
sleep 2

step "校验"
ip=$(lan_ip)
if port_up "$PORT"; then
	code=$(wget -q -O /dev/null --timeout=5 "http://127.0.0.1:$PORT/" 2>/dev/null && echo 200 || echo fail)
	ok "8080 在听（HTTP $code）"
else
	bad "8080 没起来，看日志：logread | grep share-web"
fi
if [ -n "$CERT" ] && port_up "$PORT_TLS"; then
	ok "8443 在听（HTTPS）"
fi
echo
info "共享地址：http://$ip:$PORT/"
[ -n "$CERT" ] && info "　　　　　https://$ip:$PORT_TLS/  （域名访问时证书才对得上）"
info "往 $SHARE_DIR 里放电影，手机浏览器打开上面地址即可播放"
