#!/usr/bin/env bash
# 用阿里 P3C（p3c-pmd 2.1.1）检查 Java 改动文件。
# P3C 2.1.1 基于 PMD 6.15.0 构建，与 PMD 7 不兼容，
# 因此这里独立下载 PMD 6.15.0 运行，不依赖项目自身的构建配置。
# 用法：p3c-check.sh [file.java ...]；不传参数时检查工作区中变更的 .java 文件（含未跟踪的新文件）。
# 退出码：0 无违规且无解析缺口；2 有违规；3 无违规但有文件未能解析（覆盖缺口）；1 脚本或工具错误。
# 两类结果同时存在时返回 2，但输出中两类信息都会列出，调用方应同时阅读。

set -euo pipefail

PMD_VERSION=6.15.0
P3C_VERSION=2.1.1
KOTLIN_VERSION=1.3.72
CACHE_DIR="${P3C_HOME:-${HOME:-$PWD}/.cache/p3c-check}"
PMD_DIR="$CACHE_DIR/pmd-bin-$PMD_VERSION"
P3C_JAR="$CACHE_DIR/p3c-pmd-$P3C_VERSION.jar"
KOTLIN_JAR="$CACHE_DIR/kotlin-stdlib-$KOTLIN_VERSION.jar"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RULESET="$SCRIPT_DIR/p3c-all.xml"

# 下载产物的 SHA-256 固定值。依赖从网络获取后会以 java 执行，必须校验内容而不只是 HTTP 状态。
# 值取自 2026-10-15 对上述 URL 的首次下载；升级版本时需同步更新。
PMD_SHA256=af294bec4629892121d88daa72785a6a12b48c7f51c759cb764ae598414d7f97
P3C_SHA256=e7afec9340a0f30f56f4fdcd3b9c49e79ed24253719fcb9f457f5bcb43e54860
KOTLIN_SHA256=3856a7349ebacd6d1be6802b2fed9c4dc2c5a564ea92b6b945ac988243d4b16b

if ! command -v java >/dev/null 2>&1; then
  echo "p3c-check: 未找到 java" >&2
  exit 1
fi

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    sha256sum "$1" | cut -d' ' -f1
  fi
}

# 下载到临时文件，校验通过后才移动到目标位置，避免中断的下载留下被当作完好的缓存。
# 超时与重试避免网络异常时质量检查无限挂起。
fetch() {
  local url="$1" dest="$2" expected="$3" tmp
  tmp="$dest.part"
  echo "p3c-check: 下载 $(basename "$dest")" >&2
  if ! curl -fsSL --connect-timeout 10 --max-time 300 --retry 3 --retry-delay 2 -o "$tmp" "$url"; then
    rm -f "$tmp"
    echo "p3c-check: 下载失败：$url" >&2
    exit 1
  fi
  if [ "$(sha256_of "$tmp")" != "$expected" ]; then
    rm -f "$tmp"
    echo "p3c-check: $(basename "$dest") 校验和不匹配，已拒绝使用" >&2
    exit 1
  fi
  mv "$tmp" "$dest"
}

mkdir -p "$CACHE_DIR"
if [ ! -d "$PMD_DIR" ]; then
  fetch "https://github.com/pmd/pmd/releases/download/pmd_releases/$PMD_VERSION/pmd-bin-$PMD_VERSION.zip" \
    "$CACHE_DIR/pmd-bin-$PMD_VERSION.zip" "$PMD_SHA256"
  # 先解压到临时目录，成功后再改名，避免解压中断留下半成品目录
  STAGE="$(mktemp -d "$CACHE_DIR/stage.XXXXXX")"
  if ! unzip -q -o "$CACHE_DIR/pmd-bin-$PMD_VERSION.zip" -d "$STAGE"; then
    rm -rf "$STAGE" "$CACHE_DIR/pmd-bin-$PMD_VERSION.zip"
    echo "p3c-check: PMD 解压失败" >&2
    exit 1
  fi
  mv "$STAGE/pmd-bin-$PMD_VERSION" "$PMD_DIR"
  rm -rf "$STAGE" "$CACHE_DIR/pmd-bin-$PMD_VERSION.zip"
fi
if [ ! -f "$P3C_JAR" ]; then
  fetch "https://repo1.maven.org/maven2/com/alibaba/p3c/p3c-pmd/$P3C_VERSION/p3c-pmd-$P3C_VERSION.jar" \
    "$P3C_JAR" "$P3C_SHA256"
fi
# P3C 部分规则用 Kotlin 编写，运行时需要 kotlin-stdlib（版本与 p3c 的 kotlin.version 一致）
if [ ! -f "$KOTLIN_JAR" ]; then
  fetch "https://repo1.maven.org/maven2/org/jetbrains/kotlin/kotlin-stdlib/$KOTLIN_VERSION/kotlin-stdlib-$KOTLIN_VERSION.jar" \
    "$KOTLIN_JAR" "$KOTLIN_SHA256"
fi

if [ "$#" -gt 0 ]; then
  FILES="$(printf '%s,' "$@")"
else
  # 已跟踪文件中相对 HEAD 有变化（含已暂存、未暂存）的 .java，加上未跟踪的新 .java；
  # 只保留仍存在的文件。用 if 而不是 && 过滤，避免失败的测试让整个管道返回非零。
  # core.quotePath=false 让含非 ASCII 字符的路径不被 C 风格转义，否则 [ -f ] 会误判为不存在。
  # 跳过任何以 . 开头的目录下的文件（如 .claude/），只检查实现代码
  FILES="$({ git -c core.quotePath=false diff --name-only HEAD --diff-filter=ACMR -- '*.java'
             git -c core.quotePath=false ls-files --others --exclude-standard -- '*.java'; } \
           | { grep -v -e '^\.' -e '/\.' || true; } \
           | while read -r f; do
               if [ -f "$f" ]; then printf '%s,' "$f"; fi
             done)"
fi
FILES="${FILES%,}"
if [ -z "$FILES" ]; then
  echo "p3c-check: 没有需要检查的 Java 文件" >&2
  exit 0
fi

# PMD 6 的 -d 接受逗号分隔的文件列表；退出码 4 表示发现违规
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
set +e
java -cp "$PMD_DIR/lib/*:$P3C_JAR:$KOTLIN_JAR" net.sourceforge.pmd.PMD \
  -d "$FILES" -R "$RULESET" -f text -no-cache > "$OUT" 2>&1
status=$?
set -e
cat "$OUT"

# 单个文件解析失败时 PMD 仍可能返回“有违规”的退出码，因此解析缺口要单独统计，不能只看退出码。
# PMD 6.15 无法解析 record 等较新的语法，这类文件属于 P3C 的覆盖缺口，需由人工复核。
GAPS="$(grep 'PMDException' "$OUT" || true)"

# PMD 退出码 4 = 有违规；其他非 0 且非 4 的值视为工具错误，统一映射为 1，避免与本脚本的 2、3 冲突
case "$status" in
  0|4) ;;
  *) echo "p3c-check: PMD 执行失败，退出码 $status" >&2; exit 1 ;;
esac

violations=0
if [ "$status" -eq 4 ]; then violations=1; fi

if [ -n "$GAPS" ]; then
  echo "p3c-check: 以下文件未能解析，P3C 未覆盖（需人工复核，常见原因是 record 等新语法）：" >&2
  printf '%s\n' "$GAPS" | cut -f1 | sed 's/^/  /' >&2
fi

if [ "$violations" -eq 1 ]; then
  echo "p3c-check: 发现违规（见上方输出）" >&2
  exit 2
fi
if [ -n "$GAPS" ]; then
  echo "p3c-check: 无违规，但存在未覆盖文件" >&2
  exit 3
fi
echo "p3c-check: 无违规" >&2
