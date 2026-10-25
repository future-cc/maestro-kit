# 套件自测（不依赖任何项目）

用模拟器自带的“设置”应用（`com.android.settings`，离线、每台模拟器都有）当被测对象，验证套件本身：运行器、失败归类、报告、lint、标签过滤、超时、环境变量传递。

```bash
ANDROID_SERIAL=emulator-5554 bash selftest/run.sh            # 全部
ANDROID_SERIAL=emulator-5554 bash selftest/run.sh F0         # 只跑名字含 F0 的
```

结果表在 `selftest/project/.maestro/reports/selftest_<时间>.md`（已被 .gitignore 忽略）。退出码 0 表示全部“符合预期”。

## 原理
`selftest/project/` 是一个最小“项目”：里面只有 `.maestro/e2e.config` 和 `.maestro/_selftest/*.yaml`。`run.sh` 设置 `E2E_PROJECT_ROOT` 指向它，再调用 `kit/selftest.sh`。装进业务项目的用法不受影响（不设该变量时仍按 `kit/../..` 推导）。

每个用例的头部用注释声明预期，指令见 `kit/selftest.sh` 开头：`expect`（pass / fail:归类 / lint:规则 / timeout / usage / observe）、`env`、`args`、`timeout`、`serial`、`summary-has`、`lint-forbid`、`note`。

## 覆盖了什么
| 场景 | 用例 |
|---|---|
| 一定通过 | P01 |
| 元素找不到 → `element_not_found` | F01 |
| 断言不成立 → `assertion_failed` | F02、F03（仅观察措辞） |
| JS 出错 → `script_error` | F05（evalScript）、F06（runScript 语法错误）、E03（变量没传入） |
| optional 步骤：退出码 0 且摘要有“警告步骤” | O01 |
| 环境变量传递：空格、`&`、双引号、`$`、中文、全角标点 | E01、E02 |
| 向输入框输入英文 / 中英混合 | I01、I02 |
| `runFlow when` 两个分支 | R01 |
| 超时 → 124 | T01 |
| 标签过滤（无匹配 → 2；匹配 → 正常跑） | U01、S01 |
| 设备不在线 → 2 | U02 |
| lint：W001–W005、W007–W012（W006 规则不存在）、I001–I005、`lint-ignore` | L01–L17 |

## 不需要设备的单元自测
`python3 -I selftest/test_summary.py`：用合成的 commands.json 和 logcat 验证摘要脚本的失败归类（目前覆盖 ANR：被测 App 的 ANR 归 `app_anr`，别的 App 的 ANR 不算）。

## 没覆盖（如实）
- **崩溃注入**（`inject: crash@N`）：需要 `debuggable` 的包才能 `run-as kill -SEGV`，系统“设置”不是。需要在带 debug 包的项目里验证。
- **并行 `--devices a,b`**：需要两台设备，这里只有一台。
- **`--build`**、`install.sh`、`doctor.sh`：不在自测范围内。
- **横屏、录屏、`assertScreenshot`、定位、飞行模式等设备级命令**：没有搬进来（旧自测里有，但它们验证的是 Maestro 本身而不是套件，且会改设备状态）。
- **`--repeat` 汇总层 `report.html`**：`python3 -I selftest/test_repeat_html.py`，不需要设备；检查色块、链接/图片是否指向存在的文件、失败截图内嵌、转义。
- **FLOW_GLOBS 通配符不被当前目录提前展开**：`bash selftest/globs.sh`，不需要设备。
- **重复运行、失败重跑、不稳定判定**：由单独的 `bash selftest/stability.sh` 验证（一定通过 / 一定失败 / 随机约一半通过三条用例，要求汇总分别判为 稳定通过 / 稳定失败 / 不稳定）。它不含在 `run.sh` 里，因为要多跑几分钟，且随机用例有极小的误报概率（见脚本注释）。
- 用例依赖“设置”首屏的 id（`homepage_title`、`search_action_bar_title`）；这是在 Android 16（API 36）模拟器上看到的，别的系统版本可能不同，此时先跑 P01，它红了就是 id 变了。

## 已知陷阱（写用例时遇到的）
- “设置”会记住上次停在的页面（如搜索页），所以会改变页面的用例要在 `onFlowComplete` 里退回来，否则下一条用例的首屏不对。这就是“启动状态要确定”。
- 不要用键盘候选条上可能出现的文字做断言（I02 起初断言 `abc` 就假通过了：候选条上也有 abc）。
- `assertTrue` 里引用未定义变量不会报脚本错误，而是被当成“假”（见 docs/FINDINGS.md M31）。
