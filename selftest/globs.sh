#!/usr/bin/env bash
# 回归：FLOW_GLOBS 里的通配符不能在当前目录被提前展开。
# 项目根目录下放一个 x/y.yaml（模拟 app/pubspec.yaml），--list 仍必须只列出 .maestro 下的 flow。
# 不需要设备。用法: bash selftest/globs.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/x" "$T/.maestro/smoke" "$T/.maestro/sub"
echo "name: decoy" > "$T/x/y.yaml"
printf 'appId: a.b\n---\n- launchApp\n' > "$T/.maestro/smoke/a.yaml"
printf 'appId: a.b\n---\n- launchApp\n' > "$T/.maestro/sub/b.yaml"
printf 'APP_ID="a.b"\nFLOW_GLOBS="smoke/*.yaml sub/*.yaml"\n' > "$T/.maestro/e2e.config"
OUT=$(cd "$T" && E2E_PROJECT_ROOT="$T" bash "$HERE/../kit/e2e.sh" --list 2>&1)
echo "$OUT"
if echo "$OUT" | grep -q 'smoke/a.yaml' && echo "$OUT" | grep -q 'sub/b.yaml'; then echo "[globs] ✅ 通配符未被提前展开"; else echo "[globs] ❌ 没列出预期的 flow"; exit 1; fi
# 默认值 */*.yaml 同样要生效
printf 'APP_ID="a.b"\nFLOW_GLOBS="*/*.yaml"\n' > "$T/.maestro/e2e.config"
OUT=$(cd "$T" && E2E_PROJECT_ROOT="$T" bash "$HERE/../kit/e2e.sh" --list 2>&1)
echo "$OUT" | grep -q 'smoke/a.yaml' && echo "$OUT" | grep -q 'sub/b.yaml' && echo "[globs] ✅ 默认 */*.yaml 正常" || { echo "$OUT"; echo "[globs] ❌ */*.yaml 失败"; exit 1; }
