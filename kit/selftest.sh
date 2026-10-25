#!/usr/bin/env bash
# 自测运行器：对一组“自测 flow”逐个运行，并与 flow 头部声明的预期比较。
#
# 用法（项目根目录）: bash .maestro/kit/selftest.sh [目录，默认 .maestro/_selftest] [名称过滤子串]
#
# 每个自测 flow 在头部（--- 之前）用注释声明预期，可用的指令：
#   # expect: pass                 期望整体通过（退出码 0）
#   # expect: fail:<归类>          期望失败(退出码 1)且摘要里的归类等于 <归类>，如 fail:element_not_found
#   # expect: lint:W001,W002       期望 lint 命中这些规则（只做 lint，不运行）
#   # expect: timeout              期望超时(退出码 124)
#   # expect: usage                期望用法/环境错误(退出码 2)，配合 # serial: 使用
#   # expect: observe              不判定，只记录实际现象（用于摸清 Maestro 的行为）
#   # timeout: 8                   给这个 flow 设置 E2E_TIMEOUT 秒
#   # env: KEY=VALUE               透传 -e KEY=VALUE（可多行；值可含空格、引号、&、$、中文）
#   # serial: <序列号>             设置 ANDROID_SERIAL（用于测试“设备不在线”）
#   # inject: crash@10             flow 启动 10 秒后对 App 进程发 SIGSEGV（模拟崩溃；需要 debuggable 包）
#   # args: --tags nosuch         追加传给 e2e.sh 的参数（按空格拆分，如 --tags、--no-lint）
#   # lint-forbid: W002           与 lint: 配合：lint 输出里不得出现这些规则（验证 lint-ignore 等）
#   # summary-has: 文字           运行后摘要 summary.md 里必须包含这段文字（如 警告步骤），否则判不符
#   # note: 说明文字                写进结果表
set -u
KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${E2E_PROJECT_ROOT:-$(cd "$KIT_DIR/../.." && pwd)}"   # 可用 E2E_PROJECT_ROOT 指定项目根
cd "$ROOT" || exit 2
DIR="${1:-.maestro/_selftest}"; FILTER="${2:-}"
[ -d "$DIR" ] || { echo "找不到自测目录 $DIR"; exit 2; }
APP_ID=""; [ -f .maestro/e2e.config ] && . .maestro/e2e.config
TS=$(date +%Y%m%d_%H%M%S)
RES=".maestro/reports/selftest_$TS.md"; mkdir -p .maestro/reports
PASS=0; FAILN=0; OBS=0

hdr() { sed -n '1,/^---/p' "$1" | sed -n "s/^#[[:space:]]*$2:[[:space:]]*//p"; }
latest_report() { ls -d .maestro/reports/2* 2>/dev/null | tail -1; }

{
echo "# 自测结果 $TS"; echo
echo "| flow | 预期 | 实际 | 判定 | 备注 |"; echo "|---|---|---|---|---|"
} > "$RES"

for F in $(ls "$DIR"/*.yaml 2>/dev/null | sort); do
  NAME=$(basename "$F" .yaml)
  [ -n "$FILTER" ] && case "$NAME" in *"$FILTER"*) ;; *) continue ;; esac
  EXPECT=$(hdr "$F" expect | head -1); [ -n "$EXPECT" ] || EXPECT="observe"
  TMO=$(hdr "$F" timeout | head -1); SER=$(hdr "$F" serial | head -1)
  INJ=$(hdr "$F" inject | head -1); NOTE=$(hdr "$F" note | head -1); SUMHAS=$(hdr "$F" summary-has | head -1)
  XARGS_LINE=$(hdr "$F" args | head -1); XARGS=(); [ -n "$XARGS_LINE" ] && read -r -a XARGS <<< "$XARGS_LINE"
  ENVS=(); while IFS= read -r l; do [ -n "$l" ] && ENVS+=("-e" "$l"); done < <(hdr "$F" env)
  echo; echo "################ 自测: $NAME  (预期: $EXPECT) ################"

  ACTUAL=""; OK=0
  case "$EXPECT" in
    lint:*)
      OUTP=$(python3 -I "$KIT_DIR/e2e_lint.py" ${LINT_CLEARSTATE_BLOCK:+--clearstate-block "$LINT_CLEARSTATE_BLOCK"} "$F" 2>&1); echo "$OUTP"
      WANT="${EXPECT#lint:}"; MISS=""
      for c in $(echo "$WANT" | tr ',' ' '); do echo "$OUTP" | grep -q "$c " || MISS="$MISS $c"; done
      ACTUAL="命中: $(echo "$OUTP" | grep -o '[WI][0-9][0-9][0-9]' | sort -u | tr '\n' ' ')"
      [ -z "$MISS" ] && OK=1 || ACTUAL="$ACTUAL 缺少:$MISS"
      for c in $(hdr "$F" lint-forbid | tr ',' ' '); do
        if echo "$OUTP" | grep -q "$c "; then OK=0; ACTUAL="$ACTUAL 不该出现:$c"; fi
      done ;;
    *)
      PRE=$(latest_report)
      if [ -n "$INJ" ]; then
        SECS="${INJ#crash@}"
        ( sleep "$SECS"; PID=$(adb shell pidof "$APP_ID" 2>/dev/null | tr -d '\r' | awk '{print $1}')
          [ -n "$PID" ] && adb shell run-as "$APP_ID" kill -SEGV "$PID" >/dev/null 2>&1 \
            && echo "[selftest] 已向 $APP_ID (pid $PID) 注入 SIGSEGV" ) &
        INJPID=$!
      fi
      E2E_TIMEOUT="${TMO:-}" ANDROID_SERIAL="${SER:-${ANDROID_SERIAL:-}}" \
        bash "$KIT_DIR/e2e.sh" "$F" --no-lint --no-notify ${XARGS[@]+"${XARGS[@]}"} ${ENVS[@]+"${ENVS[@]}"}
      RC=$?
      [ -n "$INJ" ] && { kill "$INJPID" 2>/dev/null; wait "$INJPID" 2>/dev/null; }
      NEW=$(latest_report); CAT="-"
      if [ -n "$NEW" ] && [ "$NEW" != "$PRE" ] && [ -f "$NEW/summary.md" ]; then
        CAT=$(sed -n 's/.*归类：`\([a-z_]*\)`.*/\1/p' "$NEW/summary.md" | head -1); [ -n "$CAT" ] || CAT="-"
      fi
      ACTUAL="退出码=$RC 归类=$CAT"
      SUMOK=1
      if [ -n "$SUMHAS" ]; then
        if [ -n "$NEW" ] && [ "$NEW" != "$PRE" ] && grep -qF -- "$SUMHAS" "$NEW/summary.md" 2>/dev/null; then ACTUAL="$ACTUAL 摘要含「${SUMHAS}」"; else SUMOK=0; ACTUAL="$ACTUAL 摘要缺「${SUMHAS}」"; fi
      fi
      case "$EXPECT" in
        pass) [ $RC -eq 0 ] && OK=1 ;;
        fail:*) [ $RC -eq 1 ] && [ "$CAT" = "${EXPECT#fail:}" ] && OK=1 ;;
        timeout) [ $RC -eq 124 ] && OK=1 ;;
        usage) [ $RC -eq 2 ] && OK=1 ;;
        observe) OK=2 ;;
      esac
      [ "$SUMOK" -eq 0 ] && [ "$OK" -eq 1 ] && OK=0 ;;
  esac
  if [ $OK -eq 1 ]; then V="✅ 符合"; PASS=$((PASS+1)); elif [ $OK -eq 2 ]; then V="👁 观察"; OBS=$((OBS+1)); else V="❌ 不符"; FAILN=$((FAILN+1)); fi
  echo "[selftest] $NAME: 预期=$EXPECT 实际=$ACTUAL → $V"
  echo "| $NAME | $EXPECT | $ACTUAL | $V | $NOTE |" >> "$RES"
done
echo; echo "自测汇总: 符合 $PASS, 不符 $FAILN, 仅观察 $OBS   结果表: $RES"
echo "" >> "$RES"; echo "汇总：符合 ${PASS}，不符 ${FAILN}，仅观察 $OBS" >> "$RES"
[ $FAILN -eq 0 ]
