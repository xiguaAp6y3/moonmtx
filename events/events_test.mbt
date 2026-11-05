///|
fn ev(text : String) -> @events.Event raise {
  @events.Event::parse(text)
}

///|
fn eid(s : String) -> @ids.EventId raise {
  @ids.EventId::parse(s)
}

///|
test "event: envelope fields and raw json are kept" {
  let e = ev(
    (
      #|{"content":{"body":"This is an example text message","format":"org.matrix.custom.html","formatted_body":"<b>This is an example text message</b>","msgtype":"m.text"},
      #| "event_id":"$143273582443PhrSn:example.org","origin_server_ts":1432735824653,
      #| "room_id":"!jEsUZKDJdhlrceRyVU:example.org","sender":"@example:example.org",
      #| "type":"m.room.message","unsigned":{"age":1234,"transaction_id":"m1.2","membership":"join"},
      #| "org.example.extra":42}
    ),
  )
  assert_eq(e.event_type(), "m.room.message")
  assert_eq(e.event_id.as_str(), "$143273582443PhrSn:example.org")
  assert_eq(e.sender, "@example:example.org")
  assert_eq(e.sender_id().map(u => u.localpart), Some("example"))
  assert_eq(e.origin_server_ts, 1432735824653L)
  assert_eq(
    e.room_id.map(r => r.as_str()),
    Some("!jEsUZKDJdhlrceRyVU:example.org"),
  )
  assert_false(e.is_state())
  assert_false(e.is_redacted())
  assert_eq(e.transaction_id(), Some("m1.2"))
  assert_eq(e.unsigned.bind(u => u.age), Some(1234L))
  // Unmodelled keys survive in raw, inside unsigned and at the top level.
  assert_eq(e.raw.get("org.example.extra"), Some(Json::number(42.0)))
  assert_eq(
    e.unsigned.map(u => u.raw.get("membership")),
    Some(Some(Json::string("join"))),
  )
  let back : @events.Event = @json.from_json(e.to_json())
  assert_true(back == e)
}

///|
test "event: required fields" {
  let missing_id = try
    ev(
      "{\"type\":\"m.room.message\",\"sender\":\"@a:b.c\",\"origin_server_ts\":1,\"content\":{}}",
    )
  catch {
    e => e.to_string()
  } noraise {
    _ => "parsed"
  }
  assert_true(missing_id.contains("event_id"), msg=missing_id)
  // Missing content is tolerated (redacted events may have none).
  let e = ev(
    "{\"type\":\"m.room.message\",\"event_id\":\"$x\",\"sender\":\"@a:b.c\",\"origin_server_ts\":1}",
  )
  assert_eq(e.content.length(), 0)
  assert_eq(e.kind(), Unknown)
}

///|
test "event: room id is filled in for sync events" {
  let e = ev(
    "{\"type\":\"m.room.message\",\"event_id\":\"$x\",\"sender\":\"@a:b.c\",\"origin_server_ts\":1,\"content\":{}}",
  )
  assert_eq(e.room_id, None)
  let r = @ids.RoomId::parse("!r:b.c")
  assert_eq(e.in_room(r).room_id, Some(r))
}

///|
test "message: typed content" {
  let e = ev(
    (
      #|{"type":"m.room.message","event_id":"$1","sender":"@a:b.c","origin_server_ts":1,
      #| "content":{"msgtype":"m.notice","body":"hi","format":"org.matrix.custom.html","formatted_body":"<i>hi</i>"}}
    ),
  )
  guard e.kind() is Message(m) else { fail("expected a message") }
  assert_eq(m.msgtype, Notice)
  assert_eq(m.body, "hi")
  assert_eq(m.formatted_body, Some("<i>hi</i>"))
  assert_eq(m.relation, None)
  let e = ev(
    (
      #|{"type":"m.room.message","event_id":"$1","sender":"@a:b.c","origin_server_ts":1,
      #| "content":{"msgtype":"org.example.custom","body":"x"}}
    ),
  )
  guard e.kind() is Message(m) else { fail("expected a message") }
  assert_eq(m.msgtype, Other("org.example.custom"))
  // A message without a body does not decode as typed content.
  let e = ev(
    (
      #|{"type":"m.room.message","event_id":"$1","sender":"@a:b.c","origin_server_ts":1,
      #| "content":{"msgtype":"m.text"}}
    ),
  )
  assert_eq(e.kind(), Unknown)
}

///|
test "relations: reply, edit, annotation, thread, unknown" {
  let rel = (j : Json) => {
    guard j is Object(m) else { panic() }
    @events.Relation::from_content(m)
  }
  assert_eq(
    rel({ "m.relates_to": { "m.in_reply_to": { "event_id": "$orig" } } }),
    Some(Reply(eid("$orig"))),
  )
  assert_eq(
    rel({ "m.relates_to": { "rel_type": "m.replace", "event_id": "$orig" } }),
    Some(Replace(eid("$orig"))),
  )
  assert_eq(
    rel({
      "m.relates_to": {
        "rel_type": "m.annotation",
        "event_id": "$orig",
        "key": "👍",
      },
    }),
    Some(Annotation(eid("$orig"), key="👍")),
  )
  assert_eq(
    rel({
      "m.relates_to": {
        "rel_type": "m.thread",
        "event_id": "$root",
        "is_falling_back": true,
        "m.in_reply_to": { "event_id": "$last" },
      },
    }),
    Some(Thread(root=eid("$root"), reply_to=None)),
  )
  assert_eq(
    rel({
      "m.relates_to": {
        "rel_type": "m.thread",
        "event_id": "$root",
        "m.in_reply_to": { "event_id": "$other" },
      },
    }),
    Some(Thread(root=eid("$root"), reply_to=Some(eid("$other")))),
  )
  assert_true(
    rel({ "m.relates_to": { "rel_type": "org.example.rel", "event_id": "$x" } })
    is Some(Unknown(_)),
  )
  assert_eq(rel({ "body": "no relation" }), None)
}

///|
test "builders: text, reply, thread" {
  assert_eq(@events.text("hello").to_json(), {
    "msgtype": "m.text",
    "body": "hello",
  })
  assert_eq(@events.notice("hi", html="<b>hi</b>").to_json(), {
    "msgtype": "m.notice",
    "body": "hi",
    "format": "org.matrix.custom.html",
    "formatted_body": "<b>hi</b>",
  })
  assert_eq(@events.text("yes").reply_to(eid("$q")).to_json(), {
    "msgtype": "m.text",
    "body": "yes",
    "m.relates_to": { "m.in_reply_to": { "event_id": "$q" } },
  })
  assert_eq(@events.emote("waves").in_thread(eid("$root")).to_json(), {
    "msgtype": "m.emote",
    "body": "waves",
    "m.relates_to": { "rel_type": "m.thread", "event_id": "$root" },
  })
}

///|
test "builders: edit round trips through the parser" {
  let content = @events.edit(
    eid("$orig"),
    @events.text("fixed", html="<b>fixed</b>"),
  )
  assert_eq(content, {
    "msgtype": "m.text",
    "body": "* fixed",
    "format": "org.matrix.custom.html",
    "formatted_body": "* <b>fixed</b>",
    "m.new_content": {
      "msgtype": "m.text",
      "body": "fixed",
      "format": "org.matrix.custom.html",
      "formatted_body": "<b>fixed</b>",
    },
    "m.relates_to": { "rel_type": "m.replace", "event_id": "$orig" },
  })
  guard content is Object(c) else { fail("object") }
  let m = @events.MessageContent::decode(c, @jsonx.root())
  assert_eq(m.relation, Some(Replace(eid("$orig"))))
  assert_eq(m.replacement().map(r => r.body), Some("fixed"))
  // A non-edit has no replacement even if m.new_content is present.
  assert_eq(@events.text("x").replacement(), None)
}

///|
test "builders: reaction" {
  assert_eq(@events.reaction(eid("$t"), "🎉"), {
    "m.relates_to": {
      "rel_type": "m.annotation",
      "event_id": "$t",
      "key": "🎉",
    },
  })
}

///|
test "redaction: v11 content and legacy top-level redacts" {
  let v11 = ev(
    "{\"type\":\"m.room.redaction\",\"event_id\":\"$r\",\"sender\":\"@a:b.c\",\"origin_server_ts\":1,\"content\":{\"redacts\":\"$target\",\"reason\":\"spam\"}}",
  )
  assert_eq(v11.redacts(), Some(eid("$target")))
  assert_eq(v11.kind(), Redaction)
  let legacy = ev(
    "{\"type\":\"m.room.redaction\",\"event_id\":\"$r\",\"sender\":\"@a:b.c\",\"origin_server_ts\":1,\"redacts\":\"$old\",\"content\":{}}",
  )
  assert_eq(legacy.redacts(), Some(eid("$old")))
  let redacted = ev(
    "{\"type\":\"m.room.message\",\"event_id\":\"$m\",\"sender\":\"@a:b.c\",\"origin_server_ts\":1,\"content\":{},\"unsigned\":{\"redacted_because\":{\"type\":\"m.room.redaction\"}}}",
  )
  assert_true(redacted.is_redacted())
  assert_eq(redacted.redacts(), None)
}

///|
test "state: member, name, topic" {
  let e = ev(
    (
      #|{"content":{"avatar_url":"mxc://example.org/SEsfnsuifSDFSSEF","displayname":"Alice Margatroid","membership":"join","reason":"Looking for support"},
      #| "event_id":"$143273582443PhrSn:example.org","origin_server_ts":1432735824653,
      #| "sender":"@example:example.org","state_key":"@alice:example.org","type":"m.room.member"}
    ),
  )
  assert_true(e.is_state())
  guard e.kind() is Member(m) else { fail("expected member") }
  assert_eq(m.membership, Join)
  assert_eq(m.displayname, Some("Alice Margatroid"))
  assert_eq(m.reason, Some("Looking for support"))
  assert_false(m.is_direct)
  assert_eq(@events.Membership::parse("knock"), Knock)
  assert_eq(@events.Membership::parse("x").as_str(), "x")
  let e = ev(
    "{\"type\":\"m.room.name\",\"state_key\":\"\",\"event_id\":\"$n\",\"sender\":\"@a:b.c\",\"origin_server_ts\":1,\"content\":{\"name\":\"The room name\"}}",
  )
  assert_eq(e.kind(), Name("The room name"))
  let e = ev(
    "{\"type\":\"m.room.topic\",\"state_key\":\"\",\"event_id\":\"$t\",\"sender\":\"@a:b.c\",\"origin_server_ts\":1,\"content\":{\"topic\":\"A room topic\"}}",
  )
  assert_eq(e.kind(), Topic("A room topic"))
  // Without a state_key these are not state events and stay Unknown.
  let e = ev(
    "{\"type\":\"m.room.name\",\"event_id\":\"$n\",\"sender\":\"@a:b.c\",\"origin_server_ts\":1,\"content\":{\"name\":\"x\"}}",
  )
  assert_eq(e.kind(), Unknown)
}

///|
test "power levels: defaults, string levels, permissions" {
  let e = ev(
    (
      #|{"type":"m.room.power_levels","state_key":"","event_id":"$p","sender":"@a:b.c","origin_server_ts":1,
      #| "content":{"ban":50,"events":{"m.room.name":100,"m.room.power_levels":"100"},
      #| "users":{"@example:localhost":100},"users_default":0}}
    ),
  )
  guard e.kind() is PowerLevels(pl) else { fail("expected power levels") }
  assert_eq(pl.kick, 50)
  assert_eq(pl.invite, 0)
  assert_eq(pl.state_default, 50)
  assert_eq(pl.events.get("m.room.power_levels"), Some(100L))
  assert_eq(pl.notifications.get("room"), Some(50L))
  assert_eq(pl.user_level("@example:localhost"), 100)
  assert_eq(pl.user_level("@nobody:localhost"), 0)
  assert_true(
    pl.can_send("@nobody:localhost", "m.room.message", is_state=false),
  )
  assert_false(pl.can_send("@nobody:localhost", "m.room.topic", is_state=true))
  assert_true(pl.can_send("@example:localhost", "m.room.name", is_state=true))
  let none = @events.PowerLevels::absent(Some("@creator:localhost"))
  assert_eq(none.user_level("@creator:localhost"), 100)
  assert_true(none.can_send("@anyone:localhost", "m.room.topic", is_state=true))
  let bad = ev(
    "{\"type\":\"m.room.power_levels\",\"state_key\":\"\",\"event_id\":\"$p\",\"sender\":\"@a:b.c\",\"origin_server_ts\":1,\"content\":{\"ban\":\"lots\"}}",
  )
  assert_eq(bad.kind(), Unknown)
}

///|
test "stripped state" {
  let s : @events.StrippedState = @json.from_json(
    @json.parse(
      "{\"content\":{\"name\":\"Example Room\"},\"sender\":\"@bob:example.org\",\"state_key\":\"\",\"type\":\"m.room.name\"}",
    ),
  )
  assert_eq(s.kind_str, "m.room.name")
  assert_eq(s.content.get("name"), Some(Json::string("Example Room")))
}
