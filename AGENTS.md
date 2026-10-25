# AGENTS.md — 给 AI 助手的上手手册（maestro-kit）

> **给不是 Claude Code 的 AI 工具（Cursor、OpenCode、Codex 等）：** 你的工具可能没有自动读到本文件（`CLAUDE.md` 里的 `@AGENTS.md` 是 Claude Code 的引用写法）。如果用户让你“先读 AGENTS.md”，就完整读完本文件再动手；文中说“主动问用户”时，直接在对话里问即可，不依赖某个提问工具。你需要有终端权限（能运行 `adb`、`maestro` 和本仓库的脚本）。本套件只在 macOS 上用 Claude Code 验证过，其他工具和系统**没有验证**，遇到问题如实告诉用户，不要硬套结论。

你在一台**新电脑**上拿到了这个仓库，任务通常是：把 Maestro 测试环境配好，并把套件装进某个 Android（原生 / Flutter）项目。
按下面的顺序做。**每一步先读输出再决定下一步，不要凭印象。** 人读的说明见 [docs/SETUP.md](docs/SETUP.md)，已知问题见 [docs/FINDINGS.md](docs/FINDINGS.md)。

## 第 0 步：用户只说“想做自动化测试”时，你要主动问清楚，不要等他写提示词
用户的第一句话可能只有一句（如“帮我测一下 XX 项目的 XX 功能”“我想给这个 App 做自动化测试”）。**先别动手，也别要求他贴长提示词。**

**① 先自己查（不用问用户）：**
- 设备：`adb devices`（几台、真机还是模拟器、序列号；机型和品牌用 `adb -s <序列号> shell getprop ro.product.brand`）。品牌是小米 / 红米 / POCO（HyperOS / MIUI）的手机，**动手前**先读 [docs/REAL_DEVICE_NOTES.md](docs/REAL_DEVICE_NOTES.md)：这类手机每装一次 Maestro 驱动就弹一次“安装”确认，不提前设好 `--no-reinstall-driver`，会反复打扰用户（见硬性规则 11）。
- 机器环境：`bash kit/doctor.sh --json`。
- 项目：用户给了路径就**只读**地看项目类型、包名（`install.sh` 的识别逻辑可参考）、有没有已装的 `.maestro/`、项目自己的 `CLAUDE.md`。

**② 必须问用户（缺哪项问哪项，一次问完，不要猜、不要编）：**
1. **测什么**：被测项目路径（或 App 包名）、要测的功能/页面，范围是只读冒烟还是含写操作。
2. **环境**：正式环境还是测试环境；有哪些绝对不能碰的操作（支付、转账、投注、下单等）。**正式环境默认只读。**
3. **设备**：用哪一台（把 `adb devices` 的结果列给他选）；这台设备测试期间能不能被占用；真机首次运行是否有人在场（可能要在手机上点“安装”确认）。
4. **能不能动项目**：只读（推荐，测试目录建在项目外），还是允许把套件装进项目。
5. **账号**：用例需要登录时，让他提供测试账号；说明会放在**不入库**的 `e2e.env`、不会在对话里复述。不要让他把密码写进提示词。
6. **想要的结果**：只要单次冒烟，还是要连续稳定性（跑几次；正式环境上反复登录有风控风险，次数要他定）。

**③ 问完先复述一遍计划**（测什么、在哪台设备、哪个环境、不碰什么、跑几次），**等他确认再开始**。

**④ 测试目录建在项目外（项目只读时）：**
```bash
mkdir -p <测试目录>/.maestro/<模块>         # 用例放这里
# 写 <测试目录>/.maestro/e2e.config（参考 templates/e2e.config.tmpl：APP_ID、FLOW_GLOBS 等）
E2E_PROJECT_ROOT=<测试目录> bash <本仓库>/kit/e2e.sh <flow或目录> ...
```
`E2E_PROJECT_ROOT` 会让运行器把“项目根”指向测试目录，套件脚本留在本仓库里，不用复制，也不碰被测项目。（`selftest/` 用的就是这个办法；真机上的 `PRE_FLOW_CMD` 等配置照常写在测试目录的 `e2e.config` 里。）

## 按任务查文档（先读这张表，再读对应文档）
| 你要做的 | 读哪份 |
|---|---|
| 配环境、装套件 | 本文“配置步骤”、[docs/SETUP.md](docs/SETUP.md) |
| 需求做完后怎么走完整流程（探索→写 flow→入库→回归→验收） | [docs/WORKFLOW.md](docs/WORKFLOW.md) |
| 判断“这件事该脚本、该 Claude 探索、该排查还是该人看”；失败了怎么排查 | [docs/ROUTING.md](docs/ROUTING.md) |
| 要开发改代码：怎么加控件标识、让启动状态确定 | [docs/DEV_CONVENTIONS.md](docs/DEV_CONVENTIONS.md) |
| 要向团队要测试环境/账号/风控放行/数据重置 | [docs/TEST_ENV_REQUIREMENTS.md](docs/TEST_ENV_REQUIREMENTS.md) |
| 最后给人验收 | [docs/ACCEPTANCE_CHECKLIST.md](docs/ACCEPTANCE_CHECKLIST.md) |
| 遇到怪现象 | [docs/FINDINGS.md](docs/FINDINGS.md)、[docs/STABILITY_BASELINE.md](docs/STABILITY_BASELINE.md) |

## 仓库里有什么
| 路径 | 作用 |
|---|---|
| `kit/doctor.sh` | 环境自检；`--json` 输出机器可读结果（见下） |
| `install.sh` | 把 `kit/` 复制进项目的 `.maestro/kit/`，生成 `.maestro/e2e.config` 等 |
| `kit/e2e.sh` | 运行器（装进项目后用 `bash .maestro/kit/e2e.sh`） |
| `kit/e2e_lint.py` / `kit/e2e_summary.py` / `kit/selftest.sh` | flow 静态检查 / 报告生成 / 自测 |
| `templates/` | 配置模板、示例 flow、会追加进项目 `CLAUDE.md` 的约定片段 |

> 本文是写给 AI 的；[docs/SETUP.md](docs/SETUP.md) 是写给人的。两者冲突时，**以本文的"硬性规则"为准**。
> 命令里的相对路径（`kit/…`、`install.sh`）都假设**当前目录是 maestro-kit 仓库根目录**；对项目的操作建议用绝对路径。

## 配置步骤（按顺序）

### 1. 自检，读结果
```bash
bash kit/doctor.sh --json          # 在本仓库里：只查机器环境
# 在已装套件的项目里：bash .maestro/kit/e2e.sh --doctor --json
```
输出是一个 JSON：`checks[]` 里每项有 `id`、`status`（`ok` / `fail` / `warn` / `skip`）、`message`、`fix`、`fix_kind`、`needs_user_approval`。退出码 `2` 表示有必需项缺失。

- **`doctor` 是只读的**：它会执行 `adb devices`、`adb shell pm list packages`、`adb shell settings get …`、`adb shell ime list` 这几条只读命令，不修改设备。
- **要跑两遍**：先在本仓库里跑一遍（只查机器环境，`project` 一项会是 `skip`），**装进项目之后再在项目里跑一遍**（才会检查项目配置、App 是否已装、账号文件、输入法）。
- `fix_kind`（"谁来做"）和 `needs_user_approval`（"要不要先问"）是**两个独立维度**：`manual` + `needs_user_approval: true` 表示"只有用户能做，而且这是一件需要用户同意的事"。

处理规则：
- `fix_kind: "command"` 且 `needs_user_approval: false` → 可以直接执行。
- `needs_user_approval: true` → **先把要做的事和原因告诉用户，等明确同意再做**。包括：执行远程安装脚本（如 `curl … | bash`）、装 JDK / Android SDK、改设备设置（输入法、动画）、构建并安装 App、清理磁盘、任何需要凭证的事。
- `fix_kind: "manual"` → 你做不了，把步骤告诉用户（如启动模拟器、装 SDK 平台）。
- `fix_kind: "config"` → 改项目里的 `.maestro/e2e.config` 或设置环境变量。
- 修完重新跑一遍自检，**以新的输出为准**，不要假设修好了。
- **装完工具后 PATH 可能没更新**（新装的 Maestro / adb 要新开终端才生效）：先用 `command -v maestro adb` 验证。已知的默认安装位置可以在**本次会话里临时** `export PATH=…`（Maestro：`~/.maestro/bin`；adb：`~/Library/Android/sdk/platform-tools`）；**不要擅自修改用户的 shell 配置文件**（`~/.zshrc` 等），要改先问。
- 同一个依赖有多种装法（如 Maestro 的官方脚本 / Homebrew）时，**由用户选**，不要替用户选。

### 2. 把套件装进项目
```bash
bash install.sh /path/to/project
```
它会识别项目类型、appId、构建命令和 APK 路径，生成 `.maestro/e2e.config`、示例 flow、更新 `.gitignore`、追加 `CLAUDE.md` 约定。

> ⚠️ **`install.sh` 每次都会清空并重写项目里的 `.maestro/kit/`**（`--update` 也是）。**不要手改 `.maestro/kit/` 里的文件**；要改套件，去仓库里改，再 `install.sh <项目> --update`。项目自己的 `e2e.config`、flow、`CLAUDE.md` 不会被覆盖。

**装完必须读一遍生成的 `.maestro/e2e.config`**：
- `APP_ID` 是否为空；原生项目带 flavor / 多个 `flavorDimensions` 时，`BUILD_CMD`、`APK_PATH` 要和用户确认（脚本会打印"识别说明"）。
- 项目已有 `.maestro/e2e.config` 时不会被覆盖。

### 3. 账号等变量
- **只有 flow 里引用了 `${USERNAME}` 这类变量才需要账号文件**；离线、无登录的 App 不用建。`doctor` 的 `env_file` 项会替你判断（flow 没用到时会报 ok 并说明不需要）。
- 需要时：`cp .maestro/e2e.env.example .maestro/e2e.env`，然后**让用户提供真实值，不要编造、不要从别处推测、不要写进 flow**，也不要在对话里复述。

### 4. 把示例 flow 换成真的，再先看再跑
`install.sh` 生成的 `.maestro/smoke/smoke_example.yaml` 里是**占位文字**（"替换成…"），**不换就一定失败**（lint **W012** 会提示；lint 没有 WARN 也不代表它能运行）。要换成被测 App 首屏上真实存在的文字或 id：App 装好后用 `maestro hierarchy` 看元素树（**小米/红米真机除外，改用 `adb exec-out uiautomator dump`，见硬性规则 11**），或直接问用户；**不要猜文案**。
```bash
bash .maestro/kit/e2e.sh --list     # 会跑哪些 flow
bash .maestro/kit/e2e.sh --lint     # 静态检查，先处理 WARN
bash .maestro/kit/e2e.sh <flow> --no-notify    # --no-notify：结束时不弹桌面通知
```
多台设备必须指定 `ANDROID_SERIAL=<序列号>`；用 `adb devices` 看。第一次需要装 App 时加 `--build`（会运行构建命令，先问用户）。

### 5. 稳定性：新用例要连续 20 次全过才入库
```bash
bash .maestro/kit/e2e.sh <新flow> --repeat 20 --retry-failed 1 --no-notify
```
（与 [docs/WORKFLOW.md](docs/WORKFLOW.md) 第 5 步同一条命令。`--retry-failed 1` 只用来把偶发失败标成“不稳定”；不带它，失败就是失败，同样不能入库。）
- 每次运行都是独立的一次 `e2e.sh`，报告在 `.maestro/reports/<时间>_repeat/runs/<用例>/rNN_aK/`；汇总看 `<时间>_repeat/summary.md`（给人/AI 读）和 `result.json`（机器读）。
- **第一次就通过才算通过**；第一次失败、重跑才通过 = “不稳定(flaky)”，**不算通过**，也不能入库。
- 一个用例的结论：全部通过=稳定通过；全部失败=稳定失败；其余=不稳定。`summary.md` 会写“是否达到入库门槛（20 次）”。
- 不稳定时：先读 `summary.md` 里的失败归类和失败截图，**多数是应用冷启动状态不确定（弹窗、落点页）或等待不足**，修用例的启动步骤，而不是加 `optional` 或删断言。
- 重复运行期间同样**不要操作同一台设备**。每次运行约多花十几秒的 Maestro 启动开销。
- `--repeat` / `--retry-failed` 暂不能与 `--devices` 同用。
- 个别真机（如小米 HyperOS）：每次运行都弹“安装驱动”确认、`launchApp` 到不了前台。解法见 [docs/REAL_DEVICE_NOTES.md](docs/REAL_DEVICE_NOTES.md)：`--no-reinstall-driver` + `e2e.config` 的 `PRE_FLOW_CMD`。

### 6. 读结果
每次运行生成 `.maestro/reports/<时间>/`：**先读 `summary.md`**（每步状态、失败归类与建议、失败时间点日志），要给人看用 `report.html`。退出码：`0` 通过、`1` 有失败、`124` 超时、`2` 用法/环境错误。
**通过不等于真的成功**：登录这类关键流程要打开最后一张截图确认，不要只看退出码。

## 硬性规则（不要违反）
1. **反欺诈 / 验证码 / 设备校验 / 风控一律不处理、不绕过**，遇到就停下告诉用户。
2. **登录类 flow 不加 `clearState: true`**（会让设备变成"非授信设备"）。
3. **不下载、不安装第三方工具**（如 ADBKeyBoard 等输入法 APK）而不经用户同意。
4. **不提交** `.maestro/e2e.env`、`.maestro/reports/`；不要把账号、公司项目名、内部域名写进本仓库的任何文件——**本仓库是公开的**。
5. **跑测试期间不要操作同一台设备**（不要同时用 Maestro MCP / adb 点界面）；一次只让一个东西控制设备。
6. 改设备设置（`--prep-device`、`PREP_IME`）前先问用户；它们会持久改动设备，`PREP_IME` 会在结束时自动恢复，`--prep-device` 关闭的动画不会自动恢复。
7. 失败时**先读失败截图和日志再下结论**；不要为了让测试通过而改断言、删步骤。
8. 涉及支付、转账、下单等真实业务写操作的用例，不要在线上环境跑。
9. 写 shell 脚本时，`$VAR` 后面紧跟中文标点必须写成 `${VAR}`（macOS 自带 bash 3.2 否则会把它读成另一个变量名）。
10. 只在被问到或确有必要时才推送到任何远端；推送公开仓库前先扫描敏感内容。
11. **小米 / 红米 / POCO 真机上，每次 Maestro 启动都会重装驱动并弹“安装”确认**（[REAL_DEVICE_NOTES.md](docs/REAL_DEVICE_NOTES.md) R1）。所以：
    - 一律通过 `e2e.sh` 跑，并带 `--no-reinstall-driver`；**不要直接手敲 `maestro test`、`maestro hierarchy`、`maestro studio`**（它们每次都会让用户点一次确认）。确要直接调用 `maestro test`，也必须带 `--no-reinstall-driver`。
    - 看页面元素用 `adb exec-out uiautomator dump` 或截图，不用 `maestro hierarchy`。
    - 第一次运行前，**先告诉用户“手机会弹一次安装确认，请在旁边点一下”**，再运行；驱动装好后不应再弹。如果用户反馈又频繁弹，先检查自己是不是漏了参数，再查别的原因。
    - 测试全部结束后，告诉用户驱动还留在手机上，问是否卸载。

## 出了问题先看哪里
- 多数现象在 [docs/FINDINGS.md](docs/FINDINGS.md) 有记录并带"套件的应对"（输入法把英文转汉字、`hideKeyboard` 会退出页面、`launchApp` 不等首帧、`--tags` 对单个 flow 无效、新设备系统弹窗、APK 装不上等）。
- 新项目最常见的两类：Compose 默认没有 `resource-id`（要加 `testTag` + `testTagsAsResourceId`）；Flutter 要用 `Semantics(identifier:)`。
- 想验证套件本身是否正常：在本仓库里用模拟器跑 `ANDROID_SERIAL=<序列号> bash selftest/run.sh`（不依赖任何项目）；稳定性功能用 `bash selftest/stability.sh`。

## 不要假设的事
- 套件只在 **macOS（Apple Silicon）** 上测试过；Linux / Windows 没测，理论上可用但**没有验证**，遇到问题如实说明，不要硬套结论。
- 只验证过 Android；不支持 iOS。
- "全部通过"只代表这批用例通过，不代表应用没有问题。
