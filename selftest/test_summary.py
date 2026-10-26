#!/usr/bin/env python3
"""摘要脚本的失败归类单元自测：不需要设备。用合成的 commands.json + logcat.txt 调用 kit/e2e_summary.py。

用法: python3 -I selftest/test_summary.py
覆盖: 被测 App 的 ANR → app_anr；别的 App 的 ANR 不算；没有 ANR 时仍是 assertion_failed。
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SUMMARY = os.path.join(HERE, "..", "kit", "e2e_summary.py")
APP = "com.example.app"

FAILED_ASSERT = [
    {"command": {"launchAppCommand": {}}, "metadata": {"status": "COMPLETED", "timestamp": 1000, "duration": 10}},
    {"command": {"assertConditionCommand": {"label": "等首屏"}},
     "metadata": {"status": "FAILED", "timestamp": 1000, "duration": 10,
                  "error": {"message": "Assertion is false: id: home is visible"}}},
]


def run_case(logcat_lines, commands=None):
    with tempfile.TemporaryDirectory() as d:
        fd = os.path.join(d, "artifacts", "flow1", "t", "flow1")
        os.makedirs(fd)
        json.dump(commands or FAILED_ASSERT, open(os.path.join(fd, "commands.json"), "w"))
        open(os.path.join(d, "logcat.txt"), "w").write("\n".join(logcat_lines) + "\n")
        env = dict(os.environ, E2E_APP_ID=APP)
        subprocess.run([sys.executable, "-I", SUMMARY, d, "1"], env=env, check=True, stdout=subprocess.DEVNULL)
        return json.load(open(os.path.join(d, "result.json")))["flows"][0]["category"]


def anr(pkg):
    return [
        "10-25 16:32:32.329 E/ActivityManager(  585): ANR in %s" % pkg,
        "10-25 16:32:32.329 E/ActivityManager(  585): PID: 10911",
        "10-25 16:32:32.329 E/ActivityManager(  585): Reason: Process ProcessRecord{2c15b2a 10911:%s/u0a570} failed to complete startup" % pkg,
    ]


# 百分比坐标写了小数：Maestro 抛 NumberFormatException（For input string），应归为 script_error 而不是 unknown
NUM_FMT = [
    {"command": {"tapOnPointV2Command": {"label": "点位置"}},
     "metadata": {"status": "FAILED", "timestamp": 1000, "duration": 4,
                  "error": {"message": 'For input string: "22.5"'}}},
]

cases = [
    ("被测 App 的 ANR", anr(APP), "app_anr"),
    ("别的 App 的 ANR", anr("com.other.app"), "assertion_failed"),
    ("百分比小数", [], "script_error", NUM_FMT),
    ("没有 ANR", ["10-25 16:32:00.000 I/ActivityManager(  585): Start proc 1:%s/u0a1" % APP], "assertion_failed"),
]
bad = 0
for case in cases:
    name, lines, want = case[:3]
    got = run_case(lines, case[3] if len(case) > 3 else None)
    ok = got == want
    bad += 0 if ok else 1
    print("[test_summary] %-12s 期望=%-16s 实际=%-16s %s" % (name, want, got, "✅" if ok else "❌"))
print("[test_summary] %s" % ("全部符合" if not bad else "有 %d 项不符" % bad))
sys.exit(1 if bad else 0)
