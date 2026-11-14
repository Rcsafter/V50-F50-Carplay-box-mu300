#!/bin/sh
# v50-box · 一键安装入口
#
#   sh install.sh --check                 只体检，不改任何东西
#   sh install.sh --all                   安装 base + share + tls
#   sh install.sh --module share          只装某个模块（可重复）
#   sh install.sh --module tls --dry-run  只打印将要执行的操作
#   sh install.sh --rollback /path/etc.tgz 从备份回滚
#
# 所有模块都是幂等的：重复执行不会重复改配置。
set -u

BASE=$(cd "$(dirname "$0")" && pwd)
. "$BASE/lib/common.sh"

MODULES=""
ALL=0
CHECK=0
YES=0
ROLLBACK=""

usage() {
	cat <<EOF
v50-box 安装器

用法：
  sh install.sh --check                    体检（只读）
  sh install.sh --all                      安装 base + share + tls
  sh install.sh --module <名字>            可用模块：base share tls traffic
  sh install.sh --module a --module b      多个模块按顺序装
  sh install.sh --dry-run                  配合上面任一参数，只打印不执行
  sh install.sh --rollback <etc.tgz>       回滚 /etc 备份并重启
  sh install.sh --yes                      不询问（给 AI 自动化用）

环境变量：
  BOX_LAN=100.96.0.1   指定盒子局域网地址（默认自动探测）
  SHARE_DIR=/mnt/...   共享根目录（默认自动挑数据盘）
  TZ_NAME=Asia/Shanghai
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--check) CHECK=1 ;;
		--all) ALL=1 ;;
		--yes|-y) YES=1 ;;
		--dry-run) DRY=1 ;;
		--module) shift; [ $# -gt 0 ] || die "--module 后面要跟模块名"; MODULES="$MODULES $1" ;;
		--rollback) shift; [ $# -gt 0 ] || die "--rollback 后面要跟备份文件"; ROLLBACK="$1" ;;
		-h|--help) usage; exit 0 ;;
		*) die "未知参数：$1（用 --help 看用法）" ;;
	esac
	shift
done

need_root
is_openwrt || die "这不是 OpenWrt（缺 /etc/openwrt_release）。本仓库只支持刷好 OpenWrt 的 V50/MU300。"

# ---------- 回滚 ----------
if [ -n "$ROLLBACK" ]; then
	step "回滚 /etc"
	[ -f "$ROLLBACK" ] || die "备份文件不存在：$ROLLBACK"
	warn "将用 $ROLLBACK 覆盖当前 /etc，然后重启。"
	confirm "确定吗？" || die "已取消"
	tar xzf "$ROLLBACK" -C / || die "解包失败，备份可能损坏"
	ok "已恢复，即将重启"
	sync; reboot
	exit 0
fi

# ---------- 体检 ----------
if [ "$CHECK" = 1 ] || { [ "$ALL" = 0 ] && [ -z "$MODULES" ]; }; then
	sh "$BASE/scripts/00-check.sh"
	[ "$CHECK" = 1 ] && exit 0
	echo
	info "体检完成。要安装请执行：sh install.sh --all"
	exit 0
fi

# ---------- 模块 ----------
[ "$ALL" = 1 ] && MODULES="base share tls"

echo
info "盒子地址：$(lan_ip)　　数据盘：$(disk_root)"
info "模块顺序：$MODULES"
[ "$DRY" = 1 ] && warn "dry-run 模式：只打印，不落盘"

for m in $MODULES; do
	case "$m" in
		base|share|tls|traffic) ;;
		*) die "未知模块：$m" ;;
	esac
	f=$BASE/scripts/10-base.sh
	case "$m" in
		share)   f=$BASE/scripts/20-share.sh ;;
		tls)     f=$BASE/scripts/30-tls.sh ;;
		traffic) f=$BASE/scripts/40-traffic.sh ;;
	esac
	step "模块 $m"
	sh "$f" || die "模块 $m 失败，已停止。修好后再跑一次即可（幂等）。"
done

echo
ok "全部完成。"
info "体检：sh install.sh --check"
