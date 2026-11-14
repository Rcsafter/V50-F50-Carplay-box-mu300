#!/bin/sh
# v50-box · 一键安装入口
#
#   sh install.sh                     体检 + 逐项询问要装哪些功能
#   sh install.sh --check             只体检，不改任何东西
#   sh install.sh --all               装免凭据、不花钱的那几项（base share tls dashplay hover）
#   sh install.sh --module share      只装某个模块（可重复）
#   sh install.sh --module tls --dry-run  只打印将要执行的操作
#   sh install.sh --rollback /root/.../etc-xxx.tgz   从备份回滚
#
# 所有模块都是幂等的：重复执行不会重复改配置。
set -u

BASE=$(cd "$(dirname "$0")" && pwd)
. "$BASE/lib/common.sh"

# 全部可选功能，按建议顺序执行
ALL_FEATURES="base share tls dashplay hover traffic tunnel ai"
# --all 只装这些：不需要额外凭据、不花钱
SAFE_SET="base share tls dashplay hover"

MODULES=""
ALL=0
CHECK=0
YES=0
ROLLBACK=""

mod_title() {
	case "$1" in
		base)     echo "基础设置" ;;
		share)    echo "车内共享" ;;
		tls)      echo "HTTPS 证书" ;;
		dashplay) echo "DashPlay 投屏" ;;
		hover)    echo "车机悬浮视频窗" ;;
		traffic)  echo "开机查流量" ;;
		tunnel)   echo "外网隧道" ;;
		ai)       echo "AI 助手推送" ;;
		*)        echo "$1" ;;
	esac
}

mod_desc() {
	case "$1" in
		base)     echo "时区/日志/主机名/备份 —— 必装，其他模块都依赖它" ;;
		share)    echo "手机车机直接播盘里的电影，支持拖进度条" ;;
		tls)      echo "让局域网入口不再显示「不安全」" ;;
		dashplay) echo "投屏主体（作者：抖音「一只小黑狗」），这里只设开机自启" ;;
		hover)    echo "车机画面右下角一个可拖动圆钮，点开看视频" ;;
		traffic)  echo "开机自动发「查流量」短信（约 0.1 元/条，6 小时去重）" ;;
		tunnel)   echo "cloudflared 挂公网域名（需要你自己的 tunnel 凭据）" ;;
		ai)       echo "检查助手进程与密钥权限，配合 traffic 推送短信到微信" ;;
	esac
}

mod_script() {
	case "$1" in
		base)     echo 10-base.sh ;;
		share)    echo 20-share.sh ;;
		tls)      echo 30-tls.sh ;;
		traffic)  echo 40-traffic.sh ;;
		dashplay) echo 50-dashplay.sh ;;
		hover)    echo 60-hover.sh ;;
		tunnel)   echo 70-tunnel.sh ;;
		ai)       echo 80-ai.sh ;;
	esac
}

usage() {
	cat <<EOF
v50-box 安装器

用法：
  sh install.sh                       体检，然后逐项问你要装哪些
  sh install.sh --check               只体检（只读）
  sh install.sh --all                 装 $SAFE_SET
  sh install.sh --module <名字>        可用：$ALL_FEATURES
  sh install.sh --list                只列功能清单
  sh install.sh --dry-run             配合上面，只打印不执行
  sh install.sh --rollback <etc.tgz>  回滚 /etc 备份并重启
  sh install.sh --yes                 不询问（给 AI 自动化用）

环境变量：
  BOX_LAN=100.96.0.1   指定盒子局域网地址（默认自动探测）
  SHARE_DIR=/mnt/...   共享根目录（默认自动挑数据盘）
  TZ_NAME=Asia/Shanghai
EOF
}

list_features() {
	for m in $ALL_FEATURES; do
		printf '%-10s %s\n' "$m" "$(mod_desc "$m")"
	done
}

while [ $# -gt 0 ]; do
	case "$1" in
		--check) CHECK=1 ;;
		--all) ALL=1 ;;
		--yes|-y) YES=1 ;;
		--dry-run) DRY=1 ;;
		--list) list_features; exit 0 ;;
		--module) shift; [ $# -gt 0 ] || die "--module 后面要跟模块名"; MODULES="$MODULES $1" ;;
		--rollback) shift; [ $# -gt 0 ] || die "--rollback 后面要跟备份文件"; ROLLBACK="$1" ;;
		-h|--help) usage; exit 0 ;;
		*) die "未知参数：$1（用 --help 看用法）" ;;
	esac
	shift
done

need_root
is_openwrt || die "这不是 OpenWrt（缺 /etc/openwrt_release）。本仓库只支持刷好 OpenWrt 的 V50/F50（MU300）。"

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

# ---------- 只体检 ----------
if [ "$CHECK" = 1 ]; then
	sh "$BASE/scripts/00-check.sh"
	exit 0
fi

# ---------- 选择要装的功能 ----------
if [ "$ALL" = 1 ]; then
	MODULES=$SAFE_SET
fi

if [ -z "$MODULES" ]; then
	sh "$BASE/scripts/00-check.sh"
	echo

	if [ "$YES" = 1 ]; then
		MODULES=$SAFE_SET
		info "--yes 模式：装默认的 $SAFE_SET"
	elif [ ! -t 0 ]; then
		die "当前不是交互终端，没法逐项问你。请用 --all，或 --module 指定要装的功能（--list 看清单）"
	else
		printf '\033[1m%s\033[0m\n' "▶ 要装哪些功能？"
		info "回车=跳过，y=装。不装任何东西也能正常用 DashPlay。"
		echo
		for m in $ALL_FEATURES; do
			printf '  \033[1m%-9s\033[0m %s\n' "$m" "$(mod_desc "$m")"
			printf '            装吗？[y/N] '
			read -r a
			case "$a" in y|Y) MODULES="$MODULES $m" ;; *) echo "            跳过" ;; esac
			echo
		done
	fi
	[ -z "$MODULES" ] && { info "什么都没选，退出。随时可以重跑本脚本。"; exit 0; }
fi

# ---------- 执行 ----------
echo
info "盒子地址：$(lan_ip)　　数据盘：$(disk_root)"
info "将按顺序执行：$MODULES"
[ "$DRY" = 1 ] && warn "dry-run 模式：只打印，不落盘"
[ "$YES" = 0 ] && [ "$DRY" = 0 ] && { confirm "开始？" || die "已取消"; }

for m in $MODULES; do
	f=$BASE/scripts/$(mod_script "$m")
	[ -n "$(mod_script "$m")" ] || die "未知模块：$m（可用：$ALL_FEATURES）"
	[ -f "$f" ] || die "缺脚本：$f，请重新拉一次代码"
	step "模块 $m —— $(mod_title "$m")"
	sh "$f" || die "模块 $m 失败，已停止。修好后再跑一次即可（幂等）。"
done

echo
ok "全部完成。"
info "体检：sh install.sh --check"
info "只想补装某一项：sh install.sh --module tunnel"
