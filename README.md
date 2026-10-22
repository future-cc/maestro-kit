# maestro-kit

给 Android（原生 / Flutter）项目用的 Maestro 运行套件：逐步进度、截图报告、失败归类、flow 静态检查、自测。

## 换了电脑 / 新队友

**先读 [docs/SETUP.md](docs/SETUP.md)**：需要装什么（Java 17+、Maestro CLI、adb、python3）、怎么拿到本仓库、换电脑最容易踩的坑、平台支持情况。装好后用 `bash .maestro/kit/e2e.sh --doctor` 一条命令检查缺什么。

> 注意：本仓库目前只在原电脑本地，**尚未推送到远端**；别的电脑要用，需要先推送或拷贝目录（见 SETUP.md 第 3 节）。

## 安装到项目

```bash
bash install.sh /path/to/project            # 首次：复制脚本、生成配置、更新 .gitignore、追加 CLAUDE.md 约定
bash install.sh /path/to/project --update   # 之后只更新 .maestro/kit 里的脚本
```

装完后：检查 `.maestro/e2e.config`，把 `.maestro/e2e.env.example` 复制为 `e2e.env` 填账号，然后 `bash .maestro/kit/e2e.sh --list`。

## 日常使用（在项目根目录）

```bash
bash .maestro/kit/e2e.sh                       # 按 FLOW_GLOBS 逐个跑
bash .maestro/kit/e2e.sh .maestro/x/y.yaml     # 单个
bash .maestro/kit/e2e.sh --build               # 先构建安装
bash .maestro/kit/e2e.sh --lint                # 只做静态检查
bash .maestro/kit/e2e.sh --doctor              # 环境自检（Java/Maestro/adb/设备/项目配置）
ANDROID_SERIAL=emulator-5554 bash .maestro/kit/e2e.sh   # 多设备时必须指定
bash .maestro/kit/e2e.sh --devices emulator-5554,emulator-5556   # 并行：flow 轮流分给各设备，每台一份子报告 + 合并摘要
bash .maestro/kit/e2e.sh --prep-device         # 新设备首次使用：确认系统引导弹窗、关闭动画（会持久改设备设置）
bash .maestro/kit/e2e.sh --tags smoke          # 套件自己按标签过滤（Maestro 对单个 flow 不过滤）
bash .maestro/kit/selftest.sh                  # 跑 .maestro/_selftest 自测并与预期比对
```

退出码：`0` 通过 · `1` 有失败 · `124` 有 flow 超时 · `2` 用法/环境错误。

## 内容

| 文件 | 作用 |
|---|---|
| `kit/e2e.sh` | 运行器 |
| `kit/e2e_summary.py` | 生成 `summary.md` / `report.html` / `result.json`，失败归类 |
| `kit/e2e_lint.py` | flow 静态检查（W001–W011，I001–I005） |
| `kit/selftest.sh` | 自测运行器（头部注释声明预期） |
| `kit/doctor.sh` | 环境自检（`e2e.sh --doctor` 调用它） |
| `templates/` | 配置、示例 flow、CLAUDE.md 片段 |
| `docs/SETUP.md` | **在其他电脑上使用：环境要求、获取方式、常见坑、平台支持** |
| `docs/FINDINGS.md` | **Maestro 与套件的已知问题清单、未覆盖项** |

## 约束
- 只依赖 bash（兼容 macOS 自带 3.2）、adb、maestro、python3 标准库。
- 脚本里 `$VAR` 后紧跟非 ASCII 字符必须写 `${VAR}`（见 docs/FINDINGS.md K2）。
- 反欺诈 / 验证码 / 设备校验属风控：脚本不处理、不绕过。
