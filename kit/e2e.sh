#!/usr/bin/env bash
# maestro-kit 运行器（Android）。兼容 macOS 自带 bash 3.2，只依赖 bash / adb / maestro / python3。
#
# 用法（在项目根目录）:
#   bash .maestro/kit/e2e.sh [flow文件或目录] [选项] [-e KEY=VAL ...]
#
# 选项:
#   --build            先构建并安装 APK（读取 e2e.config 的 BUILD_CMD / APK_PATH）
#   --doctor           环境自检（Java/Maestro/adb/设备/项目配置），换电脑后先跑一遍
#   --list             只列出将要运行的 flow，不运行
#   --lint             只做 flow 静态检查，不运行
#   --strict           lint 发现 WARN 时中止
#   --tags a,b         只跑带这些 tag 的 flow（套件自己按 flow 头部 tags 过滤；Maestro 对单个 flow 文件不会应用标签过滤）
#   --exclude-tags a   排除带这些 tag 的 flow
#   --devices a,b      并行：把 flow 轮流分给这些设备，各自独立运行并生成子报告，最后合并（每台设备的 App 状态需一致）
#   --prep-device      运行前准备设备：确认沉浸模式提示、关闭三项动画（也可在 e2e.config 设 PREP_DEVICE=1）
#                      e2e.config 里设 PREP_IME="<包名>/<服务类>" 会在运行期间临时切换输入法，结束后自动恢复（中文拼音输入法会把英文输入转成汉字）
#   --no-notify        结束时不弹通知
#   --no-lint          运行前不做 lint
#   其余参数原样透传给 maestro test（如 -e KEY=VAL）
#
# 环境变量: ANDROID_SERIAL 指定设备；E2E_TIMEOUT 每个 flow 超时秒数（默认读配置，否则 900）
# 配置: .maestro/e2e.config（KEY=VALUE，shell 语法）；.maestro/e2e.env 里的 KEY=VAL 会自动作为 -e 传入
# 产物: .maestro/reports/<时间>/{summary.md,report.html,screenshots/,logcat.txt,maestro_output.txt,artifacts/}
# 退出码: 0 全部通过 | 1 有失败 | 124 有 flow 超时被终止 | 2 用法/环境错误（设备、配置、构建）
set -u

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$KIT_DIR/../.." && pwd)"   # 项目根 = <root>/.maestro/kit/..
cd "$ROOT" || exit 2

# 环境自检：bash .maestro/kit/e2e.sh --doctor
[ "${1:-}" = "--doctor" ] && exec bash "$KIT_DIR/doctor.sh"

# ---------- 配置 ----------
APP_ID=""; BUILD_CMD=""; APK_PATH=""; FLOW_GLOBS="*/*.yaml"; FLOW_TIMEOUT=900
NOTIFY=1; ENV_FILE=".maestro/e2e.env"; BLOCK_PATTERNS=""; LINT_CLEARSTATE_BLOCK=""; PREP_DEVICE=0; PREP_IME=""
[ -f .maestro/e2e.config ] && . .maestro/e2e.config
TIMEOUT_SEC="${E2E_TIMEOUT:-$FLOW_TIMEOUT}"

# ---------- 参数 ----------
DEVICES=""; TARGET=""; DO_BUILD=0; DO_LIST=0; LINT_ONLY=0; STRICT=0; DO_LINT=1; TAGS=""; EXCL_TAGS=""
PASS_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --build) DO_BUILD=1 ;;
    --list) DO_LIST=1 ;;
    --lint) LINT_ONLY=1 ;;
    --strict) STRICT=1 ;;
    --no-lint) DO_LINT=0 ;;
    --no-notify) NOTIFY=0 ;;
    --prep-device) PREP_DEVICE=1 ;;
    --devices) shift; DEVICES="${1:-}" ;;
    --tags) shift; TAGS="${1:-}" ;;
    --exclude-tags) shift; EXCL_TAGS="${1:-}" ;;
    -e) PASS_ARGS+=("-e" "${2:-}"); shift ;;
    -*) PASS_ARGS+=("$1") ;;
    *) if [ -z "$TARGET" ]; then TARGET="$1"; else PASS_ARGS+=("$1"); fi ;;
  esac
  shift
done
[ -n "$TARGET" ] || TARGET=".maestro"

# .maestro/e2e.env 里的 KEY=VAL（忽略空行和 # 注释）转为 -e；命令行已给出同名则以命令行为准
ENV_ARGS=()
if [ -f "$ENV_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"
    already=0
    i=0; while [ $i -lt ${#PASS_ARGS[@]} ]; do
      [ "${PASS_ARGS[$i]}" = "-e" ] && case "${PASS_ARGS[$((i+1))]:-}" in "$key="*) already=1 ;; esac
      i=$((i+1))
    done
    [ $already -eq 0 ] && ENV_ARGS+=("-e" "$line")
  done < "$ENV_FILE"
fi

die() { echo "错误: $*" >&2; exit 2; }

# ---------- flow 列表 ----------
FLOWS=()
if [ -n "${E2E_FLOW_LIST:-}" ] && [ -f "${E2E_FLOW_LIST}" ]; then
  # 并行模式下由父进程分配好的 flow 列表
  while IFS= read -r line; do [ -n "$line" ] && FLOWS+=("$line"); done < "${E2E_FLOW_LIST}"
elif [ -f "$TARGET" ]; then
  FLOWS=("$TARGET")
elif [ -d "$TARGET" ]; then
  if [ "${TARGET%/}" = ".maestro" ]; then
    for g in $FLOW_GLOBS; do
      for f in .maestro/$g; do
        [ -f "$f" ] || continue
        case "$f" in .maestro/subflows/*|.maestro/kit/*|.maestro/reports/*) continue ;; esac
        FLOWS+=("$f")
      done
    done
  else
    for f in "${TARGET%/}"/*.yaml; do [ -f "$f" ] && FLOWS+=("$f"); done
  fi
else
  die "找不到 flow 文件或目录: $TARGET"
fi
[ ${#FLOWS[@]} -gt 0 ] || die "没有找到可运行的 flow（目标: $TARGET, FLOW_GLOBS=${FLOW_GLOBS}）"

# ---------- 标签过滤（套件自己做）----------
if [ -n "$TAGS" ] || [ -n "$EXCL_TAGS" ]; then
  KEPT=()
  while IFS= read -r line; do [ -n "$line" ] && KEPT+=("$line"); done < <(python3 -I - "$TAGS" "$EXCL_TAGS" "${FLOWS[@]}" <<'PYEOF'
import re, sys
inc = [t for t in sys.argv[1].split(",") if t]
exc = [t for t in sys.argv[2].split(",") if t]
skipped = []
for path in sys.argv[3:]:
    tags, in_tags = set(), False
    for l in open(path, encoding="utf-8").read().splitlines():
        if l.strip() == "---":
            break
        if re.match(r"^tags\s*:", l):
            in_tags = True
            continue
        m = re.match(r"^\s*-\s*(\S+)", l)
        if in_tags and m:
            tags.add(m.group(1).strip("\"'"))
        elif in_tags and l.strip() and not l.startswith((" ", "-", "#")):
            in_tags = False
    if inc and not (tags & set(inc)):
        skipped.append(path)
        continue
    if exc and (tags & set(exc)):
        skipped.append(path)
        continue
    print(path)
if skipped:
    if len(skipped) <= 5:
        sys.stderr.write("[tags] 跳过: " + ", ".join(skipped) + "\n")
    else:
        sys.stderr.write("[tags] 按标签过滤，跳过 %d 个 flow\n" % len(skipped))
PYEOF
)
  FLOWS=(${KEPT[@]+"${KEPT[@]}"})
  [ ${#FLOWS[@]} -gt 0 ] || die "标签过滤后没有 flow 可运行（--tags '$TAGS' --exclude-tags '$EXCL_TAGS'）"
fi

if [ $DO_LIST -eq 1 ]; then printf '%s\n' "${FLOWS[@]}"; exit 0; fi

# ---------- lint ----------
if [ $DO_LINT -eq 1 ] || [ $LINT_ONLY -eq 1 ]; then
  LINT_ARGS=()
  [ -n "$LINT_CLEARSTATE_BLOCK" ] && LINT_ARGS+=(--clearstate-block "$LINT_CLEARSTATE_BLOCK")
  python3 -I "$KIT_DIR/e2e_lint.py" ${LINT_ARGS[@]+"${LINT_ARGS[@]}"} "${FLOWS[@]}"
  LRC=$?
  [ $LINT_ONLY -eq 1 ] && exit $LRC
  if [ $LRC -ne 0 ] && [ $STRICT -eq 1 ]; then die "lint 发现问题且指定了 --strict"; fi
fi

# ---------- 并行模式（父进程）----------
if [ -n "$DEVICES" ] && [ -z "${E2E_CHILD:-}" ]; then
  command -v adb >/dev/null 2>&1 || die "找不到 adb"
  IFS=',' read -r -a DEVS <<< "$DEVICES"
  ND=${#DEVS[@]}
  for d in "${DEVS[@]}"; do
    adb devices | grep -q "^${d}[[:space:]]*device" || die "设备 ${d} 不在线（adb devices 里没有）"
  done
  OUT=".maestro/reports/$(date +%Y%m%d_%H%M%S)_parallel"
  mkdir -p "$OUT"; OUT_ABS="$(cd "$OUT" && pwd)"
  i=0
  for F in "${FLOWS[@]}"; do
    echo "$F" >> "$OUT_ABS/flows_${DEVS[$((i % ND))]}.txt"; i=$((i+1))
  done
  echo "并行运行：${#FLOWS[@]} 个 flow 分配到 ${ND} 台设备"
  for d in "${DEVS[@]}"; do [ -f "$OUT_ABS/flows_${d}.txt" ] && echo "  ${d}: $(wc -l < "$OUT_ABS/flows_${d}.txt" | tr -d ' ') 个"; done
  PPIDS=(); PDEVS=(); PREP_ARG=(); [ "$PREP_DEVICE" -eq 1 ] && PREP_ARG=(--prep-device)
  for d in "${DEVS[@]}"; do
    [ -f "$OUT_ABS/flows_${d}.txt" ] || continue
    (
      E2E_CHILD=1 E2E_FLOW_LIST="$OUT_ABS/flows_${d}.txt" E2E_REPORT_DIR="$OUT_ABS/${d}" ANDROID_SERIAL="${d}" \
        bash "$KIT_DIR/e2e.sh" --no-lint --no-notify ${PREP_ARG[@]+"${PREP_ARG[@]}"} ${PASS_ARGS[@]+"${PASS_ARGS[@]}"} 2>&1 \
        | awk -v d="${d}" '{print "[" d "] " $0; fflush()}' | tee "$OUT_ABS/console_${d}.txt"
      exit "${PIPESTATUS[0]}"
    ) &
    PPIDS+=($!); PDEVS+=("$d")
  done
  CODE=0; k=0
  for pid in "${PPIDS[@]}"; do
    wait "$pid"; RC=$?
    echo "${PDEVS[$k]} $RC" >> "$OUT_ABS/exit_codes.txt"
    if [ "$RC" -eq 124 ]; then CODE=124; elif [ "$RC" -ne 0 ] && [ "$CODE" -ne 124 ]; then CODE=1; fi
    k=$((k+1))
  done
  python3 -I - "$OUT_ABS" "$CODE" <<'PYEOF2'
import json, os, re, sys
out, code = sys.argv[1], int(sys.argv[2])
rows, md = [], ["# E2E 并行测试摘要", ""]
codes = dict(l.split() for l in open(os.path.join(out, "exit_codes.txt")).read().splitlines() if l.strip())
verdict = {0: "全部通过", 124: "有设备的 flow 超时"}.get(code, "存在失败")
md += [f"- 结果：**{verdict}**（退出码 {code}）", f"- 报告目录：`{os.path.relpath(out)}`", "", "| 设备 | flow 数 | 退出码 | 子报告 |", "|---|---|---|---|"]
total = 0
for d in sorted(codes):
    n = len(open(os.path.join(out, f"flows_{d}.txt")).read().split())
    total += n
    md.append(f"| {d} | {n} | {codes[d]} | `{d}/summary.md` |")
    rows.append({"device": d, "flows": n, "exit_code": int(codes[d])})
md += [""]
for d in sorted(codes):
    sp = os.path.join(out, d, "summary.md")
    if not os.path.exists(sp):
        md += [f"## {d}：没有生成摘要（见 `console_{d}.txt`）", ""]
        continue
    t = open(sp, encoding="utf-8").read()
    fl = re.findall(r"^## (.+?)：(通过|失败)", t, re.M)
    md += [f"## {d}", ""] + [f"- {n}：{'✅ 通过' if r == '通过' else '❌ 失败'}" for n, r in fl]
    for m in re.finditer(r"- \*\*归类：`(\w+)`\*\* — (.+)", t):
        md.append(f"  - 失败归类 `{m.group(1)}`：{m.group(2)[:120]}")
    md.append("")
open(os.path.join(out, "summary.md"), "w", encoding="utf-8").write("\n".join(md) + "\n")
json.dump({"exit_code": code, "verdict": verdict, "devices": rows, "total_flows": total}, open(os.path.join(out, "result.json"), "w"), ensure_ascii=False, indent=2)
PYEOF2
  echo; echo "并行汇总: .maestro/reports/$(basename "$OUT_ABS")/summary.md  （各设备子报告在其子目录）"
  if [ "$NOTIFY" -eq 1 ] && command -v osascript >/dev/null 2>&1; then
    case "$CODE" in 0) MSG="全部通过";; 124) MSG="超时被终止";; *) MSG="有失败";; esac
    osascript -e "display notification \"${MSG}（并行 ${ND} 台设备）\" with title \"E2E 测试结束\" sound name \"Glass\"" >/dev/null 2>&1 || true
  fi
  exit "$CODE"
fi

# ---------- 设备 ----------
command -v adb >/dev/null 2>&1 || die "找不到 adb，请安装 Android platform-tools 并加入 PATH"
command -v maestro >/dev/null 2>&1 || die "找不到 maestro，请先安装: curl -fsSL https://get.maestro.mobile.dev | bash"
NDEV=$(adb devices | grep -c "device$")
[ "$NDEV" -ge 1 ] || die "没有可用设备，请先启动模拟器或连接真机（adb devices 为空）"
if [ "$NDEV" -gt 1 ] && [ -z "${ANDROID_SERIAL:-}" ]; then
  echo "检测到 $NDEV 台设备，请指定其一：ANDROID_SERIAL=<序列号> bash .maestro/kit/e2e.sh ..." >&2
  adb devices >&2; exit 2
fi
if [ -n "${ANDROID_SERIAL:-}" ]; then
  adb devices | grep -q "^$ANDROID_SERIAL[[:space:]]*device" || die "指定的设备 $ANDROID_SERIAL 不在线"
fi
UDID_ARGS=(); [ -n "${ANDROID_SERIAL:-}" ] && UDID_ARGS=(--udid "$ANDROID_SERIAL")
ADB=(adb); [ -n "${ANDROID_SERIAL:-}" ] && ADB=(adb -s "$ANDROID_SERIAL")

# ---------- 清理（无论成功、失败还是 die 都会执行）----------
ORIG_IME=""; LOGCAT_PID=""
cleanup() {
  [ -n "$LOGCAT_PID" ] && kill "$LOGCAT_PID" 2>/dev/null
  if [ -n "$ORIG_IME" ]; then
    "${ADB[@]}" shell ime set "$ORIG_IME" >/dev/null 2>&1 && echo "已恢复输入法: ${ORIG_IME}"
  fi
}
trap cleanup EXIT

# ---------- 设备准备 ----------
# 全新设备首次使用会弹系统引导（如“Viewing full screen”），它会盖住 App、拦截点击并拖慢用例；动画也会让等待变慢
if [ "$PREP_DEVICE" -eq 1 ]; then
  echo "===== 设备准备 ====="
  "${ADB[@]}" shell settings put secure immersive_mode_confirmations confirmed >/dev/null 2>&1
  for k in window_animation_scale transition_animation_scale animator_duration_scale; do
    "${ADB[@]}" shell settings put global "$k" 0 >/dev/null 2>&1
  done
  echo "已确认沉浸模式提示，并关闭窗口/过渡/动画时长三项动画（这会持久改变设备设置）"
  echo "如需恢复动画：for k in window_animation_scale transition_animation_scale animator_duration_scale; do adb shell settings put global \$k 1.0; done"
fi

# 输入法：中文拼音输入法（搜狗等）会把 Maestro 输入的英文字母当拼音转成汉字（实测 "Buy milk" 变成 "不要"）
if [ -n "$PREP_IME" ]; then
  CUR_IME=$("${ADB[@]}" shell settings get secure default_input_method 2>/dev/null | tr -d '\r')
  if [ "$CUR_IME" != "$PREP_IME" ]; then
    if "${ADB[@]}" shell ime list -s 2>/dev/null | tr -d '\r' | grep -qxF "$PREP_IME"; then
      "${ADB[@]}" shell ime set "$PREP_IME" >/dev/null 2>&1 && ORIG_IME="$CUR_IME" && echo "输入法 ${CUR_IME} -> ${PREP_IME}（结束后自动恢复）"
    else
      echo "警告: 设备上没有输入法 ${PREP_IME}，保持当前输入法 ${CUR_IME}" >&2
    fi
  fi
fi

# ---------- 构建安装 ----------
if [ $DO_BUILD -eq 1 ]; then
  [ -n "$BUILD_CMD" ] || die "指定了 --build 但 e2e.config 没有 BUILD_CMD"
  [ -n "$APK_PATH" ] || die "指定了 --build 但 e2e.config 没有 APK_PATH"
  echo "===== 构建: $BUILD_CMD ====="
  ( eval "$BUILD_CMD" ) || die "构建失败"
  # APK_PATH 支持通配符（如 app/build/outputs/apk/foss/debug/*.apk）：APK 文件名常带版本号或自定义 archivesName，无法预测
  APK_RESOLVED=$(ls -t $APK_PATH 2>/dev/null | head -1)
  [ -n "$APK_RESOLVED" ] && [ -f "$APK_RESOLVED" ] || die "构建后找不到 APK: $APK_PATH"
  APK_PATH="$APK_RESOLVED"
  echo "===== 安装: $APK_PATH ====="
  INSTALL_OUT=$("${ADB[@]}" install -r "$APK_PATH" 2>&1)
  if ! echo "$INSTALL_OUT" | grep -q "^Success"; then
    echo "$INSTALL_OUT" | grep -E "Failure|INSTALL_FAILED|Exception:|error" | head -3 >&2
    echo "设备数据分区剩余空间:" >&2; "${ADB[@]}" shell df -h /data 2>&1 | tail -1 >&2
    echo "提示：INSUFFICIENT_STORAGE 说明设备存储不足；可换空间更大的模拟器，或给 APK 去掉不需要的 ABI 后重新签名" >&2
    die "安装失败（APK $(du -h "$APK_PATH" | cut -f1)）"
  fi
fi
if [ -n "$APP_ID" ]; then
  "${ADB[@]}" shell pm list packages 2>/dev/null | grep -q "package:$APP_ID\$" \
    || die "设备上没有安装 ${APP_ID}，请先构建安装（可加 --build）"
fi

# ---------- 运行 ----------
OUT="${E2E_REPORT_DIR:-.maestro/reports/$(date +%Y%m%d_%H%M%S)${ANDROID_SERIAL:+_${ANDROID_SERIAL}}}"
mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"
"${ADB[@]}" logcat -c
"${ADB[@]}" logcat -v time > "$OUT_ABS/logcat.txt" 2>&1 &
LOGCAT_PID=$!

CODE=0; N=0; TOTAL=${#FLOWS[@]}
: > "$OUT_ABS/maestro_output.txt"
# 把 config 里的 BLOCK_PATTERNS 交给摘要脚本做“被验证拦截”归类
export E2E_BLOCK_PATTERNS="$BLOCK_PATTERNS" E2E_APP_ID="$APP_ID"
for F in "${FLOWS[@]}"; do
  N=$((N+1)); NAME=$(basename "$F" .yaml)
  echo; echo "===== [$N/$TOTAL] $F ====="
  # Maestro 一次跑多个 flow 不打印逐步进度，所以逐个 flow 单独运行；--no-ansi 让 tee 下输出保持纯文本
  maestro test ${UDID_ARGS[@]+"${UDID_ARGS[@]}"} \
    ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} ${PASS_ARGS[@]+"${PASS_ARGS[@]}"} "$F" \
    --test-output-dir "$OUT_ABS/artifacts/$NAME" --no-ansi \
    > >(tee -a "$OUT_ABS/maestro_output.txt") 2>&1 &
  MPID=$!
  ( sleep "$TIMEOUT_SEC"; if kill "$MPID" 2>/dev/null; then touch "$OUT_ABS/.timeout"; echo "
!!! flow 超过 ${TIMEOUT_SEC}s，已强制终止: $F" | tee -a "$OUT_ABS/maestro_output.txt"; fi ) >/dev/null 2>&1 &
  WD=$!
  wait "$MPID"; RC=$?
  pkill -P "$WD" 2>/dev/null; kill "$WD" 2>/dev/null
  [ "$RC" -ne 0 ] && CODE=1
  [ -f "$OUT_ABS/.timeout" ] && break
done
# 必须先结束 logcat 再 wait：logcat 是永不退出的后台进程，裸 wait 会一直等下去
kill "$LOGCAT_PID" 2>/dev/null
wait "$LOGCAT_PID" 2>/dev/null
[ -f "$OUT_ABS/.timeout" ] && CODE=124

echo
if [ "$CODE" -eq 0 ]; then echo "全部 $TOTAL 个 flow 通过"; else echo "有 flow 失败或超时（退出码 ${CODE}）"; fi
[ "$CODE" -ne 0 ] && "${ADB[@]}" exec-out screencap -p > "$OUT_ABS/failure_final_screen.png" 2>/dev/null
python3 -I "$KIT_DIR/e2e_summary.py" "$OUT_ABS" "$CODE" || echo "（生成摘要失败，见上方错误）"
echo "报告目录: $OUT"
echo "摘要: $OUT/summary.md"
echo "网页报告: $OUT/report.html"

# ---------- 完成通知 ----------
if [ "$NOTIFY" -eq 1 ] && command -v osascript >/dev/null 2>&1; then
  case "$CODE" in 0) MSG="全部通过";; 124) MSG="超时被终止";; *) MSG="有失败";; esac
  osascript -e "display notification \"${MSG}（$TOTAL 个 flow）\" with title \"E2E 测试结束\" sound name \"Glass\"" >/dev/null 2>&1 || true
fi
exit "$CODE"
