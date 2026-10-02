# 让 Python 优先走 IPv4。
#
# 背景: 有些网络(校园网/某些家宽)会回 AAAA 记录, 但 IPv6 出口其实是黑洞 —— 连接不是
# 立刻 ENETUNREACH, 而是 SYN 发出去没人应, 吃满整个 connect 超时。Python 的
# socket.create_connection 会按 getaddrinfo 的顺序逐个尝试, 不会并行 happy-eyeballs,
# 于是 colab CLI 一条请求要等 4x30s=2 分钟 (表现为 `colab sessions` 无输出地卡住)。
#
# 这里在解析层把 IPv4 排到前面, 但**保留 IPv6 作为后备**, 所以双栈都通的环境不受影响,
# 只有"IPv6 黑洞"的网络会明显变快。
#
# 由 colab-sg 在确认 IPv6 不可用后通过 PYTHONPATH 注入 (见 ipv6_usable), 不常驻生效。
import socket

_orig_getaddrinfo = socket.getaddrinfo


def getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
    res = _orig_getaddrinfo(host, port, family, type, proto, flags)
    if family == socket.AF_INET6 or len(res) < 2:
        return res
    v4 = [r for r in res if r[0] == socket.AF_INET]
    v6 = [r for r in res if r[0] == socket.AF_INET6]
    return (v4 + v6) if v4 and v6 else res


socket.getaddrinfo = getaddrinfo