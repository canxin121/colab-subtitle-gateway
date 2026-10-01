#!/usr/bin/env bash
# 把 bin/colab-sg 装到 PATH 里 (macOS / Linux 通用)
#
#   ./install.sh              # 软链到 ~/.local/bin (推荐)
#   ./install.sh --system     # 软链到 /usr/local/bin (需要写权限)
#   ./install.sh --copy       # 复制而不是软链 (仓库目录会被删时用这个)
#   ./install.sh --uninstall  # 卸载
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/bin/colab-sg"
MODE="user"; COPY=0; UNINSTALL=0

for a in "$@"; do
  case "$a" in
    --system)    MODE="system" ;;
    --copy)      COPY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)   sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
  esac
done

if [ "$MODE" = "system" ]; then DEST_DIR="/usr/local/bin"; else DEST_DIR="$HOME/.local/bin"; fi
DEST="$DEST_DIR/colab-sg"
mkdir -p "$DEST_DIR"

if [ "$UNINSTALL" = 1 ]; then
  rm -f "$DEST" && echo "已卸载 $DEST"
  exit 0
fi

[ -x "$SRC" ] || chmod +x "$SRC"

if [ "$COPY" = 1 ]; then
  install -m 0755 "$SRC" "$DEST" && echo "已复制 → $DEST"
else
  ln -sfn "$SRC" "$DEST" && echo "已软链 → $DEST ($SRC)"
fi

case ":$PATH:" in
  *":$DEST_DIR:"*) ;;
  *) cat <<EOF

注意: $DEST_DIR 不在 PATH 里, 加到 shell 配置 (zsh 是 ~/.zshrc, bash 是 ~/.bashrc):

    export PATH="$DEST_DIR:\$PATH"

EOF
     ;;
esac

cat <<'EOF'
依赖检查:
  - colab CLI  (uv tool install google-colab-cli)
  - 一个可用的 Colab 账号 (colab 已完成 OAuth 登录)

接手使用:
  colab-sg doctor     # 体检
  colab-sg up         # 建会话 + 起服务 + 拿公网地址
  colab-sg demo       # 端到端自测
EOF
