#!/bin/sh
# lib/common.sh —— 公共函数。POSIX sh（OpenWrt 的 ash / busybox），不要用 bash 语法。
# 被 install.sh 与 scripts/*.sh source。

DRY=${DRY:-0}
YES=${YES:-0}
BOX_LAN=${BOX_LAN:-}
TPUT=0
[ -t 1 ] && TPUT=1

_c() {
	# $1=color  $2=text
	if [ "$TPUT" = 1 ]; then printf '\033[%sm%s\033[0m\n' "$1" "$2"; else printf '%s\n' "$2"; fi
}
ok()   { _c "32" "  [✓] $*"; }
bad()  { _c "31" "  [✗] $*"; }
warn() { _c "33" "  [!] $*"; }
info() { _c "36" "  · $*"; }
step() { printf '\n\033[1m%s\033[0m\n' "▶ $*"; }
die()  { _c "31" "错误：$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

need_root() {
	[ "$(id -u)" = 0 ] || die "需要 root 权限（OpenWrt 下直接 root 登录）"
}

is_openwrt() {
	[ -f /etc/openwrt_release ]
}

pkg_mgr() {
	if have apk; then echo apk; elif have opkg; then echo opkg; else echo none; fi
}

# 装包：pkg_add <包名...>（已装则跳过；失败只警告不中断）
pkg_add() {
	m=$(pkg_mgr)
	case "$m" in
		apk)  apk add "$@" >/dev/null 2>&1 || warn "apk add $* 失败（可能已安装或源不可用）" ;;
		opkg) opkg install "$@" >/dev/null 2>&1 || warn "opkg install $* 失败（可能已安装或源不可用）" ;;
		*)    warn "没有包管理器，跳过：$*" ;;
	esac
}

# 备份文件到 .bak-<时间戳>，已存在同批备份则不覆盖
backup_file() {
	f=$1
	[ -f "$f" ] || return 0
	b="$f.bak-$(date +%Y%m%d-%H%M)"
	[ -f "$b" ] || cp -f "$f" "$b"
}

# 只在内容不同时写入（幂等）
write_if_diff() {
	dst=$1; shift
	tmp=/tmp/.v50box.$$
	printf '%s\n' "$*" > "$tmp"
	if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then rm -f "$tmp"; return 1; fi
	backup_file "$dst"
	mkdir -p "$(dirname "$dst")"
	cat "$tmp" > "$dst"; rm -f "$tmp"
	return 0
}

# 只在文件里没有这一行时追加（幂等；用文字做标记，不靠行号）
append_once() {
	f=$1; line=$2
	[ -f "$f" ] || touch "$f"
	grep -Fqx "$line" "$f" && return 1
	if [ "$DRY" = 1 ]; then printf '  (dry) append to %s: %s\n' "$f" "$line"; return 0; fi
	backup_file "$f"
	if [ "$f" = /etc/rc.local ]; then
		# rc.local 必须在 exit 0 之前插入，否则不生效
		if grep -q '^exit 0' "$f"; then
			sed -i "\|^exit 0|i $line" "$f"
		else
			printf '%s\n' "$line" >> "$f"
		fi
	else
		printf '%s\n' "$line" >> "$f"
	fi
	return 0
}

# 执行（DRY_RUN=1 时只打印）
run() {
	if [ "$DRY" = 1 ]; then printf '  (dry) %s\n' "$*"; return 0; fi
	sh -c "$*"
}

uciset() { # uciset <config> <key> <value>
	cfg=$1; key=$2; val=$3
	cur=$(uci -q get "$cfg.$key" 2>/dev/null)
	[ "$cur" = "$val" ] && return 1
	if [ "$DRY" = 1 ]; then printf '  (dry) uci set %s.%s=%s\n' "$cfg" "$key" "$val"; return 0; fi
	uci set "$cfg.$key=$val" && uci commit "$cfg"
	return 0
}

# 端口是否有服务在听（busybox 没有 ss，用 netstat 兜底）
port_up() {
	p=$1
	netstat -lnt 2>/dev/null | grep -q ":$p " && return 0
	return 1
}

# 本机 LAN 地址（优先 br-lan，其次第一个非回环 IPv4）
lan_ip() {
	[ -n "$BOX_LAN" ] && { echo "$BOX_LAN"; return; }
	ip -4 addr show br-lan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1
}

disk_root() {
	# 找最大的可写挂载点作为数据盘（常见 /mnt/mu300-disk 或 /mnt/sda1）
	for d in /mnt/mu300-disk /mnt/sda1 /mnt/usb /overlay; do
		[ -d "$d" ] && [ -w "$d" ] && { echo "$d"; return; }
	done
	echo /mnt
}

confirm() {
	[ "$YES" = 1 ] && return 0
	printf '%s [y/N] ' "$*"
	read -r a
	case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}
