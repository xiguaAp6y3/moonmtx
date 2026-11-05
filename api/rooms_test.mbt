///|
fn room() -> @ids.RoomId raise {
  @ids.RoomId::parse("!636q39766251:example.com")
}

///|
test "send, state and redact paths" {
  let r = @api.send_request(room(), "m.room.message", "m1.35", {
    "msgtype": "m.text",
    "body": "hi",
  })
  assert_eq(r.verb, Put)
  assert_eq(
    r.path,
    "/_matrix/client/v3/rooms/%21636q39766251%3Aexample.com/send/m.room.message/m1.35",
  )
  assert_eq(r.body, Some({ "msgtype": "m.text", "body": "hi" }))
  let r = @api.state_request(room(), "m.room.name", { "name": "x" })
  assert_eq(
    r.path,
    "/_matrix/client/v3/rooms/%21636q39766251%3Aexample.com/state/m.room.name/",
  )
  let r = @api.state_request(
    room(),
    "m.room.member",
    { "membership": "join" },
    state_key="@a:example.com",
  )
  assert_true(r.path.has_suffix("/state/m.room.member/%40a%3Aexample.com"))
  let e = @ids.EventId::parse("$143273582443PhrSn:example.org")
  let r = @api.redact_request(room(), e, "t1", reason="spam")
  assert_true(
    r.path.has_suffix("/redact/%24143273582443PhrSn%3Aexample.org/t1"),
  )
  assert_eq(r.body, Some({ "reason": "spam" }))
  assert_eq(
    @api.parse_event_id(
      @api.Response::new(200, "{\"event_id\":\"$YUwRidLecu:example.com\"}"),
    ).as_str(),
    "$YUwRidLecu:example.com",
  )
}

///|
test "create room" {
  let r = @api.create_room_request(
    name="The Grand Duke Pub",
    topic="All about happy hour",
    preset=PublicChat,
    public=true,
    room_alias_name="thepub",
    invite=[@ids.UserId::parse("@bob:example.com")],
  )
  assert_eq(r.path, "/_matrix/client/v3/createRoom")
  assert_eq(
    r.body,
    Some({
      "name": "The Grand Duke Pub",
      "topic": "All about happy hour",
      "preset": "public_chat",
      "visibility": "public",
      "invite": ["@bob:example.com"],
      "room_alias_name": "thepub",
    }),
  )
  assert_eq(
    @api.create_room_request(is_direct=true).body,
    Some({ "visibility": "private", "is_direct": true }),
  )
  assert_eq(
    @api.parse_room_id(
      @api.Response::new(200, "{\"room_id\":\"!sefiuhWgwghwWgh:example.com\"}"),
    ).as_str(),
    "!sefiuhWgwghwWgh:example.com",
  )
}

///|
test "join, leave, invite" {
  let room_alias = @ids.RoomAlias::parse("#monkeys:matrix.org")
  let r = @api.join_request(Alias(room_alias), via=[
    @ids.ServerName::parse("matrix.org"),
    @ids.ServerName::parse("elsewhere.ca"),
  ])
  assert_eq(
    r.url("https://hs"),
    "https://hs/_matrix/client/v3/join/%23monkeys%3Amatrix.org?via=matrix.org&via=elsewhere.ca",
  )
  assert_eq(r.body, Some({}))
  let r = @api.join_request(Id(room()), reason="hello")
  assert_eq(r.body, Some({ "reason": "hello" }))
  let r = @api.leave_request(room())
  assert_true(r.path.has_suffix("/leave"))
  let r = @api.invite_request(
    room(),
    @ids.UserId::parse("@cheeky_monkey:matrix.org"),
  )
  assert_eq(r.body, Some({ "user_id": "@cheeky_monkey:matrix.org" }))
  assert_true(@api.forget_request(room()).path.has_suffix("/forget"))
}

///|
test "typing and receipts" {
  let me = @ids.UserId::parse("@me:example.com")
  let r = @api.typing_request(room(), me, true)
  assert_eq(r.body, Some({ "typing": true, "timeout": 30000 }))
  assert_true(r.path.has_suffix("/typing/%40me%3Aexample.com"))
  assert_eq(
    @api.typing_request(room(), me, false).body,
    Some({ "typing": false }),
  )
  let e = @ids.EventId::parse("$1435641916114394fHBLK:matrix.org")
  let r = @api.receipt_request(room(), e)
  assert_true(
    r.path.has_suffix("/receipt/m.read/%241435641916114394fHBLK%3Amatrix.org"),
  )
  assert_eq(r.body, Some({}))
}
