#!/usr/bin/env bash
# 在套件仓库里一条命令跑全部自测（被测对象：Android 模拟器自带的“设置”应用，不依赖任何项目）。
#
# 用法: ANDROID_SERIAL=emulator-5554 bash selftest/run.sh [名称过滤子串]
# 前提: 只连着一台设备，或用 ANDROID_SERIAL 指定；已装 maestro / adb / python3。
# 原理: 用 E2E_PROJECT_ROOT 把“项目根”指向 selftest/project，其余照常。
# 副作用: 运行期间会临时切换输入法（结束自动恢复）；会反复启动/停止“设置”应用；不改其他设置。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
export E2E_PROJECT_ROOT="$HERE/project"
exec bash "$HERE/../kit/selftest.sh" .maestro/_selftest "${1:-}"
