# 在其他电脑上使用 maestro-kit

先分清你是哪种情况，两种需要的东西不一样：

| 情况 | 你要做的 |
|---|---|
| **A. 项目已经装过套件**（比如某个已接入的项目：`.maestro/kit/` 已随代码提交），你只想在另一台电脑上跑测试 | 只需要准备**机器环境**（第 1 节），拉下项目代码即可，**不需要 maestro-kit 仓库** |
| **B. 想把套件装进一个新项目** | 需要**拿到 maestro-kit 仓库**（第 3 节）+ 机器环境 |

> 套件是“复制式”的：`install.sh` 会把脚本复制进项目的 `.maestro/kit/`，所以 A 情况下队友和 CI 不用另外安装它。代价是各项目里的副本版本可能不一致，见第 5 节。

---

## 1. 机器环境（所有情况都要）

| 需要 | 要求 | 怎么装 / 怎么查 |
|---|---|---|
| **Java** | **17 或更高**（Maestro 官方要求），建议设置 `JAVA_HOME` | `java -version` |
| **Maestro CLI** | 官方 CLI（套件在 2.11.0 上测试） | macOS / Linux：`curl -fsSL "https://get.maestro.mobile.dev" \| bash`；macOS 也可用 Homebrew（官方文档的三步：`brew tap mobile-dev-inc/tap`、`brew trust --formula mobile-dev-inc/tap/maestro`、`brew install mobile-dev-inc/tap/maestro`）；Windows 见官方文档。装完**重开终端**，`maestro --help` 能运行即可 |
| **adb** | Android SDK **platform-tools** 在 `PATH` 里 | macOS 默认在 `~/Library/Android/sdk/platform-tools`；`adb version` |
| **python3** | 只用标准库；套件在 3.9.6 上测试，更低版本未验证 | macOS：`xcode-select --install`；`python3 --version` |
| **bash** | macOS 自带的 3.2 即可（套件就是按 3.2 写的） | `bash --version` |
| **设备** | Android 模拟器，或开了 USB 调试的真机 | `adb devices` 要显示 `device` |
| 构建工具（**只在加 `--build` 时需要**） | Flutter 项目：flutter / fvm；原生项目：项目自带的 `./gradlew` + 对应 Android SDK 平台 | 看项目的 `.maestro/e2e.config` 里的 `BUILD_CMD` |

> `curl … | bash` 会下载并执行一个远程脚本。这是 Maestro 官方给出的安装方式，但是否执行由你决定；也可以用 Homebrew 或从 GitHub Releases 手动安装。

**装完后一条命令检查有没有漏：**

```bash
bash .maestro/kit/e2e.sh --doctor        # 在已装套件的项目里（会连项目配置一起查）
bash <maestro-kit 仓库>/kit/doctor.sh    # 只查机器环境
```

标记含义：`✓` 正常；`✗` 必需项缺失（退出码 2）；`!` 建议处理，不影响运行。它会检查 Java 版本、Maestro、adb、设备数量、磁盘、项目配置、App 是否已装、`e2e.env` 是否存在、输入法等。

## 2. 情况 A：在另一台电脑上跑已有项目的测试

```bash
git clone <项目地址> && cd <项目>
# 1) 装好第 1 节的环境，并启动模拟器/连上真机
bash .maestro/kit/e2e.sh --doctor
# 2) 账号等变量（不入库的文件，要在这台电脑上自己建）
cp .maestro/e2e.env.example .maestro/e2e.env     # 然后填写
# 3) 第一次建议加 --build（先构建并安装 App），之后不改代码就不用
bash .maestro/kit/e2e.sh --list                  # 先看会跑哪些 flow
bash .maestro/kit/e2e.sh --build                 # 构建安装并运行
```

几个**换电脑最容易踩的坑**（都来自实测，详见 [FINDINGS.md](FINDINGS.md)）：

- **连了多台设备必须指定**：`ANDROID_SERIAL=<序列号> bash .maestro/kit/e2e.sh …`；想并行用 `--devices a,b`。
- **新设备首次使用会弹系统引导**（如 “Viewing full screen”），盖住 App、拦截点击。加 `--prep-device`（或在 `e2e.config` 设 `PREP_DEVICE=1`），注意它会持久改设备的动画等设置。
- **默认输入法是中文拼音输入法**（搜狗等）时，英文输入会被转成汉字。在 `e2e.config` 里设 `PREP_IME`（例如 Gboard），运行期间临时切换、结束自动恢复。
- **存储紧张的模拟器装不上 debug 包**（`INSUFFICIENT_STORAGE`）：换空间大的模拟器，或把 APK 去掉不用的 ABI 后重新签名。
- **项目自己的前置条件**不在套件里：比如某些项目的登录依赖“已授信设备”，新设备要人工完成一次手机校验，见该项目 CLAUDE.md 的“已知问题”。
- 账号文件 `.maestro/e2e.env` 已被 `.gitignore` 忽略，**不会随代码带过来**，每台电脑要自己建。

## 3. 情况 B：把套件装进新项目

### 3.1 先拿到 maestro-kit 仓库

```bash
git clone https://github.com/future-cc/maestro-kit.git
```

这是**公开仓库**，不要往里提交账号、公司项目名或内部域名。没有网络、或想离线使用时，也可以把整个 `maestro-kit/` 目录（含 `kit/`、`templates/`、`install.sh`、`VERSION`）用压缩包或 U 盘拷过去，不依赖其他东西。

### 3.2 安装

```bash
bash maestro-kit/install.sh /path/to/project
```

它会自动识别项目类型（Flutter / 原生 Android）、appId、构建命令和 APK 路径，生成 `.maestro/e2e.config`、示例 flow，更新 `.gitignore`，并把测试约定追加到项目的 `CLAUDE.md`。**装完要检查 `.maestro/e2e.config`**，尤其是有多个 flavor / 多 flavorDimensions 的原生项目（脚本会提示你确认）。

然后：`cp .maestro/e2e.env.example .maestro/e2e.env` → 填账号 → `bash .maestro/kit/e2e.sh --doctor` → 改示例 flow → 运行。

## 4. 配合 Claude Code 使用

- `install.sh` 追加到项目 `CLAUDE.md` 的约定，会让 Claude 统一用 `e2e.sh` 跑测试、按固定顺序读报告排查。注意：如果项目把 `CLAUDE.md` 加进了 `.gitignore`（有的项目就是这样），这段约定**不会随代码同步到别的电脑**，需要在那台电脑上重新 `install.sh` 或手动复制。
- 想让 Claude 用 Maestro MCP 实时操作设备，**在每台电脑上自己执行**：`claude mcp add maestro -- maestro mcp`（用命令名，不要写绝对路径）。不要把含本机绝对路径的 `.mcp.json` 提交到仓库，队友的路径不一样。
- 跑测试期间不要让 Claude 同时操作同一台设备。

## 5. 版本与更新

- 套件版本在仓库根目录的 `VERSION`，项目里的副本在 `.maestro/kit/VERSION`；`--doctor` 会显示项目里的版本。
- 更新项目里的副本：`bash maestro-kit/install.sh /path/to/project --update`（只覆盖 `.maestro/kit/`，不动配置和 flow）。
- 副本会被提交进项目仓库，更新后记得提交。

## 6. 平台支持（如实说明）

| 平台 | 状态 |
|---|---|
| **macOS（Apple Silicon）** | 开发和全部测试所在的环境 |
| **Linux** | **没测过**。脚本只用 bash / awk / sed / adb / python3 等通用命令，桌面通知依赖 macOS 的 `osascript`，缺失时会自动跳过；理论上可用，请先跑 `--doctor` 和 `selftest.sh` 验证 |
| **Windows** | **没测过**，需要在 Git Bash 或 WSL 里运行 bash 脚本；Maestro 本身的 Windows 安装方式见官方文档 |
| **iOS** | 不支持（按约定先只做 Android） |

要在新平台上验证套件本身是否可用：装好环境、连上设备，在装了套件的项目里运行 `bash .maestro/kit/selftest.sh`（需要该项目里有自测用例目录 `.maestro/_selftest/`）。
