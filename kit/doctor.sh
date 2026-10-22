#!/usr/bin/env bash
# 环境自检：换电脑 / 新队友第一次用之前跑一遍，看缺什么、怎么补。
#
# 用法:
#   bash .maestro/kit/e2e.sh --doctor        （在已安装套件的项目里；会连项目配置一起检查）
#   bash <maestro-kit 仓库>/kit/doctor.sh    （只检查机器环境）
#
# 标记: ✓ 正常   ✗ 必需项缺失（退出码 2）   ! 建议处理但不影响运行
# 兼容 macOS 自带 bash 3.2；只依赖 bash / java / adb / maestro / python3。
set -u
KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$KIT_DIR/../.." && pwd)"
FAIL=0; WARN=0
ok()   { echo "  ✓ $*"; }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
warn() { echo "  ! $*"; WARN=$((WARN+1)); }
have() { command -v "$1" >/dev/null 2>&1; }

echo "== 机器环境 =="
echo "  系统: $(uname -s) $(uname -m)   bash: ${BASH_VERSION%%(*}"
case "$(uname -s)" in
  Darwin) ok "macOS（本套件开发和测试所在的系统）" ;;
  Linux)  warn "Linux：脚本用到的都是通用命令，但套件只在 macOS 上测试过；桌面通知会自动跳过" ;;
  *)      warn "$(uname -s)：Windows 请在 Git Bash 或 WSL 里运行；套件没有在该环境测试过" ;;
esac

# python3
if have python3; then ok "python3 $(python3 -c 'import sys;print("%d.%d.%d" % sys.version_info[:3])')（只用标准库）"
else bad "找不到 python3（报告和 lint 需要）。macOS: xcode-select --install；Linux: 用包管理器安装 python3"; fi

# java（Maestro 官方要求 17+）
if have java; then
  JV=$(java -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+)(\.([0-9]+))?.*/\1 \3/')
  set -- $JV; JMAJ="${1:-0}"; [ "$JMAJ" = "1" ] && JMAJ="${2:-0}"
  if [ "${JMAJ}" -ge 17 ] 2>/dev/null; then ok "Java ${JMAJ}（Maestro 要求 17 及以上）"
  else bad "Java 版本是 ${JMAJ}，Maestro 需要 17 及以上；请安装 JDK 17+ 并设置 JAVA_HOME"; fi
  [ -n "${JAVA_HOME:-}" ] && ok "JAVA_HOME=${JAVA_HOME}" || warn "没有设置 JAVA_HOME（官方建议设置；Maestro 会用 PATH 里的 java）"
else bad "找不到 java。请安装 JDK 17+（Maestro 与 Android 构建都需要）"; fi

# maestro
if have maestro; then ok "Maestro $(maestro --version 2>/dev/null | tail -1)"
else bad "找不到 maestro。官方安装：curl -fsSL \"https://get.maestro.mobile.dev\" | bash（macOS 也可用 Homebrew；Windows 见官方文档），装完重开终端"; fi

# adb
if have adb; then ok "$(adb version 2>/dev/null | head -1)"
else bad "找不到 adb。请安装 Android SDK platform-tools，并把它加入 PATH（macOS 默认在 ~/Library/Android/sdk/platform-tools）"; fi

# 设备
if have adb; then
  NDEV=$(adb devices 2>/dev/null | grep -c "device$")
  if [ "$NDEV" -eq 0 ]; then warn "没有在线的设备：请启动模拟器或用 USB 连接真机（adb devices 应显示 device）"
  elif [ "$NDEV" -eq 1 ]; then ok "1 台设备在线: $(adb devices | awk '/device$/ {print $1}')"
  else warn "${NDEV} 台设备在线，运行时必须指定：ANDROID_SERIAL=<序列号> bash .maestro/kit/e2e.sh …（或用 --devices a,b 并行）"; adb devices | grep "device$" | sed 's/^/      /'; fi
fi

# 磁盘
FREE=$(df -k "$HOME" 2>/dev/null | awk 'NR==2 {printf "%.0f", $4/1048576}')
if [ -n "$FREE" ]; then
  if [ "$FREE" -lt 5 ]; then warn "磁盘剩余约 ${FREE} GB，构建 Android/Flutter 项目和模拟器可能不够"; else ok "磁盘剩余约 ${FREE} GB"; fi
fi
have osascript && ok "桌面通知可用（osascript）" || warn "没有 osascript：测试结束时不会弹桌面通知（不影响运行）"

# 项目配置
echo; echo "== 项目 =="
if [ ! -f "$ROOT/.maestro/e2e.config" ]; then
  echo "  （当前不在已安装套件的项目里，跳过项目检查。装进项目用 install.sh）"
else
  APP_ID=""; BUILD_CMD=""; APK_PATH=""; ENV_FILE=".maestro/e2e.env"; PREP_IME=""
  . "$ROOT/.maestro/e2e.config"
  ok "找到 .maestro/e2e.config（套件版本 $(cat "$KIT_DIR/VERSION" 2>/dev/null || echo 未知)）"
  [ -n "$APP_ID" ] && ok "APP_ID=${APP_ID}" || bad "e2e.config 里 APP_ID 为空"
  if [ -f "$ROOT/$ENV_FILE" ]; then ok "账号变量文件 ${ENV_FILE} 存在"
  elif [ -f "$ROOT/.maestro/e2e.env.example" ]; then warn "缺少 ${ENV_FILE}：cp .maestro/e2e.env.example ${ENV_FILE} 并填写（需要账号的用例才用得到）"
  fi
  if [ -n "$BUILD_CMD" ]; then
    FIRST="${BUILD_CMD%% *}"; [ "$FIRST" = "cd" ] && FIRST=$(echo "$BUILD_CMD" | sed -E 's/^cd [^ ]+ *(&&|;) *//' | awk '{print $1}')
    case "$FIRST" in
      ./gradlew) [ -x "$ROOT/gradlew" ] && ok "构建命令用 ./gradlew（存在）" || warn "BUILD_CMD 用 ./gradlew，但项目里没有可执行的 gradlew" ;;
      flutter|fvm) have "$FIRST" && ok "构建命令用 ${FIRST}（已安装）" || warn "BUILD_CMD 用 ${FIRST}，但本机找不到（只在加 --build 时需要）" ;;
      *) have "$FIRST" && ok "构建命令 ${FIRST}（已安装）" || warn "BUILD_CMD 的命令 ${FIRST} 本机找不到（只在加 --build 时需要）" ;;
    esac
  fi
  if have adb; then
    ADBC=(adb); [ -n "${ANDROID_SERIAL:-}" ] && ADBC=(adb -s "$ANDROID_SERIAL")
    if [ "$(adb devices 2>/dev/null | grep -c "device$")" -ge 1 ] && { [ "$(adb devices | grep -c "device$")" -eq 1 ] || [ -n "${ANDROID_SERIAL:-}" ]; }; then
      if [ -n "$APP_ID" ]; then
        "${ADBC[@]}" shell pm list packages 2>/dev/null | grep -q "package:${APP_ID}\$" \
          && ok "设备上已安装 ${APP_ID}" || warn "设备上没有安装 ${APP_ID}：先构建安装，或加 --build"
      fi
      if [ -n "$PREP_IME" ]; then
        "${ADBC[@]}" shell ime list -s 2>/dev/null | tr -d '\r' | grep -qxF "$PREP_IME" \
          && ok "PREP_IME 指定的输入法在设备上存在" || warn "PREP_IME=${PREP_IME} 在这台设备上不存在，运行时会保持当前输入法"
      fi
      CUR=$("${ADBC[@]}" shell settings get secure default_input_method 2>/dev/null | tr -d '\r')
      case "$CUR" in *sogou*|*sohu*|*baidu*|*iflytek*|*pinyin*|*Pinyin*) [ -z "$PREP_IME" ] && warn "当前输入法是中文拼音输入法（${CUR}）：英文输入可能被转成汉字；建议在 e2e.config 设 PREP_IME 指向 Gboard" ;; esac
    fi
  fi
fi

echo
if [ "$FAIL" -gt 0 ]; then echo "结果: ${FAIL} 项必需条件缺失，${WARN} 项建议处理。先解决带 ✗ 的项。"; exit 2
else echo "结果: 必需条件都满足（${WARN} 项建议处理）。"; exit 0; fi
