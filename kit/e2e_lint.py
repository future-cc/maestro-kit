#!/usr/bin/env python3
"""flow 静态检查：在运行前发现“容易假通过/不稳定/不安全”的写法。只用标准库，逐行分析 YAML。

用法: python3 -I e2e_lint.py [--clearstate-block 关键字,关键字] flow.yaml [...]
退出码: 0 无 WARN；1 有 WARN（INFO 不影响退出码）
忽略: 在命令上一行或命令块内写 `# lint-ignore: W004`（可逗号分隔多个规则）

规则:
  W001 只有否定断言：流程里有 assertNotVisible / notVisible，却没有任何正向断言（遮罩会让元素消失，误判通过）
  W002 坐标点击：tapOn 使用 point / "x,y" / "50%,50%"
  W003 clearState 出现在路径包含 --clearstate-block 关键字的 flow 里（会让设备变成“非授信设备”）
  W004 凭证写死：向 password/pwd/密码 相关输入框 inputText 了字面量（应使用 ${变量}）
  W005 缺少 appId
  W007 takeScreenshot 重名（Maestro 会静默覆盖同名文件，只保留最后一张）或名字含 / （会建子目录）
  W008 inputText 含非 ASCII 字符（Android 上 Maestro 会静默丢弃这些字符，步骤仍显示成功）
  I004 步骤使用 optional: true（找不到元素时不报错，只在报告里标 WARNED，可能掩盖问题）
  W009 swipe 起点在屏幕边缘（百分比坐标 ≤1% 或 ≥99%）：会被系统当作返回/通知栏/控制中心手势，App 可能直接退出（Maestro 2.11 实测）
  W010 launchApp 之后紧跟的不是等待/断言（如截图、waitForAnimationToEnd、assertNotVisible），或 launchApp 是最后一步：launchApp 是冷启动且不等首帧，会撞上空白启动页
  I005 使用 hideKeyboard：Android 上软键盘没显示时它会发送返回键，可能直接退出当前页面（实测，模拟器启用硬件键盘时尤其常见）；优先点击页面上一个中性元素来收起焦点
  W011 等待/断言的文字是 .+ 或 .*（匹配任意文字）：launchApp 后它会被上一个 App 的内容满足，等于没等，截图还会截到切换过渡画面（实测）
  I001 步骤没有 label（报告里只能看到命令类型）
  I002 整个 flow 没有 takeScreenshot
  I003 label 里引用了 ${变量}（Maestro 不一定在原始命令里展开，报告以 evaluatedCommand 为准）
"""
import re
import sys

args = sys.argv[1:]
block_keys = []
if args and args[0] == "--clearstate-block":
    block_keys = [k for k in args[1].split(",") if k]
    args = args[2:]

CMD_RE = re.compile(r"^(\s*)- (\w+)\s*:?\s*(.*)$")
NEG = ("assertNotVisible", "notVisible")
POS = ("assertVisible", "assertTrue", "extendedWaitUntil", "assertWithAI")


def lint(path):
    issues = []
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError as e:
        return [("W", "W000", 0, f"无法读取: {e}")]
    # 拆分 header 与命令区
    sep = next((i for i, l in enumerate(lines) if l.strip() == "---"), None)
    header = lines[: sep or 0]
    body = lines[(sep + 1) if sep is not None else 0 :]
    off = (sep + 1) if sep is not None else 0
    if not any(re.match(r"\s*appId\s*:", l) for l in header):
        issues.append(("W", "W005", 1, "缺少 appId"))

    # 命令块：以顶层 "- cmd" 开头直到下一个顶层 "- "
    blocks = []
    for i, l in enumerate(body):
        m = CMD_RE.match(l)
        if m and len(m.group(1)) == 0:
            blocks.append([m.group(2), i + off + 1, [l]])
        elif blocks:
            blocks[-1][2].append(l)

    text = "\n".join(body)
    has_pos = False
    has_neg = False
    last_assert = None  # "pos"/"neg"
    prev_target = ""
    shot = False
    shot_names = {}
    for idx, (cmd, ln, ls) in enumerate(blocks):
        chunk = "\n".join(ls)
        prev_line = body[ln - off - 2] if ln - off - 2 >= 0 else ""
        ignore = set(re.findall(r"lint-ignore\s*:\s*([A-Z0-9, ]+)", chunk + "\n" + prev_line))
        ignore = {c.strip() for grp in ignore for c in grp.split(",") if c.strip()}
        n0 = len(issues)
        if cmd == "takeScreenshot":
            shot = True
            nm = re.search(r"takeScreenshot\s*:\s*['\"]?([^'\"\n]+)", chunk)
            nm = (nm.group(1).strip() if nm else "")
            if nm in shot_names:
                issues.append(("W", "W007", ln, f"截图名 \"{nm}\" 与第 {shot_names[nm]} 行重复，后一张会覆盖前一张"))
            else:
                shot_names[nm] = ln
            if "/" in nm:
                issues.append(("W", "W007", ln, f"截图名 \"{nm}\" 含 /，Maestro 会建子目录"))
        if cmd in ("assertVisible", "assertTrue", "assertWithAI") or (
            cmd == "extendedWaitUntil" and re.search(r"\bvisible\s*:", chunk)
        ):
            has_pos = True
            last_assert = "pos"
        if cmd == "assertNotVisible" or (cmd == "extendedWaitUntil" and re.search(r"\bnotVisible\s*:", chunk)):
            has_neg = True
            last_assert = "neg"
        # W002 坐标
        if cmd in ("tapOn", "longPressOn", "doubleTapOn"):
            if re.search(r"^\s*point\s*:", chunk, re.M) or re.search(r"""tapOn:\s*["']?\d+%?\s*,\s*\d+%?""", chunk):
                issues.append(("W", "W002", ln, "使用坐标点击，分辨率变化会失效；请改用 id 或文本"))
            prev_target = chunk
        # W009 边缘滑动
        if cmd == "swipe":
            for key in ("start", "end"):
                m9 = re.search(key + r"\s*:\s*['\"]?\s*(\d+(?:\.\d+)?)\s*%\s*,\s*(\d+(?:\.\d+)?)\s*%", chunk)
                if m9 and (min(float(m9.group(1)), float(m9.group(2))) <= 1.0 or max(float(m9.group(1)), float(m9.group(2))) >= 99.0):
                    issues.append(("W", "W009", ln, f"swipe 的 {key} 在屏幕边缘（{m9.group(1)}%,{m9.group(2)}%），会触发系统手势，App 可能被直接退出；起点请避开边缘"))
                    break
        # W010 launchApp 后没有显式等待
        if cmd == "launchApp":
            nxt = blocks[idx + 1][0] if idx + 1 < len(blocks) else None
            ok_next = ("extendedWaitUntil", "assertVisible", "assertTrue", "runFlow", "tapOn", "evalScript", "runScript", "stopApp", "killApp", "launchApp")
            if nxt is None:
                issues.append(("W", "W010", ln, "launchApp 是 flow 的最后一步：它是冷启动且不等首帧，之后没有任何等待或断言"))
            elif nxt not in ok_next:
                issues.append(("W", "W010", ln, f"launchApp 之后紧跟 {nxt}：launchApp 不等首帧，可能撞上空白启动页；请先 extendedWaitUntil 等一个首屏元素"))
        # W003 clearState
        if cmd == "launchApp" and re.search(r"clearState\s*:\s*true", chunk):
            if any(k in path for k in block_keys):
                issues.append(("W", "W003", ln, "该 flow 属于受限路径但使用了 clearState: true（设备会失去授信/登录状态）"))
        # W008 非 ASCII 输入
        if cmd == "inputText":
            m8 = re.search(r"^\s*text\s*:\s*['\"]?([^'\"\n]+)", chunk, re.M) or re.search(r"inputText\s*:[ \t]*['\"]?([^'\"\n]+)", chunk)
            if m8 and re.search(r"[^\x00-\x7f]", m8.group(1)):
                issues.append(("W", "W008", ln, "inputText 含非 ASCII 字符；Android 上 Maestro 会静默丢弃它们且步骤仍显示成功，请改用 ASCII 或其他输入方式"))
        if cmd in ("extendedWaitUntil", "assertVisible") and re.search(r"(?:visible|text)\s*:\s*['\"]?\.[*+]['\"]?\s*$", chunk, re.M):
            issues.append(("W", "W011", ln, "等待/断言的文字是 .+ 或 .*，会被上一个 App 的内容满足；请等被测 App 自己的元素（resource-id 或确定的文案）"))
        if cmd == "hideKeyboard":
            issues.append(("I", "I005", ln, "hideKeyboard 在软键盘未显示时会发送返回键，可能直接退出当前页面；确认这一步不会离开页面"))
        if re.search(r"^\s*optional\s*:\s*true", chunk, re.M):
            issues.append(("I", "I004", ln, f"{cmd} 使用 optional: true，找不到元素会被忽略（报告里标 WARNED）；确认这是有意为之"))
        # W004 凭证
        if cmd == "inputText":
            lit = re.search(r"^\s*text\s*:\s*['\"]?([^'\"\n]+)", chunk, re.M) or re.search(r"inputText\s*:[ \t]*['\"]?([^'\"\n]+)", chunk)
            val = lit.group(1).strip() if lit else ""
            if re.search(r"(?i)password|pwd|passwd|密码", prev_target) and val and "${" not in val:
                issues.append(("W", "W004", ln, "向密码相关输入框输入了字面量，应使用 ${PASSWORD} 并通过 -e / e2e.env 传入"))
        # I001 / I003 label
        if cmd not in ("takeScreenshot", "hideKeyboard", "waitForAnimationToEnd", "back", "runFlow", "launchApp", "stopApp", "killApp", "clearState") and not re.search(r"\blabel\s*:", chunk):
            issues.append(("I", "I001", ln, f"{cmd} 没有 label"))
        m = re.search(r"\blabel\s*:\s*(.*)", chunk)
        if m and "${" in m.group(1):
            issues.append(("I", "I003", ln, "label 引用了 ${变量}，报告以 evaluatedCommand 为准，请确认显示是否符合预期"))
        if ignore:
            issues[n0:] = [i for i in issues[n0:] if i[1] not in ignore]

    if has_neg and not has_pos:
        issues.append(("W", "W001", 1, "只有否定断言（assertNotVisible/notVisible），没有正向断言；遮罩或弹窗会让它误判通过"))
    if not shot:
        issues.append(("I", "I002", 1, "整个 flow 没有 takeScreenshot，人工无法对照截图复核"))
    return issues


total_w = 0
for p in args:
    iss = lint(p)
    w = [i for i in iss if i[0] == "W"]
    total_w += len(w)
    if not iss:
        print(f"[lint] OK    {p}")
        continue
    print(f"[lint] {'WARN' if w else 'INFO'}  {p}")
    for kind, code, ln, msg in iss:
        print(f"         {code} {'WARN' if kind == 'W' else 'INFO'} 行{ln}: {msg}")
print(f"[lint] 共 {len(args)} 个 flow，{total_w} 条 WARN")
sys.exit(1 if total_w else 0)
