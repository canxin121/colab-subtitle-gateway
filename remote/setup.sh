#!/bin/bash
# subtitle-gateway 在 Colab VM 上的一次性环境准备 (在 VM 里执行, 幂等可重复跑)
#
# 用法:
#   bash remote/setup.sh            # 完整: 克隆 + 依赖 + 模型 (已就绪的部分自动跳过)
#   bash remote/setup.sh --clone    # 只克隆/更新上游仓库 (菜单要先读它的 models.json)
#   bash remote/setup.sh --deps     # 只装依赖
#   bash remote/setup.sh --models   # 只下模型
#   bash remote/setup.sh --check    # 只体检, 不动任何东西
#
# 环境变量来源: 先读 $CSG_ROOT/deploy.env (由本机 CLI 生成), 再用环境变量覆盖。
#   CSG_ROOT        远端根目录 (默认 /content/csg)
#   CSG_UV_INDEX    uv 的 index (默认 PyPI; 国内网络下可设 https://mirrors.aliyun.com/pypi/simple/)
#   CSG_SEED_CACHE  已有模型缓存目录; 首次部署时从它硬拷贝, 省掉一次下载
set -uo pipefail

CSG_ROOT="${CSG_ROOT:-/content/csg}"
# 部署参数: CLI 落盘的那份是唯一真相 (colab exec 每次都是新 shell, export 活不过去)
[ -f "$CSG_ROOT/deploy.env" ] && . "$CSG_ROOT/deploy.env"
CSG_ROOT="${CSG_ROOT:-/content/csg}"

REPO="$CSG_ROOT/repo"
SRC="$CSG_ROOT/src"          # 本仓库的远端副本 (remote/); 由本机 CLI 注入
: "$SRC"
SELECTED="$CSG_ROOT/models.selected.json"
PY="$REPO/.venv/bin/python"
SG_UPSTREAM="${CSG_UPSTREAM:-https://github.com/canxin121/subtitle-gateway.git}"

DO_DEPS=0; DO_MODELS=0; DO_CHECK=0; DO_CLONE=0
case "${1:---all}" in
  --all)   DO_DEPS=1; DO_MODELS=1 ;;
  --clone) DO_CLONE=1 ;;
  --deps)  DO_DEPS=1 ;;
  --models) DO_MODELS=1 ;;
  --check) DO_CHECK=1 ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac

step() { echo; echo "===== $* ====="; }

clone_repo() {
  local have=0
  [ -d "$REPO/.git" ] && have=1
  if [ "$have" = 1 ]; then
    git -C "$REPO" fetch --depth 1 origin main -q && git -C "$REPO" reset --hard -q FETCH_HEAD || true
  else
    git clone --depth 1 "$SG_UPSTREAM" "$REPO"
  fi
  # 上游全量清单留一份: 本机选模型的菜单要读它, 而 repo/models.json 会被选中清单覆盖。
  # 必须从 git 对象里取 (FETCH_HEAD:models.json) —— 工作区那份已经是"选中的几项"了,
  # 拿它当上游全貌的话, 上游新增的模型永远进不了菜单, 之前没选的也再也加不回来。
  local wrote=0
  if [ "$have" = 1 ] && git -C "$REPO" show FETCH_HEAD:models.json > "$CSG_ROOT/models.upstream.json.tmp" 2>/dev/null; then
    mv "$CSG_ROOT/models.upstream.json.tmp" "$CSG_ROOT/models.upstream.json"; wrote=1
  fi
  if [ "$wrote" = 0 ] && [ ! -s "$CSG_ROOT/models.upstream.json" ] && [ -s "$REPO/models.json" ]; then
    cp "$REPO/models.json" "$CSG_ROOT/models.upstream.json"   # 全新克隆: 工作区就是上游原始那份
  fi
  rm -f "$CSG_ROOT/models.upstream.json.tmp"
  echo "upstream: $(python3 -c 'import json,sys;print(",".join(json.load(open(sys.argv[1]))["models"]))' "$CSG_ROOT/models.upstream.json" 2>/dev/null || echo '?')"
  echo "rev: $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo '?')"
}

# 把选中的模型清单盖上 repo/models.json (网关与下载脚本都读这一份)。
# 缺失时**必须**报错退出: 否则会静默退回上游那 4 个模型全开, 用户的选择被吃掉。
apply_selected() {
  if [ ! -s "$SELECTED" ]; then
    echo "ERROR: 缺少 $SELECTED —— 先在本机跑 colab-sg config (选模型) 或 colab-sg install" >&2
    return 1
  fi
  cp "$SELECTED" "$REPO/models.json" || return 1
  echo "models.json ← $(python3 -c 'import json,sys;m=json.load(open(sys.argv[1]));print(",".join(m["models"]),"| preload",",".join(m.get("preload",[])))' "$SELECTED" 2>/dev/null)"
}

# 选中的清单里有没有需要 qwen-asr 的模型 (Qwen3-ASR 两个 id)
needs_qwen() {
  local ids
  # 选中清单优先; 它还没生成时 (首次克隆后) 读上游清单, 按 CSG_MODELS 判断
  if [ -s "$SELECTED" ]; then ids="$SELECTED"
  elif [ -s "$REPO/models.json" ]; then ids="$REPO/models.json"
  else echo unknown; return; fi
  python3 -c '
import json,sys
m=json.load(open(sys.argv[1]))
keys=[k for k in m["models"] if k in sys.argv[2].split()] if len(sys.argv)>2 and sys.argv[2].strip() else list(m["models"])
print("yes" if any(k.startswith("qwen") or "qwen" in m["models"][k].get("model","").lower() for k in keys) else "no")
' "$ids" "${CSG_MODELS:-}" 2>/dev/null || echo unknown
}

# --------------------------------------------------------------------------
# 体检 (--check)
# --------------------------------------------------------------------------
check() {
  step "体检"
  echo "python(venv): $([ -x "$PY" ] && "$PY" -V 2>&1 || echo MISSING)"
  echo "repo:         $([ -d "$REPO/.git" ] && echo OK || echo MISSING)"
  echo "rev:          $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo -)"
  echo "models_cache: $(du -sh "$REPO/models_cache" 2>/dev/null | cut -f1 || echo MISSING)"
  echo "selected:     $([ -s "$SELECTED" ] && echo OK || echo 'MISSING (本机 colab-sg config)')"
  # 清单里声明的模型逐个核对缓存 (只看目录大小会把"别的模型下过了"误判成已就绪)
  local verdict
  verdict="$(python3 - "$REPO" "$SELECTED" "$CSG_ROOT/models.upstream.json" <<'PY'
import json, pathlib, sys
repo = pathlib.Path(sys.argv[1]); sel = pathlib.Path(sys.argv[2]); upf = pathlib.Path(sys.argv[3])
def snap_dirs(cache, hub, name):
    """该模型在缓存里对应的 snapshots 目录 (hub=ms 走 models/, hf 走 hub/models--*)。"""
    base = (cache / "hub" / ("models--" + name.replace("/", "--"))) if hub == "hf" \
        else (cache / "models" / name.replace("/", "--"))
    return [p for p in (base / "snapshots").glob("*") if p.is_dir()] if base.is_dir() else []
def present(cache, hub, name, min_bytes=100 * 1024 * 1024):
    # 名字要试两种写法: 清单里写的是 "fsmn-vad", 而 FunASR 自己的 resolver 会把它
    # 补成 "funasr/fsmn-vad" 再落盘 (models--funasr--fsmn-vad)。
    # 只按清单里的写法找, 永远找不到 → 每次 up/setup 都判定缺失, 重下 1.9G 的模型。
    for candidate in ([name] if "/" in name else [name, "funasr/" + name]):
        for snap in snap_dirs(cache, hub, candidate):
            biggest = max((p.stat().st_size for p in snap.rglob("*") if p.is_file()), default=0)
            if biggest > min_bytes: return True
    return False

cache = repo / "models_cache"
try:
    up = json.loads(upf.read_text())
except Exception as exc:
    print("MANIFEST_ERR %s" % exc); up = None
try:
    want = json.loads(sel.read_text()) if sel.is_file() else (up or {})
except Exception as exc:
    print("SELECTED_ERR %s" % exc); want = up or {}

up_ids = list((up or {}).get("models", {}))
print("upstream:     " + (",".join(up_ids) or "?"))
if want:
    print("selected:     " + ",".join(want["models"]) + " | preload " + ",".join(want.get("preload", [])))
    vanished = [k for k in want["models"] if up_ids and k not in up_ids]
    if vanished:
        print("drift:        上游已没有这些 id: " + ",".join(vanished) + " (colab-sg config 重新选)")
missing = []
for key, entry in (want or {}).get("models", {}).items():
    hub, name = entry.get("hub", "ms"), entry["model"]
    ok = present(cache, hub, name)
    # VAD 本来就是小模型 (fsmn-vad 约 2MB), 用 100MB 那个阈值永远判缺失。
    # 这里只要目录里有非空文件即算就绪。
    if ok and entry.get("vad_model") and not present(cache, hub, entry["vad_model"], min_bytes=1):
        ok = False
    if not ok: missing.append(key)
    print("  %-20s %-3s %-8s %s" % (key, hub, "OK" if ok else "MISSING", name))
print("MODELS_STATE %s" % ("ok" if want and not missing else "missing"))
PY
)"
  printf '%s\n' "$verdict"
  local qwen; qwen="$(needs_qwen)"
  local deps="ok" cuda="?" upstream=""
  if [ ! -x "$PY" ]; then deps="missing"
  else
    "$PY" -c 'import funasr, torch' >/dev/null 2>&1 || deps="missing"
  fi
  if [ "$qwen" = yes ] && [ -x "$PY" ]; then
    "$PY" -c 'import qwen_asr' >/dev/null 2>&1 || deps="missing"
  fi
  if [ -x "$PY" ]; then
    cuda="$("$PY" -c 'import torch;print(torch.cuda.is_available())' 2>/dev/null || echo '?')"
    "$PY" - <<'EOF'
import importlib
for m in ("torch","torchaudio","funasr","fastapi","uvicorn","cryptography","qwen_asr"):
    try:
        print(f"  {m:14} {getattr(importlib.import_module(m),'__version__','?')}")
    except Exception:
        print(f"  {m:14} MISSING")
try:
    import torch
    if torch.cuda.is_available():
        print("  device        ", torch.cuda.get_device_name(0),
              f"{torch.cuda.get_device_properties(0).total_memory/2**30:.1f} GiB")
except Exception as exc:
    print("  cuda           ERR", exc)
EOF
  fi
  echo "cloudflared:  $(/content/cloudflared --version 2>/dev/null || echo MISSING)"
  echo "gateway:      $(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${CSG_PORT:-8000}/health" || true)"
  # 机器可读的一行: 本机 CLI 的 assess_vm 只认这一行 (别再靠 "cuda: False"/"*G*" 猜)
  local models_state; models_state="$(printf '%s\n' "$verdict" | sed -n 's/^MODELS_STATE //p' | tail -1)"
  echo "READY: deps=$deps models=${models_state:-missing} qwen=$qwen cuda=$cuda rev=$upstream"
}
[ "$DO_CHECK" = 1 ] && { check; exit 0; }

# --------------------------------------------------------------------------
# 克隆 (菜单要先读上游的 models.json, 而它只有克隆后才存在)
# --------------------------------------------------------------------------
if [ "$DO_CLONE" = 1 ]; then
  step "克隆/更新 subtitle-gateway"
  clone_repo
  [ -s "$SELECTED" ] && apply_selected
  echo
  echo "===== clone done ($CSG_ROOT) ====="
  exit 0
fi

# --------------------------------------------------------------------------
# 依赖
# --------------------------------------------------------------------------
if [ "$DO_DEPS" = 1 ]; then
  step "0/6 系统包 (libopus: ferrum 协议的 Opus 解码)"
  ldconfig -p 2>/dev/null | grep -q libopus || apt-get install -y -qq libopus0 libopusfile0 >/dev/null 2>&1 || true

  step "1/6 拉取/更新 subtitle-gateway"
  clone_repo
  apply_selected || exit 1

  step "2/6 venv + 服务端依赖"
  uv venv --python 3.12 --allow-existing "$REPO/.venv"
  [ -n "${CSG_UV_INDEX:-}" ] && IDX=(--index-url "$CSG_UV_INDEX") || IDX=()
  uv pip install --python "$PY" "${IDX[@]}" -r "$REPO/requirements.txt"

  step "3/6 funasr (关键: 必须钉 transformers/tokenizers, 否则解到 4.12/0.10 需要 Rust 编译并整体回滚)"
  uv pip install --python "$PY" "${IDX[@]}" funasr huggingface_hub \
    'transformers>=4.49,<5' 'tokenizers>=0.21' 'numpy>=1.26,<3'

  step "4/6 torch/torchaudio (与上游 setup.sh 同一组 pin; Colab 的 580 驱动下会装成 +cu130, CUDA 可用)"
  uv pip install --python "$PY" "${IDX[@]}" "torch==2.13.0" "torchaudio==2.11.0"

  step "5/6 Qwen3-ASR 运行时 (只在选中清单里有 qwen 模型时装)"
  if [ "$(needs_qwen)" = yes ]; then
    # qwen-asr 硬性要求 transformers==4.57.6; 必须放在 funasr/torch 之后, 否则依赖解析会把 5.x 拉回来
    uv pip install --python "$PY" "${IDX[@]}" \
      "qwen-asr==0.0.6" "transformers==4.57.6" "tokenizers==0.22.2" "huggingface_hub==0.36.2"
  else
    echo "跳过 (选中的模型不需要 qwen-asr)"
  fi

  step "6/6 cloudflared (公网隧道; 无账号的 quick tunnel)"
  if [ ! -x /content/cloudflared ]; then
    curl -fsSL -o /content/cloudflared \
      https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
      && chmod +x /content/cloudflared
  fi
  /content/cloudflared --version

  "$PY" - <<'EOF' || echo "WARN: torch 看不到 CUDA"
import torch
print("cuda available:", torch.cuda.is_available(), "| build", torch.version.cuda)
EOF
fi

# --------------------------------------------------------------------------
# 模型
# --------------------------------------------------------------------------
if [ "$DO_MODELS" = 1 ]; then
  step "模型下载 (清单 = repo/models.json, 幂等, 已缓存则跳过)"
  apply_selected || exit 1
  # 首次部署: 若 VM 上已有别的缓存 (例如部署目录搬家前的旧 models_cache), 先复用
  if [ -n "${CSG_SEED_CACHE:-}" ] && [ -d "${CSG_SEED_CACHE}" ] && [ ! -e "$REPO/models_cache/hub" ]; then
    echo "seeding cache from $CSG_SEED_CACHE"
    mkdir -p "$REPO"
    cp -al "${CSG_SEED_CACHE}" "$REPO/models_cache" 2>/dev/null \
      || cp -a "${CSG_SEED_CACHE}" "$REPO/models_cache" 2>/dev/null || true
  fi
  ls -la "$REPO/models_cache" 2>/dev/null | head -3
  # 只下选中的模型 (上游脚本的 --model 可重复; 不传 = 下清单里全部)
  mapfile -t SEL < <(python3 -c 'import json,sys;print("\n".join(json.load(open(sys.argv[1]))["models"]))' "$SELECTED" 2>/dev/null)
  ARGS=(); for m in "${SEL[@]}"; do ARGS+=(--model "$m"); done
  echo "下载: ${SEL[*]:-<全部>}"
  timeout 3600 "$PY" "$REPO/scripts/download-models.py" "${ARGS[@]}" || echo "WARN: 模型下载未完成, 可重跑本脚本"
fi

echo
echo "===== setup done ($CSG_ROOT) ====="