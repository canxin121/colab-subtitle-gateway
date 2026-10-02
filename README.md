# Colab GPU 上的 subtitle-gateway 服务

把 [subtitle-gateway](https://github.com/canxin121/subtitle-gateway)（FunASR 语音识别 + 翻译网关）
跑在 Colab 的 GPU 运行时上，用一个 CLI 管起来：建会话、装环境、拉服务、开公网隧道、断了自动重建。

**模型自己挑**：安装时从上游 `subtitle-gateway` 的清单里勾选要部署的模型（`sensevoice`、
`fun-asr-mlt-nano`、`qwen3-asr-1.7b`、`qwen3-asr-0.6b` …），只下选中的、只在网关注册选中的。
协议端点、密钥、公网入口同样在同一个向导里选。T4 上 `fun-asr-mlt-nano` 显存常驻约 1.4 GB。

---

## 它解决什么

| 痛点 | 这里的做法 |
|---|---|
| Colab 会话断了、进程全没了 | VM 侧 `setsid` 独立会话 + 本地 `watch`/`service` 两级自愈 |
| 一条命令装环境，跑一半 kernel 卡住 | 长任务全部丢 VM 后台跑 + 轮询日志，`exec` 超时也不留半路 |
| 免费 Colab 没有公网入口 | cloudflared quick tunnel，零账号零配置 |
| 每次重建会话公网域名都变 | 地址变化写本地文件 + 发系统通知 + 可选钩子；要固定域名就配 connector token |
| macOS / Linux 行为不一致 | `service install` 自动选 launchd 或 systemd --user |

---

## 安装

**新机器一键装**（不用先 clone）：

```bash
curl -fsSL https://raw.githubusercontent.com/canxin121/colab-subtitle-gateway/main/bootstrap.sh | bash
```

它会 clone 到 `~/.local/share/colab-subtitle-gateway`、把 `colab-sg` 软链进 `~/.local/bin`，
然后直接进交互式向导。管道模式下给参数要写成 `bash -s -- …`：

```bash
curl -fsSL …/bootstrap.sh | bash -s -- --system   # 装到 /usr/local/bin
curl -fsSL …/bootstrap.sh | bash -s -- --yes      # 跳过配置选择 (首次 Colab OAuth 仍需浏览器授权)
curl -fsSL …/bootstrap.sh | bash -s -- --ref main      # 也可指定已有的分支或标签
```

`bootstrap.sh` 会准备 Git / `uv` / Google Colab CLI（缺少 Git 时尽可能调用系统包管理器安装），
把仓库弄到本地，再把控制权交给仓库里的 `install.sh`；安装与向导逻辑只有一份。
所以远端执行需要的 `remote/*.sh` 始终在同一个目录，`colab-sg upgrade` 也按安装时记录的分支或标签更新它，且发现本地改动时不会覆盖。

| 选项 | 作用 |
|---|---|
| `--dir DIR` | 仓库落地目录（默认 `~/.local/share/colab-subtitle-gateway`） |
| `--ref REF` | 用哪个分支或标签（默认 `main`）；写入本地配置，`colab-sg upgrade` 继续跟随它 |
| `--proxy URL` | 下载仓库、安装 CLI 与访问 Colab 走的代理（默认读 `https_proxy` / `HTTPS_PROXY`） |
| `--system` / `--no-wizard` / `--yes` | 原样转给 `install.sh` |
| `-- <参数…>` | `--` 之后的参数原样交给 `install.sh` |

已经 clone 过就直接用仓库里的脚本（两者等价）：

```bash
git clone https://github.com/canxin121/colab-subtitle-gateway.git
cd colab-subtitle-gateway
./install.sh            # 软链到 ~/.local/bin，然后进交互式向导
```

bootstrap 会自动检查并安装 `uv` 与 Google Colab CLI；Linux 上缺少 Git 时会尝试用系统包管理器补齐。
运行环境需要 `curl` 和 Bash；macOS 首次使用 Git 时，系统可能会提示安装 Xcode Command Line Tools。
安装结束后向导会引导完成 Colab 登录、GPU 会话创建、模型下载与服务启动。

`./install.sh` 接下来的向导会一步步问：

1. **本地自检** — `colab` CLI / `timeout` / 网络与代理
2. **Colab 登录** — 未登录时 `colab` 会打印授权 URL，浏览器里点完把授权码粘回来
3. **会话** — 会话名 / GPU 型号 / 端口 / 设备 / 代理
4. **模型** — 从**上游清单**里多选（默认勾 `fun-asr-mlt-nano`），再选启动预载哪个、
   最多常驻几个。选了 Qwen 的会自动多装一组依赖（见下）
5. **协议与密钥** — 哪些端点启用、翻译走哪个上游、ferrum 要不要鉴权密钥
6. **公网入口** — quick / 固定域名（connector token）/ 固定域名（cert.pem）/ 不开
7. **装依赖 + 下模型** — 只下选中的那几个
8. **起服务 → 自测 → 可选装成常驻服务**

不想逐项选择时可用 `./install.sh --yes` 取默认；如果 Colab 尚未登录，仍需在浏览器完成一次 OAuth 授权。
`colab-sg install --dry-run` 只打印将要执行的远端动作和本次选择，不碰 VM。

> 需要 Colab 账号本身能建 GPU 运行时（免费额度即可拿到 T4，实测可用）。
> 免费额度的会话随时可能被回收——这正是 `watch` 存在的理由。

选择都落在两个文件里，之后随时 `colab-sg config` 重问（同样支持 `--yes`）：

| 文件 | 内容 |
|---|---|
| `~/.config/colab-subtitle-gateway/config.sh` | 会话 / 端口 / 模型 / 协议 / 隧道（600） |
| `~/.config/colab-subtitle-gateway/secrets.env` | ferrum 鉴权密钥等（600，`.gitignore` 已排除） |

优先级：**命令行参数 > 环境变量 > `config.sh` > 内置默认**。

## 模型

模型清单不在本仓库维护了，直接读上游部署在 VM 上的 `models.json`（`colab-sg config`
时从 VM 拉回来），所以上游加了新模型，重新跑一次 `colab-sg config` 就能看到并勾选。

选中的结果生成 `/content/csg/models.selected.json`，由 `remote/setup.sh` 覆盖成
`repo/models.json`——网关与上游的下载脚本都只认这一份，所以**没选的模型不会下载、
也不会出现在 `/v1/models`**。覆盖失败会直接报错退出（静默退回"上游全量"等于吃掉你的选择）。

`colab-sg models` 会把本地选择与 VM 上实际的缓存并排打出来，顺带提示上游清单里已消失的 id。

## 协议与密钥

网关的四条路由（`/v1/audio/transcriptions`、`/transcribe`、`/v1/translate`、`/translate`）
是**无条件挂载**的，`/health` 与 `/v1/models` 更没有鉴权开关。所以向导能真正控制的是：

| 选择 | 实际效果 |
|---|---|
| `openai` | `/v1/audio/transcriptions`，永远可用；只影响 `demo` 跑不跑 |
| `ferrum` | `/transcribe`。勾了鉴权 → 传 `--auth-secret`，客户端必须带 `x-auth-token`（= `sha256(secret)`），否则 401；再生成加密口令 → `--encryption-key`，客户端可用 `x-encrypted: 1` |
| `deepl` | `/v1/translate` 的上游与 API key |
| `libretranslate` | `/translate` 的上游与 API key |
| 翻译免费源 | 两条翻译路由共用。四个都没配时写 `--translate-free none`，翻译端点直接 503（这是**真的**关掉） |

`colab-sg keygen` 可以随时补生成 ferrum 密钥；`colab-sg config` 里把 ferrum 去掉再
保存，就会回到无鉴权（mpv STT 插件等不带 token 的客户端也能用）。

**密钥的边界**：只从本地文件经 `colab exec` 的 stdin 送进 VM，落在 `/content/csg/secrets.env`
（600）。它不进仓库、不进日志、不进本机 `~/.local/state` 下的 job/driver 文件。
**残留暴露面**：网关只认命令行参数，所以密钥会出现在 VM 的 `ps` 里。Colab VM 是单租户
root 环境，`ps` 与 600 文件的可见范围本来就是同一圈人，为此扭曲设计不值得——但你在共享
机器上跑就别这么干。

## 上手

```bash
colab-sg doctor     # 体检: colab CLI / 配置摘要 / 会话 / 上次地址
colab-sg up         # 建会话 → 装环境 → 下模型 → 起网关 + 隧道（首次约 10 分钟）
colab-sg demo       # 跑一遍选中的协议，确认真的能用
colab-sg url        # 打印公网地址
```

`up` 做这些事（之后都幂等跳过）：

1. 建/复用一个 T4 会话
2. 在 VM 上装 venv + 依赖（含 `transformers` 的版本钉，见下；选了 Qwen 再多一组 pin）
3. 只下选中的模型到 `repo/models_cache`
4. 起 gateway（参数全部来自 `deploy.env`）与 cloudflared 隧道
5. 把公网地址写到 `~/.local/state/colab-subtitle-gateway/url`

拿到地址后就能直接当服务用：

```bash
U=$(colab-sg url)

# OpenAI 兼容的语音转写（model 用你选中的 id: colab-sg models）
curl -X POST "$U/v1/audio/transcriptions" \
     -F file=@audio.wav -F model=fun-asr-mlt-nano

# 带分段时间戳
curl -X POST "$U/v1/audio/transcriptions" \
     -F file=@audio.wav -F model=fun-asr-mlt-nano \
     -F response_format=verbose_json -F 'timestamp_granularities[]=segment'

# ferrum 协议（mpv STT 插件用的那个）: 原始 body + 16kHz 单声道 wav
# 向导里开了鉴权的话，必须带 x-auth-token（= sha256(auth_secret)）
curl -X POST "$U/transcribe" -H "x-model: fun-asr-mlt-nano" -H 'x-compression: wav' \
     --data-binary @audio.wav

# LibreTranslate 协议 / DeepL 协议（默认走免费翻译源，google 优先、失败自动切 edge）
curl -X POST "$U/translate" -H 'Content-Type: application/json' \
     -d '{"q":"Hello","source":"en","target":"zh"}'
curl -X POST "$U/v1/translate" -H 'Content-Type: application/json' \
     -d '{"text":["Good morning"],"target_lang":"ZH"}'

curl "$U/health"     # {"status":"ok","device":"cuda","models_available":[...],"models_loaded":[...]}
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

会按你当前的配置生成单元（参数只剩 `watch`，其余都从 `config.sh` 读，改配置不用重装单元），
`KeepAlive`/`Restart=always` 保证进程本身也活着。
Linux 上想做到未登录也跑：

```bash
sudo loginctl enable-linger "$USER"
```

手工版模板在 [`templates/`](templates/)（`com.colab-subtitle-gateway.plist`、
`colab-subtitle-gateway.service`），需要加环境变量或装成系统级服务时用。

## 固定域名（可选）

默认 quick tunnel 每次重建会话都会换域名，因为它是 Cloudflare 的匿名隧道。
要固定，得先把隧道**挂到你自己账号的域名下**。推荐用 connector token 这条路：
全程不需要在这台机器上登录 Cloudflare，也不需要 API Token 权限。

**1. 在 Cloudflare 侧建隧道并配好公网主机名**（网页点几下即可）

1. 域名要已经在 Cloudflare 上（`example.com`，NS 指向 Cloudflare）
2. [Zero Trust 控制台](https://one.dash.cloudflare.com/) → Networks → Tunnels → **Create a tunnel**
   选 **Cloudflared**，起个名字（如 `colab-sg`）
3. 在 **Public Hostnames** 里加一条，例如 `asr.example.com`，
   Service 选 `HTTP`、URL 填 `localhost:8000`（端口要和 `--port` 一致）
4. 创建完它会给出 connector 的安装命令，把那串 `eyJhIjoi…` 的 **token 复制出来**

**2. 把 token 和主机名交给 CLI**

向导里选 `token` 模式会让你粘贴 token、填主机名（也可以先跳过，事后再补）：

```bash
colab-sg config     # 公网入口 → 2) token → 粘贴 eyJhIjoi… → 主机名 asr.example.com
colab-sg up         # 之后重建会话域名都不变
```

手改的话就是两个文件：

```bash
mkdir -p ~/.config/colab-subtitle-gateway
printf '%s' 'eyJhIjoi…' > ~/.config/colab-subtitle-gateway/tunnel.token
chmod 600 ~/.config/colab-subtitle-gateway/tunnel.token
export CSG_TUNNEL_MODE=token CSG_TUNNEL_HOSTNAME=asr.example.com
```

token 只经 `colab exec` 的 stdin 送进 VM，落在 `/content/csg/tunnel.token`（600），
本地这份也在配置目录里、已被 `.gitignore` 排除。`colab-sg doctor` 与
`colab-sg tunnel status` 都会显示当前隧道模式与主机名。

> 想换个域名？在 Cloudflare 的 Public Hostnames 里改即可，本地只改 `CSG_TUNNEL_HOSTNAME`。

<details>
<summary>另一条路：cert.pem 模式（需要 API Token 权限）</summary>

不用 token 时，也可以让 VM 上的 cloudflared 用证书建隧道。这条路的代价是
`cloudflared login` 会产生一个能建/删隧道的 **account 级 `cert.pem`**，比 connector token
权限大得多，所以不推荐。而且 cert.pem 只活在 VM 上，会话被回收就没了：

```bash
colab-sg config                  # 公网入口 → 3) named → 隧道名 + 主机名
colab-sg tunnel login            # 在 Colab 里跑 cloudflared login, 打印授权链接让你点
colab-sg up
```

`--cf-token-file`（`CSG_CF_TOKEN_FILE`）那条是给需要 API Token 做 DNS/隧道管理的场景留的，
需要 `Cloudflare Tunnel: Edit` 与 `DNS: Edit`，同样只在需要时配。

</details>

## 常用命令

| 命令 | 作用 |
|---|---|
| `colab-sg install` | 交互式向导（装机、改配置都走它） |
| `colab-sg config` | 只重问配置（模型 / 协议 / 密钥 / 入口），不重装不重下 |
| `colab-sg upgrade` | 升级本地脚本 + VM 侧环境，然后重启网关（**不掉会话**） |
| `colab-sg uninstall [--purge]` | 停服务 + 摘 launchd/systemd；`--purge` 连配置与状态目录一起清（命令入口由 `./install.sh uninstall` 摘） |
| `colab-sg up` | 建/复用会话 → 同步 → 起服务 → 拿地址 |
| `colab-sg status` | 会话 / gateway / 隧道 / 地址 一屏 |
| `colab-sg restart` | 停服务 → **重建会话** → 再拉起（断开后手动恢复用这条） |
| `colab-sg reload` | 重启网关 + 隧道，**不掉会话**（改完配置用这条；`upgrade` 内部也用它） |
| `colab-sg login` | 探活 Colab 登录，没登录就走 OAuth |
| `colab-sg tunnel login\|status` | cert.pem 模式的隧道登录 / 看当前隧道设置 |
| `colab-sg keygen` | 生成 ferrum 鉴权密钥（写进 `secrets.env`） |
| `colab-sg models` | 选中的模型 ↔ VM 上实际缓存 |
| `colab-sg logs [n]` | 看 VM 上的 supervisor / gateway / tunnel 日志 |
| `colab-sg exec <cmd>` | 在 VM 上执行任意命令 |
| `colab-sg down [--stop-session]` | 停服务；加参数连 Colab 会话一起释放 |
| `colab-sg setup [-f]` | 只做环境准备（幂等，`-f` 强制重装依赖） |

VM 上的布局：

```
/content/csg/
  deploy.env              VM 侧全部非密钥参数（CLI 生成，setup/supervisor 都读它）
  secrets.env             密钥（600，只经 stdin 注入）
  tunnel.token            connector token（600，token 模式才有）
  models.upstream.json    上游全量清单（选模型的菜单数据源）
  models.selected.json    你的选择 → 覆盖成 repo/models.json
  src/remote/             本仓库注入的 setup.sh / supervisor.sh
  repo/                   subtitle-gateway checkout（含 .venv 与 models_cache）
  run/                    gateway.log tunnel.log supervisor.log tunnel.url *.pid
```

> `deploy.env` 不是可有可无的：`colab exec` 每次都是新的 shell，在驱动脚本里 `export`
> 的东西活不过那个 cell，所以 VM 侧的参数只能靠文件传递。

跑完 `colab-sg up` 后可以在 VM 里直接操作（`self-contained`，不依赖本地仓库）：

```bash
colab-sg exec bash /content/csg/src/remote/supervisor.sh status
colab-sg exec tail -n 50 /content/csg/run/gateway.log
```

## 目录结构

```
bin/colab-sg            本地 CLI（唯一入口；macOS/Linux 通用）
install.sh              装到 ~/.local/bin，然后交给 colab-sg 的向导
remote/setup.sh         VM 侧环境准备：克隆 / 依赖 / 模型 / 体检，幂等
remote/supervisor.sh    VM 侧常驻：gateway + 隧道 + 自检循环
templates/              launchd plist 与 systemd unit 模板
```

模型清单不在本仓库里——它来自上游 checkout（`/content/csg/models.upstream.json`）。

`bin/colab-sg` 会把 `remote/*.sh` 按需 base64 注入 VM，因此本地改完脚本，下一次
`up`/`setup`/`upgrade` 就生效，不需要在 VM 上手动同步。

## 五个已知坑（已在脚本里处理）

1. **`colab exec` 只吃 Python**：`colab exec` 把内容当 notebook cell 执行，第一行是 shell 就
   `SyntaxError`；它也不吃位置参数（只能 `-f` 或 stdin）。仓库里所有远端调用都统一走
   「临时文件 + `-f` + `%%bash` 头」，所以 `colab-sg exec 'ls /content'` 能用。
2. **`colab exec` 的 shell 不持久**：每次 exec 都是新 bash，`export` 活不过那个 cell。
   所以 VM 侧的部署参数一律写进 `/content/csg/deploy.env`，由 `setup.sh` / `supervisor.sh`
   自己 source——否则改了端口或隧道模式，重启后又会退回默认值。
3. **`colab` 没有 `login` 子命令**：OAuth 是惰性的，`colab sessions` 发现没登录时才打印
   授权 URL 并等输入。`colab-sg login` 就是带代理前台跑一次 `sessions`。
4. **funasr 的依赖解析**：`funasr 1.4.16` 对 `transformers` 没有版本下限，在新 Python 上会解到
   `transformers 4.12.2 → tokenizers 0.10.3`，后者需要 Rust 编译，装不上且**回滚整个事务**
   （连 torch 一起丢）。所以 setup 里显式钉了 `transformers>=4.49,<5`、`tokenizers>=0.21`。
   Qwen3-ASR 那两个模型反过来要求 `transformers==4.57.6`，必须在 funasr/torch **之后**装，
   否则依赖解析会把 5.x 拉回来——所以只有选了 Qwen 才装那一组。
5. **CUDA wheel 不要走 `cu128` index**：Colab 驱动的 580 分支下，`torch==2.13.0` 从 PyPI
   默认就装成 `+cu130`（拉 `nvidia-*-cu13`），`torch.cuda.is_available()` 为 True；而
   `download.pytorch.org/whl/cu128` 最高只到 torch 2.9.1。直接用 PyPI 默认即可。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `CSG_SESSION` | `colab-sg` | Colab 会话名 |
| `CSG_GPU` | `T4` | GPU 型号（`L4`/`G4`/`A100`/`H100` 按额度） |
| `CSG_PORT` | `8000` | 网关端口 |
| `CSG_DEVICE` | `cuda` | `cuda` / `auto` / `cpu` |
| `CSG_ROOT` | `/content/csg` | VM 上的部署根目录 |
| `CSG_MODELS` | `fun-asr-mlt-nano` | 选中部署的模型 id（空格分隔，见 `colab-sg models`） |
| `CSG_PRELOAD` | 选中列表的第一个 | 启动时预载哪个（其余按需加载） |
| `CSG_MAX_LOADED_MODELS` | `min(选中数, 2)` | 最多常驻几个模型，`0` = 不限 |
| `CSG_PROTOCOLS` | 全开 | 空格分隔：`openai ferrum deepl libretranslate` |
| `CSG_TRANSLATE_FREE` | `google,edge` | 免费翻译源，`none` = 关掉翻译端点（503） |
| `CSG_TRANSLATE_UPSTREAM` | 空 | DeepL 上游地址（默认走免费源） |
| `CSG_LIBRETRANSLATE_UPSTREAM` | 空 | LibreTranslate 上游地址 |
| `CSG_TUNNEL_MODE` | `quick` | `quick` / `token` / `named` / `off` |
| `CSG_TUNNEL_NAME` | 空 | 命名隧道名（cert.pem 模式） |
| `CSG_TUNNEL_HOSTNAME` | 空 | 固定域名的主机名，配了 token 时用（如 `asr.example.com`） |
| `CSG_TUNNEL_TOKEN_FILE` | `~/.config/…/tunnel.token` | 命名隧道的 connector token 文件 |
| `CSG_UV_INDEX` | 空 | uv 的 index（国内网络可设阿里云镜像） |
| `CSG_PROXY` | 空 | 访问 Google 用的代理（如 `http://127.0.0.1:7890`）；不设时会自动读环境里的 `HTTPS_PROXY` |
| `CSG_SEED_CACHE` | 空 | 已存在的模型缓存目录，首次部署时硬链接复用，省一次下载 |
| `CSG_ON_URL_CHANGE` | 空 | 地址变化时的钩子，可用 `$CSG_URL` / `$CSG_OLD_URL` |
| `CSG_EXEC_TIMEOUT` | `180` | 单次 `colab exec` 墙钟上限 |
| `CSG_WATCH_INTERVAL` | `120` | `watch` 自检间隔（秒） |

密钥类只放 `secrets.env`，别写进 `config.sh`（那个文件会被 `config` 重写）：
`CSG_AUTH_SECRET`（ferrum 鉴权）、`CSG_ENCRYPTION_KEY`（ferrum AES 口令）、
`CSG_TRANSLATE_API_KEY` / `CSG_LIBRETRANSLATE_API_KEY`（客户端侧 key）、
`CSG_TRANSLATE_UPSTREAM_KEY` / `CSG_LIBRETRANSLATE_UPSTREAM_KEY`（上游侧 key）。

## 升级与卸载

```bash
cd colab-subtitle-gateway && git pull
colab-sg upgrade                # 重注入 remote/* + 重跑依赖 + 重启网关（会话保留）
colab-sg config                 # 上游加了新模型时，重选一次

colab-sg uninstall              # 停服务 + 摘 launchd/systemd，保留配置
colab-sg uninstall --purge      # 连 ~/.config 与 ~/.local/state 一起清
./install.sh uninstall          # 再摘下 ~/.local/bin/colab-sg 这个入口
colab-sg down --stop-session    # 单独释放 Colab 会话（想省额度时）
```

`upgrade` 故意不重建会话：cert.pem 模式的那份证书只活在 VM 家目录里，会话一回收就得
重新 `colab-sg tunnel login`。真要重建会话用 `colab-sg restart`。

## 许可

MIT
