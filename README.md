# moonmtx

English | [简体中文](README.zh-CN.md)

Matrix Client-Server API SDK core for MoonBit.

moonmtx builds requests, consumes responses, and keeps the client state a
Matrix client needs between them: room state, the timeline with its gaps, the
sync token, and a queue of outgoing messages. The core does no I/O, so it runs
on every MoonBit target and works with any HTTP client. A native transport
based on `moonbitlang/async` is included.

Targets the [Matrix specification v1.19](https://spec.matrix.org/v1.19/client-server-api/).
Status: 0.1 in development. See [docs/ROADMAP.md](docs/ROADMAP.md).

## What it does

- **Resumable sync.** `Store::apply` folds a `/sync` response into room state
  and advances the sync token in the same step; `Store::to_json` writes both
  into one snapshot. After a crash the client syncs again from the saved
  token, and events the server sends twice are dropped by event ID.
- **Gaps.** A `limited` timeline leaves a gap marker. `fill_gap` pages
  backwards until it reaches an event stored before the gap.
- **Idempotent sending.** Each queued message keeps its transaction ID across
  retries, so the server never posts it twice. Rate limits use the server's
  delay; local echoes are matched by `unsigned.transaction_id`.
- **Events keep their JSON.** Typed views (messages, relations, membership,
  power levels) are decoded on demand; unknown fields are never lost.

Not in 0.1: end-to-end encryption, media, federation, application services.

## Packages

| Package | Contents |
| --- | --- |
| `ids` | User, room, event IDs, room aliases, server names |
| `api` | `Request`/`Response`, error model, discovery, login, room endpoints |
| `events` | Event envelope, message content and relations, state contents, redaction |
| `sync` | Filters, `/sync` parsing, `Store`, gap filling, snapshots |
| `send` | `Outbox`: the idempotent send queue |
| `client` | `Client`: a session combining the above; `prepare` makes HTTP-ready requests |
| `transport` | Native only: HTTP with `moonbitlang/async`, `run_sync_loop` |
| `cmd/echo_bot` | Example bot |

## Usage

With the native transport:

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

With your own HTTP client, drive the session yourself:

```moonbit
let req = c.prepare(c.sync_request())       // verb, url, headers, body
let resp = @api.Response::new(status, body) // from your HTTP client
let summary = c.on_sync_response(resp)
while c.next_send(now_ms) is Some((txn_id, req)) {
  // send req, then:
  ignore(c.on_send_response(txn_id, @api.Response::new(status, body), now_ms))
}
```

Persist `c.snapshot()` with one atomic write after each sync and restore with
`Client::restore`. The snapshot does not contain the access token; store the
`Session` separately as a secret.

### Example bot

```bash
MATRIX_HOMESERVER=https://matrix.example.org MATRIX_USER=@bot:example.org MATRIX_PASSWORD=secret MATRIX_STATE=bot.json moon run --target native cmd/echo_bot
```

It answers `!echo <text>` with a notice. With `MATRIX_STATE` it resumes
without logging in again and does not answer old messages.

## Development

```bash
moon check --target all --deny-warn
```

```bash
moon test --target all
```

```bash
moon fmt
```

Enable the pre-commit hook with `git config core.hooksPath .githooks`.
The toolchain is pinned to `0.10.15+943464bfa` in CI because
`moonbitlang/async@0.22.4` must match the core library.

## Sources and license

Apache-2.0. See [LICENSE](LICENSE). Specification sources, test fixture
provenance and related projects are listed in [docs/upstream.md](docs/upstream.md).
