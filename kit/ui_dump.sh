#!/usr/bin/env bash
# 列出当前屏幕上有文字/无障碍描述的元素，写 flow 时用来找定位文字和位置点击的百分比坐标。只读，不改设备。
#
# 用法（装进项目后）: bash .maestro/kit/ui_dump.sh [--xml]
#   设备：多台时用 ANDROID_SERIAL=<序列号> 指定（adb devices 查看）
#   --xml  直接输出原始元素树（uiautomator dump 的 XML）
#
# 输出每行：文字（无障碍描述优先）｜中心点百分比 x%,y%（整数，可直接写进 tapOn 的 point）｜左上角像素坐标
#
# 说明：
# - Maestro 驱动进程残留时，uiautomator dump 会被系统杀掉（"Killed"），所以先停掉驱动进程（只停进程，不卸载）。
# - 小米/红米真机上不要用 maestro hierarchy（每次都弹安装确认），用本脚本（见 AGENTS.md 硬性规则 11）。
# - Flutter / 自绘页面的元素只有无障碍描述（content-desc），没有 resource-id；网页（WebView）里的文字通常看不到。
set -u
XML=0; [ "${1:-}" = "--xml" ] && XML=1
ADB=(adb); [ -n "${ANDROID_SERIAL:-}" ] && ADB=(adb -s "$ANDROID_SERIAL")
command -v adb >/dev/null 2>&1 || { echo "错误: 找不到 adb（见 docs/SETUP.md）" >&2; exit 2; }
N=$("${ADB[@]}" devices 2>/dev/null | awk 'NR>1 && $2=="device"' | wc -l | tr -d ' ')
[ "$N" -ge 1 ] || { echo "错误: 没有在线设备（adb devices）" >&2; exit 2; }
[ "$N" -eq 1 ] || [ -n "${ANDROID_SERIAL:-}" ] || { echo "错误: 有 $N 台设备，请用 ANDROID_SERIAL=<序列号> 指定" >&2; exit 2; }

"${ADB[@]}" shell am force-stop dev.mobile.maestro >/dev/null 2>&1
"${ADB[@]}" shell am force-stop dev.mobile.maestro.test >/dev/null 2>&1
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
( "${ADB[@]}" exec-out uiautomator dump /dev/stdout > "$TMP" 2>/dev/null ) &
P=$!; ( sleep 20; kill "$P" 2>/dev/null ) >/dev/null 2>&1 & W=$!
wait "$P" 2>/dev/null; kill "$W" 2>/dev/null; wait "$W" 2>/dev/null
grep -q "<hierarchy" "$TMP" || { echo "错误: 没取到元素树（设备锁屏、或系统拦截了 uiautomator）" >&2; exit 1; }
[ "$XML" -eq 1 ] && { cat "$TMP"; exit 0; }
SIZE=$("${ADB[@]}" shell wm size 2>/dev/null | tr -d '\r' | grep -Eo '[0-9]+x[0-9]+' | tail -1)
python3 -I - "$TMP" "${SIZE:-0x0}" <<'PYEOF'
import re, sys
x = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
w, h = (int(v) for v in sys.argv[2].split("x"))
rows = []
for n in re.findall(r"<node[^>]*>", x):
    t = re.search(r' content-desc="([^"]*)"', n)
    t = t.group(1) if t and t.group(1) else (re.search(r' text="([^"]*)"', n).group(1) if re.search(r' text="([^"]*)"', n) else "")
    t = t.replace("&#10;", " / ").replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").strip()
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
    if not t or not b:
        continue
    x1, y1, x2, y2 = (int(v) for v in b.groups())
    pct = "%d%%,%d%%" % (round((x1 + x2) / 2 * 100 / w), round((y1 + y2) / 2 * 100 / h)) if w and h else "?"
    rows.append((t[:48], pct, "%d,%d" % (x1, y1)))
if not rows:
    print("（屏幕上没有带文字或描述的元素；可能是纯图片/视频/WebView 页面，改用截图）")
for t, pct, xy in rows:
    print("%-50s｜中心 %-10s｜左上角 %s" % (t, pct, xy))
PYEOF
