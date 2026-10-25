# Maestro 与 maestro-kit 的已知问题清单

测试环境：Maestro CLI 2.11.0 · Android 模拟器（Pixel 8a, API 36 / sdk_gphone64_arm64）· Flutter 调试包 · macOS 自带 bash 3.2。
依据：一个示例 Flutter 项目的 `.maestro/_selftest/` 下 75 个自测用例的实际运行结果（`bash .maestro/kit/selftest.sh`）。

## 一、Maestro 本身的问题 / 坑（已实测确认）

| # | 现象 | 影响 | 套件的应对 |
|---|---|---|---|
| M1 | **Android 上 `inputText` 含中文等非 ASCII 字符时静默丢弃**：输入 `中文abc`，输入框里只有 `abc`，步骤仍显示 COMPLETED | 用例"通过"但输入是错的 | lint **W008** 在运行前警告；**没有找到不依赖第三方工具的绕过办法**（见下方实验） |
| M2 | **一次运行多个 flow 时不打印逐步进度**，只显示 `Waiting for flows to complete...` | 人看不到执行到哪 | `e2e.sh` 逐个 flow 单独运行 |
| M3 | **加 `--format JUNIT` 后单个 flow 也不再打印逐步进度** | 同上 | `e2e.sh` 不使用 `--format`，报告由 `commands.json` 生成 |
| M4 | **`assertNotVisible` / `notVisible` 会被加载遮罩、弹窗误判通过**（遮罩让元素从元素树里消失） | 登录失败也显示"通过"，实测出现两次 | lint **W001**；规则：必须有正向断言 |
| M5 | **同名 `takeScreenshot` 静默覆盖**，只保留最后一张 | 人工核对时少图 | lint **W007** |
| M6 | **截图名含 `/` 会创建子目录**（`a/b` → `a/b.png`） | 简单遍历会漏图 | 摘要脚本递归复制；lint **W007** |
| M7 | **JS 表达式出错时，`commands.json` 里该步骤停在 `RUNNING`，没有 `error` 字段**，只有控制台堆栈 | 只读 commands.json 得不到失败原因 | 摘要脚本回读控制台输出，归类为 `script_error` |
| M8 | **步骤 `label` 里的 `${变量}` 在控制台输出里不展开**（原样显示 `你好 ${WHO}`），但 `commands.json` 的 `evaluatedCommand` 里是展开的 | 控制台看到的和实际执行的不一致 | 报告使用 `evaluatedCommand` |
| M9 | 环境变量值含引号（如 `a b&c"d$e`）时 picocli 打印 `Unbalanced quotes` 警告，**但值本身是完整传入的**（长度、字符位置均正确） | 只有噪音，无功能影响 | 无需处理，记录在案 |
| M10 | 文本选择器是**正则**：`标签甲\|标签乙` 可作备选；含未闭合 `(` 的文本不会报"正则非法"，只是匹配不到 | 含括号等特殊字符的文案需转义，否则看起来像"元素不存在" | 记录在案 |
| M11 | `scrollUntilVisible` 找不到元素时的错误是 `No visible element found`，**和 `tapOn` 的 `Element not found` 措辞不同** | 按单一关键字归类会漏 | 摘要脚本两种都识别 |
| M12 | 调试输出目录嵌套：`artifacts/<flow>/<时间戳>/<flow>/...`（指定 `--test-output-dir` 后依然多一层） | 路径写死会找不到 | 摘要脚本递归查找 `commands.json` |

| M13 | **`--include-tags` 对单个 flow 文件无效**：给一个带 `smoke` 标签的 flow 传 `--include-tags nosuchtag`，flow 照常完整执行并返回 0 | 以为过滤了，其实全跑了；标签不匹配也"通过" | 套件自己按 flow 头部 `tags:` 过滤（`--tags` / `--exclude-tags`），无匹配时退出码 2 |
| M14 | **`selected` / `checked` 状态选择器在 Flutter 自绘控件上不可用**：元素树里只有 `clickable`、`enabled`；`selected: true` 断言失败，`enabled: true` 可用 | 无法用状态判断"当前选中的标签" | 记录在案；改用文案/位置等其他断言 |
| M15 | **同类 JS 错误的记录不一致**：`assertTrue` 条件里 JS 出错 → `commands.json` 中步骤停在 `RUNNING` 且无 error；`runScript` 语法错误 → `FAILED` 且带 `SyntaxError` 信息 | 归类逻辑要两条路径都处理 | 摘要脚本先读 error，没有再回读控制台；`SyntaxError` / `TypeError` / `ReferenceError` 都归 `script_error` |
| M16 | **从屏幕最左边缘（0%）起始的 `swipe` 会触发系统返回手势，App 直接退到桌面** | 看似普通滑动，实际退出了 App | lint **W009**：swipe 的 start/end 百分比坐标在 ≤1% 或 ≥99% 时警告 |
| M17 | **`launchApp` 是冷启动（默认先停掉 App），且不等首帧**：`pressKey Home` 后再 `launchApp`，5 秒后仍是空白启动页；`waitForAnimationToEnd` 也不会等 App 渲染完成 | 紧跟 `launchApp` 的截图/断言会撞上启动页 | lint **W010**：`launchApp` 后紧跟截图/`waitForAnimationToEnd`/否定断言等，或它是最后一步时警告；模板 `launch_app.yaml` 已显式等待首屏 |
| M18 | Maestro **自动保存的失败截图在更深一层目录**（`screenshots/step-NNN-<命令>-<label>.png`），不在 flow 目录顶层 | 只扫顶层会漏掉失败截图 | 摘要脚本递归查找并以 `auto_` 前缀拷入报告 |

| M19 | **`setOrientation` 报成功但屏幕可能没转**：`LANDSCAPE_LEFT` 步骤 COMPLETED，截图仍是竖屏（原因未验证：可能是 App 锁定竖屏，也可能与模拟器设置有关——测试时该模拟器 `accelerometer_rotation=0`，即自动旋转关闭） | 横屏用例会假通过 | 横屏用例必须配截图/断言确认；记录在案 |
| M20 | **`WARNED` 状态不显眼**：`optional: true` 的步骤找不到元素时只标 WARNED，退出码仍是 0，终端和旧报告里几乎看不出 | 掩盖"该出现的元素没出现" | 摘要和网页报告新增"⚠ 警告步骤"区块；lint **I004** 提示 |
| M21 | **`extendedWaitUntil` 超时有 ±0.5s 误差，且可能提前结束**：timeout 3000 实际 3470ms，timeout 1000 实际 712ms | 不能用它做精确计时 | 记录在案 |

| M22 | **Maestro 原生分片 `--shard-split N` 可用**：自动识别 N 台设备并均分 flow（`Will split 8 flows across 2 shards`），结果带 `[shard N]` 前缀，产物目录名形如 `<flow>-shard-N`；**但同样没有逐步进度**，只有每个 flow 的通过/失败汇总 | 并行能用，但看不到执行到哪 | 套件自己实现并行 `--devices a,b`（见下），保留逐步进度 |
| M23 | **全新设备首次使用会弹 Android 系统引导**（如沉浸模式提示 "Viewing full screen / Got it"），盖在 App 上拦截点击、拖慢用例（一个 flow 耗时 1 分 32 秒），表现为“元素找不到/断言不成立” | 新设备/新模拟器上用例莫名失败 | 套件 `--prep-device`（或 `PREP_DEVICE=1`）：`settings put secure immersive_mode_confirmations confirmed` 并关闭三项动画；**注意这会持久改变设备设置** |
| M24 | **`flutter build apk --debug --target-platform android-arm64` 不会去掉插件自带的其他 ABI 原生库**：APK 体积几乎没变（114 MB），在存储紧张的设备上 `INSTALL_FAILED_INSUFFICIENT_STORAGE` | 装不上，Maestro 只会说 App 没安装 | 套件 `--build` 失败时打印真实 adb 错误、设备剩余空间和提示；实际瘦身要手动删 `lib/armeabi-v7a`、`lib/x86_64` 后重新对齐签名（76.7 MB） |
| M25 | 新设备默认连**测试环境**（本项目接口全部 404），首页显示“您访问的页面出错啦”，依赖首页标签的用例失败；而只检查底部导航的用例照样通过 | 同一批用例在不同设备上结果不同 | 并行前用 `.maestro/_tools/prep_env_on_fresh_device.yaml` 让所有设备处于同一环境 |

| M26 | **设备默认输入法是中文拼音输入法时，Maestro 输入的英文会被转成汉字**：搜狗输入法下 `inputText: "Buy milk"` 得到 "不要"，`"two bottles"` 得到 "听我"；切到 Gboard 后正确。只在普通文本框暴露——示例项目的登录框是密码/可见密码类型，输入法不做拼音组合，所以此前没发现 | 英文输入内容错乱，且表现为"断言失败"，极难联想到输入法 | 配置 `PREP_IME`：运行期间临时切换输入法，结束（含失败/中断）后自动恢复 |
| M27 | **`hideKeyboard` 在软键盘没显示时会发送返回键，直接把当前页面退出**：新建任务页输入标题后 `hideKeyboard`，页面退回了列表（模拟器启用硬件键盘时软键盘不显示，只剩输入法的小工具条）。示例项目的登录页禁止返回，所以先前的 Z03 测试没发现 | flow 莫名其妙离开当前页，后续步骤全部找不到元素 | lint **I005** 提示；写法上优先点一个中性元素收起焦点，或干脆不收键盘 |
| M28 | **Compose 控件默认没有 `resource-id`**：architecture-samples 元素树里 10 个有文字的节点 0 个带 id，只有无障碍描述（`New Task`、`Save task`、`Open Drawer` 等）可按文字选择。实测：根节点加 `Modifier.semantics { testTagsAsResourceId = true }` 并给控件加 `testTag("add_task_fab")` 后，`id:` 选择器可用 | 新 Compose 项目只能靠文字选择，文案/多语言一改就失效 | 模板 CLAUDE.md 已写明 Compose 的做法；本次已在真实项目上验证 |

| M29 | **`extendedWaitUntil` 的 `visible: ".+"`（任意文字）会被上一个 App 的内容满足**：`launchApp` 刚发出，界面还是原来的 App，等待立刻通过，随后的截图截到的是两个 App 的切换过渡画面（实测：半个上一个 App 的页面滑出）。套件自己的 `launch_app.yaml` 模板就这样写过 | "等首屏"等于没等，截图和断言撞上旧界面 | lint **W011**；模板已改为等被测 App 自己的元素（resource-id 或确定的文案） |
| M30 | **元素树会混入输入法自己的窗口节点**（实测有搜狗的 `com.sohu.inputmethod.sogou:id/...` 约 8 个）；文本选择器若恰好和输入法界面文字重合会误命中 | 键盘弹出时 `hierarchy` 变长、选择器可能歧义 | 记录在案；优先用被测 App 的 id |

| M31 | **`assertTrue` 条件里的 JS 异常被吞成“假”**：`assertTrue: ${notDefined == 1}` 报的是 `Assertion is false: false is true`，没有 ReferenceError；而 `evalScript` / `runScript` 里的同类错误会报脚本错误（实测 2.11.0） | 条件里写错变量名，只会看到“断言不成立”，容易当成 App 的问题；套件归类为 `assertion_failed` 而不是 `script_error` | 记录在案；变量是否传入可先用 `evalScript` 检查；自测 F04（assertTrue）与 E03/F05/F06（script_error）对照 |
| M32 | **M1（中文输入被丢）在最近一次实测中没有复现**：Android 16 模拟器 + Gboard + Maestro 2.11.0，向“设置”搜索框 `inputText: "中文abc"`，截图确认输入框里是完整的 `中文abc`；M1 当时的环境是另一台设备/应用，**原因未查清**（可能与系统版本、被测应用的输入框类型有关） | 不能再断言“Maestro 一定丢中文”，也不能断言“一定不丢” | lint W008 仍保留（保守）；自测 I02 是哨兵：断言完整 `中文abc` 可见，环境变了会变红。注意不要断言 `abc`——键盘候选条上也有，会假通过 |
| M33 | **软键盘会盖住 Compose 页面右下角的保存按钮**：待办 App 新建页输入标题和描述后，Gboard 弹出，“Save task” 悬浮按钮被盖住，`tapOn` 报 `Element not found`（同一条用例在另一次模拟器状态下通过；该模拟器当前 `show_ime_with_hard_keyboard=1`，之前的值未记录）。基线里 30 次全失败 | 用例结果取决于“软键盘是否显示”这个设备状态，不是 App 或脚本的偶发问题 | 输入后 `hideKeyboard`（键盘会显示时有效；10 次验证通过），但键盘没显示时它会退出页面（M27）——要让测试设备键盘行为固定；见 docs/STABILITY_BASELINE.md |
| M34 | **ANR（应用无响应）没有被识别为崩溃类**：笔记 App 冷启动超时，logcat 有 `ANR in <包名>` + `Reason: … failed to complete startup`，摘要把它归类为 `assertion_failed`，真实原因要自己翻 logcat（基线 30 次里 1 次） | 读摘要会误判成断言问题 | 记录在案；套件尚未支持 ANR 归类（待办）。排查时遇到“截图是别的 App 的页面”先 grep `ANR in` |
| M35 | **`tapOn` 默认会等页面“静止”，在实时刷新的页面上每次要 2~8 秒，但这个等待同时在掩盖用例缺少的显式等待**：某个真实 Flutter 项目上实测，一个 27 步用例每次约 56s，其中步骤 40s、`PRE_FLOW_CMD` 8s、Maestro 启动/收尾约 8s；断言约 0.2s、截图约 0.5s、每个 `tapOn` 2~8s。给所有 `tapOn` 加 `waitToSettleTimeoutMs: 500` 后单次省 4~5s，但 3 次里失败 1 次：点“早盘”后列表还在加载，按位置点第一场点空了 | 不要整体缩短；要缩就只在**点击后紧跟显式等待**的地方用，并且位置点击前先 `extendedWaitUntil` 等列表出现。每次报告的“耗时分解”可以看到时间花在哪 |

### 已排除的怀疑（实测后确认**不是**问题）
- "中文被丢和输入法有关"（M1 的实验）：默认输入法为搜狗时丢字；**临时切到 Gboard 后结果相同**（输入 `中文abc` 只剩 `abc`），所以与输入法无关，是 Maestro 对非 ASCII 的处理问题。
  - 系统自带的办法都走不通：`adb shell input text` 只支持 ASCII；`cmd clipboard` 在 API 35 上没有可用子命令。
  - 剩下的办法都需要**安装第三方工具**（如 ADBKeyBoard 输入法），属于下载外部文件，本次没有做。若项目确实需要自动输入中文，可选方向：① 在 App 的 debug 包里加测试专用入口预填内容；② 用 `copyTextFrom` / `pasteText` 从屏幕上已有的中文文本复制（Flutter 输入框上已验证可用）；③ 经团队同意后引入 ADBKeyBoard。
- "点已选中的标签会因 `retryTapIfNoChange` 变慢"：对比实验中默认值 2.6s、`retryTapIfNoChange: false` 2.5s、点未选中标签 1.5s，差异不显著。之前观察到的 `tapOn` 4–12 秒波动，更可能是首页数据实时刷新导致 Maestro 等待界面稳定，随负载变化。

### 已确认"不是 Maestro 的问题"（避免误判）
- `eraseText`：输入 10 个字符擦 4 个，剩余 6 个，行为正确。
- `copyTextFrom` / `pasteText`：在 Flutter 输入框上可用，`pasteText` 是追加。
- `hideKeyboard`：无键盘时不报错；收起后输入框内容保留。
- `appId: ${APP_ID}`：可以用 `-e APP_ID=...` 插值。
- `runFlow.when` 的 `visible` / `notVisible` 两个分支、`repeat`、`retry`、`optional: true`（找不到时为 WARNED 而非失败）：均符合预期。
- Flutter 通过 `Semantics(identifier:)` 暴露为 `resource-id`，`id:` 选择器可用。
- `longPressOn`、`doubleTapOn`、按百分比坐标 `tapOn: point`、`swipe`（起止坐标 / 从元素出发 / 带 duration）、`scroll`：在 Flutter 标签与列表上执行均无报错，坐标点击能正确选中"标签B"标签。
- 相对选择器 `leftOf` / `rightOf` / `above` / `below`：正向、反向均符合预期；`index`（含越界报 `Element not found`）符合预期。
- 文本选择器是**整串正则匹配**：`标` 不匹配 `标签A`，`.*A` 匹配。
- `runScript`（读 env、写 `output`）、`onFlowStart`（在主流程前执行）、**`onFlowComplete`（flow 失败时仍执行）**、`repeat while`（`true:` 与 `visible:` 条件）：均符合预期。
- `inputRandomText` / `Number` / `Email` / `PersonName`：生成内容均为 ASCII（人名为 `JoieNader` 形式），不会踩 M1。
- 账号输入框有最大长度 16（App 行为，不是 Maestro 的）。
- **并行（套件 `--devices a,b`）实测**：8 个只读 flow 分给两台 arm64 模拟器（一台 4 KB 页，均为 Android 15），**8/8 通过**，各设备独立子报告 + 合并摘要，flow 内耗时约 44 s / 47 s（串行约 91 s）；终端每行带 `[设备]` 前缀，两台的逐步进度同时可见；两个 Maestro 进程同时运行未出现 adb 或端口冲突。
- **原生 Android 项目试装（android/architecture-samples，Compose，Apache-2.0）**：`install.sh` 自动识别为 `android-native`，appId、`./gradlew assembleDebug`、`app/build/outputs/apk/debug/app-debug.apk` 全部正确；Gradle 8.11.1 首次构建 2 分 40 秒、APK 23.5 MB；`--build` 构建→安装→运行全链路可用；"新建任务并确认出现在列表"用例通过（截图确认列表里有 `Buy milk` 和 "Task added" 提示）；`clearState` 在离线、无账号的 App 上可以放心使用。仓库主分支最近一次提交是 2025-07-17。
- **第二个原生项目：FossifyOrg/Notes（传统 XML View，GPL-3.0，最近提交 2026-10-14）**：Gradle 9.8.1 / AGP 9.4.1，首次构建 3 分 03 秒，APK 30.2 MB。元素树里有 **19 个 `resource-id`**（`new_note`、`open_search`、`text_note_view`…），**`id: "text_note_view"` 不带包名前缀即可匹配**，View 项目不用像 Compose 那样打补丁。用例"写笔记""新建带标题的第二篇并用搜索找到"通过，截图确认标签页 `Groceries`、正文 `milk and eggs`、搜索高亮 `eggs`。
- **第二批（单设备）**：`openLink`（外部网页）、`launchApp` 的 `stopApp: false`（回到前台并**保留页面状态**，已验证原先选中的标签仍选中）、`startRecording` / `stopRecording`（产物在 `artifacts/<flow>/<时间>/<flow>/startRecording/<名>.mp4`，约 20 秒 0.9 MB）、`assertScreenshot`（先 `takeScreenshot` 同名再比对，通过）、`setLocation`、`addMedia`、`pressKey`（Volume Down / Tab / Backspace，无输入焦点也不报错）、从屏幕顶部边缘 `swipe` 拉出通知栏后用 `back` 关闭、`setAirplaneMode`（状态栏出现飞机图标，App 显示"加载错误/解析错误"，`onFlowComplete` 恢复网络有效）：均可用。
- 附带的 App 现象（非 Maestro 问题）：飞行模式下 App 提示"解析错误"而不是网络错误，可能值得产品侧看一眼。

## 二、maestro-kit 自己踩过并已修复的 bug

| # | 问题 | 根因 | 修复 |
|---|---|---|---|
| K1 | `e2e.sh` 结束时**永久卡死** | 裸 `wait` 会等 `adb logcat` 这个永不退出的后台进程 | 先 kill logcat 再 `wait` 指定 PID |
| K2 | 所有失败路径**丢失摘要/失败截图，超时返回 1 而不是 124** | `"$CODE）"`：变量名后紧跟全角字符，macOS bash 3.2 把高位字节当成变量名一部分，`set -u` 报 unbound 并退出。**仅在真实终端的语言环境下发生，工具环境无法复现** | 所有变量改 `${VAR}`；用 `LC_ALL=C` 验证 |
| K3 | `install.sh` 生成的 `BUILD_CMD` 乱码 | `sed` 替换串里 `&`（`&&`）被当成"匹配文本" | 转义 `& \ \|` |
| K4 | 只传 `-e` 不传路径时，`-e` 被当成 flow 路径，退出码 2 被误标为"超时" | 参数解析 | 解析重写；超时改用独立退出码 124 |
| K5 | lint 误报：把 `label:` 当成输入值 | 正则取值错误 | 优先取 `text:` 字段 |
| K6 | 失败归类缺口：`scrollUntilVisible`、JS 错误被归为 `unknown` | 只匹配了 `Element not found` | 补充匹配（见 M7、M11） |

| K7 | 两个 `e2e.sh` 同一秒启动会写进同一个报告目录 | 目录名只精确到秒 | 目录名追加设备序列号；并行模式用 `<时间>_parallel/<序列号>/` |
| K8 | `--tags` 实际无效（M13） | 把过滤交给了 Maestro | 套件自己过滤 |
| K9 | 失败截图、录屏没进报告（M18、录屏） | 只扫了顶层目录 | 递归查找并拷贝，录屏进 `videos/` 并在网页报告里内嵌播放 |
| K10 | **`--prep-device` 在并行模式下也作用于用户的主模拟器**（我自己踩的：把 5554 的动画关了，事后手动恢复到 1.0） | 准备步骤会持久改设备设置 | 输出里明确提示并给出恢复命令；默认关闭，需显式 `--prep-device` / `PREP_DEVICE=1` |
| K11 | **崩溃误判**：任何进程的 "Process xxx has died"（系统正常回收后台进程）都被当成被测 App 崩溃，示例项目的断言失败被错误归类为 `app_crash` | 日志解析没有限定包名 | FATAL / native crash / 进程退出线索都必须能确认属于 `APP_ID` 才算；Y02 崩溃注入回归仍通过 |
| K12 | **logcat 是整台设备的日志**，别的应用（如同时在跑的另一个 Flutter App）的 `[http-error]` 被算到被测 App 头上 | 没有按进程过滤 | 从 `Start proc <pid>:<包名>/` 建立被测 App 的 pid 集合，只采信这些进程的 flutter 输出；找不到映射时不过滤 |
| K13 | **套件自己的示例模板违反自己的 W010**（`launchApp` 后紧跟截图） | 加规则时没检查模板 | 模板改为先 `extendedWaitUntil`；教训：新增 lint 规则后要对模板和样例跑一遍 |
| K14 | 新写的输入法恢复代码里又出现 `$PREP_IME（…）`（K2 同款） | 凭记忆写脚本 | 提交前用正则扫描"变量名后紧跟非 ASCII"；已全部加花括号 |
| K15 | **原生项目识别只认字面量 `applicationId = "…"`**：Fossify Notes 里是 `project.property("APP_ID")`（值在 `gradle.properties`），appId 识别为空 | 正则太窄 | 解析 `project.property/findProperty/properties[...]` 并去 `gradle.properties` 查值 |
| K16 | **debug 包名带后缀被漏掉**：真实包名是 `org.fossify.notes.debug`，配置里的 APP_ID 少了 `.debug`，运行前"App 是否已安装"检查会误报没装 | 没读 `buildTypes.debug.applicationIdSuffix` | 解析并拼接 debug 后缀 |
| K17 | **有 product flavor 时 `assembleDebug` 会构建所有 flavor，APK 路径也不对**（Notes 有 foss / gplay） | 模板写死 `assembleDebug` 与 `app-debug.apk` | 识别 flavor，生成 `assemble<Flavor>Debug`，并提示可改；多 flavorDimensions 时提醒手动确认 |
| K18 | **APK 文件名不可预测**：Notes 实际是 `notes-13-foss-debug.apk`（自定义 archivesName + 版本号），而不是 `app-foss-debug.apk` | 把文件名写死 | `APK_PATH` 支持通配符（`…/foss/debug/*.apk`），构建后取最新一个 |
| K19 | **应用模块检测依赖插件 id 字符串**：Notes 用版本目录别名 `alias(libs.plugins.android)`，文本里没有 `com.android.application` | 判据错 | 改为以 `applicationId` 是否存在为准（库模块没有它） |
| K20 | **`FLOW_GLOBS` 未加引号，`*/*.yaml` 被提前展开**：某个真实 Flutter 项目上实测 `--list` 和批量运行都报“没有找到可运行的 flow” | `for g in $FLOW_GLOBS` 让通配符先在**项目根目录**展开，匹配到 `app/pubspec.yaml` 之类，拼成 `.maestro/app/pubspec.yaml` 后不存在 | 先按空白拆成数组再遍历（`read -r -a`）；`selftest/globs.sh` 回归（不需要设备） |

> 经验：**脚本里 `$VAR` 后面紧跟中文标点时一律写成 `${VAR}`**；`install.sh` 不检查这点，请在写新脚本时自查。

## 二点五、稳定性观察（偶发失败的真实样本）

- **示例 Flutter 项目的一个用例在一次回归里失败，紧接着重跑 3 次全部通过**（共 4 次运行，1 次失败）。失败截图显示：App 冷启动后停在了一个和预期首页不同的页面，并盖着一个营销弹窗，所以等待首页元素超时。
- 这**不是 Maestro 或套件的问题**，而是 **App 冷启动落点和弹窗不固定**（上一轮测试把 App 留在了某个页面，启动后又弹出营销弹窗）。套件的报告在这次失败里工作正常：失败截图、归类 `assertion_failed`、日志片段都能直接定位原因。
- **对写 flow 的启示**：不要假设冷启动一定落在首页；启动后要先把 App 带到确定状态（关弹窗 / 回首页），再做断言。这类偶发只有靠**连续多次运行**才能量化，这也是“稳定性测试”要解决的问题：现在已有 `--repeat` / `--retry-failed`，第一次基线见 [STABILITY_BASELINE.md](STABILITY_BASELINE.md)。

## 三、本次没有覆盖到的情况（不假装"全部"）

已测过的命令见上；以下**仍未测试**：

- **iOS**：按约定先只做 Android。
- **真机**：只在模拟器上测试；USB 授权、息屏、厂商弹窗未覆盖。
- **并行的更大规模与边界**：只测了 2 台、8 个只读 flow；3 台以上、flow 数少于设备数、有状态的 flow（同账号多端登录会互相踢线）、`--shard-all`（每台跑全部 flow）未测。**16 KB 页大小**镜像（`sdk_gphone16k`）上 App 能否正常运行未验证（那台设备存储已满，装不上）。
- **原生项目只验证了 2 个项目（1 个 Compose、1 个 XML View）共 4 条用例**：Compose 列表滚动与勾选/删除、抽屉、真实业务复杂度的页面、release 构建、多语言、多 flavorDimensions、多模块工程均未测。
- **`assertScreenshot` 的失败路径**：只测了"同一张图比对通过"，没测"画面不同时是否真的失败"、阈值与 `cropOn` 的行为、基准图的存放约定。
- **`setOrientation` 的真实效果**：命令成功但截图仍竖屏，原因（App 锁竖屏 / 模拟器设置）未查清，也没测 `LANDSCAPE_RIGHT`、`UPSIDE_DOWN`。
- **权限弹窗**（相机、定位、通知等系统授权对话框）、`setAirplaneMode` 之外的弱网模拟（限速、丢包）。
- **`pressKey` 其余按键**（Power、Lock、Menu、媒体键等）、`launchApp` 的 `arguments`、`toggleAirplaneMode`。
- **WebView / 混合页面**（项目用了 dsbridge；会产生服务端会话的入口未触碰）、视频与地图等 platform view、长列表的真正懒加载边界（只滚动了 6 次）。
- **`clearState`**：故意没测（会让设备失去授信）。
- **Maestro Cloud / CI**：CI 里每次是新设备，会遇到"设备授信"问题（见使用该套件的项目自己的文档）。
- **`--analyze`（AI Insights）、Maestro Studio、Maestro MCP**：未评估。
- **崩溃类型**：只模拟了 SIGSEGV；OOM、Dart 未捕获异常的日志格式未逐一验证。ANR 只见过一个样本（M34），套件尚未识别。
- **日志解析**只认 Flutter dio 的 `[http-error]`；okhttp / Retrofit / Ktor 的格式未适配。
- **时区**：失败时间点日志切片按宿主机本地时间对齐，模拟器时区不同会对不上。
- **测试范围**：只在一个示例 Flutter 项目的登录页、首页、个人页，且连线上环境（只读），没碰支付类操作和列表交互。
