#!/usr/bin/env python3
"""让 cloudflared 启动前先等本机 dnsmasq 就绪。

现象：开机时 cloudflared 由 S99 启动，此时 127.0.0.1:53 上的 dnsmasq 还没监听，
SRV 查询 `_v2-origintunneld._tcp.argotunnel.com` 返回 connection refused，
cloudflared 打印 "Initiating shutdown" 直接退出，公网域名直到手动 restart 才恢复。

做法：在 procd_open_instance 之前插入一段最多 40 秒的等待，DNS 可用立即继续。
"""
import sys

P = "/etc/init.d/cloudflared"
MARK = "wait-dnsmasq"

snippet = """	# {mark}: S99 启动时 dnsmasq 可能还没监听 127.0.0.1:53，SRV 查询会被拒导致 cloudflared
	# 直接 shutdown。这里最多等 40 秒，DNS 通就立刻继续（不通也照常启动，交给 rc.local 兜底重启）。
	local _i=0
	while [ $_i -lt 20 ]; do
		nslookup argotunnel.com 127.0.0.1 >/dev/null 2>&1 && break
		sleep 2
		_i=$((_i + 1))
	done

""".format(mark=MARK)

s = open(P, encoding="utf-8").read()
if MARK in s:
    print("already patched")
    sys.exit(0)

anchor = '\tprocd_open_instance "$CONF"'
assert anchor in s, "anchor not found"
s = s.replace(anchor, snippet + anchor, 1)
open(P, "w", encoding="utf-8").write(s)
print("patched")
