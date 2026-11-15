#!/bin/sh
# 35-domain.sh —— 申请一个免费域名，让车机能打开、证书能生效
#
# 为什么要域名（不是矫情）：
#   1. 特斯拉车机浏览器不认 192.168.x.x / 100.96.x.x 这类私网地址，直接输 IP 打不开或弹警告；
#   2. Let's Encrypt 不给私网 IP 签证书，用 IP 访问永远是「不安全」；
#   3. 证书只认域名，所以「让浏览器不警告」和「让车机能打开」其实是同一件事。
#
# 做法：
#   1. DuckDNS 免费二级域名（只要一个 token，不用备案、不用买）
#   2. 在盒子的 dnsmasq 里把这个域名解析到盒子自己 —— 局域网内解析得到 100.96.0.1/192.168.1.1
#   3. acme.sh 用 DNS-01 方式签 Let's Encrypt 证书（不占 80 端口，不需要公网可达）
#   4. 结果交给 30-tls.sh 接线（uhttpd / share-web）
set -u
BASE=$(cd "$(dirname "$0")/.." && pwd)
. "$BASE/lib/common.sh"

CONF_DIR=/etc/v50-box
CONF=$CONF_DIR/domain.conf
OUT=/etc/v50-box-tls

ip=$(lan_ip)
[ -n "$ip" ] || ip=192.168.1.1

step "域名配置"

SUB=${DUCKDNS_SUB:-}
TOK=${DUCKDNS_TOKEN:-}

# 已经配过就直接复用，除非显式给了新值
if [ -z "$SUB" ] && [ -f "$CONF" ]; then
	. "$CONF" 2>/dev/null || true
	SUB=${DD_SUB:-}
	TOK=${DD_TOKEN:-}
	[ -n "$SUB" ] && info "沿用已保存的配置：$SUB.duckdns.org"
fi

if [ -z "$SUB" ]; then
	if [ ! -t 0 ]; then
		# 不中断安装：--all 里带了这个模块，没 token 就跳过，
		# 后面的 tls 会退回自签，功能不受影响，只是浏览器仍会提示。
		warn "没有交互终端，也没有 DuckDNS 信息 —— 跳过域名配置"
		info "补装方式：DUCKDNS_SUB=mysub DUCKDNS_TOKEN=xxxx sh install.sh --module domain"
		info "（子域名在 duckdns.org 免费注册，token 就是首页上那串，不用备案不用买）"
		exit 0
	fi
	printf '  DuckDNS 子域名（只要前缀，例如 v50car → v50car.duckdns.org）：'
	read -r SUB
	printf '  DuckDNS token（duckdns.org 登录后首页那条）：'
	read -r TOK
fi

SUB=$(echo "$SUB" | tr -d ' \t\r\n' | tr 'A-Z' 'a-z')
TOK=$(echo "$TOK" | tr -d ' \t\r\n')
DOM="$SUB.duckdns.org"

[ -n "$SUB" ] || die "子域名不能为空"
[ -n "$TOK" ] || warn "没有 token：仍然会把域名解析到本机，但签不了证书"
case "$SUB" in
	*.*) die "这里只填前缀，不要带 .duckdns.org" ;;
esac

step "记下配置"
if [ "$DRY" = 1 ]; then
	info "(dry) 写 $CONF"
else
	mkdir -p "$CONF_DIR"
	cat > "$CONF" <<EOF
# v50-box 域名配置（删掉这行注释也不影响）
# 由 scripts/35-domain.sh 生成，$(date '+%F %T')
DD_SUB=$SUB
DD_TOKEN=$TOK
DD_DOM=$DOM
EOF
	chmod 600 "$CONF"
	ok "$CONF（权限 600，只有 root 能读）"
fi

# ---------- 1. 把 A 记录指到盒子自己 ----------
step "DuckDNS A 记录"
# 说明：这个 A 记录指向局域网地址，公网访问不到它；它存在的意义是让
# 「域名 → 盒子」这条对应关系在 DuckDNS 那边也是对的，方便排查。
# 真正的解析靠下面第 2 步的本地 dnsmasq。
A_IP=${DDNS_IP:-$ip}
if [ "$DRY" = 1 ]; then
	info "(dry) 更新 $DOM 的 A 记录为 $A_IP"
else
	resp=$(wget -q -T 10 -O - \
		"https://www.duckdns.org/update?domains=$SUB&token=$TOK&ip=$A_IP" 2>/dev/null)
	case "$resp" in
		OK) ok "$DOM → $A_IP（DuckDNS 已记录）" ;;
		KO) warn "DuckDNS 拒绝更新（token 或子域名不对）" ;;
		"") warn "连不上 duckdns.org（先确认盒子能上网）" ;;
		*)  warn "DuckDNS 返回：$resp" ;;
	esac
fi

# ---------- 1.5 保活：DuckDNS 30 天不动会删掉免费域名 ----------
step "保活（DuckDNS 30 天不更新会回收域名）"
UPD=$CONF_DIR/ddns-update.sh
if [ "$DRY" = 1 ]; then
	info "(dry) 生成 $UPD + 每天 04:17 的 cron"
else
	cat > "$UPD" <<'EOS'
#!/bin/sh
# 由 35-domain.sh 生成。作用有两个：
#   1) 把域名指到盒子当前地址（换网段后自动跟上）
#   2) 保活 —— DuckDNS 的免费域名 30 天内没有更新会被删除
C=/etc/v50-box/domain.conf
[ -f "$C" ] || exit 0
. "$C"
ip=$(ip -4 addr show br-lan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1)
[ -n "$ip" ] || ip=$(ip -4 route 2>/dev/null | sed -n 's/^default .* src \([0-9.]*\).*/\1/p' | head -1)
[ -n "$ip" ] || exit 0
r=$(wget -q -T 10 -O - \
	"https://www.duckdns.org/update?domains=$DD_SUB&token=$DD_TOKEN&ip=$ip" 2>/dev/null)
echo "$(date '+%F %T') $DD_DOM -> $ip : ${r:-无响应}" >> /tmp/ddns-update.log
EOS
	chmod 755 "$UPD"
	ok "生成 $UPD"

	TMP=/tmp/.v50cron.$$
	crontab -l 2>/dev/null > "$TMP" || true
	if grep -q 'v50-box ddns' "$TMP"; then
		ok "cron 已有保活任务"
	else
		echo "17 4 * * * $UPD >/dev/null 2>&1 # v50-box ddns" >> "$TMP"
		crontab "$TMP" && ok "已加 cron：每天 04:17 更新一次"
	fi
	rm -f "$TMP"
	/etc/init.d/cron restart >/dev/null 2>&1
fi

# ---------- 2. 局域网内把这个域名指回盒子 ----------
step "本地 DNS：让 $DOM 在车内就解析到 $ip"
# address= 负责 A 记录；server=/域名/ 负责掐掉上游那条陈旧的 AAAA，
# 否则手机会先试 IPv6、连不上再回落，体感就是「打开很慢」。
cur_addr=$(uci -q get dhcp.@dnsmasq[0].address 2>/dev/null | tr ' ' '\n' | grep -F "/$DOM/" | head -1)
if [ "$cur_addr" = "/$DOM/$ip" ]; then
	ok "address 已配置"
else
	if [ "$DRY" = 1 ]; then
		info "(dry) uci add_list dhcp.@dnsmasq[0].address=/$DOM/$ip"
	else
		# 清掉同域名的旧条目，避免改地址后留下冲突
		for old in $(uci -q get dhcp.@dnsmasq[0].address 2>/dev/null | tr ' ' '\n' | grep -F "/$DOM/"); do
			uci del_list "dhcp.@dnsmasq[0].address" "$old" 2>/dev/null
		done
		uci add_list "dhcp.@dnsmasq[0].address=/$DOM/$ip"
		uci commit dhcp
		ok "已写入 dnsmasq"
	fi
fi

if uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | tr ' ' '\n' | grep -qxF "/$DOM/"; then
	ok "AAAA 上游已屏蔽"
else
	if [ "$DRY" = 1 ]; then
		info "(dry) uci add_list dhcp.@dnsmasq[0].server=/$DOM/"
	else
		uci add_list "dhcp.@dnsmasq[0].server=/$DOM/"
		uci commit dhcp
		ok "已屏蔽该域名的上游 AAAA 查询"
	fi
fi

run "/etc/init.d/dnsmasq restart"
if [ "$DRY" = 0 ]; then
	sleep 2
	got=$(nslookup "$DOM" 127.0.0.1 2>/dev/null | sed -n 's/^Address: \([0-9.]*\)$/\1/p' | tail -1)
	[ "$got" = "$ip" ] && ok "本机解析 $DOM → $got" || warn "本机解析结果：${got:-无}（等几秒再试）"
fi

# ---------- 3. 签证书 ----------
step "Let's Encrypt 证书（DNS-01，不占端口）"
ACME=""
for c in /opt/dashplay/state/acme/acme.sh /root/.acme.sh/acme.sh /usr/lib/acme/client/acme.sh; do
	[ -f "$c" ] && { ACME=$c; break; }
done
[ -z "$ACME" ] && have acme.sh && ACME=$(command -v acme.sh)
if [ -z "$ACME" ]; then
	info "没找到 acme.sh，尝试安装 acme 包"
	pkg_add acme acme-dnsapi 2>/dev/null
	for c in /usr/lib/acme/client/acme.sh /root/.acme.sh/acme.sh; do
		[ -f "$c" ] && { ACME=$c; break; }
	done
fi

CERT=""; KEY=""
if [ -n "$ACME" ]; then
	ok "acme.sh：$ACME"
	CADIR=$(echo "$ACME" | sed 's#/acme.sh$##')
	# 已经签过就不用再签（30 天内到期 acme 会自己续）
	for d in "$CADIR/${DOM}_ecc" "$CADIR/$DOM"; do
		if [ -f "$d/fullchain.cer" ] && [ -f "$d/$DOM.key" ]; then
			CERT=$d/fullchain.cer; KEY=$d/$DOM.key; break
		fi
	done

	if [ -z "$CERT" ]; then
		if [ -z "$TOK" ]; then
			warn "没有 token，签不了证书"
		else
			info "正在签 $DOM（约 30~90 秒，要能解析 duckdns 的 TXT 记录）"
			if [ "$DRY" = 1 ]; then
				info "(dry) DUCKDNS_Token=*** $ACME --issue --dns dns_duckdns -d $DOM --keylength ec-256"
			else
				DUCKDNS_Token="$TOK" "$ACME" --issue --dns dns_duckdns -d "$DOM" \
					--keylength ec-256 --server letsencrypt 2>&1 | tail -12
				for d in "$CADIR/${DOM}_ecc" "$CADIR/$DOM"; do
					if [ -f "$d/fullchain.cer" ] && [ -f "$d/$DOM.key" ]; then
						CERT=$d/fullchain.cer; KEY=$d/$DOM.key; break
					fi
				done
			fi
		fi
	fi
else
	warn "盒子/软件源里都没有 acme.sh"
	warn "两个替代办法：① LuCI 装 luci-app-acme，在「系统 → 证书」里按 DNS 方式签"
	warn "              ② 如果装了 DashPlay，它的 acme 目录里可能已有证书，--module tls 会自动复用"
fi

# ---------- 4. 把证书放到固定位置，等 30-tls.sh 接线 ----------
if [ -n "$CERT" ]; then
	step "落位到 $OUT"
	if [ "$DRY" = 1 ]; then
		info "(dry) ln -sf $CERT $OUT/fullchain.cer"
	else
		mkdir -p "$OUT"
		ln -sf "$CERT" "$OUT/fullchain.cer"
		ln -sf "$KEY"  "$OUT/key.pem"
		ok "$OUT/fullchain.cer → $CERT"
		if have openssl; then
			openssl x509 -in "$CERT" -noout -subject -dates -ext subjectAltName 2>/dev/null | sed 's/^/    /'
		fi
	fi
fi

# ---------- 5. 告诉用户接下来怎么用 ----------
echo
step "接下来"
if [ -n "$CERT" ]; then
	info "1) 把证书接到各项服务上：sh install.sh --module tls"
	info "2) 之后统一用域名访问（车机只认这个）："
	info "     https://$DOM/            路由后台"
	info "     https://$DOM:8444/       手机控制台"
	info "     https://$DOM:8443/       车内共享"
	info "     https://$DOM:18443/      投屏 / 车机页面"
else
	info "域名已就绪（$DOM → $ip），证书还没签下来。"
	info "先跑 sh install.sh --module tls 用自签顶上，之后补签了再跑一次即可。"
fi
echo
info "注意：这个域名只在你车里的局域网有效（A 记录是内网地址），外面打不开。"
info "要在外面也能看，得另外配隧道（--module tunnel）。"
