# moonmtx

Matrix Client-Server API SDK core for MoonBit.

moonmtx is a sans-IO library: it builds requests and consumes responses, and
keeps the client-side state that a Matrix client needs between them. It does
not open sockets itself, so the same core runs on every MoonBit target; an
optional native HTTP transport is provided separately.

Status: early development. See [ROADMAP.md](ROADMAP.md).

## Scope

Targets [Matrix specification v1.19](https://spec.matrix.org/v1.19/client-server-api/).

Planned for 0.1:

- Identifier grammar: user / room / event IDs, room aliases, server names
- Request builders and the standard error model (`errcode`, rate limits)
- Server discovery (`/.well-known/matrix/client`, `/versions`) and login
- Event model that keeps the original JSON and exposes typed content
- `/sync` parsing, a room state store, and checkpoints that save state and the
  sync token together so a restarted client neither drops nor repeats events
- Gap detection for limited timelines, with backfill requests
- Idempotent sending with transaction IDs and local-echo matching

Not in 0.1: end-to-end encryption, media, federation, application services.

## Development

```bash
moon check --target all
moon test --target all
moon fmt
```

Enable the pre-commit hook with `git config core.hooksPath .githooks`.

## License

Apache-2.0. See [LICENSE](LICENSE).
