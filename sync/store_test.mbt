// Store behaviour tests. Responses are built as JSON and decoded with the
// real parser, so these also exercise `SyncResponse::decode`.

///|
let me : String = "@me:example.org"

///|
fn msg(
  id : String,
  sender~ : String = "@alice:example.org",
  body~ : String = "hi",
) -> Json {
  {
    "type": "m.room.message",
    "event_id": id,
    "sender": sender,
    "origin_server_ts": 1,
    "content": { "msgtype": "m.text", "body": body },
  }
}

///|
fn st(id : String, kind : String, key : String, content : Json) -> Json {
  {
    "type": kind,
    "event_id": id,
    "sender": "@alice:example.org",
    "origin_server_ts": 1,
    "state_key": key,
    "content": content,
  }
}

///|
fn mem(
  id : String,
  user : String,
  membership~ : String = "join",
  name? : String,
) -> Json {
  let c : Map[String, Json] = { "membership": Json(membership) }
  if name is Some(n) {
    c["displayname"] = Json(n)
  }
  st(id, "m.room.member", user, Json::object(c))
}

///|
fn room_body(
  events : Array[Json],
  state~ : Array[Json] = [],
  limited~ : Bool = false,
  prev? : String,
  summary? : Json,
  ephemeral~ : Array[Json] = [],
) -> Json {
  let tl : Map[String, Json] = {
    "events": Json::array(events),
    "limited": Json(limited),
  }
  if prev is Some(p) {
    tl["prev_batch"] = Json(p)
  }
  let m : Map[String, Json] = {
    "state": { "events": Json::array(state) },
    "timeline": Json::object(tl),
    "ephemeral": { "events": Json::array(ephemeral) },
  }
  if summary is Some(s) {
    m["summary"] = s
  }
  Json::object(m)
}

///|
fn sync(
  next : String,
  join~ : Map[String, Json] = Map([]),
  leave~ : Map[String, Json] = Map([]),
  invite~ : Map[String, Json] = Map([]),
) -> @sync.SyncResponse raise {
  let j : Json = {
    "next_batch": Json(next),
    "rooms": {
      "join": Json::object(join),
      "leave": Json::object(leave),
      "invite": Json::object(invite),
    },
  }
  guard j is Object(m) else { panic() }
  @sync.SyncResponse::decode(m)
}

///|
fn page(
  start : String,
  end? : String,
  chunk : Array[Json],
  state~ : Array[Json] = [],
) -> @sync.Messages raise {
  let m : Map[String, Json] = {
    "start": Json(start),
    "chunk": Json::array(chunk),
    "state": Json::array(state),
  }
  if end is Some(e) {
    m["end"] = Json(e)
  }
  @sync.parse_messages(@api.Response::new(200, Json::object(m).stringify()))
}

///|
let room_a : String = "!a:example.org"

///|
fn rid(s : String) -> @ids.RoomId raise {
  @ids.RoomId::parse(s)
}

///|
fn ids_of(room : @sync.Room) -> Array[String] {
  room
  .timeline()
  .map(item => {
    match item {
      Event(e) => e.event_id.as_str()
      Gap(t) => "gap:" + t
    }
  })
}

///|
fn first_sync() -> @sync.SyncResponse raise {
  sync(
    "s1",
    join=Map([
      (
        room_a,
        room_body(
          [mem("$m_bob", "@bob:example.org"), msg("$1"), msg("$2")],
          state=[
            st("$create", "m.room.create", "", { "room_version": "11" }),
            mem("$m_alice", "@alice:example.org", name="Alice"),
            mem("$m_me", me),
          ],
          prev="p0",
          summary={ "m.joined_member_count": 3, "m.invited_member_count": 0 },
          ephemeral=[
            {
              "type": "m.typing",
              "content": { "user_ids": ["@bob:example.org"] },
            },
          ],
        ),
      ),
    ]),
  )
}

///|
test "apply: initial sync builds state and timeline" {
  let store = @sync.Store::new()
  assert_eq(store.since(), None)
  let s = store.apply(first_sync())
  assert_eq(store.since(), Some("s1"))
  assert_eq(s.rooms.length(), 1)
  assert_eq(s.rooms[0].events.map(e => e.event_id.as_str()), [
    "$m_bob", "$1", "$2",
  ])
  assert_eq(s.rooms[0].gap, None)
  let room = store.room(rid(room_a)).unwrap()
  assert_eq(room.membership(), Join)
  assert_eq(ids_of(room), ["$m_bob", "$1", "$2"])
  assert_eq(room.back_token(), Some("p0"))
  // Timeline state events update state, after the state section.
  let joined = room.members_with(Join)
  joined.sort_by((a, b) => a.lexical_compare(b))
  assert_eq(joined, ["@alice:example.org", "@bob:example.org", me])
  assert_eq(room.member_name("@alice:example.org"), "Alice")
  assert_eq(room.member_name("@bob:example.org"), "@bob:example.org")
  assert_eq(room.typing(), ["@bob:example.org"])
  assert_eq(room.power_levels().user_level("@alice:example.org"), 100)
}

///|
test "apply: incremental sync appends and reports only new events" {
  let store = @sync.Store::new()
  ignore(store.apply(first_sync()))
  let s = store.apply(
    sync(
      "s2",
      join=Map([(room_a, room_body([msg("$2"), msg("$3")], prev="p1"))]),
    ),
  )
  // $2 was already stored: it is neither reported nor stored twice.
  assert_eq(s.rooms[0].events.map(e => e.event_id.as_str()), ["$3"])
  assert_eq(ids_of(store.room(rid(room_a)).unwrap()), [
    "$m_bob", "$1", "$2", "$3",
  ])
  assert_eq(store.since(), Some("s2"))
}

///|
test "apply: the same response twice is a no-op" {
  let store = @sync.Store::new()
  ignore(store.apply(first_sync()))
  let again = store.apply(first_sync())
  assert_eq(again.rooms, [])
  assert_eq(ids_of(store.room(rid(room_a)).unwrap()), ["$m_bob", "$1", "$2"])
}

///|
test "checkpoint: resume after a crash neither drops nor repeats events" {
  let store = @sync.Store::new()
  ignore(store.apply(first_sync()))
  // Persist after s1.
  let saved = store.to_json().stringify()
  // s2 is applied in memory, then the process dies before persisting.
  let s2 = sync(
    "s2",
    join=Map([(room_a, room_body([msg("$3"), msg("$4")], prev="p1"))]),
  )
  ignore(store.apply(s2))
  // Restart from the snapshot: the token is still s1, so the client syncs
  // from s1 again and the server sends $3 and $4 again (batched
  // differently, with a later event).
  let restored = @sync.Store::from_json(@json.parse(saved))
  assert_eq(restored.since(), Some("s1"))
  let s2b = restored.apply(
    sync(
      "s2b",
      join=Map([
        (room_a, room_body([msg("$3"), msg("$4"), msg("$5")], prev="p1")),
      ]),
    ),
  )
  assert_eq(s2b.rooms[0].events.map(e => e.event_id.as_str()), [
    "$3", "$4", "$5",
  ])
  // A further replay of overlapping events is dropped.
  let s3 = restored.apply(
    sync(
      "s3",
      join=Map([
        (room_a, room_body([msg("$4"), msg("$5"), msg("$6")], prev="p2")),
      ]),
    ),
  )
  assert_eq(s3.rooms[0].events.map(e => e.event_id.as_str()), ["$6"])
  assert_eq(ids_of(restored.room(rid(room_a)).unwrap()), [
    "$m_bob", "$1", "$2", "$3", "$4", "$5", "$6",
  ])
}

///|
test "checkpoint: snapshot round trip keeps everything" {
  let store = @sync.Store::new(timeline_cap=50)
  ignore(store.apply(first_sync()))
  ignore(
    store.apply(
      sync(
        "s2",
        join=Map([(room_a, room_body([msg("$9")], limited=true, prev="gap1"))]),
      ),
    ),
  )
  let json = store.to_json()
  let back = @sync.Store::from_json(@json.parse(json.stringify()))
  assert_eq(back.to_json(), json)
  let room = back.room(rid(room_a)).unwrap()
  assert_eq(room.gaps(), ["gap1"])
  assert_eq(room.typing(), ["@bob:example.org"])
  assert_eq(room.member_name("@alice:example.org"), "Alice")
  // Restored de-duplication still works.
  let s = back.apply(
    sync("s3", join=Map([(room_a, room_body([msg("$9"), msg("$10")]))])),
  )
  assert_eq(s.rooms[0].events.map(e => e.event_id.as_str()), ["$10"])
}

///|
test "checkpoint: unknown version is rejected" {
  let r : @sync.StoreError? = try
    @sync.Store::from_json({ "version": 99 })
  catch {
    e => Some(e)
  } noraise {
    _ => None
  }
  assert_true(r is Some(BadSnapshot(_)))
}

///|
test "gap: limited sync opens a gap that backfill closes" {
  let store = @sync.Store::new()
  ignore(store.apply(first_sync()))
  let s = store.apply(
    sync(
      "s2",
      join=Map([
        (room_a, room_body([msg("$20"), msg("$21")], limited=true, prev="g1")),
      ]),
    ),
  )
  assert_eq(s.rooms[0].gap, Some("g1"))
  let room = store.room(rid(room_a)).unwrap()
  assert_eq(ids_of(room), ["$m_bob", "$1", "$2", "gap:g1", "$20", "$21"])
  // First page: newest first, does not reach known events yet.
  let req = @sync.messages_request(rid(room_a), "g1", limit=2)
  assert_eq(
    req.url("https://hs"),
    "https://hs/_matrix/client/v3/rooms/%21a%3Aexample.org/messages?from=g1&dir=b&limit=2",
  )
  let got = store.fill_gap(
    rid(room_a),
    page("g1", end="g2", [msg("$19"), msg("$18")]),
  )
  assert_eq(got.map(e => e.event_id.as_str()), ["$18", "$19"])
  assert_eq(room.gaps(), ["g2"])
  assert_eq(ids_of(room), [
    "$m_bob", "$1", "$2", "gap:g2", "$18", "$19", "$20", "$21",
  ])
  // Second page reaches $2, which was stored before the gap: closed.
  let got = store.fill_gap(
    rid(room_a),
    page("g2", end="g3", [msg("$17"), msg("$2"), msg("$1")]),
  )
  assert_eq(got.map(e => e.event_id.as_str()), ["$17"])
  assert_eq(room.gaps(), [])
  assert_eq(ids_of(room), [
    "$m_bob", "$1", "$2", "$17", "$18", "$19", "$20", "$21",
  ])
  // The old token no longer names a gap.
  let stale = page("g1", [])
  let room_id = rid(room_a)
  let r : @sync.StoreError? = try store.fill_gap(room_id, stale) catch {
    e => Some(e)
  } noraise {
    _ => None
  }
  assert_eq(r, Some(StaleToken("g1")))
}

///|
test "gap: a repeated limited response does not open a gap" {
  let store = @sync.Store::new()
  ignore(store.apply(first_sync()))
  let s = store.apply(
    sync(
      "s2",
      join=Map([
        (room_a, room_body([msg("$2"), msg("$3")], limited=true, prev="g1")),
      ]),
    ),
  )
  assert_eq(s.rooms[0].gap, None)
  assert_eq(ids_of(store.room(rid(room_a)).unwrap()), [
    "$m_bob", "$1", "$2", "$3",
  ])
}

///|
test "paginate back to the start of the room" {
  let store = @sync.Store::new()
  ignore(store.apply(first_sync()))
  let room = store.room(rid(room_a)).unwrap()
  let got = store.paginate_back(
    rid(room_a),
    page("p0", end="p-1", [msg("$0b"), msg("$0a")], state=[
      mem("$m_carol", "@carol:example.org", name="Carol"),
    ]),
  )
  assert_eq(got.map(e => e.event_id.as_str()), ["$0a", "$0b"])
  assert_eq(room.back_token(), Some("p-1"))
  // Lazy-loaded members from the page fill in missing state.
  assert_eq(room.member_name("@carol:example.org"), "Carol")
  ignore(store.paginate_back(rid(room_a), page("p-1", [])))
  assert_eq(room.back_token(), None)
  assert_eq(ids_of(room), ["$0a", "$0b", "$m_bob", "$1", "$2"])
}

///|
test "page state never replaces newer state" {
  let store = @sync.Store::new()
  ignore(store.apply(first_sync()))
  let room = store.room(rid(room_a)).unwrap()
  ignore(
    store.paginate_back(
      rid(room_a),
      page("p0", end="p-1", [], state=[
        mem("$old_alice", "@alice:example.org", name="Old Alice"),
      ]),
    ),
  )
  assert_eq(room.member_name("@alice:example.org"), "Alice")
}

///|
test "trim drops whole chunks and keeps a valid back token" {
  let store = @sync.Store::new(timeline_cap=3)
  ignore(
    store.apply(
      sync(
        "s1",
        join=Map([(room_a, room_body([msg("$1"), msg("$2")], prev="p0"))]),
      ),
    ),
  )
  ignore(
    store.apply(
      sync(
        "s2",
        join=Map([(room_a, room_body([msg("$3"), msg("$4")], prev="p1"))]),
      ),
    ),
  )
  ignore(
    store.apply(
      sync(
        "s3",
        join=Map([(room_a, room_body([msg("$5")], limited=true, prev="p2"))]),
      ),
    ),
  )
  let room = store.room(rid(room_a)).unwrap()
  // [$1 $2][$3 $4][gap $5]: dropping the first chunk leaves 3 events.
  assert_eq(ids_of(room), ["$3", "$4", "gap:p2", "$5"])
  assert_eq(room.back_token(), Some("p1"))
}

///|
test "redaction in the timeline redacts the stored event" {
  let store = @sync.Store::new()
  ignore(store.apply(first_sync()))
  let red : Json = {
    "type": "m.room.redaction",
    "event_id": "$red",
    "sender": "@alice:example.org",
    "origin_server_ts": 2,
    "content": { "redacts": "$1" },
  }
  ignore(store.apply(sync("s2", join=Map([(room_a, room_body([red]))]))))
  let room = store.room(rid(room_a)).unwrap()
  let e1 = room.events().filter(e => e.event_id.as_str() == "$1")[0]
  assert_true(e1.is_redacted())
  assert_eq(e1.content.length(), 0)
}

///|
test "membership transitions: invite, join, leave" {
  let store = @sync.Store::new()
  let invite_state : Json = {
    "invite_state": {
      "events": [
        {
          "type": "m.room.name",
          "state_key": "",
          "sender": "@alice:example.org",
          "content": { "name": "Party" },
        },
      ],
    },
  }
  let s = store.apply(
    sync("s1", invite=Map([("!b:example.org", invite_state)])),
  )
  assert_eq(s.invited.map(r => r.as_str()), ["!b:example.org"])
  assert_eq(store.invites().length(), 1)
  ignore(
    store.apply(
      sync("s2", join=Map([("!b:example.org", room_body([mem("$j", me)]))])),
    ),
  )
  assert_eq(store.invites().length(), 0)
  assert_eq(store.room(rid("!b:example.org")).unwrap().membership(), Join)
  let s = store.apply(
    sync(
      "s3",
      leave=Map([
        ("!b:example.org", room_body([mem("$l", me, membership="leave")])),
      ]),
    ),
  )
  assert_eq(s.rooms[0].membership, Leave)
  let room = store.room(rid("!b:example.org")).unwrap()
  assert_eq(room.membership(), Leave)
  assert_eq(room.members_with(Leave), [me])
}

///|
test "room display name" {
  let store = @sync.Store::new()
  ignore(store.apply(first_sync()))
  let room = store.room(rid(room_a)).unwrap()
  // No name or alias: heroes from members, excluding me, sorted.
  assert_eq(room.display_name(me), "Alice and @bob:example.org")
  ignore(
    store.apply(
      sync(
        "s2",
        join=Map([
          (
            room_a,
            room_body([
              st("$alias", "m.room.canonical_alias", "", {
                "alias": "#a:example.org",
              }),
            ]),
          ),
        ]),
      ),
    ),
  )
  assert_eq(room.display_name(me), "#a:example.org")
  ignore(
    store.apply(
      sync(
        "s3",
        join=Map([
          (
            room_a,
            room_body([st("$name", "m.room.name", "", { "name": "Our Room" })]),
          ),
        ]),
      ),
    ),
  )
  assert_eq(room.display_name(me), "Our Room")
  // Heroes from the summary, with a count of the others.
  let s = @sync.Store::new()
  ignore(
    s.apply(
      sync(
        "s1",
        join=Map([
          (
            "!c:example.org",
            room_body([], summary={
              "m.heroes": ["@x:example.org"],
              "m.joined_member_count": 5,
            }),
          ),
        ]),
      ),
    ),
  )
  assert_eq(
    s.room(rid("!c:example.org")).unwrap().display_name(me),
    "@x:example.org and 3 others",
  )
  // Only me left.
  let s = @sync.Store::new()
  ignore(
    s.apply(
      sync(
        "s1",
        join=Map([
          (
            "!d:example.org",
            room_body([], summary={
              "m.heroes": ["@gone:example.org"],
              "m.joined_member_count": 1,
            }),
          ),
        ]),
      ),
    ),
  )
  assert_eq(
    s.room(rid("!d:example.org")).unwrap().display_name(me),
    "Empty Room (was @gone:example.org)",
  )
}

///|
test "member names are disambiguated" {
  let store = @sync.Store::new()
  ignore(
    store.apply(
      sync(
        "s1",
        join=Map([
          (
            room_a,
            room_body([], state=[
              mem("$a", "@alice:example.org", name="Al"),
              mem("$b", "@alice2:example.org", name="Al"),
            ]),
          ),
        ]),
      ),
    ),
  )
  let room = store.room(rid(room_a)).unwrap()
  assert_eq(room.member_name("@alice:example.org"), "Al (@alice:example.org)")
}
