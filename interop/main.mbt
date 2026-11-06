// Interop check against a real homeserver. Every request is built and every
// response consumed by moonmtx; the homeserver is a stock Synapse.
//
//   interop/synapse.sh up
//   moon run --target native interop
//   interop/synapse.sh down
//
// Scenarios run in order and share one room. The first failure stops the
// run with a non-zero exit code.

///|
let password : String = "moonmtx-interop-pw"

///|
let passed : Ref[Int32] = Ref(0)

///|
fn check(cond : Bool, what : String) -> Unit raise {
  if !cond {
    fail("check failed: \{what}")
  }
}

///|
fn ok(name : String) -> Unit {
  passed.val += 1
  println("PASS \{name}")
}

///|
async fn login(
  hs : String,
  user : String,
  filter? : @sync.Filter,
) -> @client.Client {
  let req = @api.login_request(Password(User(user), password~))
  let session = @api.parse_login(@transport.request(hs, req))
  match filter {
    Some(f) => @client.Client::new(hs, session, filter=f)
    None => @client.Client::new(hs, session)
  }
}

///|
/// Syncs until `done` holds, up to 20 long-polls of one second.
async fn sync_until(
  c : @client.Client,
  done : (@client.Client) -> Bool,
  what : String,
) -> Array[@sync.SyncSummary] {
  let summaries = []
  for _ in 0..<20 {
    let resp = @transport.perform(c.prepare(c.sync_request(timeout_ms=1000)))
    summaries.push(c.on_sync_response(resp))
    if done(c) {
      return summaries
    }
  }
  fail("timed out waiting for \{what}")
}

///|
/// Sends everything queued and syncs until the local echoes arrive.
async fn send_all(c : @client.Client) -> Unit {
  @transport.flush_sends(c)
  check(
    c.outbox.pending().iter().all(p => p.state() is Sent(_)),
    "all sends accepted",
  )
  ignore(sync_until(c, c => c.outbox.pending().is_empty(), "local echoes"))
}

///|
fn room_of(c : @client.Client, room : @ids.RoomId) -> @sync.Room raise {
  guard c.store.room(room) is Some(r) else { fail("room not in store") }
  r
}

///|
/// Bodies of the text messages stored for `room`, oldest first.
fn bodies(c : @client.Client, room : @ids.RoomId) -> Array[String] {
  let out = []
  guard c.store.room(room) is Some(r) else { return out }
  for e in r.events() {
    if e.kind() is Message(m) && m.relation is None {
      out.push(m.body)
    }
  }
  out
}

///|
fn count(xs : Array[String], x : String) -> Int32 {
  xs.filter(y => y == x).length()
}

///|
async fn call(c : @client.Client, req : @api.Request) -> @api.Response {
  @transport.perform(c.prepare(req))
}

///|
async fn run(hs : String) -> Unit {
  // Discovery. Everything moonmtx uses is in v1.17; the server's newest
  // advertised version is printed for the record.
  let versions = @api.parse_versions(
    @transport.request(hs, @api.versions_request()),
  )
  check(versions.supports("v1.17"), "server supports v1.17")
  let newest = versions.versions.filter(v => v.has_prefix("v1.")).last()
  ok("discovery: /versions parsed, newest \{newest.unwrap_or("?")}")

  // Login and whoami.
  let alice = login(hs, "alice")
  let bob = login(hs, "bob")
  let who = @api.parse_whoami(call(alice, @api.whoami_request()))
  check(who.user_id == alice.user_id(), "whoami matches login")
  ok("login and whoami for two users")

  // Create a room, invite, join.
  ignore(sync_until(alice, _ => true, "alice initial sync"))
  ignore(sync_until(bob, _ => true, "bob initial sync"))
  let room = @api.parse_room_id(
    call(
      alice,
      @api.create_room_request(name="moonmtx interop", preset=PrivateChat, invite=[
        bob.user_id(),
      ]),
    ),
  )
  ignore(sync_until(bob, c => c.store.invites().contains(room), "bob's invite"))
  ignore(@api.parse_room_id(call(bob, @api.join_request(Id(room)))))
  ignore(
    sync_until(
      bob,
      c => c.store.room(room).map(r => r.membership()) == Some(Join),
      "bob joined",
    ),
  )
  check(bob.store.invites().is_empty(), "invite cleared after join")
  let me_bob = bob.user_id().to_string()
  check(
    room_of(bob, room).display_name(me_bob) == "moonmtx interop",
    "room name from m.room.name",
  )
  ok("create room, invite, join; invite moves to joined")

  // Messages arrive in order, with local echo.
  for i in 1..<=3 {
    ignore(alice.send_text(room, "m\{i}"))
  }
  send_all(alice)
  ignore(
    sync_until(bob, c => count(bodies(c, room), "m3") == 1, "bob gets m1-m3"),
  )
  check(bodies(bob, room) == ["m1", "m2", "m3"], "order m1 m2 m3")
  check(bodies(alice, room) == ["m1", "m2", "m3"], "alice echo order")
  ok("send three messages; echoes complete the queue; order kept")

  // The same transaction ID twice gives the same event.
  let content = @events.text("idempotent").to_json()
  let req = @api.send_request(
    room, "m.room.message", "interop-fixed-txn", content,
  )
  let e1 = @api.parse_event_id(call(alice, req))
  let e2 = @api.parse_event_id(call(alice, req))
  check(e1 == e2, "retry with the same txn id returns the same event")
  ignore(
    sync_until(
      bob,
      c => count(bodies(c, room), "idempotent") >= 1,
      "idempotent message",
    ),
  )
  check(count(bodies(bob, room), "idempotent") == 1, "posted once")
  ok("retry with the same transaction ID posts once")

  // Crash and resume from a snapshot: nothing lost, nothing repeated.
  let saved = bob.snapshot().stringify()
  for b in ["r1", "r2", "r3"] {
    ignore(alice.send_text(room, b))
  }
  send_all(alice)
  ignore(
    sync_until(bob, c => count(bodies(c, room), "r3") == 1, "bob gets r1-r3"),
  )
  // bob "crashes" here without persisting what it just synced.
  let bob2 = @client.Client::restore(hs, bob.session(), @json.parse(saved))
  let delivered = []
  for s in sync_until(bob2, c => count(bodies(c, room), "r3") == 1, "replay") {
    for r in s.rooms {
      for e in r.events {
        if e.kind() is Message(m) {
          delivered.push(m.body)
        }
      }
    }
  }
  check(
    delivered == ["r1", "r2", "r3"],
    "replay delivers r1-r3 once: \{delivered.join(",")}",
  )
  ignore(sync_until(bob2, _ => true, "one more sync"))
  let all = bodies(bob2, room)
  check(
    count(all, "r1") == 1 && count(all, "r2") == 1 && count(all, "r3") == 1,
    "no duplicates after resume",
  )
  ok("resume from snapshot after a crash: r1-r3 delivered exactly once")

  // A limited timeline opens a gap that backfill closes.
  let small = @sync.Filter::new(timeline_limit=3)
  let carol = login(hs, "bob", filter=small)
  ignore(sync_until(carol, c => c.store.room(room) is Some(_), "carol initial"))
  let expected = []
  for i in 1..<=12 {
    expected.push("g\{i}")
    ignore(alice.send_text(room, "g\{i}"))
  }
  send_all(alice)
  let summaries = sync_until(
    carol,
    c => count(bodies(c, room), "g12") == 1,
    "carol gets g12",
  )
  let opened = summaries
    .iter()
    .any(s => s.rooms.iter().any(r => r.room_id == room && r.gap is Some(_)))
  check(opened, "limited sync opened a gap")
  let mut pages = 0
  while room_of(carol, room).gaps().get(0) is Some(token) && pages < 20 {
    let page = @sync.parse_messages(
      call(carol, @sync.messages_request(room, token, limit=5)),
    )
    ignore(carol.store.fill_gap(room, page))
    pages += 1
  }
  check(room_of(carol, room).gaps().is_empty(), "gap closed")
  let got = bodies(carol, room).filter(b => b.has_prefix("g"))
  check(got == expected, "g1-g12 in order after backfill: \{got.join(",")}")
  ok("limited sync leaves a gap; \{pages} backfill pages close it in order")

  // Edits, reactions and redactions.
  let target = room_of(alice, room)
    .events()
    .filter(e => e.kind() is Message({ body: "m1", .. }))[0].event_id
  let doomed = room_of(alice, room)
    .events()
    .filter(e => e.kind() is Message({ body: "m2", .. }))[0].event_id
  ignore(
    alice.send(
      room,
      "m.room.message",
      @events.edit(target, @events.text("m1 (edited)")),
    ),
  )
  send_all(alice)
  ignore(bob.send(room, "m.reaction", @events.reaction(target, "👍")))
  send_all(bob)
  ignore(
    @api.parse_event_id(
      call(
        alice,
        @api.redact_request(room, doomed, "interop-redact", reason="test"),
      ),
    ),
  )
  let edited = (c : @client.Client) => {
    let r = c.store.room(room)
    guard r is Some(r) else { return false }
    r
    .events()
    .iter()
    .any(e => {
      e.kind() is Message(m) &&
      m.replacement().map(x => x.body) == Some("m1 (edited)")
    })
  }
  let redacted = (c : @client.Client) => {
    guard c.store.room(room) is Some(r) else { return false }
    r.events().iter().any(e => e.event_id == doomed && e.is_redacted())
  }
  ignore(sync_until(bob, c => edited(c) && redacted(c), "edit and redaction"))
  let reactions = room_of(bob, room)
    .events()
    .filter(e => e.kind() is Reaction(Annotation(t, key="👍")) && t == target)
  check(reactions.length() == 1, "one reaction on m1")
  check(
    room_of(bob, room).events().filter(e => e.event_id == doomed)[0].content.is_empty(),
    "redacted content stripped",
  )
  ok("edit, reaction and redaction seen by the other user")

  // Back-pagination reaches the start of the room.
  let tiny = login(hs, "bob", filter=@sync.Filter::new(timeline_limit=2))
  ignore(sync_until(tiny, c => c.store.room(room) is Some(_), "tiny initial"))
  let mut back_pages = 0
  while room_of(tiny, room).back_token() is Some(token) && back_pages < 50 {
    let page = @sync.parse_messages(
      call(tiny, @sync.messages_request(room, token, limit=10)),
    )
    ignore(tiny.store.paginate_back(room, page))
    back_pages += 1
  }
  let evs = room_of(tiny, room).events()
  check(room_of(tiny, room).back_token() is None, "reached the start")
  check(evs[0].event_type() == "m.room.create", "first event is m.room.create")
  check(bodies(tiny, room) == bodies(bob, room), "same history as bob")
  ok("paginate back to m.room.create in \{back_pages} pages; history matches")

  // Leaving moves the room to Leave.
  ignore(@api.parse_empty(call(bob, @api.leave_request(room))))
  ignore(
    sync_until(
      bob,
      c => c.store.room(room).map(r => r.membership()) == Some(Leave),
      "bob left",
    ),
  )
  ignore(
    sync_until(
      alice,
      c => {
        c.store.room(room).map(r => r.members_with(Leave).contains(me_bob)) ==
        Some(true)
      },
      "alice sees bob leave",
    ),
  )
  ok("leave: own membership and the other side's member list update")
}

///|
async fn main {
  let hs = @env.get_env_var("MATRIX_HOMESERVER").unwrap_or(
    "http://127.0.0.1:8008",
  )
  println("homeserver \{hs}")
  run(hs)
  println("\{passed.val} scenarios passed")
}
