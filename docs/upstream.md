# Sources, provenance and related projects

## Specification

- Matrix specification, release v1.19:
  <https://github.com/matrix-org/matrix-spec> (tag `v1.19`), rendered at
  <https://spec.matrix.org/v1.19/>.
- License: the repository root `LICENSE` and the OpenAPI files under
  `data/api/client-server/` (e.g. the header of `sync.yaml`) are Apache-2.0.
- Sections implemented from: Identifier Grammar (appendix), Server Discovery,
  Client Authentication, Standard error response, Syncing, Filtering, Room
  events, Transaction identifiers, Rich replies, Event replacements,
  Threading, Event annotations and reactions, Calculating the display name
  for a room / for a user, and the room version 11 redaction algorithm.

moonmtx is an original implementation written from the specification. No
code was copied from other Matrix SDKs.

## Test fixtures

Fixtures are written by hand in the shape of the spec's request/response
examples. Some example values (IDs, tokens, display names such as
`@cheeky_monkey:matrix.org`, `!636q39766251:example.com`, `"The Grand Duke
Pub"`) are taken from those examples, which are Apache-2.0 licensed as part
of `matrix-org/matrix-spec`. No fixture files are copied verbatim.

## Dependencies

| Module | Version | License | Used by |
| --- | --- | --- | --- |
| `moonbitlang/core` | toolchain 0.10.15 | Apache-2.0 | all packages |
| `moonbitlang/async` | 0.22.4 | Apache-2.0 | `transport`, `cmd/echo_bot` (native only) |

## Related projects

- `kupas/imrelay` (<https://github.com/tomasky/imrelay>, Apache-2.0): a
  multi-platform agent message gateway with a Matrix adapter covering login,
  sending, replies/edits/reactions, typing and polling joined-room text
  messages from `/sync` with an in-memory token. moonmtx covers what that
  adapter does not: general room state, resumable sync with persisted
  tokens, gap filling, and an idempotent send queue. A gateway could use
  moonmtx as its Matrix backend.
- `matrix-org/matrix-rust-sdk` (Apache-2.0): its event cache also stores the
  timeline as linked chunks separated by gaps. moonmtx uses the same idea,
  implemented independently and much smaller.
- `matrix-org/sytest` and `matrix-org/complement` (Apache-2.0) are black-box
  test suites for homeservers. They are not used here; moonmtx's interop
  check drives a homeserver through the SDK itself.
