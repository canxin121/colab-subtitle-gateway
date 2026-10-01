#!/bin/bash
# subtitle-gateway 在 Colab VM 上的一次性环境准备 (在 VM 里执行, 幂等可重复跑)
#
# 用法:
#   bash remote/setup.sh            # 完整: 依赖 + 模型 (已就绪的部分自动跳过)
#   bash remote/setup.sh --deps     # 只装依赖
#   bash remote/setup.sh --models   # 只下模型
#   bash remote/setup.sh --check    # 只体检, 不动任何东西
#
# 环境变量:
#   CSG_ROOT       远端根目录 (默认 /content/csg)
#   CSG_UV_INDEX   uv 的 index (默认 PyPI; 国内网络下可设 https://mirrors.aliyun.com/pypi/simple/)
#   CSG_SEED_CACHE 已有模型缓存目录; 首次部署时从它硬链接/拷贝, 省掉一次 ~2GB 下载
#   CSG_UV_INDEX   uv 的 index (默认 PyPI; 国内网络下可设 https://mirrors.aliyun.com/pypi/simple/)
set -uo pipefail

CSG_ROOT="${CSG_ROOT:-/content/csg}"
REPO="$CSG_ROOT/repo"
SRC="$CSG_ROOT/src"          # 本仓库的远端副本 (remote/ + models.json)
PY="$REPO/.venv/bin/python"
SG_UPSTREAM="https://github.com/canxin121/subtitle-gateway.git"

DO_DEPS=0; DO_MODELS=0; DO_CHECK=0
case "${1:---all}" in
  --all)   DO_DEPS=1; DO_MODELS=1 ;;
  --deps)  DO_DEPS=1 ;;
  --models) DO_MODELS=1 ;;
  --check) DO_CHECK=1 ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac

step() { echo; echo "===== $* ====="; }

# --------------------------------------------------------------------------
# 体检 (--check)
# --------------------------------------------------------------------------
check() {
  step "体检"
  echo "python(venv): $([ -x "$PY" ] && "$PY" -V 2>&1 || echo MISSING)"
  echo "repo:         $([ -d "$REPO/.git" ] && echo OK || echo MISSING)"
  echo "models_cache: $(du -sh "$REPO/models_cache" 2>/dev/null | cut -f1 || echo MISSING)"
  # 清单里声明的模型逐个核对缓存 (只看目录大小会把"别的模型下过了"误判成已就绪)
  python3 - "$REPO" <<'PY'
import json, pathlib, sys
repo = pathlib.Path(sys.argv[1])
try:
    manifest = json.loads((repo / "models.json").read_text())
except Exception as exc:
    print(f"manifest:     ERR {exc}")
    raise SystemExit(0)
cache = repo / "models_cache"
print("manifest:     " + ",".join(manifest["models"]) + " | preload " + ",".join(manifest.get("preload", [])))
for key, entry in manifest["models"].items():
    hub, name = entry.get("hub", "ms"), entry["model"]
    if hub == "hf":
        root = cache / "hub" / ("models--" + name.replace("/", "--"))
    else:
        root = cache / "models" / name.replace("/", "--")
    snaps = sorted(p for p in (root / "snapshots").glob("*") if p.is_dir()) if root.is_dir() else []
    biggest = max((p.stat().st_size for p in snaps[0].rglob("*") if p.is_file()), default=0) if snaps else 0
    state = "OK" if snaps and biggest > 100 * 1024 * 1024 else "MISSING"
    print(f"  {key:20} {hub:3} {state:8} {biggest/1e6:7.1f} MB  {name}")
PY
  echo "cloudflared:  $(/content/cloudflared --version 2>/dev/null || echo MISSING)"
  echo "gateway:      $(curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/health || true)"
  if [ -x "$PY" ]; then
    "$PY" - <<'EOF'
import importlib
for m in ("torch","torchaudio","funasr","fastapi","uvicorn","cryptography"):
    try:
        print(f"  {m:14} {getattr(importlib.import_module(m),'__version__','?')}")
    except Exception:
        print(f"  {m:14} MISSING")
try:
    import torch
    print("  cuda          ", torch.cuda.is_available(), torch.version.cuda)
    if torch.cuda.is_available():
        print("  device        ", torch.cuda.get_device_name(0),
              f"{torch.cuda.get_device_properties(0).total_memory/2**30:.1f} GiB")
except Exception as exc:
    print("  cuda           ERR", exc)
EOF
  fi
}
[ "$DO_CHECK" = 1 ] && { check; exit 0; }

# --------------------------------------------------------------------------
# 依赖
# --------------------------------------------------------------------------
if [ "$DO_DEPS" = 1 ]; then
  step "0/5 系统包 (libopus: ferrum 协议的 Opus 解码)"
  ldconfig -p 2>/dev/null | grep -q libopus || apt-get install -y -qq libopus0 libopusfile0 >/dev/null 2>&1 || true

  step "1/5 拉取/更新 subtitle-gateway"
  if [ -d "$REPO/.git" ]; then
    git -C "$REPO" fetch --depth 1 origin main -q && git -C "$REPO" reset --hard -q FETCH_HEAD && echo "updated"
  else
    git clone --depth 1 "$SG_UPSTREAM" "$REPO"
  fi
  # 本仓库自带的单模型清单覆盖上游的 models.json (网关与下载脚本共用这一份)
  cp "$SRC/remote/models.json" "$REPO/models.json"

  step "2/5 venv + 服务端依赖"
  uv venv --python 3.12 --allow-existing "$REPO/.venv"
  [ -n "${CSG_UV_INDEX:-}" ] && IDX=(--index-url "$CSG_UV_INDEX") || IDX=()
  uv pip install --python "$PY" "${IDX[@]}" -r "$REPO/requirements.txt"

  step "3/5 funasr (关键: 必须钉 transformers/tokenizers, 否则解到 4.12/0.10 需要 Rust 编译并整体回滚)"
  uv pip install --python "$PY" "${IDX[@]}" funasr huggingface_hub \
    'transformers>=4.49,<5' 'tokenizers>=0.21' 'numpy>=1.26,<3'

  step "4/5 torch/torchaudio (与上游 setup.sh 同一组 pin; Colab 的 580 驱动下会装成 +cu130, CUDA 可用)"
  uv pip install --python "$PY" "${IDX[@]}" "torch==2.13.0" "torchaudio==2.11.0"

  step "5/5 cloudflared (公网隧道; 无账号的 quick tunnel)"
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
  # 首次部署: 若 VM 上已有别的缓存 (例如部署目录搬家前的旧 models_cache), 先复用
  if [ -n "${CSG_SEED_CACHE:-}" ] && [ -d "${CSG_SEED_CACHE}" ] && [ ! -e "$REPO/models_cache/hub" ]; then
    echo "seeding cache from $CSG_SEED_CACHE"
    mkdir -p "$REPO"
    cp -al "${CSG_SEED_CACHE}" "$REPO/models_cache" 2>/dev/null \
      || cp -a "${CSG_SEED_CACHE}" "$REPO/models_cache" 2>/dev/null || true
  fi
  ls -la "$REPO/models_cache" 2>/dev/null | head -3
  timeout 3600 "$PY" "$REPO/scripts/download-models.py" || echo "WARN: 模型下载未完成, 可重跑本脚本"
fi

echo
echo "===== setup done ($CSG_ROOT) ====="
