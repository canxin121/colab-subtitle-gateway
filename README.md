# Colab GPU subtitle-gateway

用 Google Colab GPU 运行 [subtitle-gateway](https://github.com/canxin121/subtitle-gateway)，通过 Cloudflare tunnel 暴露语音识别与翻译 API。**部署逻辑和配置都在 `colab-sg.ipynb`**：没有本地交互式安装向导、没有本地运维 CLI，也没有 VM 端 shell supervisor。仓库里唯一需要在 notebook 之外运行的操作文件是 launchd / systemd 服务模板。

## 工作方式

- 修改 notebook 顶部的 `CONFIG`，再用 Google Colab CLI 无头执行。运行中的 gateway 与 cloudflared 由 Python `subprocess.Popen(start_new_session=True)` 启动，脱离 notebook kernel。
- Colab VM 上的 checkout、venv、缓存、日志和 PID 文件默认位于 `/content/csg`。
- 模型清单从上游仓库读取；notebook 只把所选模型写入 gateway 清单，并只下载所选模型。
- Cloudflare 由 Python 下载、启动和监管官方 `cloudflared` connector。它仍是 Cloudflare 提供的独立程序；目前可用的 Python 包同样是封装/下载该 connector，并不实现 Cloudflare tunnel 协议。
- 本地 launchd / systemd 模板循环检查 Colab 会话、必要时创建会话，然后重跑 notebook，以应对 VM 回收。

## 首次运行

需要 Python 环境、Google Colab CLI（`google-colab-cli`）和一个有 GPU 运行权限的 Colab 账号。安装 CLI 的一种方式：

```bash
uv tool install google-colab-cli
```

先按 Colab CLI 指引完成账号授权。服务进程不会处理登录提示或交互式 OAuth；首次授权应在终端完成。

```bash
git clone https://github.com/canxin121/colab-subtitle-gateway.git
cd colab-subtitle-gateway
```

打开 `colab-sg.ipynb` 并编辑 `CONFIG`。首次创建 Colab 会话后运行 notebook：

```bash
colab new --gpu T4 -s colab-sg
colab exec -s colab-sg -f colab-sg.ipynb --timeout 21600
```

`colab new` 只在该会话尚不存在时需要运行。`--timeout 21600` 是 6 小时，首次安装依赖或下载大模型时不要使用 CLI 默认的 30 秒。执行会生成 `colab-sg_output.ipynb`；它被 `.gitignore` 忽略，提交前仍应检查输出中没有不想分享的内容。

也可以在 Colab 网页中打开 notebook 后运行全部单元格。该方式直接使用网页当前连接的 Colab runtime；本机 launchd / systemd 服务则使用本地 Google Colab CLI。

## 配置

`CONFIG` 是唯一配置入口，默认值和含义都写在 notebook 中。最常用的项目：

| 键 | 默认值 | 说明 |
|---|---|---|
| `mode` | `deploy` | `deploy` / `status` / `stop` / `uninstall` |
| `session`, `gpu` | `colab-sg`, `T4` | 本地服务模板创建/使用的会话名和 GPU 型号 |
| `port`, `device` | `8000`, `cuda` | gateway 监听端口与推理设备（`cuda` / `auto` / `cpu`） |
| `root` | `/content/csg` | Colab VM 上的部署根目录 |
| `models` | `fun-asr-mlt-nano` | 从上游 `models.json` 选择的模型 ID 列表 |
| `preload` | `fun-asr-mlt-nano` | 启动时预加载的所选模型；`[]` 表示不预加载 |
| `protocols` | 四种协议全开 | `openai`、`ferrum`、`deepl`、`libretranslate` 的列表 |
| `translate_free` | `google,edge` | 免费翻译来源；`none` 可关闭免费后备来源 |
| `tunnel` | `quick` | `quick`、`token`、`named` 或 `off` |
| `force_deps`, `force_download` | `False` | 强制重装依赖或重新检查/下载模型 |
| `run_demo` | `False` | 部署后请求本地转写与翻译端点 |

可在 `colab exec` 中重复传 `--env KEY=VALUE` 覆盖相应配置，例如：

```bash
colab exec -s colab-sg -f colab-sg.ipynb --timeout 21600 \
  --env CSG_MODE=deploy --env 'CSG_PROTOCOLS=openai ferrum' --env CSG_TUNNEL_MODE=off
```

支持的环境覆盖字段见 notebook 的 `_ENV_FIELDS` 映射。列表值接受空格或逗号分隔。直接改 `CONFIG` 更适合作为长期配置；环境覆盖只影响这次执行。

## 模型与依赖

模型 ID 来自上游 checkout 的原始 Git 清单（`git show HEAD:models.json`），而不是被选择结果覆盖的工作树文件。若配置中的模型已从上游移除，会打印告警；若没有任何可用模型则会停止，避免静默退回上游全量清单。

依赖安装幂等并保持必要顺序：上游 requirements → FunASR 与 transformers/tokenizers pins → torch/torchaudio pins →（选择 Qwen 时）Qwen3-ASR pins。这个顺序避免 FunASR 把 transformers/tokenizers 解到不兼容或需要本地 Rust 编译的版本。模型下载直接调用上游的 `scripts/download-models.py`，缓存位于 `repo/models_cache`。

## 协议与密钥

配置字段与网关参数对应：

- `openai`：`/v1/audio/transcriptions`
- `ferrum`：`/transcribe`；若设置 `auth_secret`，客户端的 `x-auth-token` 必须为 `hex(sha256(secret))`。`encryption_key` 启用 ferrum AES 加密。
- `deepl`：DeepL-compatible `/v1/translate`；`translate_upstream_key` 是发给上游的 key，`translate_api_key` 是调用 gateway 的客户端鉴权 key。
- `libretranslate`：`/translate`；`libretranslate_upstream_key` 是上游 key，`libretranslate_api_key` 是客户端鉴权 key。

未启用协议的凭据不会传给 gateway。上游应用仍无条件挂载 API 路由，因此配置只控制后端能力、翻译来源和鉴权，不会移除 FastAPI 路由本身。

**密钥会进入 Git 历史**：把需要的密钥直接填进 notebook 是本项目当前约定，默认值为空。不要把仓库或 notebook 输出公开；若凭据曾被提交到公开仓库，删除提交不能保证清除缓存，应立即轮换。VM 上的 `secrets.env` 与 connector token 文件使用 `0600` 权限；gateway 本身只接受命令行参数，因此 gateway 的密钥仍可能出现在同一 VM 用户可见的进程参数中。

## Cloudflare tunnel

- `quick`：零配置，获得 `trycloudflare.com` 临时地址；重建 tunnel 后地址可能改变。
- `token`：在 Cloudflare Zero Trust 创建 tunnel 和 Public Hostname，将 connector token 填入 `tunnel_token`，hostname（不带 `https://`）填入 `tunnel_hostname`。域名固定，推荐使用。
- `named`：填 `tunnel_name` 与 `tunnel_hostname`，并确保 Colab VM 中已有 `~/.cloudflared/cert.pem`。
- `off`：不启动 tunnel。

`cloudflared` 会下载到 `root/cloudflared`；日志和最近一次 URL 分别在 `root/run/tunnel.log` 与 `root/run/tunnel.url`。状态单元会检查 `/health`，发现失败时重启对应进程。Tunnel 路由和 DNS 必须事先在 Cloudflare 侧配置；notebook 不会创建 Cloudflare 账号资源。

## 示例请求

从部署输出中复制公网 URL：

```bash
URL='https://your-tunnel.example.com'

curl -X POST "$URL/v1/audio/transcriptions" \
  -F file=@audio.wav -F model=fun-asr-mlt-nano \
  -F response_format=verbose_json -F 'timestamp_granularities[]=segment'

# ferrum: x-auth-token 仅在 CONFIG.auth_secret 非空时必需
curl -X POST "$URL/transcribe" \
  -H 'x-model: fun-asr-mlt-nano' -H 'x-compression: wav' \
  --data-binary @audio.wav

curl -X POST "$URL/translate" -H 'Content-Type: application/json' \
  -d '{"q":"Hello","source":"en","target":"zh"}'

curl "$URL/health"
```

`run_demo=True` 会在 VM 本地回环地址运行 OpenAI 转写、ferrum 转写和已启用的翻译协议测试；语音请求可能触发真实模型推理并消耗 GPU 时间。

## 常驻服务

服务模板只负责本机的恢复循环；它不是第二套部署实现。运行服务前，先确保 notebook 的 `CONFIG["mode"]` 为 `"deploy"`，并完成 Colab CLI 授权。模板每 120 秒检查一次 `colab status -s <session>` 的“Session not found”输出（该命令对不存在的会话也可能返回 0）；发现会话不存在时尝试创建，然后执行 notebook。`colab exec` 失败也会重试。路径中如含特殊字符，请手工正确引用/转义占位符。

模板占位符：

- `__EXEC__`：`colab` 可执行文件的绝对路径（可用 `command -v colab` 查找）
- `__SESSION__` / `__GPU__`：与 notebook CONFIG 一致
- `__NOTEBOOK__`：notebook 的绝对路径
- `__PATH__`：包含 `colab` 与必要运行器的 PATH
- `__STATE__`：仅 launchd 模板使用的、预先创建的日志目录

### macOS (launchd)

把 [`templates/com.colab-subtitle-gateway.plist`](templates/com.colab-subtitle-gateway.plist) 复制到 `~/Library/LaunchAgents/`，替换上述占位符并创建 `__STATE__` 对应目录，然后加载：

```bash
launchctl load ~/Library/LaunchAgents/com.colab-subtitle-gateway.plist
launchctl list | grep com.colab-subtitle-gateway
```

卸载：

```bash
launchctl unload ~/Library/LaunchAgents/com.colab-subtitle-gateway.plist
rm ~/Library/LaunchAgents/com.colab-subtitle-gateway.plist
```

### Linux (systemd --user)

把 [`templates/colab-subtitle-gateway.service`](templates/colab-subtitle-gateway.service) 复制到 `~/.config/systemd/user/colab-subtitle-gateway.service`，替换占位符：

```bash
mkdir -p ~/.config/systemd/user
systemctl --user daemon-reload
systemctl --user enable --now colab-subtitle-gateway
journalctl --user -u colab-subtitle-gateway -f
```

要在注销后继续运行，可启用 linger：

```bash
sudo loginctl enable-linger "$USER"
```

停止并卸载服务：

```bash
systemctl --user disable --now colab-subtitle-gateway
rm ~/.config/systemd/user/colab-subtitle-gateway.service
systemctl --user daemon-reload
```

要释放 Colab 会话，先停掉本机服务循环，再运行 `colab stop -s colab-sg`。仅停止 VM 服务请将 notebook 的 `mode` 设为 `stop`；删除 VM 部署目录则先停本机服务，再设为 `uninstall` 并将 `confirm_uninstall` 显式改为 `True`。卸载不会自动停止 Colab 会话。

## 目录结构

```text
colab-sg.ipynb                         唯一配置面与部署程序
templates/                              launchd / systemd 服务模板
/content/csg/                           Colab VM 默认部署目录
  deploy.env                            非密钥部署摘要
  secrets.env                           协议密钥副本，权限 0600
  tunnel.token                          connector token，权限 0600（token 模式）
  models.upstream.json                  上游完整模型清单
  models.selected.json                  用户选择清单
  cloudflared                           Python 管理的官方 tunnel connector
  repo/                                 subtitle-gateway checkout、venv 与模型缓存
  run/                                  gateway/tunnel 日志、PID、URL 与配置指纹
```

## 许可

MIT
