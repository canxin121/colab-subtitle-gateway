#!/bin/bash
# Colab VM 端的常驻 supervisor: 保活 + 拉起 gateway + 拉起 cloudflared 隧道,
# 任一环节挂掉自动重启。由本机 CLI 用 colab exec 启停, 不依赖 Colab 的 kernel 会话存活。
#
#   bash remote/supervisor.sh start|stop|status|url|logs [--tunnel|--no-tunnel]
#
# 运行时文件都在 $CSG_ROOT/run/ 下:
#   gateway.log  tunnel.log  supervisor.log  tunnel.url  gateway.pid  cloudflared.pid
set -uo pipefail

CSG_ROOT="${CSG_ROOT:-/content/csg}"
REPO="$CSG_ROOT/repo"
RUN="$CSG_ROOT/run"
PY="$REPO/.venv/bin/python"
PORT="${CSG_PORT:-8000}"
TUNNEL_MODE="${CSG_TUNNEL_MODE:-auto}"     # auto | quick | off
TUNNEL_NAME="${CSG_TUNNEL_NAME:-}"         # 命名隧道才用得上
CFG="/content/cloudflared"
GW_LOG="$RUN/gateway.log"
TU_LOG="$RUN/tunnel.log"
SUP_LOG="$RUN/supervisor.log"
URL_FILE="$RUN/tunnel.url"
GW_PID="$RUN/gateway.pid"
TU_PID="$RUN/cloudflared.pid"

export MODELSCOPE_CACHE="$REPO/models_cache"
export HF_HOME="$REPO/models_cache"

# 首次部署时把仓库内的 models.json 复制成网关读的那份:
#   仓库里的 models.json 是唯一"我们要跑哪个模型"的声明; repo/models.json 是网关+下载脚本读的那份。
# 这里覆盖掉的是我们自己的仓库 checkout, 幂等且无副作用。
if [ -f "$CSG_ROOT/src/remote/models.json" ] && ! cmp -s "$CSG_ROOT/src/remote/models.json" "$REPO/models.json"; then
  cp "$CSG_ROOT/src/remote/models.json" "$REPO/models.json"
fi

mkdir -p "$RUN"
log() { echo "$(date -u +%H:%M:%S) $*" >> "$SUP_LOG"; }

# --------------------------------------------------------------------------
# 探活
# --------------------------------------------------------------------------
gw_alive()  { curl -sf -m 4 -o /dev/null "http://127.0.0.1:$PORT/health"; }
tun_alive() { [ -s "$URL_FILE" ] && curl -sf -m 8 -o /dev/null "$(cat "$URL_FILE")/health"; }
pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

gw_pid() { [ -f "$GW_PID" ] && cat "$GW_PID" || true; }
tu_pid() { [ -f "$TU_PID" ] && cat "$TU_PID" || true; }

# --------------------------------------------------------------------------
# gateway
# --------------------------------------------------------------------------
start_gateway() {
  if gw_alive; then log "gateway already up"; return 0; fi
  : > "$GW_LOG"
  # 必须 cd 进 repo 再 -m gateway: python -m 靠 sys.path[0]=cwd 找包, 而 kernel 的
  # cwd 是 /content, 直接跑会 "No module named gateway" (日志里看着像秒退)。
  setsid nohup bash -c "cd '$REPO' && exec '$PY' -m gateway --device cuda --port '$PORT' \
    --cache-dir '$REPO/models_cache' --translate-free google,edge" \
    >> "$GW_LOG" 2>&1 < /dev/null &
  echo $! > "$GW_PID"
  log "gateway started pid=$(cat "$GW_PID")"
}

stop_gateway() {
  local p; p=$(gw_pid)
  pid_alive "$p" && kill "$p" 2>/dev/null
  pkill -f "python -m gateway" 2>/dev/null
  rm -f "$GW_PID"
  log "gateway stopped"
}

wait_health() {   # $1 = 秒
  local n="${1:-600}" i=0
  while [ "$i" -lt "$n" ]; do
    gw_alive && { log "gateway healthy after ${i}s"; return 0; }
    sleep 2; i=$((i+2))
  done
  log "gateway NOT healthy after ${n}s (见 $GW_LOG)"
  return 1
}

# --------------------------------------------------------------------------
# cloudflared
# --------------------------------------------------------------------------
start_tunnel() {
  [ -x "$CFG" ] || { log "cloudflared missing"; return 1; }
  [ "$TUNNEL_MODE" = "off" ] && { log "tunnel disabled"; return 0; }
  if tun_alive; then log "tunnel already up: $(cat "$URL_FILE")"; return 0; fi
  : > "$TU_LOG"; rm -f "$URL_FILE"

  if [ -n "$TUNNEL_NAME" ]; then                 # 命名隧道: 域名固定, 每次重建会话也不变
    setsid nohup "$CFG" tunnel --no-autoupdate run --url "http://127.0.0.1:$PORT" "$TUNNEL_NAME" \
      >> "$TU_LOG" 2>&1 < /dev/null &
  else                                           # quick tunnel: 零配置, 重建会话后域名会变
    setsid nohup "$CFG" tunnel --no-autoupdate --url "http://127.0.0.1:$PORT" \
      >> "$TU_LOG" 2>&1 < /dev/null &
  fi
  echo $! > "$TU_PID"
  log "cloudflared started pid=$(cat "$TU_PID") (mode=$TUNNEL_MODE name=${TUNNEL_NAME:-none})"
}

stop_tunnel() {
  local p; p=$(tu_pid)
  pid_alive "$p" && kill "$p" 2>/dev/null
  pkill -f "cloudflared tunnel" 2>/dev/null
  rm -f "$TU_PID" "$URL_FILE"
  log "tunnel stopped"
}

wait_url() {      # 抓一次公网地址 (quick tunnel 才会出现在日志里)
  local n="${1:-90}" i=0
  while [ "$i" -lt "$n" ]; do
    local u
    u=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TU_LOG" 2>/dev/null | head -1)
    [ -n "$u" ] && { echo "$u" > "$URL_FILE"; log "tunnel url: $u"; return 0; }
    sleep 2; i=$((i+2))
  done
  [ -n "$TUNNEL_NAME" ] && { log "named tunnel: 地址由 Cloudflare 侧固定域名决定"; return 0; }
  log "tunnel url NOT found after ${n}s (见 $TU_LOG)"
  return 1
}

# --------------------------------------------------------------------------
# 保活循环 (start 时后台起, 每 60s 自检一次)
# --------------------------------------------------------------------------
watch_loop() {
  echo $$ > "$RUN/watch.pid"
  log "watch loop started"
  local misses=0
  while true; do
    sleep 60
    gw_alive || { log "gateway health failed, restarting"; stop_gateway; start_gateway; wait_health 900; }
    tun_alive || { log "tunnel health failed, restarting"; stop_tunnel; start_tunnel; wait_url 90; }
  done
}

case "${1:-status}" in
  start)
    [ -x "$PY" ] || { echo "venv 缺失: 先跑 bash remote/setup.sh" >&2; exit 1; }
    [ -x "$CFG" ] || echo "WARN: /content/cloudflared 缺失, 隧道不会起来 (先跑 setup.sh)"
    start_gateway
    wait_health 900
    start_tunnel
    wait_url 120
    if ! pid_alive "$(cat "$RUN/watch.pid" 2>/dev/null || echo)"; then
      setsid nohup "$0" watch >> "$SUP_LOG" 2>&1 < /dev/null &
      log "watch loop spawned"
    fi
    "$0" status
    ;;
  watch)   watch_loop ;;
  stop)
    pkill -f "supervisor.sh watch" 2>/dev/null; rm -f "$RUN/watch.pid"
    stop_tunnel; stop_gateway
    ;;
  restart) "$0" stop; sleep 2; "$0" start ;;
  status)
    echo "gateway:  $(gw_alive && echo UP || echo DOWN)  (port $PORT, pid $(gw_pid))"
    echo "tunnel:   $(tun_alive && echo UP || echo DOWN)  ${TUNNEL_NAME:+name=$TUNNEL_NAME}"
    echo "watch:    $(pid_alive "$(cat "$RUN/watch.pid" 2>/dev/null || echo)" && echo RUNNING || echo STOPPED)"
    echo "url:      $([ -s "$URL_FILE" ] && cat "$URL_FILE" || echo '(none)')"
    [ -x "$PY" ] && curl -sf -m 5 "http://127.0.0.1:$PORT/health" | head -c 400
    echo
    ;;
  url)
    [ -s "$URL_FILE" ] || { echo "(no url yet — 看 $TU_LOG)" >&2; exit 1; }
    cat "$URL_FILE"; echo
    ;;
  logs)
    echo "===== supervisor ====="; tail -n "${2:-20}" "$SUP_LOG" 2>/dev/null
    echo "===== gateway =====";    tail -n "${2:-20}" "$GW_LOG" 2>/dev/null
    echo "===== tunnel =====";     tail -n "${2:-20}" "$TU_LOG" 2>/dev/null
    ;;
  *) echo "usage: $0 start|stop|restart|status|url|logs [lines]" >&2; exit 2 ;;
esac
