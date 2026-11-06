# moonmtx

[English](README.md) | 简体中文

MoonBit 的 Matrix Client-Server API SDK 内核。

moonmtx 负责构造请求、解析响应，并在两者之间维护 Matrix 客户端所需的状态：
房间状态、带缺口标记的时间线、同步令牌，以及待发消息队列。内核不做任何 I/O，
因此能在 MoonBit 的全部后端上运行，可以接任意 HTTP 客户端。仓库另附一个基于
`moonbitlang/async` 的 native 传输层。

对应 [Matrix 规范 v1.19](https://spec.matrix.org/v1.19/client-server-api/)。
状态：0.1 开发中，见 [docs/ROADMAP.md](docs/ROADMAP.md)。

## 功能

- **可恢复的同步。** `Store::apply` 把一次 `/sync` 响应归并进房间状态，并在
  同一步推进同步令牌；`Store::to_json` 把两者写进同一个快照。崩溃后客户端从
  保存的令牌重新同步，服务器重发的事件按事件 ID 去重。
- **缺口。** `limited` 时间线会留下缺口标记，`fill_gap` 向前翻页，直到遇到
  缺口之前已存储的事件。
- **幂等发送。** 每条排队的消息在重试中保持同一个事务 ID，服务器不会重复发出。
  限流时按服务器给出的延迟等待；本地回显按 `unsigned.transaction_id` 匹配。
- **事件保留原始 JSON。** 类型化视图（消息、关系、成员、权限等级）按需解码，
  未知字段不会丢失。

0.1 不包含：端到端加密、媒体、联邦、应用服务（Application Service）。

## 包

| 包 | 内容 |
| --- | --- |
| `ids` | 用户 / 房间 / 事件 ID、房间别名、服务器名 |
| `api` | `Request`/`Response`、错误模型、服务器发现、登录、房间端点 |
| `events` | 事件外壳、消息内容与关系、状态内容、重定向（删减） |
| `sync` | 过滤器、`/sync` 解析、`Store`、缺口回填、快照 |
| `send` | `Outbox`：幂等发送队列 |
| `client` | `Client`：组合以上各包的会话；`prepare` 生成可直接发送的 HTTP 请求 |
| `transport` | 仅 native：基于 `moonbitlang/async` 的 HTTP 与 `run_sync_loop` |
| `cmd/echo_bot` | 示例机器人 |

## 用法

使用自带的 native 传输层：

```moonbit
async fn run(homeserver : String, user : String, password : String) -> Unit {
  let login = @api.login_request(Password(User(user), password~))
  let session = @api.parse_login(@transport.request(homeserver, login))
  let c = @client.Client::new(homeserver, session)
  @transport.run_sync_loop(c, summary => {
    for r in summary.rooms {
      for e in r.events {
        if e.kind() is Message(m) && m.body == "!ping" {
          ignore(c.send_message(r.room_id, @events.notice("pong").reply_to(e.event_id)))
        }
      }
    }
    true
  }, persist=snapshot => save_somewhere(snapshot))
}
```

使用自己的 HTTP 客户端时，自行驱动会话：

```moonbit
let req = c.prepare(c.sync_request())       // verb, url, headers, body
let resp = @api.Response::new(status, body) // from your HTTP client
let summary = c.on_sync_response(resp)
while c.next_send(now_ms) is Some((txn_id, req)) {
  // send req, then:
  ignore(c.on_send_response(txn_id, @api.Response::new(status, body), now_ms))
}
```

每次同步后用一次原子写入保存 `c.snapshot()`，用 `Client::restore` 恢复。
快照不含访问令牌；`Session` 需作为机密单独保存。

### 示例机器人

```bash
MATRIX_HOMESERVER=https://matrix.example.org MATRIX_USER=@bot:example.org MATRIX_PASSWORD=secret MATRIX_STATE=bot.json moon run --target native cmd/echo_bot
```

它会用 notice 回复 `!echo <文本>`。设置 `MATRIX_STATE` 后，重启时无需重新
登录，也不会回复旧消息。

## 开发

```bash
moon check --target all --deny-warn
```

```bash
moon test --target all
```

```bash
moon fmt
```

用 `git config core.hooksPath .githooks` 启用 pre-commit 钩子。
CI 把工具链固定为 `0.10.15+943464bfa`，因为 `moonbitlang/async@0.22.4`
必须与核心库版本一致。

## 来源与许可证

Apache-2.0，见 [LICENSE](LICENSE)。规范来源、测试夹具出处与相关项目见
[docs/upstream.md](docs/upstream.md)。
