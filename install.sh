#!/usr/bin/env bash
# 把 maestro-kit 装进一个项目（复制式：项目自带一份，队友和 CI 不需要额外安装）。
# 用法: bash install.sh <项目根目录> [--update]
#   首次安装: 复制 kit/ 到 <项目>/.maestro/kit，生成 e2e.config / e2e.env.example，更新 .gitignore，追加 CLAUDE.md 约定
#   --update: 只覆盖 .maestro/kit 里的脚本，不动项目自己的配置、flow、CLAUDE.md
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="${1:-}"; MODE="${2:-}"
[ -n "$PROJ" ] && [ -d "$PROJ" ] || { echo "用法: bash install.sh <项目根目录> [--update]"; exit 2; }
PROJ="$(cd "$PROJ" && pwd)"

mkdir -p "$PROJ/.maestro"
rm -rf "$PROJ/.maestro/kit"
mkdir -p "$PROJ/.maestro/kit"
cp "$HERE"/kit/* "$PROJ/.maestro/kit/"
cp "$HERE/VERSION" "$PROJ/.maestro/kit/VERSION"
echo "已安装脚本到 $PROJ/.maestro/kit （版本 $(cat "$HERE/VERSION")）"
[ "$MODE" = "--update" ] && { echo "仅更新脚本，完成。"; exit 0; }

# ---------- 识别项目类型与 appId ----------
TYPE="unknown"; APP_ID=""; BUILD_CMD=""; APK_PATH=""
gradle_app_id() { sed -n 's/.*applicationId[[:space:]=]*["'"'"']\([^"'"'"']*\)["'"'"'].*/\1/p' "$1" 2>/dev/null | head -1; }
if [ -f "$PROJ/pubspec.yaml" ] && [ -d "$PROJ/android" ] || { [ -f "$PROJ/pubspec.yaml" ] && [ -d "$PROJ/app/android" ]; }; then
  TYPE="flutter"
  ANDROID_DIR="$PROJ/android"; [ -d "$ANDROID_DIR" ] || ANDROID_DIR="$PROJ/app/android"
  for f in "$ANDROID_DIR/app/build.gradle.kts" "$ANDROID_DIR/app/build.gradle"; do
    [ -f "$f" ] && APP_ID="$(gradle_app_id "$f")" && [ -n "$APP_ID" ] && break
  done
  FL="flutter"; [ -d "$PROJ/.fvm" ] || [ -L "$PROJ/.fvm" ] && FL="fvm flutter"
  SUB="${ANDROID_DIR#$PROJ/}"; SUB="${SUB%/android}"
  if [ "$SUB" = "android" ] || [ -z "$SUB" ]; then BUILD_CMD="$FL build apk --debug"; APK_PATH="build/app/outputs/flutter-apk/app-debug.apk"
  else BUILD_CMD="cd $SUB && $FL build apk --debug"; APK_PATH="$SUB/build/app/outputs/flutter-apk/app-debug.apk"; fi
elif [ -f "$PROJ/gradlew" ]; then
  TYPE="android-native"
  # 原生项目：applicationId 可能是字面量，也可能是 project.property("X")（值在 gradle.properties），
  # debug 包常带 applicationIdSuffix，还可能有 productFlavors —— 用 python 解析
  DETECT=$(python3 -I - "$PROJ" <<'PYDET'
import os, re, sys
proj = sys.argv[1]

def read(p):
    try:
        return open(p, encoding="utf-8", errors="ignore").read()
    except OSError:
        return ""

def props():
    d = {}
    for f in (os.path.join(proj, "gradle.properties"),):
        for l in read(f).splitlines():
            m = re.match(r"\s*([\w.]+)\s*=\s*(.*?)\s*$", l)
            if m and not l.lstrip().startswith("#"):
                d[m.group(1)] = m.group(2)
    return d

def block(text, name):
    """返回 `name {` 之后到配对 `}` 之间的内容（简单花括号配对）"""
    m = re.search(r"\b" + name + r"\s*\{", text)
    if not m:
        return None
    i, depth = m.end(), 1
    while i < len(text) and depth:
        depth += {"{": 1, "}": -1}.get(text[i], 0)
        i += 1
    return text[m.end(): i - 1]

# 找应用模块：优先 app/，否则第一个含 com.android.application 的模块
mod = None
for cand in ["app"] + sorted(d for d in os.listdir(proj) if os.path.isdir(os.path.join(proj, d))):
    for f in ("build.gradle.kts", "build.gradle"):
        t = read(os.path.join(proj, cand, f))
        # 插件可能以版本目录别名声明（alias(libs.plugins.android)），所以以 applicationId 为准（库模块没有它）
        if "applicationId" in t or "com.android.application" in t or "android.application" in t:
            mod = (cand, t)
            break
    if mod:
        break
if not mod:
    print("MODULE=\nAPP_ID=\nFLAVOR=\nNOTE=没找到应用模块（含 applicationId 的 build.gradle[.kts]）")
    sys.exit()
name, text = mod
pr = props()
app_id = ""
m = re.search(r"applicationId\s*=?\s*[\"']([^\"']+)[\"']", text)
if m:
    app_id = m.group(1)
else:
    m = re.search(r"applicationId\s*=?\s*(?:project|rootProject)\.(?:property|findProperty)\(\s*[\"'](\w+)[\"']\s*\)", text) \
        or re.search(r"applicationId\s*=?\s*(?:project\.)?properties\[\s*[\"'](\w+)[\"']\s*\]", text)
    if m:
        app_id = pr.get(m.group(1), "")
# debug 的 applicationIdSuffix
bt = block(text, "buildTypes") or ""
dbg = block(bt, "debug") or block(bt, "getByName\\(\"debug\"\\)") or ""
sm = re.search(r"applicationIdSuffix\s*=?\s*[\"']([^\"']+)[\"']", dbg)
suffix = sm.group(1) if sm else ""
# flavors
flavors, dims = [], len(re.findall(r"flavorDimensions", text))
pf = block(text, "productFlavors")
if pf:
    flavors = re.findall(r"(?:register|create)\(\s*[\"'](\w+)[\"']\s*\)", pf)
    if not flavors:
        # 顶层 `name {` 或 `"name" {`
        depth, cur = 0, ""
        for tok in re.finditer(r"([\w\"']+)\s*\{|\}", pf):
            if tok.group(0) == "}":
                depth -= 1
            else:
                if depth == 0:
                    flavors.append(tok.group(1).strip("\"'"))
                depth += 1
note = []
if suffix:
    note.append("debug 包名带后缀 %s" % suffix)
if len(flavors) > 1:
    note.append("检测到 flavor: %s，默认选 %s，需要别的请改 BUILD_CMD / APK_PATH" % (", ".join(flavors), flavors[0]))
if dims > 1:
    note.append("有多个 flavorDimensions，构建命令和 APK 路径请手动确认")
print("MODULE=" + name)
print("APP_ID=" + (app_id + suffix if app_id else ""))
print("FLAVOR=" + (flavors[0] if flavors and dims <= 1 else ""))
print("NOTE=" + "；".join(note))
PYDET
)
  MOD=$(echo "$DETECT" | sed -n 's/^MODULE=//p'); APP_ID=$(echo "$DETECT" | sed -n 's/^APP_ID=//p')
  FLAVOR=$(echo "$DETECT" | sed -n 's/^FLAVOR=//p'); DNOTE=$(echo "$DETECT" | sed -n 's/^NOTE=//p')
  MOD="${MOD:-app}"
  if [ -n "$FLAVOR" ]; then
    CAP="$(printf '%s' "$FLAVOR" | cut -c1 | tr '[:lower:]' '[:upper:]')$(printf '%s' "$FLAVOR" | cut -c2-)"
    BUILD_CMD="./gradlew assemble${CAP}Debug"; APK_PATH="${MOD}/build/outputs/apk/${FLAVOR}/debug/*.apk"
  else
    BUILD_CMD="./gradlew assembleDebug"; APK_PATH="${MOD}/build/outputs/apk/debug/*.apk"
  fi
  [ -n "$DNOTE" ] && echo "识别说明: ${DNOTE}"
fi
echo "项目类型: $TYPE   appId: ${APP_ID:-（未识别，请手动填写）}"

# ---------- 生成配置（已存在则不覆盖）----------
if [ -f "$PROJ/.maestro/e2e.config" ]; then
  echo "保留已有 .maestro/e2e.config"
else
  # sed 替换串里 & \ | 有特殊含义（BUILD_CMD 常含 &&），先转义
  esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
  sed -e "s|@TYPE@|$(esc "$TYPE")|" -e "s|@APP_ID@|$(esc "$APP_ID")|" \
      -e "s|@BUILD_CMD@|$(esc "$BUILD_CMD")|" -e "s|@APK_PATH@|$(esc "$APK_PATH")|" \
    "$HERE/templates/e2e.config.tmpl" > "$PROJ/.maestro/e2e.config"
  echo "已生成 .maestro/e2e.config"
fi
[ -f "$PROJ/.maestro/e2e.env.example" ] || cp "$HERE/templates/e2e.env.example" "$PROJ/.maestro/e2e.env.example"
mkdir -p "$PROJ/.maestro/subflows"
[ -f "$PROJ/.maestro/subflows/launch_app.yaml" ] || cp "$HERE/templates/subflows/launch_app.yaml" "$PROJ/.maestro/subflows/launch_app.yaml"
if [ -z "$(ls "$PROJ"/.maestro/*/*.yaml 2>/dev/null | grep -v '/subflows/\|/kit/')" ]; then
  mkdir -p "$PROJ/.maestro/smoke"
  sed "s|com.example.app|${APP_ID:-com.example.app}|" "$HERE/templates/smoke_example.yaml" > "$PROJ/.maestro/smoke/smoke_example.yaml"
  echo "已生成示例 flow .maestro/smoke/smoke_example.yaml（请按项目修改）"
fi

# ---------- .gitignore ----------
touch "$PROJ/.gitignore"
for pat in ".maestro/reports/" ".maestro/e2e.env"; do
  grep -qxF "$pat" "$PROJ/.gitignore" || printf '\n%s\n' "$pat" >> "$PROJ/.gitignore"
done

# ---------- CLAUDE.md 约定（有标记则不重复追加）----------
if [ -f "$PROJ/CLAUDE.md" ] && grep -q "maestro-kit:begin" "$PROJ/CLAUDE.md"; then
  echo "CLAUDE.md 已含 maestro-kit 约定，跳过"
else
  cat "$HERE/templates/CLAUDE.md.snippet" >> "$PROJ/CLAUDE.md"
  echo "已把测试约定追加到 CLAUDE.md"
fi
echo
echo "完成。下一步: 1) 检查 .maestro/e2e.config  2) cp .maestro/e2e.env.example .maestro/e2e.env 并填写  3) bash .maestro/kit/e2e.sh --list"
