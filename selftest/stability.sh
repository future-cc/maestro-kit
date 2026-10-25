#!/usr/bin/env bash
# 验证 --repeat / --retry-failed 本身：3 条故意设计的用例（一定通过 / 一定失败 / 随机约一半通过），
# 汇总必须分别判为 稳定通过 / 稳定失败 / 不稳定。
#
# 用法: ANDROID_SERIAL=emulator-5554 bash selftest/stability.sh [重复次数，默认 12]
# 随机用例误判的概率：每次“第一次就过”的概率约 1/2，N 次全过的概率 (1/2)^N（N=12 约 0.02%）；
# 全失败（含重跑）的概率约 (1/4)^N，可忽略。极小概率下本脚本会误报失败，重跑即可。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
N="${1:-12}"
export E2E_PROJECT_ROOT="$HERE/project"
cd "$E2E_PROJECT_ROOT" || exit 2
rm -rf .maestro/reports/*_repeat 2>/dev/null
bash "$HERE/../kit/e2e.sh" .maestro/_stability --repeat "$N" --retry-failed 1 --no-notify --no-lint
echo "[stability] e2e.sh 退出码=$?（有不稳定/失败的用例时应为 1）"
OUT=$(ls -d .maestro/reports/*_repeat | tail -1)
python3 -I - "$OUT/result.json" "$N" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8")); n = int(sys.argv[2])
want = {"STAB_always_pass": "stable_pass", "STAB_always_fail": "stable_fail", "STAB_random_half": "unstable"}
bad = 0
for f in d["flows"]:
    ok = f["verdict"] == want.get(f["name"]) and f["total"] == n
    extra = ""
    if f["name"] == "STAB_always_fail":      # 失败要归类、且每次都重跑过一次
        ok = ok and f["failure_categories"] == {"assertion_failed": n} and all(len(r["attempts"]) == 2 for r in f["runs"])
    if f["name"] == "STAB_always_pass":      # 通过的不应有重跑
        ok = ok and all(len(r["attempts"]) == 1 for r in f["runs"]) and f["pass_rate"] == 1.0
    if f["name"] == "STAB_random_half":
        extra = " 第一次通过 %d / 重跑才通过(flaky) %d / 失败 %d" % (f["passed_first_try"], f["flaky"], f["failed"])
        ok = ok and 0 < f["passed_first_try"] < n
    print("[stability] %-18s 期望=%-11s 实际=%-11s 通过率=%s%s → %s" % (f["name"], want.get(f["name"]), f["verdict"], f["pass_rate"], extra, "✅" if ok else "❌"))
    bad += 0 if ok else 1
print("[stability] 总退出码字段=%s，汇总：%s" % (d["exit_code"], "全部符合" if not bad and d["exit_code"] == 1 else "有不符"))
sys.exit(1 if bad or d["exit_code"] != 1 else 0)
PYEOF
