# moonmtx 路线图

目标：一个纯 MoonBit 的 Matrix Client-Server API **SDK 内核**。重点是"可恢复的 `/sync`
状态处理"，不是 REST 端点的薄封装。规范锚定 Matrix v1.19（`matrix-org/matrix-spec`
release v1.19）。

窗口：11 月轮日期未在内置章程流程表中列出，以赛事群通知为准。本路线图按"窗口内四周"
排布。

约定：
- 每个里程碑合入前 `moon check --deny-warn` / `moon test` / `moon fmt --check` 全绿；
- 核心包保持 sans-IO（不做网络 I/O），用固定 JSON 夹具测试；传输层单独成包；
- 每个 commit 是一个可编译、带测试的完整改动，不做空提交或无意义拆分。

## 架构

```
ids        Matrix 标识符语法（@user:server、!room、$event、#alias、服务器名）
api        请求描述（方法/路径/查询/JSON 体）、百分号编码、错误模型、认证与发现
events     事件模型：保留原始 JSON + 常用类型化内容（消息、成员、房间元数据、关系）
sync       /sync 响应解析、过滤器构造、房间状态存储与检查点
send       事务 ID 与幂等发送队列（本地回显匹配、限流重试）
client     把以上组合为会话对象：吃响应、吐请求，不持有连接
http       （仅 native）基于 moonbitlang/async 的传输实现 + 示例
```

## M0 工程骨架 ✅

- [x] 模块元数据、Apache-2.0、pre-commit（moon check）
- [x] CI：三平台 `moon check/test --target all` + `moon fmt --check`
- [x] README / ROADMAP

## M1 标识符（ids）

- [ ] 服务器名（DNS 名 / IPv4 / IPv6 字面量 + 可选端口）
- [ ] 用户 ID（含历史字符集兼容的宽松解析）、房间 ID、事件 ID、房间别名
- [ ] 长度上限 255 字节与错误类型
- 验收：规范附录"标识符语法"的正/负样本单测

## M2 请求模型与错误（api）

- [ ] `Request`：方法、路径段百分号编码、查询串、JSON 体、是否需要令牌
- [ ] 标准错误 `{errcode, error}` 解析，`M_LIMIT_EXCEEDED` 的 `retry_after_ms`
- [ ] 发现：`/.well-known/matrix/client` 解析、`/versions`
- [ ] 认证：`/login`（密码 / 令牌）、`/logout`、`/account/whoami`
- 验收：请求构造与响应解析的夹具测试

## M3 事件模型（events）

- [ ] 事件外壳：type / event_id / sender / origin_server_ts / state_key / unsigned，保留原始 JSON
- [ ] 类型化内容：`m.room.message`（text/notice/emote）、`m.room.member`、`m.room.create`、
      `m.room.name`、`m.room.topic`、`m.room.power_levels`、`m.reaction`、`m.room.redaction`
- [ ] 关系：`m.relates_to`（回复 / 编辑 `m.replace` / 注解）
- [ ] 未知事件类型原样保留，不丢字段
- 验收：每类事件的解析与回写测试

## M4 /sync 解析（sync）

- [ ] 过滤器构造（timeline limit、lazy-load members）
- [ ] 响应解析：`rooms.join/invite/leave`、timeline（`limited`、`prev_batch`）、state、
      ephemeral、account_data、`next_batch`
- 验收：初次同步 / 增量同步 / limited 时间线的夹具测试

## M5 房间状态与可恢复同步（sync）

- [ ] 房间状态存储：按 `(type, state_key)` 归并，state 段先于 timeline 段应用
- [ ] 成员表、房间名计算、power level 查询
- [ ] 事件按 event_id 去重
- [ ] 检查点：状态与 `next_batch` 一起序列化/恢复；令牌只在状态写入后推进
- [ ] 缺口：`limited` 时间线记录缺口，生成 `/rooms/{id}/messages?dir=b&from=prev_batch` 回填请求
- 验收："崩溃后从检查点恢复不丢不重"、"limited 缺口回填"的夹具测试

## M6 幂等发送（send）

- [ ] 事务 ID 生成（会话内单调 + 随机前缀）
- [ ] 待发队列：重试复用同一事务 ID；`M_LIMIT_EXCEEDED` 退避
- [ ] 本地回显：用 `unsigned.transaction_id` 匹配 /sync 中回来的自己的事件
- [ ] 房间操作请求：create / join / leave / invite、redact
- 验收：重试不重复发送、回显匹配测试

## M7 会话与传输（client / http）

- [ ] `client`：组合认证、同步、发送，暴露"下一步请求 / 处理响应"接口
- [ ] `http`（native）：基于 `moonbitlang/async` 的 HTTP 传输
- [ ] 示例：echo bot（`moon run`）
- 验收：示例可运行；接口有文档

## M8 互通验证与发布

- [ ] Docker Synapse 本地互通脚本：注册 → 登录 → 建房 → 发消息 → 另一会话 `/sync` 收到
      → 断点恢复后继续同步（由 MoonBit SDK 发起请求，不是跑 SyTest 原套件）
- [ ] README 完善、API 文档
- [ ] mooncakes.io 发布 0.1.0
- [ ] 申报材料（人工撰写）与提交前自查

## 边界（首版明确不做）

- E2EE（Olm/Megolm、设备密钥、跨签名、密钥备份）
- 媒体上传/下载、缩略图
- 收据 / presence / read markers 的写入（只解析 ephemeral 原始数据）
- 联邦 Server-Server API、Application Service API、推送网关
- 完整房间管理（kick/ban/升级/空间）

## 与已有项目的关系

`kupas/imrelay`（`tomasky/imrelay`）里有一个面向 Agent 网关的 Matrix 适配器：认证、发送、
回复/编辑/reaction、typing，以及只取 joined-room 文本消息的 `/sync` 轮询（令牌只存在进程内）。
本项目做的是它没有的部分：通用房间状态归并、可持久化/可恢复的同步、缺口回填、幂等发送。
二者可以互补：网关可以把本库当作 Matrix 后端。

## 风险登记

| 风险 | 缓解 |
| --- | --- |
| 规范面太大，做成端点包装 | 以 M5 可恢复同步为技术核心；端点只做支撑它所需的子集 |
| 同步令牌与状态不一致导致丢事件 | 检查点把令牌和状态写成一个快照；令牌只在状态应用后推进 |
| `moonbitlang/async` HTTP 接口变化 | 传输层独立成包，核心不依赖它 |
| 互通测试依赖 Docker | 核心验收用夹具；Synapse 脚本作为附加证据 |
| 11 月轮窗口未确认 | 进赛事群确认；里程碑可压缩 |
