#!/usr/bin/env python3
"""稳定性编排：把每个 flow 连续跑 N 次（--repeat），失败时自动重跑（--retry-failed），汇总通过率与失败原因。只用标准库。

由 e2e.sh 在给了 --repeat / --retry-failed 时调用，不建议单独运行。
每一次运行都是一次独立的 `bash e2e.sh <flow>`，各有自己的报告目录：
    <out>/runs/<flow>/r01_a1/   第 1 次重复的第 1 次尝试
    <out>/runs/<flow>/r01_a2/   第 1 次重复失败后的重跑（只有失败时才有）
汇总写在 <out>/summary.md 和 <out>/result.json。

判定规则（每次“重复”）:
    通过   第一次尝试就通过
    不稳定 第一次失败，重跑后通过 —— 不算通过
    失败   第一次和所有重跑都失败
每个 flow 的结论:
    稳定通过  N 次重复全部“通过”
    稳定失败  N 次重复全部“失败”
    不稳定    其余情况（有通过也有失败，或出现过“不稳定”）
通过率 = 第一次尝试就通过的次数 / N（重跑才通过的不算）。

用法: python3 -I e2e_repeat.py --out DIR --e2e PATH/e2e.sh --repeat N --retry K --flows F [F ...] [-- 透传给 e2e.sh 的参数]
退出码: 0 所有 flow 稳定通过 | 1 有不稳定或失败 | 124 有运行超时
"""
import argparse
import json
import os
import subprocess
import sys
import time

GATE = 20  # 新用例连续全过多少次才算够入回归库
SHOW_MAX = 15  # 摘要里每个用例最多列出多少次“不是一次过”的运行（完整列表在 result.json）


def parse():
    argv = sys.argv[1:]
    passthrough = []
    if "--" in argv:
        i = argv.index("--")
        argv, passthrough = argv[:i], argv[i + 1:]
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--e2e", required=True)
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--retry", type=int, default=0)
    ap.add_argument("--flows", nargs="+", required=True)
    a = ap.parse_args(argv)
    a.passthrough = passthrough
    return a


def read_result(report_dir):
    """读子运行的 result.json，取第一个 flow 的失败信息；读不到（如超时被杀）返回 None"""
    try:
        d = json.load(open(os.path.join(report_dir, "result.json"), encoding="utf-8"))
        fl = d.get("flows") or []
        return fl[0] if fl else None
    except (OSError, ValueError):
        return None


def run_once(args, flow, report_dir, label, log):
    env = dict(os.environ)
    env["E2E_REPORT_DIR"] = report_dir
    env["E2E_SKIP_PREP"] = "1"  # 输入法/动画等设备准备已由父进程做过一次，子运行不再重复
    cmd = ["bash", args.e2e, flow, "--no-lint", "--no-notify"] + args.passthrough
    banner = "\n########## %s ##########" % label
    print(banner, flush=True)
    log.write(banner + "\n")
    t0 = time.time()
    p = subprocess.Popen(cmd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        for raw in iter(p.stdout.readline, b""):
            line = raw.decode("utf-8", errors="replace")
            sys.stdout.write(line)
            sys.stdout.flush()
            log.write(line)
        p.wait()
    except KeyboardInterrupt:
        p.terminate()
        p.wait()
        raise
    rc = p.returncode
    info = read_result(report_dir)
    passed = rc == 0
    if rc == 124:
        cat = "timeout_killed"
    elif rc == 2:
        cat = "env_error"
    elif passed:
        cat = None
    else:
        cat = (info or {}).get("category") or "unknown"
    return {
        "exit_code": rc,
        "passed": passed,
        "category": cat,
        "failed_step": (info or {}).get("failed_step"),
        "error": (info or {}).get("error"),
        "duration_s": round(time.time() - t0, 1),
        "report_dir": os.path.relpath(report_dir, args.out),
    }


def flow_verdict(f):
    outcomes = [r["outcome"] for r in f["runs"]]
    if outcomes and all(o == "pass" for o in outcomes):
        return "stable_pass"
    if outcomes and all(o == "fail" for o in outcomes):
        return "stable_fail"
    return "unstable"


VERDICT_ZH = {"stable_pass": "稳定通过", "stable_fail": "稳定失败", "unstable": "不稳定(flaky)"}
CAT_ZH = {
    "element_not_found": "找不到元素", "assertion_failed": "断言不成立", "script_error": "脚本错误",
    "launch_failed": "启动失败", "app_crash": "App 崩溃", "app_anr": "App 无响应(ANR)", "timeout": "等待超时", "timeout_killed": "整体超时被终止",
    "blocked_by_verification": "被验证/风控拦截", "env_error": "环境/用法错误", "unknown": "未归类",
}


def finalize(args, flows, interrupted):
    for f in flows:
        runs = f["runs"]
        f["total"] = len(runs)
        f["passed_first_try"] = sum(1 for r in runs if r["outcome"] == "pass")
        f["flaky"] = sum(1 for r in runs if r["outcome"] == "flaky")
        f["failed"] = sum(1 for r in runs if r["outcome"] == "fail")
        f["pass_rate"] = round(f["passed_first_try"] / len(runs), 4) if runs else None
        f["verdict"] = flow_verdict(f) if runs else "unstable"
        cats = {}
        for r in runs:
            if r["outcome"] == "pass":
                continue
            # 每次重复只记第一次尝试的失败原因（那是“没重跑也会遇到”的原因）
            c = r["attempts"][0]["category"] or "unknown"
            cats[c] = cats.get(c, 0) + 1
        f["failure_categories"] = cats
    any_timeout = any(a["exit_code"] == 124 for f in flows for r in f["runs"] for a in r["attempts"])
    all_stable = bool(flows) and all(f["verdict"] == "stable_pass" and f["total"] >= args.repeat for f in flows) and not interrupted
    code = 0 if all_stable else (124 if any_timeout else 1)
    verdict = "全部稳定通过" if all_stable else ("有运行超时" if any_timeout else "存在不稳定或失败的用例")
    if interrupted:
        verdict = "被中断，结果不完整"
    return code, verdict


def write_reports(args, flows, interrupted, started):
    code, verdict = finalize(args, flows, interrupted)
    md = ["# E2E 稳定性汇总", ""]
    md += [
        f"- 结果：**{verdict}**（退出码 {code}）",
        f"- 每个用例重复：{args.repeat} 次；失败自动重跑：{args.retry} 次",
        f"- 总耗时：{(time.time() - started) / 60:.1f} 分钟",
        "- 判定：**第一次就通过才算通过**；第一次失败、重跑才通过的记为“不稳定(flaky)”，不算通过。",
        "",
        "| 用例 | 结论 | 通过 | 不稳定 | 失败 | 通过率 | 失败原因（按第一次尝试）|",
        "|---|---|---|---|---|---|---|",
    ]
    for f in flows:
        cats = "，".join("%s×%d" % (CAT_ZH.get(c, c), n) for c, n in sorted(f["failure_categories"].items(), key=lambda x: -x[1])) or "-"
        rate = "-" if f["pass_rate"] is None else "%d%%（%d/%d）" % (round(f["pass_rate"] * 100), f["passed_first_try"], f["total"])
        md.append(f"| {f['name']} | {VERDICT_ZH[f['verdict']]} | {f['passed_first_try']} | {f['flaky']} | {f['failed']} | {rate} | {cats} |")
    md += ["", f"> 入库门槛：新用例连续 {GATE} 次全部通过（`--repeat {GATE}`，且每次都是第一次就通过）才能放进回归库。"]
    for f in flows:
        if f["total"] >= GATE and f["verdict"] == "stable_pass":
            md.append(f"> - `{f['name']}`：{f['total']} 次全部通过，**达到入库门槛**（仅说明这条用例在这台设备、这个环境下稳定）。")
        elif f["total"] < GATE:
            md.append(f"> - `{f['name']}`：只跑了 {f['total']} 次，不足 {GATE} 次，**不能据此入库**。")
        else:
            md.append(f"> - `{f['name']}`：**未达到入库门槛**（{VERDICT_ZH[f['verdict']]}）。")
    for f in flows:
        bad = [r for r in f["runs"] if r["outcome"] != "pass"]
        if not bad:
            continue
        md += ["", f"## {f['name']}：不是一次过的运行", ""]
        md += ["| 第几次 | 结果 | 尝试 | 失败步骤 | 原因归类 | 报告 |", "|---|---|---|---|---|---|"]
        for r in bad[:SHOW_MAX]:
            for k, a in enumerate(r["attempts"], 1):
                step = (a["failed_step"] or "-").replace("|", "/")
                md.append("| %d | %s | 第%d次尝试：%s | %s | %s | `%s` |" % (
                    r["index"], {"flaky": "不稳定", "fail": "失败"}[r["outcome"]], k, "通过" if a["passed"] else "失败",
                    step, CAT_ZH.get(a["category"], a["category"] or "-"), a["report_dir"]))
    for f in flows:
        extra = len([r for r in f["runs"] if r["outcome"] != "pass"]) - SHOW_MAX
        if extra > 0:
            md += ["", f"（{f['name']} 还有 {extra} 次未列出，完整记录见 `result.json`）"]
    md += ["", "## 其他文件", "- `runs/<用例>/rNN_aK/`：每一次运行自己的完整报告（summary.md、截图、logcat）", "- `console.txt`：全部运行的控制台输出"]
    open(os.path.join(args.out, "summary.md"), "w", encoding="utf-8").write("\n".join(md) + "\n")
    json.dump(
        {"mode": "repeat", "repeat": args.repeat, "retry_failed": args.retry, "exit_code": code, "verdict": verdict,
         "gate_runs": GATE, "interrupted": interrupted, "flows": flows},
        open(os.path.join(args.out, "result.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    return code


def main():
    args = parse()
    started = time.time()
    flows, interrupted = [], False
    log = open(os.path.join(args.out, "console.txt"), "w", encoding="utf-8")
    try:
        for flow in args.flows:
            name = os.path.splitext(os.path.basename(flow))[0]
            f = {"name": name, "path": flow, "runs": []}
            flows.append(f)
            for i in range(1, args.repeat + 1):
                run = {"index": i, "attempts": [], "outcome": None}
                f["runs"].append(run)
                for k in range(1, args.retry + 2):
                    rd = os.path.join(args.out, "runs", name, "r%02d_a%d" % (i, k))
                    os.makedirs(rd, exist_ok=True)
                    res = run_once(args, flow, rd, "%s 第 %d/%d 次%s" % (name, i, args.repeat, "" if k == 1 else "（失败重跑 %d）" % (k - 1)), log)
                    run["attempts"].append(res)
                    if res["passed"]:
                        break
                    if res["exit_code"] in (2,):  # 环境/用法错误重试没有意义
                        break
                first = run["attempts"][0]["passed"]
                run["outcome"] = "pass" if first else ("flaky" if run["attempts"][-1]["passed"] else "fail")
                print("[stability] %s 第 %d/%d 次：%s" % (name, i, args.repeat, {"pass": "通过", "flaky": "不稳定（重跑才通过）", "fail": "失败"}[run["outcome"]]), flush=True)
                write_reports(args, flows, False, started)  # 每次都落盘，中途中断也有结果
    except KeyboardInterrupt:
        interrupted = True
    code = write_reports(args, flows, interrupted, started)
    log.close()
    print("\n稳定性汇总: %s" % os.path.join(os.path.relpath(args.out), "summary.md"))
    for f in flows:
        print("  %s: %s（通过 %d / 不稳定 %d / 失败 %d，共 %d 次）" % (f["name"], VERDICT_ZH[f["verdict"]], f["passed_first_try"], f["flaky"], f["failed"], f["total"]))
    return code


if __name__ == "__main__":
    sys.exit(main())
