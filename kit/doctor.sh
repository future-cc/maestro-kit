#!/usr/bin/env bash
# 环境自检：换电脑 / 新队友第一次用之前跑一遍，看缺什么、怎么补。
#
# 用法:
#   bash .maestro/kit/e2e.sh --doctor          在已安装套件的项目里（连项目配置一起检查）
#   bash <maestro-kit 仓库>/kit/doctor.sh      只检查机器环境
#   加 --json 输出机器可读结果（给 AI / 脚本用），格式见下
#
# 标记: ✓ 正常   ✗ 必需项缺失（退出码 2）   ! 建议处理但不影响运行
#
# --json 输出（stdout 只有一个 JSON 对象）:
#   {"version":1,"ok":bool,"counts":{"fail":n,"warn":n},"checks":[
#     {"id":"maestro","status":"ok|fail|warn","message":"...",
#      "fix":"建议的修复（命令或说明）|null",
#      "fix_kind":"command|config|manual|null",
#      "needs_user_approval":bool}]}
#   fix_kind: command=可直接执行的命令；config=要改项目配置文件；manual=只能人工做（装 SDK、启动模拟器…）
#   needs_user_approval=true 表示该修复会下载/执行外部内容、改设备设置或需要用户提供凭证，**必须先问用户**
#
# 兼容 macOS 自带 bash 3.2；只依赖 bash / java / adb / maestro / python3。
set -u
KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$KIT_DIR/../.." && pwd)"
JSON=0; [ "${1:-}" = "--json" ] && JSON=1
FAIL=0; WARN=0
REC="$(mktemp 2>/dev/null || echo /tmp/maestro_kit_doctor.$$)"; : > "$REC"
trap 'rm -f "$REC"' EXIT

# 记录一条检查: rec <状态> <id> <说明> [修复] [修复类型] [是否需要用户批准 0/1]
rec() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" "${5:-}" "${6:-0}" >> "$REC"; }
ok()   { rec ok "$1" "$2"; [ "$JSON" -eq 0 ] && echo "  ✓ $2"; return 0; }
bad()  { FAIL=$((FAIL+1)); rec fail "$1" "$2" "${3:-}" "${4:-manual}" "${5:-0}"; [ "$JSON" -eq 0 ] && { echo "  ✗ $2"; [ -n "${3:-}" ] && echo "      → 修复: $3"; }; return 0; }
warn() { WARN=$((WARN+1)); rec warn "$1" "$2" "${3:-}" "${4:-manual}" "${5:-0}"; [ "$JSON" -eq 0 ] && { echo "  ! $2"; [ -n "${3:-}" ] && echo "      → 建议: $3"; }; return 0; }
say()  { [ "$JSON" -eq 0 ] && echo "$@"; return 0; }
have() { command -v "$1" >/dev/null 2>&1; }

say "== 机器环境 =="
say "  系统: $(uname -s) $(uname -m)   bash: ${BASH_VERSION%%(*}"
case "$(uname -s)" in
  Darwin) ok platform "macOS（本套件开发和测试所在的系统）" ;;
  Linux)  warn platform "Linux：脚本用到的都是通用命令，但套件只在 macOS 上测试过；桌面通知会自动跳过" "先跑 selftest.sh 验证" manual ;;
  *)      warn platform "$(uname -s)：Windows 请在 Git Bash 或 WSL 里运行；套件没有在该环境测试过" "改用 WSL 或 Git Bash" manual ;;
esac

# python3
if have python3; then ok python3 "python3 $(python3 -c 'import sys;print("%d.%d.%d" % sys.version_info[:3])')（只用标准库）"
else bad python3 "找不到 python3（报告和 lint 需要）" "macOS: xcode-select --install（会弹系统窗口，需用户操作）；Linux: 用包管理器安装 python3" manual 1; fi

# java（Maestro 官方要求 17+）
if have java; then
  JV=$(java -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+)(\.([0-9]+))?.*/\1 \3/')
  set -- $JV; JMAJ="${1:-0}"; [ "$JMAJ" = "1" ] && JMAJ="${2:-0}"
  if [ "${JMAJ}" -ge 17 ] 2>/dev/null; then ok java "Java ${JMAJ}（Maestro 要求 17 及以上）"
  else bad java "Java 版本是 ${JMAJ}，Maestro 需要 17 及以上" "安装 JDK 17+ 并设置 JAVA_HOME" manual 1; fi
  if [ -n "${JAVA_HOME:-}" ]; then ok java_home "JAVA_HOME=${JAVA_HOME}"
  else warn java_home "没有设置 JAVA_HOME（官方建议设置；Maestro 会用 PATH 里的 java）" "在 shell 配置里 export JAVA_HOME=<JDK 路径>" manual 0; fi
else bad java "找不到 java" "安装 JDK 17+（Maestro 与 Android 构建都需要）" manual 1; fi

# maestro
if have maestro; then ok maestro "Maestro $(maestro --version 2>/dev/null | tail -1)"
else bad maestro "找不到 maestro" 'curl -fsSL "https://get.maestro.mobile.dev" | bash   （官方安装脚本，会下载并执行远程内容；macOS 也可用 Homebrew；装完重开终端）' command 1; fi

# adb
if have adb; then ok adb "$(adb version 2>/dev/null | head -1)"
else bad adb "找不到 adb" "安装 Android SDK platform-tools 并加入 PATH（macOS 默认在 ~/Library/Android/sdk/platform-tools）" manual 1; fi

# 设备
if have adb; then
  NDEV=$(adb devices 2>/dev/null | grep -c "device$")
  if [ "$NDEV" -eq 0 ]; then warn devices "没有在线的设备" "启动模拟器，或用 USB 连接真机并开启 USB 调试（adb devices 应显示 device）" manual 1
  elif [ "$NDEV" -eq 1 ]; then ok devices "1 台设备在线: $(adb devices | awk '/device$/ {print $1}')"
  else
    warn devices "${NDEV} 台设备在线，运行时必须指定其一: $(adb devices | awk '/device$/ {printf "%s ", $1}')" "ANDROID_SERIAL=<序列号> bash .maestro/kit/e2e.sh …（或用 --devices a,b 并行）" config 0
  fi
fi

# 磁盘
FREE=$(df -k "$HOME" 2>/dev/null | awk 'NR==2 {printf "%.0f", $4/1048576}')
if [ -n "$FREE" ]; then
  if [ "$FREE" -lt 5 ]; then warn disk "磁盘剩余约 ${FREE} GB，构建 Android/Flutter 项目和模拟器可能不够" "清理磁盘（如 Gradle 缓存 ~/.gradle，删除前先确认）" manual 1
  else ok disk "磁盘剩余约 ${FREE} GB"; fi
fi
if have osascript; then ok notify "桌面通知可用（osascript）"
else warn notify "没有 osascript：测试结束时不会弹桌面通知（不影响运行）" "" manual 0; fi

# 项目配置
say ""; say "== 项目 =="
if [ ! -f "$ROOT/.maestro/e2e.config" ]; then
  rec skip project "当前不在已安装套件的项目里，跳过项目检查" "bash <maestro-kit>/install.sh <项目根目录>" command 0
  say "  （当前不在已安装套件的项目里，跳过项目检查。装进项目用 install.sh）"
else
  APP_ID=""; BUILD_CMD=""; APK_PATH=""; ENV_FILE=".maestro/e2e.env"; PREP_IME=""
  . "$ROOT/.maestro/e2e.config"
  ok project_config "找到 .maestro/e2e.config（套件版本 $(cat "$KIT_DIR/VERSION" 2>/dev/null || echo 未知)）"
  if [ -n "$APP_ID" ]; then ok app_id "APP_ID=${APP_ID}"
  else bad app_id "e2e.config 里 APP_ID 为空" "在 .maestro/e2e.config 里填写被测 App 的包名" config 0; fi
  if [ -f "$ROOT/$ENV_FILE" ]; then ok env_file "账号变量文件 ${ENV_FILE} 存在"
  elif [ -f "$ROOT/.maestro/e2e.env.example" ]; then
    # 只有 flow 里真的引用了 e2e.env.example 里的变量，才需要账号文件（离线/无登录的 App 不需要）
    NEEDS=""
    for K in $(grep -oE '^[A-Za-z_][A-Za-z0-9_]*' "$ROOT/.maestro/e2e.env.example"); do
      grep -rqsF --include='*.yaml' --exclude-dir=kit --exclude-dir=reports -e "\${${K}}" "$ROOT/.maestro" && NEEDS="$NEEDS $K"
    done
    if [ -n "$NEEDS" ]; then
      warn env_file "缺少 ${ENV_FILE}，而已有 flow 用到了变量:${NEEDS}" "cp .maestro/e2e.env.example ${ENV_FILE}，再让用户填写真实值（AI 不要编造或代填凭证；该文件已被 .gitignore，不要提交）" command 1
    else
      ok env_file "没有 flow 用到 e2e.env.example 里的变量，暂时不需要 ${ENV_FILE}"
    fi
  fi
  if [ -n "$BUILD_CMD" ]; then
    FIRST="${BUILD_CMD%% *}"; [ "$FIRST" = "cd" ] && FIRST=$(echo "$BUILD_CMD" | sed -E 's/^cd [^ ]+ *(&&|;) *//' | awk '{print $1}')
    case "$FIRST" in
      ./gradlew) if [ -x "$ROOT/gradlew" ]; then ok build_tool "构建命令用 ./gradlew（存在）"; else warn build_tool "BUILD_CMD 用 ./gradlew，但项目里没有可执行的 gradlew" "chmod +x gradlew，或修正 BUILD_CMD" config 0; fi ;;
      flutter|fvm) if have "$FIRST"; then ok build_tool "构建命令用 ${FIRST}（已安装）"; else warn build_tool "BUILD_CMD 用 ${FIRST}，但本机找不到（只在加 --build 时需要）" "安装 ${FIRST}，或不加 --build 而手动安装 APK" manual 1; fi ;;
      *) if have "$FIRST"; then ok build_tool "构建命令 ${FIRST}（已安装）"; else warn build_tool "BUILD_CMD 的命令 ${FIRST} 本机找不到（只在加 --build 时需要）" "安装它，或修正 BUILD_CMD" manual 1; fi ;;
    esac
  fi
  if have adb; then
    ADBC=(adb); [ -n "${ANDROID_SERIAL:-}" ] && ADBC=(adb -s "$ANDROID_SERIAL")
    NOW=$(adb devices 2>/dev/null | grep -c "device$")
    if [ "$NOW" -ge 1 ] && { [ "$NOW" -eq 1 ] || [ -n "${ANDROID_SERIAL:-}" ]; }; then
      if [ -n "$APP_ID" ]; then
        if "${ADBC[@]}" shell pm list packages 2>/dev/null | grep -q "package:${APP_ID}\$"; then ok app_installed "设备上已安装 ${APP_ID}"
        else warn app_installed "设备上没有安装 ${APP_ID}" "bash .maestro/kit/e2e.sh --build <flow 文件>（先构建并安装；会运行构建命令）" command 1; fi
      fi
      if [ -n "$PREP_IME" ]; then
        if "${ADBC[@]}" shell ime list -s 2>/dev/null | tr -d '\r' | grep -qxF "$PREP_IME"; then ok prep_ime "PREP_IME 指定的输入法在设备上存在"
        else warn prep_ime "PREP_IME=${PREP_IME} 在这台设备上不存在，运行时会保持当前输入法" "adb shell ime list -s 查看可用输入法，改 e2e.config 的 PREP_IME" config 0; fi
      fi
      CUR=$("${ADBC[@]}" shell settings get secure default_input_method 2>/dev/null | tr -d '\r')
      case "$CUR" in
        *sogou*|*sohu*|*baidu*|*iflytek*|*pinyin*|*Pinyin*)
          if [ -z "$PREP_IME" ]; then
            warn ime_pinyin "当前输入法是中文拼音输入法（${CUR}）：英文输入可能被转成汉字" "在 e2e.config 设 PREP_IME=\"com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME\"（运行期间临时切换，结束自动恢复；会改设备设置，先问用户）" config 1
          fi ;;
      esac
    fi
  fi
fi

if [ "$JSON" -eq 1 ]; then
  python3 -I - "$REC" "$FAIL" "$WARN" <<'PYEOF'
import json, sys
rows, fail, warn = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
checks = []
for line in open(rows, encoding="utf-8").read().splitlines():
    st, cid, msg, fix, kind, appr = (line.split("\t") + [""] * 6)[:6]
    checks.append({
        "id": cid,
        "status": {"skip": "skip"}.get(st, st),
        "message": msg,
        "fix": fix or None,
        "fix_kind": (kind or None) if fix else None,
        "needs_user_approval": appr == "1",
    })
print(json.dumps({"version": 1, "ok": fail == 0, "counts": {"fail": fail, "warn": warn}, "checks": checks},
                 ensure_ascii=False, indent=2))
PYEOF
else
  echo
  if [ "$FAIL" -gt 0 ]; then echo "结果: ${FAIL} 项必需条件缺失，${WARN} 项建议处理。先解决带 ✗ 的项。"
  else echo "结果: 必需条件都满足（${WARN} 项建议处理）。"; fi
fi
[ "$FAIL" -gt 0 ] && exit 2
exit 0
