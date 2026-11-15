#!/bin/sh
# 30-tls.sh —— 让局域网入口不再显示「不安全」
#
# 思路：
#   1. 优先复用镜像里已有的 Let's Encrypt 证书（dashplay 的 acme 目录），
#      这类证书浏览器天然信任，而且跟着 acme 自动续期。
#   2. 没有就用自签证书兜底：能用 https，但浏览器仍会警告（自签的通病）。
#   3. 把 uhttpd（LuCI 443）指向该证书，做成软链而不是拷贝 —— 续期后自动生效。
set -u
BASE=$(cd "$(dirname "$0")/.." && pwd)
. "$BASE/lib/common.sh"

SELF_DIR=/etc/v50-box-tls
ip=$(lan_ip)
[ -n "$ip" ] || ip=192.168.1.1
HOST=$(uci -q get system.@system[0].hostname 2>/dev/null); [ -n "$HOST" ] || HOST=v50box

step "找现成证书"
# 优先级：35-domain.sh 签的（/etc/v50-box-tls）→ dashplay 的 acme → acme.sh 自己的目录 → 其他
CERT=""; KEY=""
for d in /etc/v50-box-tls /opt/dashplay/state/acme/certs/* /root/.acme.sh/*_ecc /root/.acme.sh/* /etc/share-web /etc/acme; do
	[ -d "$d" ] || continue
	c=$(ls "$d"/fullchain.cer "$d"/fullchain.pem 2>/dev/null | head -1)
	k=$(ls "$d"/*.key "$d"/privkey.pem "$d"/key.pem 2>/dev/null | head -1)
	[ -n "$c" ] && [ -n "$k" ] && { CERT=$c; KEY=$k; break; }
done

if [ -n "$CERT" ]; then
	ok "复用 $CERT"
	if have openssl; then
		end=$(openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | cut -d= -f2)
		info "到期：$end（acme 会自动续）"
	fi
else
	warn "没有现成证书，改用自签"
	have openssl || die "没有 openssl，装一下：apk add openssl-util / opkg install openssl-util"
	SELF_DIR=/etc/v50-box-tls
	[ "$DRY" = 1 ] || mkdir -p "$SELF_DIR"
	CERT=$SELF_DIR/fullchain.pem
	KEY=$SELF_DIR/key.pem
	if [ -f "$SELF_DIR/fullchain.pem" ]; then
		ok "已有自签证书：$SELF_DIR/fullchain.pem"
	else
		run "openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
-keyout $KEY -out $CERT \
-subj '/CN=$HOST' \
-addext 'subjectAltName=DNS:$HOST,DNS:${HOST}.lan,DNS:localhost,IP:$ip,IP:127.0.0.1'"
		[ "$DRY" = 1 ] || ok "已生成自签证书"
	fi
fi

step "uhttpd（LuCI 的 443）"
# 用软链而不是拷贝：acme 续期换文件后自动生效，不用再手动同步。
cur=$(readlink /etc/uhttpd.crt 2>/dev/null)
if [ "$cur" = "$CERT" ] && [ "$(readlink /etc/uhttpd.key 2>/dev/null)" = "$KEY" ]; then
	ok "已经指向 $CERT"
else
	if [ "$DRY" = 1 ]; then
		info "(dry) ln -sf $CERT /etc/uhttpd.crt; ln -sf $KEY /etc/uhttpd.key"
	else
		[ -f /etc/uhttpd.crt ] && [ ! -L /etc/uhttpd.crt ] && backup_file /etc/uhttpd.crt
		[ -f /etc/uhttpd.key ] && [ ! -L /etc/uhttpd.key ] && backup_file /etc/uhttpd.key
		ln -sf "$CERT" /etc/uhttpd.crt
		ln -sf "$KEY"  /etc/uhttpd.key
		ok "已切换"
	fi
fi

# 确保 uhttpd 真的开了 https 监听
if [ "$(uci -q get uhttpd.main.listen_https 2>/dev/null | wc -w)" = "0" ]; then
	uciset uhttpd main.listen_https "0.0.0.0:443 [::]:443"
	uciset uhttpd main.certfile "/etc/uhttpd.crt"
	uciset uhttpd main.keyfile "/etc/uhttpd.key"
fi
run "/etc/init.d/uhttpd restart"

step "共享服务也换成同一张证书"
# 30-tls.sh 可能晚于 20-share.sh 跑，重启一下让 8443 用上新证书。
if [ -x /etc/init.d/share-web ]; then
	run "/etc/init.d/share-web restart"
	info "已重启 share-web（8443 生效）"
else
	info "没装 share-web，跳过"
fi

if [ "$DRY" = 1 ]; then
	info "dry-run 结束"; exit 0
fi
sleep 2

step "校验"
if have openssl; then
	echo | openssl s_client -connect 127.0.0.1:443 -servername "$HOST" 2>/dev/null \
		| openssl x509 -noout -subject -issuer 2>/dev/null | sed 's/^/  /'
fi
code=$(wget -q -O /dev/null --no-check-certificate --timeout=5 "https://127.0.0.1/" 2>/dev/null && echo 200 || echo fail)
[ "$code" = "200" ] && ok "https://127.0.0.1/ 返回 200" || bad "443 访问失败：logread | grep uhttpd"

echo
info "局域网访问：https://$(domain_of || echo "$ip")/"
case "$CERT" in
	*acme*|/etc/v50-box-tls*)
		ok "用的是 Let's Encrypt 证书：浏览器不会提示不安全" ;;
	*)
		warn "当前是自签证书：功能正常，但首次访问浏览器会警告，点「继续访问」即可"
		warn "想彻底不警告（车机也只认域名）：先跑 --module domain 签一张，再跑本模块" ;;
esac

case "$CERT" in
	/etc/v50-box-tls*)
		dom=$(sed -n 's/^DD_DOM=//p' /etc/v50-box/domain.conf 2>/dev/null)
		[ -n "$dom" ] && {
			echo
			info "车机/手机请用域名访问（特斯拉不认私网 IP）："
			info "  https://$dom/           路由后台"
			info "  https://$dom:8444/      手机控制台"
			info "  https://$dom:8443/      车内共享"
		} ;;
esac
