#!/bin/sh
# 10-base.sh —— 基础设置：时区、日志、主机名、/etc 备份
# 幂等：重复跑只会补缺失项。
set -u
BASE=$(cd "$(dirname "$0")/.." && pwd)
. "$BASE/lib/common.sh"

TZ_NAME=${TZ_NAME:-Asia/Shanghai}

step "时区"
cur_tz=$(uci -q get system.@system[0].timezone 2>/dev/null)
cur_zn=$(uci -q get system.@system[0].zonename 2>/dev/null)
if [ "$cur_tz" = "CST-8" ] && [ "$cur_zn" = "$TZ_NAME" ]; then
	ok "已经是 $TZ_NAME（$(date '+%F %T %Z')）"
else
	info "当前：${cur_zn:-未知} / ${cur_tz:-未知}"
	if uciset system @system[0].timezone "CST-8"; then :; fi
	if uciset system @system[0].zonename "$TZ_NAME"; then :; fi
	run "/etc/init.d/system reload"
	run "/etc/init.d/cron restart"
	if [ "$DRY" != 1 ]; then
		ok "已改为 $TZ_NAME（$(date '+%F %T %Z')）"
	fi
fi

step "日志：关掉 DNS 查询日志"
# dnsmasq 的 logqueries 会把 logread 环形缓冲刷满，重启/断网的原因就查不到了。
if [ "$(uci -q get dhcp.@dnsmasq[0].logqueries 2>/dev/null)" = "0" ]; then
	ok "logqueries 已是 0"
else
	uciset dhcp @dnsmasq[0].logqueries "0"
	run "/etc/init.d/dnsmasq restart"
	[ "$DRY" = 1 ] || ok "已关闭查询日志（保留错误与 DHCP 事件）"
fi

step "日志：限制 syslog 体积"
# 默认 64K 太小，几百行就滚掉了；给到 256K 能回溯一两天。
cur=$(uci -q get system.@system[0].log_size 2>/dev/null)
if [ -n "$cur" ] && [ "$cur" -ge 256 ] 2>/dev/null; then
	ok "log_size 已经是 ${cur}K"
else
	uciset system @system[0].log_size "256"
	run "/etc/init.d/log restart"
	[ "$DRY" = 1 ] || ok "log_size -> 256K"
fi

step "主机名"
cur_host=$(uci -q get system.@system[0].hostname 2>/dev/null)
if [ -z "$cur_host" ] || [ "$cur_host" = "OpenWrt" ]; then
	uciset system @system[0].hostname "v50box"
	[ "$DRY" = 1 ] || ok "hostname -> v50box"
else
	ok "hostname 保持 $cur_host"
fi

step "备份 /etc（回滚用）"
# 只保留最近 5 份，避免把小分区塞满。
BKDIR=/root/v50-box-backup
if [ "$DRY" = 1 ]; then
	info "(dry) tar czf $BKDIR/etc-<时间>.tgz /etc"
else
	mkdir -p "$BKDIR"
	f="$BKDIR/etc-$(date +%Y%m%d-%H%M).tgz"
	tar czf "$f" /etc >/dev/null 2>&1 && ok "已备份到 $f" || warn "备份失败（继续，不影响其他步骤）"
	ls -1t "$BKDIR"/etc-*.tgz 2>/dev/null | tail -n +6 | while read -r old; do rm -f "$old"; done
	info "回滚命令：sh install.sh --rollback $f"
fi

step "自检"
[ "$DRY" = 1 ] && { info "dry-run 结束"; exit 0; }
date '+  时间：%F %T %Z'
[ "$(uci -q get dhcp.@dnsmasq[0].logqueries 2>/dev/null)" = "0" ] && ok "DNS 查询日志已关" || warn "DNS 查询日志未关"
exit 0
