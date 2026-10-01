# Colab GPU 上的 subtitle-gateway 服务

把 [subtitle-gateway](https://github.com/canxin121/subtitle-gateway)（FunASR 语音识别 + 翻译网关）
跑在 Colab 的 GPU 运行时上，用一个 CLI 管起来：建会话、装环境、拉服务、开公网隧道、断了自动重建。

**一个模型到底**：只部署通义实验室的旗舰端到端 ASR `Fun-ASR-Nano-2512`（2 GB，中/英/日/韩/粤等
12 语，自带标点与数字规范化），不做多模型常驻。T4 上 RTF ≈ 0.17，显存常驻 ~1.4 GB。

---

## 它解决什么

| 痛点 | 这里的做法 |
|---|---|
| Colab 会话断了、进程全没了 | VM 侧 `setsid` 独立会话 + 本地 `watch`/`service` 两级自愈 |
| 一条命令装环境，跑一半 kernel 卡住 | 长任务全部丢 VM 后台跑 + 轮询日志，`exec` 超时也不留半路 |
| 免费 Colab 没有公网入口 | cloudflared quick tunnel，零账号零配置 |
| 每次重建会话公网域名都变 | 地址变化写本地文件 + 发系统通知 + 可选钩子；要固定域名就给命名隧道 |
| macOS / Linux 行为不一致 | `service install` 自动选 launchd 或 systemd --user |

---

## 安装

```bash
git clone https://github.com/canxin121/colab-subtitle-gateway.git
cd colab-subtitle-gateway
./install.sh            # 软链到 ~/.local/bin
```

依赖两样：

```bash
uv tool install google-colab-cli   # Colab 官方 CLI（本仓库的远端执行全靠它）
colab new --gpu T4 -s colab-sg     # 首次会走 OAuth 登录，跟着提示点完
```

> 需要 Colab 账号本身能建 GPU 运行时（免费额度即可拿到 T4，实测可用）。
> 免费额度的会话随时可能被回收——这正是 `watch` 存在的理由。

## 上手

```bash
colab-sg doctor     # 体检: colab CLI / 会话 / 上次地址
colab-sg up         # 建会话 → 装环境 → 下模型 → 起网关 + 隧道（首次约 10 分钟）
colab-sg demo       # 跑一遍 ASR + 翻译，确认真的能用
colab-sg url        # 打印公网地址
```

首次 `up` 会做完这些事（之后都幂等跳过）：

1. 建/复用一个 T4 会话
2. 在 VM 上装 venv + 依赖（含 `transformers` 的版本钉，见下）
3. 下 `Fun-ASR-Nano-2512`（约 2 GB）到 `repo/models_cache`
4. 起 gateway（`--device cuda`）与 cloudflared 隧道
5. 把公网地址写到 `~/.local/state/colab-subtitle-gateway/url`

拿到地址后就能直接当服务用：

```bash
U=$(colab-sg url)

# OpenAI 兼容的语音转写
curl -X POST "$U/v1/audio/transcriptions" \
     -F file=@audio.wav -F model=fun-asr-nano-2512

# 带分段时间戳
curl -X POST "$U/v1/audio/transcriptions" \
     -F file=@audio.wav -F model=fun-asr-nano-2512 \
     -F response_format=verbose_json -F 'timestamp_granularities[]=segment'

# LibreTranslate 协议 / DeepL 协议（默认走免费翻译源，google 优先、失败自动切 edge）
curl -X POST "$U/translate" -H 'Content-Type: application/json' \
     -d '{"q":"Hello","source":"en","target":"zh"}'
curl -X POST "$U/v1/translate" -H 'Content-Type: application/json' \
     -d '{"text":["Good morning"],"target_lang":"ZH"}'

curl "$U/health"     # {"status":"ok","device":"cuda","models_loaded":["fun-asr-nano-2512"],...}
```

## 保活是怎么做的

分两层，因为两个故障面的寿命完全不同：

```
本地机器                     Colab VM
┌──────────────┐            ┌─────────────────────────────┐
│ colab-sg     │  colab exec│ supervisor.sh (setsid 独立会话)│
│   watch      │ ─────────► │   ├─ gateway  (uvicorn)      │
│  每 120s 自检 │            │   ├─ cloudflared (隧道)       │
│              │ ◄───────── │   └─ watch loop (每 60s)      │
└──────────────┘   读 URL    └─────────────────────────────┘
```

- **VM 层**：`supervisor.sh` 用 `setsid` 把三个进程挂成独立会话，不挂在 Colab kernel 上。
  kernel 重启或 `colab exec` 断开都不影响它；它自己每 60 秒探活，谁挂了重启谁。
- **会话层**：Colab 运行时被回收时 VM 整个消失，只有本地能救。`colab-sg watch` 每 120 秒
  检查会话是否还在，不在就重建（`colab new --gpu T4 -s colab-sg` 会自动重新部署整个目录树）。
- **地址层**：重建后 quick tunnel 的域名一定会变，`watch` 会把新地址写进 url 文件、
  发系统通知，并可执行 `--on-url-change` 指定的钩子（新地址在 `$CSG_URL`）。

真正常驻就用服务：

```bash
colab-sg service install      # macOS → launchd;  Linux → systemd --user
colab-sg service uninstall
```

会按你当前的 `-s/-g/--port` 参数生成单元，`KeepAlive`/`Restart=always` 保证进程本身也活着。
Linux 上想做到未登录也跑：

```bash
sudo loginctl enable-linger "$USER"
```

手工版模板在 [`templates/`](templates/)（`com.colab-subtitle-gateway.plist`、
`colab-subtitle-gateway.service`），需要加环境变量或装成系统级服务时用。

## 固定域名（可选）

默认 quick tunnel 每次重建会话都换域名。要固定，用 Cloudflare 命名隧道：

```bash
mkdir -p ~/.config/colab-subtitle-gateway
printf '%s' '<你的 Cloudflare API Token>' > ~/.config/colab-subtitle-gateway/cloudflare.token
chmod 600 ~/.config/colab-subtitle-gateway/cloudflare.token

colab-sg up -n colab-sg          # 域名固定，重启/重建会话都不变
```

Token 需要有 `Cloudflare Tunnel: Edit` 与 `DNS: Edit` 权限（对应你要挂的子域所在 zone）。
token 只经 `colab exec` 的 stdin 送进 VM，不落盘在本地仓库里。

## 常用命令

| 命令 | 作用 |
|---|---|
| `colab-sg up` | 建/复用会话 → 同步 → 起服务 → 拿地址 |
| `colab-sg status` | 会话 / gateway / 隧道 / 地址 一屏 |
| `colab-sg restart` | 停服务 → 重建会话 → 再拉起（断开后手动恢复用这条） |
| `colab-sg logs [n]` | 看 VM 上的 supervisor / gateway / tunnel 日志 |
| `colab-sg exec <cmd>` | 在 VM 上执行任意命令 |
| `colab-sg down [--stop-session]` | 停服务；加参数连 Colab 会话一起释放 |
| `colab-sg setup [-f]` | 只做环境准备（幂等，`-f` 强制重装依赖） |

VM 上的布局：

```
/content/csg/
  src/remote/     本仓库注入的 models.json / setup.sh / supervisor.sh
  repo/           subtitle-gateway checkout（含 .venv 与 models_cache）
  run/            gateway.log tunnel.log supervisor.log tunnel.url *.pid
```

跑完 `colab-sg up` 后可以在 VM 里直接操作（`self-contained`，不依赖本地仓库）：

```bash
colab-sg exec bash /content/csg/src/remote/supervisor.sh status
colab-sg exec tail -n 50 /content/csg/run/gateway.log
```

## 目录结构

```
bin/colab-sg            本地 CLI（唯一入口；macOS/Linux 通用）
install.sh              装到 ~/.local/bin
remote/models.json      只留旗舰模型的模型清单（网关与下载脚本共用）
remote/setup.sh         VM 侧环境准备：依赖 / 模型 / 体检，幂等
remote/supervisor.sh    VM 侧常驻：gateway + 隧道 + 自检循环
templates/              launchd plist 与 systemd unit 模板
```

`bin/colab-sg` 会把 `remote/*` 按需 base64 注入 VM，因此本地改完脚本，下一次
`up`/`setup` 就生效，不需要在 VM 上手动同步。

## 三个已知坑（已在脚本里处理）

1. **`colab exec` 只吃 Python**：`colab exec` 把内容当 notebook cell 执行，第一行是 shell 就
   `SyntaxError`；它也不吃位置参数（只能 `-f` 或 stdin）。仓库里所有远端调用都统一走
   「临时文件 + `-f` + `%%bash` 头」，所以 `colab-sg exec 'ls /content'` 能用。
2. **funasr 的依赖解析**：`funasr 1.4.16` 对 `transformers` 没有版本下限，在新 Python 上会解到
   `transformers 4.12.2 → tokenizers 0.10.3`，后者需要 Rust 编译，装不上且**回滚整个事务**
   （连 torch 一起丢）。所以 setup 里显式钉了 `transformers>=4.49,<5`、`tokenizers>=0.21`。
3. **CUDA wheel 不要走 `cu128` index**：Colab 驱动的 580 分支下，`torch==2.13.0` 从 PyPI
   默认就装成 `+cu130`（拉 `nvidia-*-cu13`），`torch.cuda.is_available()` 为 True；而
   `download.pytorch.org/whl/cu128` 最高只到 torch 2.9.1。直接用 PyPI 默认即可。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `CSG_SESSION` | `colab-sg` | Colab 会话名 |
| `CSG_GPU` | `T4` | GPU 型号（`L4`/`G4`/`A100`/`H100` 按额度） |
| `CSG_PORT` | `8000` | 网关端口 |
| `CSG_ROOT` | `/content/csg` | VM 上的部署根目录 |
| `CSG_TUNNEL_MODE` | `quick` | `quick` / `off`（`off` = 不开隧道） |
| `CSG_TUNNEL_NAME` | 空 | 命名隧道名，给了就用固定域名 |
| `CSG_UV_INDEX` | 空 | uv 的 index（国内网络可设阿里云镜像） |
| `CSG_PROXY` | 空 | 访问 Google 用的代理（如 `http://127.0.0.1:7890`）；不设时会自动读环境里的 `HTTPS_PROXY` |
| `CSG_SEED_CACHE` | 空 | 已存在的模型缓存目录，首次部署时硬链接复用，省一次下载 |
| `CSG_ON_URL_CHANGE` | 空 | 地址变化时的钩子，可用 `$CSG_URL` / `$CSG_OLD_URL` |
| `CSG_EXEC_TIMEOUT` | `180` | 单次 `colab exec` 墙钟上限 |
| `CSG_WATCH_INTERVAL` | `120` | `watch` 自检间隔（秒） |

## 许可

MIT
