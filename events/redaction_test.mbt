///|
fn redaction_of(target : String) -> @events.Event raise {
  @events.Event::parse(
    "{\"type\":\"m.room.redaction\",\"event_id\":\"$red\",\"sender\":\"@mod:b.c\",\"origin_server_ts\":9,\"content\":{\"redacts\":\"\{target}\",\"reason\":\"spam\"}}",
  )
}

///|
test "redact: message loses content and unsigned, keeps envelope" {
  let msg = @events.Event::parse(
    "{\"type\":\"m.room.message\",\"event_id\":\"$m\",\"sender\":\"@a:b.c\",\"origin_server_ts\":1,\"room_id\":\"!r:b.c\",\"content\":{\"msgtype\":\"m.text\",\"body\":\"secret\"},\"unsigned\":{\"age\":5,\"transaction_id\":\"t1\"},\"org.example\":1}",
  )
  let r = msg.redact(redaction_of("$m"))
  assert_true(r.is_redacted())
  assert_eq(r.content.length(), 0)
  assert_eq(r.transaction_id(), None)
  assert_eq(r.event_id.as_str(), "$m")
  assert_eq(r.raw.get("org.example"), None)
  assert_eq(r.raw.get("room_id"), Some(Json::string("!r:b.c")))
  assert_eq(r.kind(), Unknown)
  // The redacted form survives a JSON round trip.
  let back : @events.Event = @json.from_json(r.to_json())
  assert_true(back == r)
}

///|
test "redact: member keeps membership and signed third-party invite" {
  let m = @events.Event::parse(
    "{\"type\":\"m.room.member\",\"state_key\":\"@a:b.c\",\"event_id\":\"$m\",\"sender\":\"@a:b.c\",\"origin_server_ts\":1,\"content\":{\"membership\":\"join\",\"displayname\":\"Alice\",\"third_party_invite\":{\"display_name\":\"x\",\"signed\":{\"token\":\"t\"}}}}",
  )
  let r = m.redact(redaction_of("$m"))
  assert_eq(Json::object(r.content), {
    "membership": "join",
    "third_party_invite": { "signed": { "token": "t" } },
  })
  guard r.kind() is Member(c) else { fail("member") }
  assert_eq(c.displayname, None)
}

///|
test "redact: power levels and create" {
  let pl = @events.Event::parse(
    "{\"type\":\"m.room.power_levels\",\"state_key\":\"\",\"event_id\":\"$p\",\"sender\":\"@a:b.c\",\"origin_server_ts\":1,\"content\":{\"ban\":50,\"notifications\":{\"room\":20},\"users\":{\"@a:b.c\":100}}}",
  )
  assert_eq(Json::object(pl.redact(redaction_of("$p")).content), {
    "ban": 50,
    "users": { "@a:b.c": 100 },
  })
  let create = @events.Event::parse(
    "{\"type\":\"m.room.create\",\"state_key\":\"\",\"event_id\":\"$c\",\"sender\":\"@a:b.c\",\"origin_server_ts\":1,\"content\":{\"room_version\":\"11\",\"m.federate\":false}}",
  )
  assert_eq(create.redact(redaction_of("$c")).content.length(), 2)
}

///|
test "stripped state json round trip" {
  let s : @events.StrippedState = @json.from_json({
    "type": "m.room.name",
    "state_key": "",
    "sender": "@bob:example.org",
    "content": { "name": "Example Room" },
  })
  let back : @events.StrippedState = @json.from_json(s.to_json())
  assert_eq(back, s)
}
