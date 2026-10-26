#!/usr/bin/env python3
"""lint 新规则的单元自测：不需要设备。W013 红线词 / W014 百分比小数 / W015 正则匹配状态栏时钟。
既测“该报的会报”，也测“不该报的不报”（label 里的说明文字、assert、整数百分比、带 \\n 的正则）。
用法: python3 -I selftest/test_lint_rules.py
"""
import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
LINT = os.path.join(HERE, "..", "kit", "e2e_lint.py")
HEAD = "appId: a.b\n---\n"

CASES = [
    # (名称, flow 正文, 应出现的规则, 不应出现的规则)
    ("W013 tapOn 文字含红线词", '- tapOn:\n    label: "x"\n    text: "存款"\n', ["W013"], []),
    ("W013 内联写法也检查", '- tapOn: "取款"\n', ["W013"], []),
    ("W013 label 里写说明不触发", '- tapOn:\n    label: "点余额下拉（只看不点转入）"\n    point: "28%,18%"\n', [], ["W013"]),
    ("W013 assertVisible 红线词不触发", '- assertVisible:\n    label: "只看"\n    text: "存款"\n', [], ["W013"]),
    ("W013 lint-ignore 可放行", '# lint-ignore: W013\n- tapOn:\n    label: "x"\n    text: "存款"\n', [], ["W013"]),
    ("W014 小数百分比", '- tapOn:\n    label: "x"\n    point: "28%,22.5%"\n', ["W014"], []),
    ("W014 整数百分比不触发", '- tapOn:\n    label: "x"\n    point: "28%,22%"\n', [], ["W014"]),
    ("W015 分钟正则没要求换行", '- tapOn:\n    label: "x"\n    text: "[0-8]?\\\\d:\\\\d\\\\d.*"\n', ["W015"], []),
    ("W015 scrollUntilVisible 也检查", '- scrollUntilVisible:\n    label: "x"\n    element:\n      text: "\\\\d\\\\d:\\\\d\\\\d.*"\n', ["W015"], []),
    ("W015 带 \\n 不触发", '- tapOn:\n    label: "x"\n    text: "[0-8]?\\\\d:\\\\d\\\\d\\\\n.*"\n', [], ["W015"]),
]

bad = 0
d = tempfile.mkdtemp()
for i, (name, body, want, nowant) in enumerate(CASES):
    p = os.path.join(d, f"c{i}.yaml")
    open(p, "w", encoding="utf-8").write(HEAD + body)
    out = subprocess.run([sys.executable, "-I", LINT, "--tap-block", "存款,取款,转入,退出登录", p], capture_output=True, text=True).stdout
    ok = all(w in out for w in want) and not any(w in out for w in nowant)
    bad += 0 if ok else 1
    print("[lint_rules] %-28s → %s" % (name, "✅" if ok else "❌\n" + out))
print("[lint_rules] %s" % ("全部符合" if not bad else "有 %d 项不符" % bad))
sys.exit(1 if bad else 0)
