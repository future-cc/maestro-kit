#!/usr/bin/env python3
"""把 Maestro 的产物整理成 summary.md（给 AI 读）和 report.html（给人看）。只用标准库。

用法: python3 -I e2e_summary.py <报告目录> <退出码>
环境变量: E2E_BLOCK_PATTERNS  用 | 分隔的正则，logcat/屏幕文案命中则归类为“被验证/风控拦截”
"""
import datetime
import html
import json
import os
import re
import shutil
import sys

OUT = sys.argv[1]
CODE = int(sys.argv[2]) if len(sys.argv) > 2 else 1
BLOCK = [p for p in os.environ.get("E2E_BLOCK_PATTERNS", "").split("|") if p]
OK_STATES = ("COMPLETED", "SKIPPED", "WARNED")
HIDDEN = {"defineVariablesCommand", "applyConfigurationCommand", "runFlowCommand"}
ANSI = re.compile(r"\x1b\[[0-9;]*m|\[38;5;\d+m|\[0m")


def rel(p):
    return os.path.relpath(p)


def kind_of(cmd):
    return next(iter(cmd.keys()), "unknown")


def describe(cmd, evaluated):
    """优先用 evaluatedCommand（变量已展开）；有 label 用 label，否则拼出命令摘要"""
    for src in (evaluated, cmd):
        if not isinstance(src, dict) or not src:
            continue
        kind = kind_of(src)
        body = src.get(kind)
        if not isinstance(body, dict):
            continue
        if body.get("label"):
            return body["label"]
    src = evaluated if isinstance(evaluated, dict) and evaluated else cmd
    kind = kind_of(src)
    body = src.get(kind) or {}
    if isinstance(body, dict):
        sel = body.get("selector") or body.get("condition") or {}
        for k in ("visible", "notVisible"):
            if k in sel:
                sel = sel[k]
        for k in ("idRegex", "textRegex"):
            if k in sel:
                return f"{kind}: {sel[k]}"
        if "path" in body:
            return f"截图: {body['path']}"
        if "text" in body:
            return f"{kind}: {body['text']}"
    return kind


def flatten(entries):
    """runFlow/repeat 里的子命令在 commands.json 里也是独立条目，这里直接按顺序使用"""
    return entries


def load_steps(flow_dir):
    data = json.load(open(os.path.join(flow_dir, "commands.json"), encoding="utf-8"))
    steps = []
    for e in flatten(data):
        cmd, meta = e.get("command", {}), e.get("metadata", {})
        kind = kind_of(cmd)
        if kind in HIDDEN:
            continue
        err = meta.get("error")
        if isinstance(err, dict):
            err = err.get("message") or json.dumps(err, ensure_ascii=False)
        ev = meta.get("evaluatedCommand") or {}
        steps.append(
            {
                "kind": kind,
                "desc": describe(cmd, ev),
                "status": meta.get("status", "?"),
                "ms": meta.get("duration", 0),
                "ts": meta.get("timestamp"),
                "error": err,
                "shot": (ev.get("takeScreenshotCommand") or cmd.get("takeScreenshotCommand") or {}).get("path"),
            }
        )
    return steps


def copy_shots(flow_dir, flow_name):
    res = {}
    dst = os.path.join(OUT, "screenshots", flow_name)
    src = os.path.join(flow_dir, "takeScreenshot")
    if os.path.isdir(src):
        os.makedirs(dst, exist_ok=True)
        # 截图名含 / 时 Maestro 会建子目录（如 a/b.png），所以要递归；key 用相对路径去掉后缀，与步骤里的名字一致
        for root, _, fs in os.walk(src):
            for f in sorted(fs):
                if not f.lower().endswith(".png"):
                    continue
                relp = os.path.relpath(os.path.join(root, f), src)
                target = os.path.join(dst, relp)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                shutil.copy(os.path.join(root, f), target)
                res[os.path.splitext(relp)[0]] = f"screenshots/{flow_name}/{relp}"
    # Maestro 自动保存的失败截图：<flow目录>/*.png 或 <flow目录>/screenshots/step-NNN-*.png（比 takeScreenshot 更深一层）
    for root, dirs, fs in os.walk(flow_dir):
        if os.path.basename(root) == "takeScreenshot":
            dirs[:] = []
            continue
        for f in sorted(fs):
            if f.lower().endswith(".png"):
                os.makedirs(dst, exist_ok=True)
                target = os.path.join(dst, "auto_" + f)
                shutil.copy(os.path.join(root, f), target)
                res["__fail__" + os.path.splitext(f)[0]] = f"screenshots/{flow_name}/auto_{f}"
    return res


def copy_videos(flow_dir, flow_name):
    """startRecording 产生的 mp4/webm 等放在 artifacts 深处，复制到 <报告>/videos/<flow>/ 方便直接打开"""
    out = []
    for root, _, fs in os.walk(flow_dir):
        for f in sorted(fs):
            if f.lower().endswith((".mp4", ".webm", ".mov", ".gif")):
                dst = os.path.join(OUT, "videos", flow_name)
                os.makedirs(dst, exist_ok=True)
                shutil.copy(os.path.join(root, f), os.path.join(dst, f))
                out.append((f"videos/{flow_name}/{f}", os.path.getsize(os.path.join(dst, f))))
    return out


def read_logcat():
    path = os.path.join(OUT, "logcat.txt")
    if not os.path.exists(path):
        return []
    return [ANSI.sub("", l).rstrip("\n") for l in open(path, encoding="utf-8", errors="ignore")]


def app_errors(lines):
    """接口错误(Flutter dio 的 [http-error])、崩溃、未捕获异常；去重，最多 20 条。
    崩溃类线索只算被测 App 的：设置了 E2E_APP_ID 时，必须能在日志里确认进程属于该包，
    否则系统回收别的后台进程（Process xxx has died）会被误判成 App 崩溃。"""
    out, seen, pending = [], set(), None
    app = os.environ.get("E2E_APP_ID", "")
    # logcat 是整台设备的日志：从 "Start proc <pid>:<包名>/" 建立被测 App 的进程号集合，
    # 只采信这些进程的 flutter 输出；没找到映射（如测试开始前 App 已在运行）时不做过滤
    app_pids = set(re.findall(r"Start proc (\d+):" + re.escape(app) + r"/", "\n".join(lines))) if app else set()
    fatal_pending = None   # 刚看到 FATAL EXCEPTION，等待下一行 "Process: <包名>"
    native_pkg = ""        # 最近一个 native crash 块里的包名（Cmdline: / >>> pkg <<<）
    anr_idx, anr_pkg = None, ""   # 刚看到 "ANR in <包名>"，等下面的 "Reason:" 行补充原因
    for raw in lines:
        t = raw.strip()
        hit = None
        mpid = re.search(r"/flutter\s*\(\s*(\d+)\)", t)
        foreign = bool(app_pids and mpid and mpid.group(1) not in app_pids)  # 别的应用进程输出的 flutter 日志
        if "[http-error]" in t:
            pending = None if foreign else t.split("[http-error]", 1)[1].strip()
        elif pending and "Status:" in t and not foreign:
            hit = f"{pending} -> {t.rsplit('Status:', 1)[1].strip()}"
            pending = None
        elif ("Unhandled Exception" in t or "EXCEPTION CAUGHT BY" in t) and not foreign:
            hit = "崩溃/异常: " + (t[t.find(":", 20) + 1 :].strip() or t)
        elif "FATAL EXCEPTION" in t:
            fatal_pending = t
        elif fatal_pending and re.search(r"Process:\s*(\S+),", t):
            pkg = re.search(r"Process:\s*(\S+),", t).group(1)
            if not app or pkg == app:
                hit = "崩溃/异常: " + fatal_pending[fatal_pending.find(":", 20) + 1 :].strip() + f"（进程 {pkg}）"
            fatal_pending = None
        elif "Cmdline:" in t and "DEBUG" in t:
            native_pkg = t.split("Cmdline:", 1)[1].strip()
        elif ">>>" in t and "<<<" in t and "DEBUG" in t:
            native_pkg = t.split(">>>", 1)[1].split("<<<", 1)[0].strip()
        elif re.search(r"\bsignal \d+ \(SIG\w+\)", t) and "DEBUG" in t:
            if not app or native_pkg == app:
                hit = "原生崩溃: " + t.split("DEBUG", 1)[-1].lstrip("): ").strip() + (f"（{native_pkg}）" if native_pkg else "")
        elif re.search(r"\bANR in (\S+)", t) and "ActivityManager" in t:
            pkg = re.search(r"\bANR in (\S+)", t).group(1)
            if not app or pkg == app:
                anr_idx = len(out)
                hit = f"ANR: 应用无响应（{pkg}）"
                anr_pkg = pkg
        elif anr_idx is not None and "Reason:" in t and "ActivityManager" in t:
            out[anr_idx] = f"ANR: 应用无响应（{anr_pkg}）：" + t.split("Reason:", 1)[1].strip()[:120]
            seen.add(out[anr_idx])
            anr_idx = None
        elif re.search(r"Process (\S+) \(pid \d+\) has died", t) and "ActivityManager" in t:
            pkg = re.search(r"Process (\S+) \(pid \d+\) has died", t).group(1)
            if not app or pkg == app:
                hit = "进程退出: " + t.split("ActivityManager", 1)[-1].lstrip("): ").strip()
        if hit and hit not in seen:
            seen.add(hit)
            out.append(hit)
    return out[:20]

APP_ID = os.environ.get("E2E_APP_ID", "")
# 只保留与 App 相关的日志：flutter 输出、崩溃相关的系统标签、或行里出现包名；排除 system_server 等无关系统报错
RELEVANT_TAGS = ("AndroidRuntime", "DEBUG", "libc", "ActivityManager", "tombstoned", "flutter")


def relevant(line, level, tag):
    if "flutter" in line.lower() or (APP_ID and APP_ID in line):
        return True
    return level in "EF" and tag in RELEVANT_TAGS


def log_slice(lines, ts_ms, before=4, after=2, limit=25):
    """取失败时间点附近的日志，只保留 flutter/E/F 级别，帮助定位失败当时 App 在干什么"""
    if not ts_ms:
        return []
    t0 = datetime.datetime.fromtimestamp(ts_ms / 1000.0)
    lo, hi = t0 - datetime.timedelta(seconds=before), t0 + datetime.timedelta(seconds=after)
    res = []
    for l in lines:
        m = re.match(r"(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d+)\s+([A-Z])/([^(\s]+)", l)
        if not m:
            continue
        mo, d, h, mi, s = map(int, m.groups()[:5])
        try:
            t = datetime.datetime(t0.year, mo, d, h, mi, s)
        except ValueError:
            continue
        if lo <= t <= hi and relevant(l, m.group(7), m.group(8)):
            res.append(l[:200])
    return res[-limit:]


def console_of(flow_name):
    """maestro_output.txt 里属于该 flow 的那一段（从 ' > Flow <名>' 到下一个 '===== ['）"""
    path = os.path.join(OUT, "maestro_output.txt")
    if not os.path.exists(path):
        return ""
    t = open(path, encoding="utf-8", errors="ignore").read()
    i = t.find(f" > Flow {flow_name}")
    if i < 0:
        return ""
    j = t.find("===== [", i)
    return t[i : j if j > 0 else len(t)]


def classify(step, flow_log, errs, shots_text=""):
    """给失败步骤归类并给出建议的下一步"""
    msg = (step.get("error") or "") + " " + " ".join(flow_log)
    if BLOCK and re.search("|".join(BLOCK), msg + shots_text):
        return ("blocked_by_verification", "被验证码/设备校验/风控拦截。脚本不处理也不要绕过，请让后端放行测试账号或由人工先完成授信。")
    if any(e.startswith("ANR") for e in errs):
        return ("app_anr", "测试期间被测 App 无响应（ANR），常见于冷启动超时。先看“App 运行日志中的异常”里的原因，再看失败截图——它可能是别的 App（系统在 ANR 后退回了上一个界面）；这是 App 或设备卡顿的问题，不要改 flow。")
    if any(e.startswith(("崩溃", "原生崩溃", "进程退出")) for e in errs):
        return ("app_crash", "测试期间 App 崩溃或退出。先看“App 运行日志中的异常”，再看 logcat；这是 App 的问题，不要改 flow。")
    e = step.get("error") or ""
    if "Unable to launch app" in e or "launchApp" in step["kind"] and step["status"] == "FAILED":
        return ("launch_failed", "App 启动失败。检查 APK 是否已安装、appId 是否正确、设备是否正常。")
    if "JsEvaluationException" in e or "JsEvaluationException" in msg or "ReferenceError" in msg or "TypeError:" in msg or "SyntaxError" in msg:
        return ("script_error", "flow 里的 JS 表达式出错（变量未定义或类型错误）。检查 ${...} 里引用的变量是否通过 -e / e2e.env 传入；这是用例问题。")
    if "Element not found" in e or "No visible element found" in e or "Could not find a visible element" in e:
        return ("element_not_found", "找不到元素。用 maestro hierarchy 看当前界面的元素树，确认 id/文本；可能是页面没跳转、被遮罩盖住或元素在屏幕外。")
    if "Assertion is false" in e:
        extra = "同时日志里有接口错误，很可能是后端问题导致页面没渲染。" if any("->" in x for x in errs) else ""
        return ("assertion_failed", "断言不成立。先看失败截图，确认页面当时实际是什么；" + extra)
    if "timeout" in e.lower() or "timed out" in e.lower():
        return ("timeout", "等待超时。网络慢、动画长或页面卡住；看失败截图和接口错误。")
    return ("unknown", "未归类，请看 maestro_output.txt 和失败截图。")


def main():
    flows = []
    for dp, _, fs in os.walk(os.path.join(OUT, "artifacts")):
        if "commands.json" in fs:
            flows.append(dp)
    flows.sort(key=lambda d: os.path.getmtime(os.path.join(d, "commands.json")))
    timed_out = os.path.exists(os.path.join(OUT, ".timeout"))
    lines = read_logcat()
    errs = app_errors(lines)
    verdict = {0: "全部通过", 124: "超时被终止"}.get(CODE, "存在失败")

    md = ["# E2E 测试摘要", ""]
    md += [f"- 结果：**{verdict}**（退出码 {CODE}）", f"- 报告目录：`{rel(OUT)}`"]
    if timed_out:
        md += ["", "> 有 flow 超过时限被强制终止，其步骤可能不完整。"]
    h = [
        "<meta charset='utf-8'><meta name='viewport' content='width=device-width'><title>E2E 报告</title>",
        "<style>body{font-family:-apple-system,sans-serif;margin:24px;max-width:1150px}"
        "table{border-collapse:collapse;width:100%}td,th{border:1px solid #ddd;padding:6px 10px;vertical-align:top}"
        ".ok{color:#1a7f37}.bad{color:#cf222e;font-weight:600}tr.bad td{background:#ffebe9}"
        "img{max-height:360px;border:1px solid #ccc;margin:4px;cursor:zoom-in}figure{display:inline-block;margin:6px;text-align:center}"
        "figcaption{font-size:12px;color:#555}pre{background:#f6f8fa;padding:8px;overflow:auto;font-size:12px}"
        "#lb{display:none;position:fixed;inset:0;background:#000d;z-index:9;justify-content:center;align-items:center}"
        "#lb img{max-height:96vh;max-width:96vw;cursor:zoom-out}</style>",
        "<div id='lb' onclick=\"this.style.display='none'\"><img></div>"
        "<script>document.addEventListener('click',e=>{if(e.target.tagName=='IMG'&&!e.target.closest('#lb')){"
        "var lb=document.getElementById('lb');lb.firstChild.src=e.target.src;lb.style.display='flex'}})</script>",
        f"<h1>E2E 测试报告</h1><p>结果：<b class='{'ok' if CODE == 0 else 'bad'}'>{verdict}</b></p>",
    ]
    if not flows:
        md += ["", "未找到任何 flow 产物。请查看 `maestro_output.txt`（可能是设备未连接、flow 语法错误、启动失败或被超时终止）。"]
        h.append("<p class='bad'>未找到 flow 产物，请查看 maestro_output.txt</p>")

    results = []
    total_warn = 0
    for fd in flows:
        name = os.path.basename(fd)
        steps = load_steps(fd)
        shots = copy_shots(fd, name)
        failed = [s for s in steps if s["status"] not in OK_STATES]
        total_ms = sum(s["ms"] or 0 for s in steps)
        results.append({"name": name, "failed": bool(failed), "category": None, "failed_step": None, "error": None, "steps": len(steps), "duration_s": round(total_ms / 1000, 1), "warned_steps": len([s for s in steps if s["status"] == "WARNED"])})
        md += ["", f"## {name}：{'失败' if failed else '通过'}（{len(steps)} 步，{total_ms/1000:.1f}s）", ""]
        md += ["| # | 步骤 | 状态 | 耗时ms | 截图 |", "|---|---|---|---|---|"]
        h.append(f"<h2>{html.escape(name)} — <span class='{'bad' if failed else 'ok'}'>{'失败' if failed else '通过'}</span> <small>({len(steps)} 步, {total_ms/1000:.1f}s)</small></h2>")
        h.append("<table><tr><th>#</th><th>步骤</th><th>状态</th><th>耗时</th><th>截图</th></tr>")
        for i, s in enumerate(steps, 1):
            shot_rel = shots.get(s["shot"]) if s["shot"] else None
            bad = s["status"] not in OK_STATES
            md.append(f"| {i} | {s['desc'].replace('|', '/')} | {s['status']} | {s['ms']} | {shot_rel or ''} |")
            cell = f"<figure><img src='{shot_rel}'><figcaption>{html.escape(s['shot'])}</figcaption></figure>" if shot_rel else ""
            h.append(
                f"<tr class='{'bad' if bad else ''}'><td>{i}</td><td>{html.escape(s['desc'])}"
                + (f"<br><small>{html.escape(str(s['error']))}</small>" if s["error"] else "")
                + f"</td><td>{s['status']}</td><td>{s['ms']}</td><td>{cell}</td></tr>"
            )
        h.append("</table>")
        warned = [(i, st) for i, st in enumerate(steps, 1) if st["status"] == "WARNED"]
        total_warn += len(warned)
        if warned:
            md += ["", f"### ⚠ 警告步骤（{name}）：这些步骤没通过但被忽略（如 optional: true），可能掩盖问题", ""]
            md += [f"- 第 {i} 步：{st['desc']}" for i, st in warned]
            h.append("<h3>⚠ 警告步骤</h3><ul>" + "".join(f"<li>第 {i} 步：{html.escape(st['desc'])}</li>" for i, st in warned) + "</ul>")
        vids = copy_videos(fd, name)
        if vids:
            md += ["", f"### 录屏（{name}）", ""] + [f"- `{v}`（{sz/1024:.0f} KB）" for v, sz in vids]
            h.append("<h3>录屏</h3>" + "".join(f"<video src='{v}' controls style='max-height:420px'></video>" for v, _ in vids))
        if failed:
            f0 = failed[0]
            sl = log_slice(lines, f0.get("ts"))
            if not f0.get("error"):
                # Maestro 在 JS 表达式出错等情况下，commands.json 里该步骤停在 RUNNING 且没有 error，只能从控制台找
                con = console_of(name)
                first = next((l.strip() for l in con.splitlines() if re.search(r"Exception|Error|error:", l)), "")
                if first:
                    f0["error"] = first[:300] + "（取自控制台输出，commands.json 中该步骤状态为 " + f0["status"] + "）"
            cat, advice = classify(f0, sl, errs)
            results[-1].update({"category": cat, "failed_step": f0["desc"], "error": (f0.get("error") or "")[:300]})
            md += [
                "",
                f"### 失败详情（{name}）",
                f"- 失败步骤：{f0['desc']}（命令 `{f0['kind']}`）",
                f"- 错误信息：{f0['error'] or '（commands.json 未提供，见 maestro_output.txt）'}",
                f"- **归类：`{cat}`** — {advice}",
            ]
            fail_imgs = [v for k, v in shots.items() if k.startswith("__fail__")]
            if fail_imgs:
                md.append(f"- Maestro 自动保存的失败截图：{', '.join(fail_imgs)}")
                h.append("<h3>失败截图</h3>" + "".join(f"<img src='{p}'>" for p in fail_imgs))
            h.append(f"<p class='bad'>归类：{cat}</p><p>{html.escape(advice)}</p>")
            if sl:
                md += ["- 失败时间点附近的 App 相关日志（flutter 输出、崩溃相关、含包名的行）：", "```"] + sl + ["```"]
                h.append("<h3>失败时间点附近的 App 日志</h3><pre>" + html.escape("\n".join(sl)) + "</pre>")

    md += ["", "## App 运行日志中的异常（来自 logcat）", ""]
    if errs:
        md += [f"- `{e}`" for e in errs]
        md += ["", "> 这些是 App 自己打印的接口错误/崩溃，常常是 UI 测试失败的真正原因，排查时优先看这里。"]
        h.append("<h2>App 日志异常</h2><ul>" + "".join(f"<li><code>{html.escape(e)}</code></li>" for e in errs) + "</ul>")
    else:
        md += ["- 未发现接口错误或崩溃"]
    final = os.path.join(OUT, "failure_final_screen.png")
    if os.path.exists(final) and os.path.getsize(final) > 0:
        md += ["", f"- 失败结束时的屏幕截图：`{rel(final)}`"]
        h.append("<h3>失败结束时屏幕</h3><img src='failure_final_screen.png'>")
    md += [
        "",
        "## 其他文件",
        "- `maestro_output.txt`：Maestro 控制台原始输出",
        "- `logcat.txt`：整个测试期间的 Android 日志（查崩溃/异常时 grep `FATAL|Exception|flutter`）",
        "- `artifacts/`：Maestro 原始产物（commands.json 等）",
    ]
    open(os.path.join(OUT, "summary.md"), "w", encoding="utf-8").write("\n".join(md) + "\n")
    open(os.path.join(OUT, "report.html"), "w", encoding="utf-8").write("\n".join(h))
    # 机器可读的结果，方便 CI 或其他脚本消费
    json.dump(
        {"exit_code": CODE, "verdict": verdict, "flows": results, "app_errors": errs},
        open(os.path.join(OUT, "result.json"), "w", encoding="utf-8"),
        ensure_ascii=False,
        indent=2,
    )


main()
