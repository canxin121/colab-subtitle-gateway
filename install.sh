#!/usr/bin/env bash
# colab-subtitle-gateway 的安装入口 (macOS / Linux 通用)
#
#   ./install.sh              # 软链到 ~/.local/bin, 然后进交互式向导 (推荐)
#   ./install.sh --system     # 软链到 /usr/local/bin (需要写权限)
#   ./install.sh --copy       # 复制而不是软链 (仓库目录会被删时用这个)
#   ./install.sh --no-wizard  # 只装命令, 不跑向导
#   ./install.sh --yes        # 向导全部取默认值 (CI / 非交互)
#   ./install.sh upgrade      # 升级 (等价 colab-sg upgrade; 也有 uninstall/config/login/reload)
#   ./install.sh uninstall    # 卸载 (等价 colab-sg uninstall)
#
# 剩下的都交给 colab-sg 自己: 向导 / 升级 / 卸载 都在那个脚本里, 这里只负责
# 把它放到 PATH 上。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/bin/colab-sg"
MODE="user"; COPY=0; ACTION="install"; WIZARD=1; PASSTHRU=()

for a in "$@"; do
  case "$a" in
    --system)    MODE="system" ;;
    --copy)      COPY=1 ;;
    --no-wizard) WIZARD=0 ;;
    upgrade|uninstall|config|login|doctor|status|reload)
                 ACTION="$a" ;;
    -y|--yes|--purge|--dry-run|--stop-session) PASSTHRU+=("$a") ;;
    -h|--help)   sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' | sed '/^$/d'; exit 0 ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
  esac
done

if [ "$MODE" = "system" ]; then DEST_DIR="/usr/local/bin"; else DEST_DIR="$HOME/.local/bin"; fi
DEST="$DEST_DIR/colab-sg"
mkdir -p "$DEST_DIR"

# uninstall 可能在没有仓库的情况下被调用 (比如先删了 clone): 那时命令已经摘掉了,
# 剩下的收尾只有 colab-sg 自己能做, 没有它就到此为止。
# 注意这里必须就地 exec 掉, 不能再往下走到"链接"那一段 —— 那会把刚摘掉的命令装回来。
if [ "$ACTION" = "uninstall" ]; then
  rm -f "$DEST" && echo "已移除 $DEST"
  if [ -x "$SRC" ]; then
    # exec 仓库里的真实路径, 不是软链 (软链会让 colab-sg 找不到同仓库的 remote/)
    exec "$SRC" uninstall ${PASSTHRU[@]+"${PASSTHRU[@]}"}
  fi
  echo "仓库里的 bin/colab-sg 不在了 —— 配置与状态目录还留着:"
  echo "  ${XDG_CONFIG_HOME:-$HOME/.config}/colab-subtitle-gateway"
  echo "  ${XDG_STATE_HOME:-$HOME/.local/state}/colab-subtitle-gateway"
  exit 0
fi

[ -x "$SRC" ] || chmod +x "$SRC"

if [ "$COPY" = 1 ]; then
  install -m 0755 "$SRC" "$DEST" && echo "已复制 → $DEST"
else
  ln -sfn "$SRC" "$DEST" && echo "已软链 → $DEST ($SRC)"
fi
# 记下安装方式, upgrade 时按同样方式重装。
# 目录要先建: `printf ... > 不存在的目录/文件` 是在**重定向阶段**失败的, 那时
# `2>/dev/null` 还没生效 (重定向从左到右处理), 报错会照原样打出来吓人一跳;
# 而且 .install 根本没写成, 之后 upgrade 只能猜安装方式。
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/colab-subtitle-gateway"
if mkdir -p "$STATE_DIR"; then
  printf 'mode=%s copy=%s dest=%s src=%s\n' "$MODE" "$COPY" "$DEST" "$SRC" > "$STATE_DIR/.install"
fi

case ":$PATH:" in
  *":$DEST_DIR:"*) ;;
  *) cat <<EOF

注意: $DEST_DIR 不在 PATH 里, 加到 shell 配置 (zsh 是 ~/.zshrc, bash 是 ~/.bashrc):

    export PATH="$DEST_DIR:\$PATH"

EOF
     ;;
esac

# 剩下的动作统一 exec 仓库里的真实路径 (不是刚装好的软链)。
if [ "$ACTION" != "install" ]; then
  exec "$SRC" "$ACTION" ${PASSTHRU[@]+"${PASSTHRU[@]}"}
fi

cat <<'EOF'
依赖检查:
  - colab CLI  (uv tool install google-colab-cli)
  - 一个可用的 Colab 账号 (向导里会引导登录)
EOF

if [ "$WIZARD" = 1 ]; then
  exec "$SRC" install ${PASSTHRU[@]+"${PASSTHRU[@]}"}
fi

cat <<'EOF'

接手使用:
  colab-sg install    # 交互式向导: 选模型 / 协议 / 密钥 / 公网入口
  colab-sg doctor     # 体检
  colab-sg up         # 建会话 + 起服务 + 拿公网地址
EOF
