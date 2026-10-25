#!/usr/bin/env python3
"""验证 --repeat 汇总层的 report.html：不需要设备，用造出来的数据。
检查：三种结果的色块都在、每个链接/图片指向的文件都存在、失败截图被内嵌、转义正确。
用法: python3 -I selftest/test_repeat_html.py
"""
import importlib.util, os, re, sys, tempfile, time, types
from urllib.parse import unquote

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("er", os.path.join(HERE, "..", "kit", "e2e_repeat.py"))
er = importlib.util.module_from_spec(spec); spec.loader.exec_module(er)

out = tempfile.mkdtemp()
def attempt(name, i, k, passed, step=None, cat=None):
    rd = "runs/%s/r%02d_a%d" % (name, i, k)
    os.makedirs(os.path.join(out, rd, "screenshots", name), exist_ok=True)
    open(os.path.join(out, rd, "report.html"), "w").write("x")
    if not passed:
        open(os.path.join(out, rd, "screenshots", name, "auto_step-007-fail.png"), "wb").write(b"png")
    return {"passed": passed, "exit_code": 0 if passed else 1, "failed_step": step, "category": cat, "report_dir": rd, "duration_s": 1.0}

flows = [{"name": "f <b>", "path": "x", "runs": [
    {"index": 1, "outcome": "pass", "attempts": [attempt("f <b>", 1, 1, True)]},
    {"index": 2, "outcome": "flaky", "attempts": [attempt("f <b>", 2, 1, False, "点 <第一场>", "assertion_failed"), attempt("f <b>", 2, 2, True)]},
    {"index": 3, "outcome": "fail", "attempts": [attempt("f <b>", 3, 1, False, "断言", "element_not_found"), attempt("f <b>", 3, 2, False, "断言", "element_not_found")]},
]}]
args = types.SimpleNamespace(out=out, repeat=3, retry=1)
code, verdict = er.finalize(args, flows, False)
er.write_html(args, flows, code, verdict, time.time() - 60)
t = open(os.path.join(out, "report.html"), encoding="utf-8").read()
bad = []
for cls in ("c-pass", "c-flaky", "c-fail"):
    if cls not in t.split("</style>")[1]: bad.append("缺少色块 " + cls)
refs = re.findall(r"(?:href|src)='([^']+)'", t)
bad += ["指向不存在的文件: " + x for x in refs if not os.path.exists(os.path.join(out, unquote(x)))]
if "auto_step-007-fail.png" not in t: bad.append("失败截图没有内嵌")
if "<b>" in t.replace("<b>", "", t.count("<b>")) or "f &lt;b&gt;" not in t: bad.append("用例名没有转义")
if "点 &lt;第一场&gt;" not in t: bad.append("失败步骤没有转义")
print("[repeat_html] 链接/图片 %d 个，问题 %d 个 → %s" % (len(refs), len(bad), "✅" if not bad else "❌ " + "; ".join(bad)))
sys.exit(1 if bad else 0)
