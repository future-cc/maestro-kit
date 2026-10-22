# AGENTS.md — 给 AI 助手的上手手册（maestro-kit）

你在一台**新电脑**上拿到了这个仓库，任务通常是：把 Maestro 测试环境配好，并把套件装进某个 Android（原生 / Flutter）项目。
按下面的顺序做。**每一步先读输出再决定下一步，不要凭印象。** 人读的说明见 [docs/SETUP.md](docs/SETUP.md)，已知问题见 [docs/FINDINGS.md](docs/FINDINGS.md)。

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
`install.sh` 生成的 `.maestro/smoke/smoke_example.yaml` 里是**占位文字**（"替换成…"），**不换就一定失败**（lint **W012** 会提示；lint 没有 WARN 也不代表它能运行）。要换成被测 App 首屏上真实存在的文字或 id：App 装好后用 `maestro hierarchy` 看元素树，或直接问用户；**不要猜文案**。
```bash
bash .maestro/kit/e2e.sh --list     # 会跑哪些 flow
bash .maestro/kit/e2e.sh --lint     # 静态检查，先处理 WARN
bash .maestro/kit/e2e.sh <flow> --no-notify    # --no-notify：结束时不弹桌面通知
```
多台设备必须指定 `ANDROID_SERIAL=<序列号>`；用 `adb devices` 看。第一次需要装 App 时加 `--build`（会运行构建命令，先问用户）。

### 5. 读结果
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

## 出了问题先看哪里
- 多数现象在 [docs/FINDINGS.md](docs/FINDINGS.md) 有记录并带"套件的应对"（输入法把英文转汉字、`hideKeyboard` 会退出页面、`launchApp` 不等首帧、`--tags` 对单个 flow 无效、新设备系统弹窗、APK 装不上等）。
- 新项目最常见的两类：Compose 默认没有 `resource-id`（要加 `testTag` + `testTagsAsResourceId`）；Flutter 要用 `Semantics(identifier:)`。
- 想验证套件本身是否正常：在装了套件、并带有 `.maestro/_selftest/` 的项目里运行 `bash .maestro/kit/selftest.sh`。

## 不要假设的事
- 套件只在 **macOS（Apple Silicon）** 上测试过；Linux / Windows 没测，理论上可用但**没有验证**，遇到问题如实说明，不要硬套结论。
- 只验证过 Android；不支持 iOS。
- "全部通过"只代表这批用例通过，不代表应用没有问题。
