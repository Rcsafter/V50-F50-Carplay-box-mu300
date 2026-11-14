#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""车机视频浮窗：后台开关补丁（幂等）

做三件事：
1) /usr/bin/dashplay-switch 增加 video-on / video-off / video-status；
2) /usr/bin/playport-video-inject 每次运行按 UCI 写 dist/hud-video.json（车机页面轮询它做即时开关）；
3) LuCI 的 DashPlay 开关页增加「车机画面视频浮窗」勾选项。
"""

import os
import sys

SW = "/usr/bin/dashplay-switch"
INJ = "/usr/bin/playport-video-inject"
LUC = "/www/luci-static/resources/view/dashplay-switch.js"


def patch_switch():
    s = open(SW, encoding="utf-8").read()
    if "video-status" in s:
        print("dashplay-switch: 已有 video-* 子命令，跳过")
        return
    anchor = "status)\n\tif ps | grep -q \"[s]upervisor_openwrt.py\""
    assert anchor in s, "dashplay-switch 找不到 status) 锚点"
    block = """video-on)
	uci set dashplay.main.video_pane=1; uci commit dashplay
	/usr/bin/playport-video-inject >/dev/null 2>&1
	echo 1
	;;
video-off)
	uci set dashplay.main.video_pane=0; uci commit dashplay
	/usr/bin/playport-video-inject >/dev/null 2>&1
	echo 0
	;;
video-status)
	on=$(uci -q get dashplay.main.video_pane); [ -z "$on" ] && on=1
	echo "$on"
	;;
"""
    s = s.replace(anchor, block + anchor, 1)
    s = s.replace(
        "usage: $0 on|off|status|",
        "usage: $0 on|off|status|video-on|video-off|video-status|",
        1,
    )
    open(SW, "w", encoding="utf-8").write(s)
    print("dashplay-switch: 已增加 video-on / video-off / video-status")


def patch_injector():
    s = open(INJ, encoding="utf-8").read()
    if "hud-video.json" in s:
        print("video-inject: 已写状态文件，跳过")
    else:
        assert "import glob" in s, "video-inject 找不到 import 锚点"
        s = s.replace("import glob\n", "import glob\nimport subprocess\n", 1)
        func = '''

def write_state():
    """车机页面每 3 秒读一次 /hud-video.json，用于后台开关即时生效。

    只改这个 json、不改 index.html，所以开关两个方向都不需要刷新车机页面。
    """
    try:
        out = subprocess.check_output(
            ["uci", "-q", "get", "dashplay.main.video_pane"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
    except Exception:
        out = ""
    on = 0 if out == "0" else 1
    path = os.path.join(DIST, "hud-video.json")
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as fp:
            fp.write('{"on":%d}' % on)
        os.replace(tmp, path)
        try:
            os.chmod(path, 0o644)
        except OSError:
            pass
    except OSError as err:
        print("写状态文件失败: %s" % err)
    return on

'''
        anchor = "\n\ndef read(path):"
        assert anchor in s, "video-inject 找不到 read() 锚点"
        s = s.replace(anchor, func + anchor, 1)
        anchor2 = '    if "--target" in args:'
        assert anchor2 in s, "video-inject 找不到 main 锚点"
        s = s.replace(anchor2, "    write_state()\n\n" + anchor2, 1)
        open(INJ, "w", encoding="utf-8").write(s)
        print("video-inject: 已增加状态文件写入")

    # 语法自检
    import ast
    ast.parse(open(INJ, encoding="utf-8").read())
    os.chmod(INJ, 0o755)


def patch_luci():
    s = open(LUC, encoding="utf-8").read()
    if "handleVideo" in s:
        print("luci: 已有视频浮窗开关，跳过")
        return

    a1 = """			fs.exec('/usr/bin/dashplay-switch', [ 'weather-city-status' ]).then(function(res) {
				return (((res && res.stdout) || '').trim());
			}).catch(function() { return ''; })"""
    assert a1 in s, "luci 找不到 weather-city-status 锚点"
    s = s.replace(a1, a1 + """,
			fs.exec('/usr/bin/dashplay-switch', [ 'video-status' ]).then(function(res) {
				return (((res && res.stdout) || '').trim() !== '0');
			}).catch(function() { return true; })""", 1)

    a2 = "\t\tvar city = state[4];"
    assert a2 in s, "luci 找不到 city 锚点"
    s = s.replace(a2, a2 + "\n\t\tvar video = state[5];", 1)

    a3 = "\trender: function(state) {"
    assert a3 in s, "luci 找不到 render 锚点"
    handler = """	// 车机视频浮窗开关
	handleVideo: function(on) {
		return fs.exec('/usr/bin/dashplay-switch', [ on ? 'video-on' : 'video-off' ]).then(function() {
			ui.addNotification(null, E('p', {},
				on ? _('已开启：车机画面出现视频圆钮') : _('已关闭：车机画面的视频圆钮已隐藏')), 'info');
		}).catch(function(e) {
			ui.addNotification(null, E('p', {}, _('切换失败：') + ((e && e.message) ? e.message : e)), 'error');
		});
	},

"""
    s = s.replace(a3, handler + a3, 1)

    a4 = """			]))
		]);
	}
});"""
    assert a4 in s, "luci 找不到结尾锚点"
    section = """			])),

			E('h2', {}, _('车机画面视频浮窗')),
			E('div', { 'class': 'cbi-section' }, [
				E('label', {
					'style': 'display:flex;align-items:center;gap:10px;padding:6px 0 10px;font-size:15px;cursor:pointer'
				}, [
					E('input', {
						'type': 'checkbox',
						'checked': video,
						'change': function(ev) {
							self.handleVideo(ev.target.checked);
						}
					}),
					E('span', {}, _('在车机画面显示视频浮窗'))
				]),
				E('div', { 'class': 'cbi-section-descr' },
					_('开启后车机画面右下角会出现一个 ▶ 圆钮。点开可在小窗里看网页视频（B站、优酷等）或共享目录里的本地视频；圆钮可拖动，松手自动吸附到最近的角落并记住位置。关闭后按钮立即隐藏，车机页面不用刷新。'))
			])
		]);
	}
});"""
    s = s.replace(a4, section, 1)
    open(LUC, "w", encoding="utf-8").write(s)
    print("luci: 已增加「车机画面视频浮窗」开关")


if __name__ == "__main__":
    patch_switch()
    patch_injector()
    patch_luci()
