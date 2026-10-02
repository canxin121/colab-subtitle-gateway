#!/usr/bin/env bash
# 一键安装引导 (给"还没 clone 过仓库"的新机器用)
#
#   curl -fsSL https://raw.githubusercontent.com/canxin121/colab-subtitle-gateway/main/bootstrap.sh | bash
#
# 它会补齐 Git / uv / Google Colab CLI, 把仓库克隆(或更新)到本地, 再交给仓库里的
# install.sh 把 colab-sg 软链进 ~/.local/bin 并进入交互式向导。
#
# 为什么需要这个文件: `curl | bash` 拿到的是标准输入, 没有仓库也就没有 install.sh,
# 更没有 remote/*.sh (那些是真正在 VM 上跑的东西)。bootstrap 只负责本机工具链与仓库,
# 安装向导仍由仓库里的 install.sh 实现 —— 逻辑只有一份, 不会出现两套流程。
#
# 选项 (管道模式下参数要写成 bash -s -- <选项>):
#   --dir DIR     仓库落地目录 (默认 $XDG_DATA_HOME/colab-subtitle-gateway)
#   --ref REF     用哪个分支或标签 (默认 main)
#   --proxy URL   下载仓库/工具与访问 Colab 走的代理 (默认读环境里的 https_proxy)
#   --system      命令装到 /usr/local/bin (等同 install.sh --system)
#   --no-wizard   只装命令, 不跑向导
#   --yes         跳过配置选择 (未登录的 Colab OAuth 仍要浏览器授权)
#   -- <参数...>  '--' 之后的参数原样交给 install.sh
#
# 例:
#   curl -fsSL <上面的地址> | bash -s -- --system
#   curl -fsSL <上面的地址> | bash -s -- --yes --no-wizard
#   curl -fsSL <上面的地址> | bash -s -- --ref main
set -euo pipefail

# 允许覆盖仓库地址: 便于自测与 fork 后自建引导
REPO_URL="${CSG_BOOTSTRAP_REPO_URL:-https://github.com/canxin121/colab-subtitle-gateway.git}"
REF="main"
DIR="${XDG_DATA_HOME:-$HOME/.local/share}/colab-subtitle-gateway"
PROXY=""
PASSTHRU=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)       DIR="$2"; shift 2 ;;
    --ref)       REF="$2"; shift 2 ;;
    --proxy)     PROXY="$2"; shift 2 ;;
    --system|--no-wizard|--yes|-y|--copy) PASSTHRU+=("$1"); shift ;;
    --)          shift; PASSTHRU+=("$@"); break ;;
    -h|--help)
      # 不能读 $0 取注释: `curl | bash` 时脚本来自标准输入, 磁盘上没有这个文件。
      cat <<'USAGE'
用法: curl -fsSL https://raw.githubusercontent.com/canxin121/colab-subtitle-gateway/main/bootstrap.sh | bash [-s -- <选项>]

  --dir DIR     仓库落地目录 (默认 $XDG_DATA_HOME/colab-subtitle-gateway)
  --ref REF     用哪个分支或标签 (默认 main)
  --proxy URL   下载仓库/工具与访问 Colab 走的代理 (默认读环境里的 https_proxy)
  --system      命令装到 /usr/local/bin (等同 install.sh --system)
  --no-wizard   只装命令, 不跑向导
  --yes         跳过配置选择 (未登录的 Colab OAuth 仍要浏览器授权)
  -- <参数...>  '--' 之后的参数原样交给 install.sh
USAGE
      exit 0 ;;
    *) echo "未知参数: $1 (--help)" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
die() { printf '错误: %s\n' "$*" >&2; exit 1; }

# 代理: git 只认自己那套 http.proxy, 不会自动继承 shell 环境里的代理。
BOOTSTRAP_PROXY="${PROXY:-${https_proxy:-${HTTPS_PROXY:-}}}"
GIT_PROXY=()
if [ -n "$BOOTSTRAP_PROXY" ]; then
  GIT_PROXY=(-c "http.proxy=$BOOTSTRAP_PROXY" -c "https.proxy=$BOOTSTRAP_PROXY")
fi
with_proxy() {
  if [ -n "$BOOTSTRAP_PROXY" ]; then
    env HTTPS_PROXY="$BOOTSTRAP_PROXY" HTTP_PROXY="$BOOTSTRAP_PROXY" ALL_PROXY="$BOOTSTRAP_PROXY" "$@"
  else
    "$@"
  fi
}
run_root() {
  if [ -n "$BOOTSTRAP_PROXY" ]; then
    if [ "$(id -u)" -eq 0 ]; then
      env HTTPS_PROXY="$BOOTSTRAP_PROXY" HTTP_PROXY="$BOOTSTRAP_PROXY" "$@"
    else
      sudo env HTTPS_PROXY="$BOOTSTRAP_PROXY" HTTP_PROXY="$BOOTSTRAP_PROXY" "$@"
    fi
  elif [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}
ensure_git() {
  command -v git >/dev/null 2>&1 && return 0
  say "系统缺少 Git, 正在用本机包管理器安装 ..."
  case "$(uname -s)" in
    Darwin)
      command -v brew >/dev/null 2>&1 || die "缺少 Git。macOS 请先安装 Xcode Command Line Tools 或 Homebrew, 然后重跑这一行"
      with_proxy brew install git || die "Homebrew 安装 Git 失败"
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        run_root apt-get update && run_root apt-get install -y git || die "apt 安装 Git 失败"
      elif command -v dnf >/dev/null 2>&1; then
        run_root dnf install -y git || die "dnf 安装 Git 失败"
      elif command -v yum >/dev/null 2>&1; then
        run_root yum install -y git || die "yum 安装 Git 失败"
      elif command -v pacman >/dev/null 2>&1; then
        run_root pacman -Sy --noconfirm git || die "pacman 安装 Git 失败"
      elif command -v apk >/dev/null 2>&1; then
        run_root apk add git || die "apk 安装 Git 失败"
      else
        die "缺少 Git, 请先用本机包管理器安装 Git, 然后重跑这一行"
      fi
      ;;
    *) die "缺少 Git, 此系统暂不支持自动安装; 请先安装 Git, 然后重跑这一行" ;;
  esac
  hash -r 2>/dev/null || true
  command -v git >/dev/null 2>&1 || die "Git 安装后仍找不到 git"
}
ensure_git

if [ -d "$DIR/.git" ]; then
  # 这个目录是安装器自己的, 但里面可能有你手改过的脚本 —— 直接 reset --hard 会无声吃掉。
  if [ -n "$(git -C "$DIR" status --porcelain 2>/dev/null)" ]; then
    die "$DIR 里有未提交的改动。先处理掉 (git -C \"$DIR\" stash), 或用 --dir 换个目录"
  fi
  CURRENT_HEAD="$(git -C "$DIR" rev-parse HEAD)"
  HEAD_MARKER="$DIR/.git/colab-sg-bootstrap-head"
  if [ -f "$HEAD_MARKER" ] && [ "$(<"$HEAD_MARKER")" != "$CURRENT_HEAD" ]; then
    die "$DIR 的 HEAD 已被手动切换/提交; 为避免覆盖, 用 --dir 换个目录或先恢复安装器版本"
  fi
  say "更新已有仓库: $DIR ($REF)"
  git ${GIT_PROXY[@]+"${GIT_PROXY[@]}"} -C "$DIR" fetch --depth 1 origin "$REF" -q \
    || die "获取安装器失败 (网络/代理? 试 --proxy http://127.0.0.1:7890)"
  TARGET_HEAD="$(git -C "$DIR" rev-parse FETCH_HEAD)"
  if [ ! -f "$HEAD_MARKER" ] && [ "$CURRENT_HEAD" != "$TARGET_HEAD" ]; then
    if ! git -C "$DIR" merge-base --is-ancestor "$CURRENT_HEAD" "$TARGET_HEAD" 2>/dev/null; then
      git ${GIT_PROXY[@]+"${GIT_PROXY[@]}"} -C "$DIR" fetch --deepen=100 origin "$REF" -q || true
      TARGET_HEAD="$(git -C "$DIR" rev-parse FETCH_HEAD)"
      git -C "$DIR" merge-base --is-ancestor "$CURRENT_HEAD" "$TARGET_HEAD" 2>/dev/null \
        || die "$DIR 的本地版本与 $REF 不构成快进; 不会覆盖本地提交, 请用 --dir 换一个新目录"
    fi
  fi
  git -C "$DIR" reset --hard -q "$TARGET_HEAD"
elif [ -e "$DIR" ]; then
  die "$DIR 已存在且不是 git 仓库; 用 --dir 换个目录, 或先移走它"
else
  say "克隆 $REPO_URL → $DIR"
  mkdir -p "$(dirname "$DIR")"
  git ${GIT_PROXY[@]+"${GIT_PROXY[@]}"} clone --depth 1 --branch "$REF" "$REPO_URL" "$DIR" \
    || die "克隆失败 (网络/代理? 试 --proxy http://127.0.0.1:7890)"
fi

INSTALLER_HEAD="$(git -C "$DIR" rev-parse HEAD)"
if [ -d "$DIR/.git" ]; then printf '%s\n' "$INSTALLER_HEAD" > "$DIR/.git/colab-sg-bootstrap-head"; fi
[ -x "$DIR/bin/colab-sg" ] || chmod +x "$DIR/bin/colab-sg"

# 新机器不要求预装 uv / google-colab-cli; 一行引导负责补齐这两个应用依赖。
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
if ! command -v uv >/dev/null 2>&1; then
  command -v curl >/dev/null 2>&1 || die "找不到 curl, 无法安装 uv"
  say "安装 uv (google-colab-cli 的运行器) ..."
  with_proxy curl -LsSf https://astral.sh/uv/install.sh | sh \
    || die "uv 安装失败; 检查网络/代理后重试"
  hash -r 2>/dev/null || true
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
fi
if ! command -v colab >/dev/null 2>&1; then
  say "安装 Google Colab CLI ..."
  with_proxy uv tool install google-colab-cli \
    || die "google-colab-cli 安装失败; 检查网络/代理后重试"
  hash -r 2>/dev/null || true
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
fi
command -v colab >/dev/null 2>&1 || die "安装后仍找不到 colab; 确认 uv tool bin 目录已加入 PATH"

say "交给仓库里的 install.sh (装命令 + 交互式向导) ..."
# exec 而不是普通调用: 向导要从终端读输入并决定退出码, 中间不要再夹一层。
INSTALL_ENV=("CSG_INSTALLER_REF=$REF" "CSG_INSTALLER_HEAD=$INSTALLER_HEAD")
[ -n "$BOOTSTRAP_PROXY" ] && INSTALL_ENV+=("CSG_PROXY=$BOOTSTRAP_PROXY")
# curl | bash 把脚本本身占了 stdin; 有控制终端时显式通知向导改从 /dev/tty 交互。
if [ ! -t 0 ] && ( : < /dev/tty ) 2>/dev/null; then
  INSTALL_ENV+=("CSG_INTERACTIVE_TTY=1")
fi
exec env "${INSTALL_ENV[@]}" bash "$DIR/install.sh" ${PASSTHRU[@]+"${PASSTHRU[@]}"}
