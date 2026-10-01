#!/bin/bash
# Colab VM 端的常驻 supervisor: 保活 + 拉起 gateway + 拉起 cloudflared 隧道,
# 任一环节挂掉自动重启。由本机 CLI 用 colab exec 启停, 不依赖 Colab 的 kernel 会话存活。
#
#   bash remote/supervisor.sh start|stop|status|url|logs
#
# 参数来源: 先读 $CSG_ROOT/deploy.env (本机 CLI 生成), 再读 $CSG_ROOT/secrets.env (600)。
# 不能靠 export: colab exec 每次都是新的 bash, 上一条命令导出的变量活不过那个 cell。
#
# 运行时文件都在 $CSG_ROOT/run/ 下:
#   gateway.log  tunnel.log  supervisor.log  tunnel.url  gateway.pid  cloudflared.pid
set -uo pipefail

CSG_ROOT="${CSG_ROOT:-/content/csg}"
[ -f "$CSG_ROOT/deploy.env" ] && . "$CSG_ROOT/deploy.env"
[ -f "$CSG_ROOT/secrets.env" ] && . "$CSG_ROOT/secrets.env"
CSG_ROOT="${CSG_ROOT:-/content/csg}"

REPO="$CSG_ROOT/repo"
RUN="$CSG_ROOT/run"
PY="$REPO/.venv/bin/python"
PORT="${CSG_PORT:-8000}"
DEVICE="${CSG_DEVICE:-cuda}"                       # auto | cuda | cpu
PRELOAD="${CSG_PRELOAD:-}"
MAX_LOADED="${CSG_MAX_LOADED_MODELS:-}"            # 空 = 用网关默认 (1)
PROTOCOLS="${CSG_PROTOCOLS:-openai ferrum deepl libretranslate}"
TRANSLATE_FREE="${CSG_TRANSLATE_FREE:-google,edge}"
TUNNEL_MODE="${CSG_TUNNEL_MODE:-auto}"             # auto | quick | token | named | off
TUNNEL_NAME="${CSG_TUNNEL_NAME:-}"                 # 命名隧道 (cert.pem 模式) 才用得上
# 命名隧道的 token 模式: Cloudflare 侧建好隧道 + 公网主机名, 把 connector token 写进
# 这个文件, 域名就固定了 —— 不需要 cert.pem, 也不需要 API Token。
TUNNEL_TOKEN_FILE="${CSG_TUNNEL_TOKEN_FILE:-$CSG_ROOT/tunnel.token}"
TUNNEL_HOSTNAME="${CSG_TUNNEL_HOSTNAME:-}"         # token 模式: 你在 Cloudflare 上配的那个公网主机名
SELECTED="$CSG_ROOT/models.selected.json"
CFG="/content/cloudflared"
GW_LOG="$RUN/gateway.log"
TU_LOG="$RUN/tunnel.log"
SUP_LOG="$RUN/supervisor.log"
URL_FILE="$RUN/tunnel.url"
GW_PID="$RUN/gateway.pid"
TU_PID="$RUN/cloudflared.pid"

export MODELSCOPE_CACHE="$REPO/models_cache"
export HF_HOME="$REPO/models_cache"

# 选中的模型清单 → 网关读的那份 repo/models.json。
# 缺失即报错: 静默跳过会让网关按上游那 4 个模型全开, 与用户的选择不一致。
sync_manifest() {
  [ -s "$SELECTED" ] || { log "ERROR: 缺 $SELECTED (本机跑一次 colab-sg up/config)"; return 1; }
  if ! cmp -s "$SELECTED" "$REPO/models.json"; then
    cp "$SELECTED" "$REPO/models.json" || return 1
    log "models.json ← selected"
  fi
}

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

has_proto() { case " $PROTOCOLS " in *" $1 "*) return 0 ;; esac; return 1; }

# 网关 argv: 全部来自 deploy.env。与选中的协议/密钥对齐 —— 没勾的协议就不传它的凭据。
# 注意 4 条路由是无条件挂载的 (ASR 无法关闭, /health /v1/models 连鉴权都没有),
# 翻译半边靠 --translate-free none 才能真正关掉。
gw_args() {
  local -a a=(--device "$DEVICE" --port "$PORT" --cache-dir "$REPO/models_cache")
  # 故意不加引号: --preload 是 nargs="*", 空格分隔的多个 id 要拆成多个参数
  # shellcheck disable=SC2206
  [ -n "$PRELOAD" ] && a+=(--preload $PRELOAD)
  [ -n "$MAX_LOADED" ] && a+=(--max-loaded-models "$MAX_LOADED")
  if has_proto ferrum; then
    [ -n "${CSG_AUTH_SECRET:-}" ]     && a+=(--auth-secret "$CSG_AUTH_SECRET")
    [ -n "${CSG_ENCRYPTION_KEY:-}" ]  && a+=(--encryption-key "$CSG_ENCRYPTION_KEY")
  fi
  if has_proto deepl; then
    if [ -n "${CSG_TRANSLATE_UPSTREAM:-}" ]; then
      a+=(--translate-upstream "$CSG_TRANSLATE_UPSTREAM")
      [ -n "${CSG_TRANSLATE_UPSTREAM_KEY:-}" ] && a+=(--translate-upstream-key "$CSG_TRANSLATE_UPSTREAM_KEY")
    fi
    [ -n "${CSG_TRANSLATE_API_KEY:-}" ] && a+=(--translate-api-key "$CSG_TRANSLATE_API_KEY")
  fi
  if has_proto libretranslate; then
    if [ -n "${CSG_LIBRETRANSLATE_UPSTREAM:-}" ]; then
      a+=(--libretranslate-upstream "$CSG_LIBRETRANSLATE_UPSTREAM")
      [ -n "${CSG_LIBRETRANSLATE_UPSTREAM_KEY:-}" ] && a+=(--libretranslate-upstream-key "$CSG_LIBRETRANSLATE_UPSTREAM_KEY")
    fi
    [ -n "${CSG_LIBRETRANSLATE_API_KEY:-}" ] && a+=(--libretranslate-api-key "$CSG_LIBRETRANSLATE_API_KEY")
  fi
  # 两个协议都没勾、又没有免费源 → none, 翻译端点直接 503 (这是真的关掉)
  if has_proto deepl || has_proto libretranslate; then
    a+=(--translate-free "$TRANSLATE_FREE")
  else
    a+=(--translate-free none)
  fi
  printf '%q ' "${a[@]}"
}

# --------------------------------------------------------------------------
# gateway
# --------------------------------------------------------------------------
start_gateway() {
  if gw_alive; then log "gateway already up"; return 0; fi
  sync_manifest || return 1
  : > "$GW_LOG"
  # 必须 cd 进 repo 再 -m gateway: python -m 靠 sys.path[0]=cwd 找包, 而 kernel 的
  # cwd 是 /content, 直接跑会 "No module named gateway" (日志里看着像秒退)。
  # 先写 pid 文件再进后台: bash -c 会把 $$ 换成那个子 shell 自己的 pid, 正是我们
  # 需要用来 kill 的进程。
  # argv 里会带密钥 (网关只认命令行参数)—— 所以这里绝不 set -x, 日志只记 pid。
  setsid nohup bash -c "echo \$\$ > '$GW_PID'; cd '$REPO' && exec '$PY' -m gateway $(gw_args)" \
    >> "$GW_LOG" 2>&1 < /dev/null &
  sleep 1
  log "gateway started pid=$(cat "$GW_PID" 2>/dev/null || echo '?')"
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
  : > "$TU_LOG"
  # 隧道重建后地址可能变 (quick tunnel 必变)。旧地址不清掉的话, tun_alive 会拿它去探活,
  # 碰巧对方还在线就误判成"隧道还活着"; 而且 start_tunnel 走到这里本来就意味着旧隧道
  # 已经不通了, 留着一个死地址只会让 status / wait_url 读到过期信息。
  rm -f "$URL_FILE"

  if [ -s "$TUNNEL_TOKEN_FILE" ]; then
    # token 模式 (推荐): Cloudflare Zero Trust 里建好隧道并配好公网主机名, 这里只跑
    # connector。域名固定、无需 cert.pem 与 API Token, 换会话/换机器只要这份 token。
    [ -n "$TUNNEL_HOSTNAME" ] && echo "https://$TUNNEL_HOSTNAME" > "$URL_FILE"
    setsid nohup "$CFG" tunnel --no-autoupdate --loglevel info run \
      --token-file "$TUNNEL_TOKEN_FILE" --url "http://127.0.0.1:$PORT" \
      >> "$TU_LOG" 2>&1 < /dev/null &
  elif [ -n "$TUNNEL_NAME" ]; then               # cert.pem 模式: 域名固定, 但需要 ~/.cloudflared/cert.pem
    setsid nohup "$CFG" tunnel --no-autoupdate run --url "http://127.0.0.1:$PORT" "$TUNNEL_NAME" \
      >> "$TU_LOG" 2>&1 < /dev/null &
  else                                           # quick tunnel: 零配置, 重建会话后域名会变
    setsid nohup "$CFG" tunnel --no-autoupdate --url "http://127.0.0.1:$PORT" \
      >> "$TU_LOG" 2>&1 < /dev/null &
  fi
  echo $! > "$TU_PID"
  log "cloudflared started pid=$(cat "$TU_PID") (mode=$TUNNEL_MODE name=${TUNNEL_NAME:-none} token=$([ -s "$TUNNEL_TOKEN_FILE" ] && echo yes || echo no))"
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
  # token 模式: 公网主机名是我们自己配的, start_tunnel 已经写进 URL_FILE
  if [ -s "$TUNNEL_TOKEN_FILE" ] && [ -n "$TUNNEL_HOSTNAME" ]; then
    log "token tunnel: 固定地址 https://$TUNNEL_HOSTNAME"; return 0
  fi
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

# 域名出现 ≠ 已经能过流量 (cloudflared 注册连接还要几秒)。等它真的能通再报 UP,
# 否则刚 start 完的 status 总是显示 tunnel: DOWN, 像是失败了。
wait_tunnel_live() {   # $1 = 秒
  local n="${1:-120}" i=0
  while [ "$i" -lt "$n" ]; do
    tun_alive && { log "tunnel reachable after ${i}s"; return 0; }
    sleep 2; i=$((i+2))
  done
  log "tunnel NOT reachable after ${n}s"
  return 1
}

# --------------------------------------------------------------------------
# 保活循环 (start 时后台起, 每 60s 自检一次)
# --------------------------------------------------------------------------
watch_loop() {
  echo $$ > "$RUN/watch.pid"
  log "watch loop started"
  while true; do
    sleep 60
    gw_alive || { log "gateway health failed, restarting"; stop_gateway; start_gateway; wait_health 900; }
    tun_alive || { log "tunnel health failed, restarting"; stop_tunnel; start_tunnel; wait_url 90 && wait_tunnel_live 120; }
  done
}

case "${1:-status}" in
  start)
    [ -x "$PY" ] || { echo "venv 缺失: 先跑 bash remote/setup.sh" >&2; exit 1; }
    [ -x "$CFG" ] || echo "WARN: /content/cloudflared 缺失, 隧道不会起来 (先跑 setup.sh)"
    start_gateway
    wait_health 900
    start_tunnel
    wait_url 120 && wait_tunnel_live 180
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