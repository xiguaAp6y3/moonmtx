# 项目申报书

**基本信息**

- 项目名称：moonmtx：MoonBit 的 Matrix Client-Server SDK 内核
- 参赛者：张国迅（GitHub @xiguaAp6y3）
- 联系方式：（公开仓库暂不展示）
- GitHub 仓库：https://github.com/xiguaAp6y3/moonmtx
- 项目方向：即时通讯协议 SDK / 应用基础设施
- 项目类型：原创实现，依据 Matrix 规范 v1.19
- 仓库现状：公开

**项目简介**

Matrix 是开放、可自建的联邦聊天协议，Synapse 等服务端已经很成熟。2026-11-06 的定向调研发现 `kupas/imrelay` 中已有网关适配器，未在检索范围内发现独立的通用 Matrix SDK。

写 Matrix 客户端，难点在 `/sync`。同步令牌、房间状态、带缺口的时间线和待发消息必须一起保存：令牌推进了而状态没落盘，重启后会漏事件；状态落盘了而令牌没推进，重启后会重复处理；重试发送时换了事务 ID，服务器会把同一条消息发两次。moonmtx 把这几件事做成一个 sans-IO 内核：调用方把 HTTP 响应交给它，它更新状态并给出下一批要发的请求；全部状态可以写成一个 JSON 快照，再原样恢复。

**项目方向与通用性**

核心包不做网络 I/O，wasm、wasm-gc、js、native 四个后端共用同一套状态逻辑，HTTP 客户端由调用方决定；需要现成传输的可以用 `transport` 包（基于 `moonbitlang/async`，仅 native）。快照是普通 JSON，存文件、数据库或浏览器存储都行。库不假设上层是机器人、网关还是图形客户端。

**预期使用场景**

1. **常驻机器人 / 告警机器人。** 机器人长轮询 `/sync`，从房间状态判断自己是否被邀请、发送者有没有权限，再回复消息。进程崩溃后从快照里的 `next_batch` 继续，服务端重发的事件按 `event_id` 丢弃；断网重试沿用原来的事务 ID，同一条告警只会出现一次。`cmd/echo_bot` 是这条路径的可运行示例。
2. **多平台网关的 Matrix 后端。** `kupas/imrelay` 这类网关同时接十几个平台，Matrix 只是其中之一。网关管路由和会话，Matrix 侧的状态归并、令牌持久化、缺口回填和幂等发送交给 moonmtx，两边通过 `Client::prepare` / `on_sync_response` 对接。
3. **桌面或 Web 客户端的数据层。** 启动时恢复快照，先显示房间列表和未读数，再增量同步。往上翻历史用 `prev_batch` 分页，`limited` 留下的缺口用 `fill_gap` 补齐。消息发出前先进 outbox 显示为“发送中”，服务端回显到达后按事务 ID 合并，界面层不用自己维护这张对应表。

**实现路径**

常见做法有三种。按端点写薄封装（imrelay 的做法）上手最快，但状态归并、令牌持久化和缺口处理都留给了调用方。从 OpenAPI 生成也不现实：v1.19 的 YAML 是 OpenAPI 3.1，现有的 MoonBit 生成器 oas2moon 只支持 3.0，而且生成出来的只有请求和类型，没有状态逻辑。通过 FFI 绑定 matrix-rust-sdk 功能最全，但实际只适合 native 目标，构建还要带上 Rust 工具链。

moonmtx 按规范手写 sans-IO 内核，端点只实现同步、发送和房间操作需要的子集。几处关键设计：

- 令牌只在本批状态应用完后推进，和状态写进同一个快照；同一响应应用两次结果不变；每个房间最近 1024 个事件 ID 随快照保存，用于去重。
- 已见过的 state 事件不再回写，防止重发的旧事件让状态倒退；翻页带回的懒加载成员只补空缺，不覆盖更新的成员信息。
- 时间线分块存储，`limited` 响应在块之间留下缺口；`fill_gap` 沿 `prev_batch` 往前翻，遇到缺口前已存的事件即闭合。matrix-rust-sdk 的 event cache 也是这个思路，这里独立实现，规模小得多。
- 事务 ID 由设备、唯一会话前缀加单调计数组成，发送前保存队列和计数；从最近已提交快照恢复后续发，不能回滚旧备份继续发送。本地回显按 `unsigned.transaction_id` 匹配，回显比发送响应先到或后到都能对上。

**核心功能（首版）**

- `ids` / `api`：标识符语法与长度上限；请求与错误模型、限流提示、well-known 发现、登录 / 登出 / whoami / refresh、建房 / 邀请 / 加入 / 离开 / 状态 / 撤回 / typing / receipt；
- `events`：保留原始 JSON 的事件模型，按需解码消息、成员、房间名与主题、power levels、回复 / 编辑 / 反应 / 线程，未知事件不丢字段；
- `sync`：过滤器、`/sync` 解析、房间状态归并、去重、快照、缺口回填、向前翻页；
- `send`：按房间有序的发送队列，限流按服务器延迟、5xx 与断网指数退避、4xx 直接失败；
- `client` / `transport`：会话对象与 HTTP 请求准备；native 传输、同步循环和 echo bot 示例。

**明确不做**：E2EE、媒体上传下载、联邦 Server-Server API、Application Service API、自动收据管理 / presence 写入、踢人 / 封禁 / 房间升级等完整房间管理。receipt 仅提供请求构造。快照不含访问令牌，Session 另行安全保存。崩溃恢复要求单一写入者、可靠原子保存和最近已提交快照；业务回调只入队回复，其他外部副作用由调用方保证幂等。

**来源与许可证**

原创实现，没有复制其他 Matrix SDK 的代码。依据 `matrix-org/matrix-spec` v1.19（Apache-2.0），测试夹具按规范示例手写，来源记录在 `docs/upstream.md`。本项目采用 Apache-2.0。

**预期验收产物**

- 工具链与依赖：适配 `moonc v1.0.0-rc1+3c0520448`（满足 `moonc >= 1.0.0-rc1` 要求）与 `moonbitlang/async@0.22.11`；
- 包发布：已在 mooncakes.io 发布 `xiguaAp6y3/moonmtx` 0.1.1，可直接 `moon add`；
- 测试与 CI：wasm / wasm-gc / js 各 84 个、native 89 个（含 `transport` 本机 HTTP 测试 5 个）；CI 在 Linux / macOS / Windows 上基于 `1.0.0-rc1+3c0520448` 运行 `check`、`build`、`test`、`fmt`（`--target all --deny-warn`）；
- `interop/run.sh` 在 Docker 中启动 Synapse 1.164.2，所有请求由 moonmtx 发出，覆盖登录、建房邀请加入、按序发送与回显、事务重试、崩溃后从快照恢复、缺口回填、编辑 / 反应 / 撤回、翻页、退房共 10 个场景；
- 中英双语 README 与可运行的 echo bot 示例。
