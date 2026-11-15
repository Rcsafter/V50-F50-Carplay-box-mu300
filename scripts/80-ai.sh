#!/bin/sh
# 80-ai.sh —— 车机 AI 助手 + 短信推送（可选，自开发功能）
#
# 盒子上跑一个常驻 AI 助手（picoclaw 一类），能读运营商短信、按你的指令回复，
# 并把结果推到微信。配合 traffic 模块，就是「开机自动查流量，回复直接到手机上」。
#
# 这里的 AI 能力来自镜像自带的助手程序，本模块只做健康检查与接线，不包含模型和密钥。
set -u
BASE=$(cd "$(dirname "$0")/.." && pwd)
. "$BASE/lib/common.sh"

step "检查助手组件"
found=0
for d in /etc/picoclaw /opt/picoclaw /root/.picoclaw; do
	[ -d "$d" ] && { ok "找到 $d"; found=1; }
done
if [ "$found" = 0 ]; then
	warn "这个镜像没带 AI 助手（没有 /etc/picoclaw 之类）"
	info "AI 助手属于镜像自带能力，不是本仓库安装的，跳过不影响其他功能"
	info "如果你只想「开机查流量 + 短信到微信」，装 traffic 模块就够了（需要助手在）"
	exit 0
fi

SEC=/etc/picoclaw/.security.yml
step "密钥文件权限"
# 里面有 API key，权限必须是 600，否则同网段的进程都能读。
if [ -f "$SEC" ]; then
	m=$(ls -l "$SEC" | awk '{print $1}')
	if [ "$m" = "-rw-------" ]; then
		ok "$SEC 权限 600"
	else
		if [ "$DRY" = 1 ]; then
			info "(dry) chmod 600 $SEC"
		else
			chmod 600 "$SEC" && ok "已收紧到 600（原 $m）"
		fi
	fi
	# 只判断有没有配置，不打印内容
	if grep -q "api_key" "$SEC" 2>/dev/null; then
		cnt=$(grep -c "api_key" "$SEC")
		ok "配置了 $cnt 处 api_key"
	else
		warn "没找到 api_key —— 助手跑起来也没法回复，需要填自己的 key"
	fi
else
	warn "没有 $SEC（助手还没初始化过，先启动一次让它生成）"
fi

step "短信发送组件"
SMSEND=""
for s in /root/.picoclaw/workspace/sms-send /usr/bin/mu300-sms /usr/bin/sms-send; do
	[ -x "$s" ] && { SMSEND=$s; break; }
done
if [ -n "$SMSEND" ]; then
	ok "$SMSEND"
else
	warn "没有发短信的可执行文件，traffic 模块会用不了"
fi

step "启动并设为自启"
SVC=""
for s in /etc/init.d/picoclaw /etc/init.d/ai-assistant; do
	[ -x "$s" ] && { SVC=$s; break; }
done
if [ -n "$SVC" ]; then
	run "$SVC enable"
	run "$SVC restart"
else
	warn "没有启动脚本，可能需要手动拉起"
fi

if [ "$DRY" = 1 ]; then
	info "dry-run 结束"; exit 0
fi

step "校验"
sleep 8
n=$(ps w 2>/dev/null | grep -c "[p]icoclaw")
if [ "$n" -ge 1 ]; then
	ok "$n 个助手进程在跑"
else
	warn "没看到进程：$SVC start 后看 tail /root/.picoclaw/logs/launcher.log"
fi
if [ -f /root/.picoclaw/logs/gateway.log ]; then
	ok "网关日志存在（最后一条：$(tail -c 400 /root/.picoclaw/logs/gateway.log 2>/dev/null | grep -o '"message":"[^"]*"' | tail -1 | cut -c1-80)）"
fi

echo
info "接下来装 traffic 模块，就能「开机自动查流量 + 回复推到微信」"
info "别把钥匙外传：$SEC 里是你的 API key，不要提交到任何仓库"
