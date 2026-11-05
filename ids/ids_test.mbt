///|
fn[T] id_err(f : () -> T raise @ids.IdError) -> @ids.IdError? {
  try f() catch {
    e => Some(e)
  } noraise {
    _ => None
  }
}

///|
fn[T] rejects(f : () -> T raise) -> Bool {
  try f() catch {
    _ => true
  } noraise {
    _ => false
  }
}

///|
test "server name: dns, ipv4, ipv6, ports" {
  let n = @ids.ServerName::parse("matrix.org")
  assert_eq(n.host, "matrix.org")
  assert_eq(n.port, None)
  let n = @ids.ServerName::parse("matrix.org:8888")
  assert_eq(n.port, Some(8888))
  assert_eq(n.to_string(), "matrix.org:8888")
  let n = @ids.ServerName::parse("1.2.3.4")
  assert_eq(n.host, "1.2.3.4")
  let n = @ids.ServerName::parse("[1234:5678::abcd]")
  assert_eq(n.host, "[1234:5678::abcd]")
  assert_eq(n.port, None)
  let n = @ids.ServerName::parse("[1234:5678::abcd]:5678")
  assert_eq(n.port, Some(5678))
  assert_eq(n.to_string(), "[1234:5678::abcd]:5678")
  let n = @ids.ServerName::parse("localhost")
  assert_eq(n.host, "localhost")
}

///|
test "server name: rejects malformed input" {
  for
    bad in [
      "", ":8448", "matrix.org:", "matrix.org:123456", "matrix.org:12a", "under_score.org",
      "[1234:5678::abcd", "[]", "[zz::1]", "[::1]8448", "exa mple.org",
    ] {
    assert_true(
      rejects(() => @ids.ServerName::parse(bad)),
      msg="should reject \{bad}",
    )
  }
}

///|
test "user id: parse and display" {
  let u = @ids.UserId::parse("@alice:example.org")
  assert_eq(u.localpart, "alice")
  assert_eq(u.server.host, "example.org")
  assert_eq(u.to_string(), "@alice:example.org")
  assert_true(u.is_compliant())
  let u = @ids.UserId::parse("@bob_1.x=y-z/w+v:[::1]:8448")
  assert_eq(u.localpart, "bob_1.x=y-z/w+v")
  assert_eq(u.server.port, Some(8448))
  assert_true(u.is_compliant())
}

///|
test "user id: historical localparts parse but are not compliant" {
  let u = @ids.UserId::parse("@Alice!:example.org")
  assert_eq(u.localpart, "Alice!")
  assert_false(u.is_compliant())
}

///|
test "user id: errors" {
  assert_eq(id_err(() => @ids.UserId::parse("")), Some(Empty))
  assert_eq(
    id_err(() => @ids.UserId::parse("alice:example.org")),
    Some(BadSigil(expected='@', input="alice:example.org")),
  )
  assert_eq(
    id_err(() => @ids.UserId::parse("@alice")),
    Some(MissingServerName("@alice")),
  )
  assert_eq(
    id_err(() => @ids.UserId::parse("@:example.org")),
    Some(InvalidLocalpart("@:example.org")),
  )
  assert_eq(
    id_err(() => @ids.UserId::parse("@al ice:example.org")),
    Some(InvalidLocalpart("@al ice:example.org")),
  )
  assert_true(
    id_err(() => @ids.UserId::parse("@alice:bad_host"))
    is Some(InvalidServerName(_)),
  )
}

///|
test "user id: 255 byte limit counts utf-8 bytes" {
  let server = ":example.org"
  let fits = "@" + "a".repeat(255 - 1 - server.length()) + server
  assert_eq(fits.length(), 255)
  assert_eq(@ids.UserId::parse(fits).to_string(), fits)
  let over = "@" + "a".repeat(255 - server.length()) + server
  assert_eq(id_err(() => @ids.UserId::parse(over)), Some(TooLong(256)))
  // Room aliases may contain non-ASCII; the limit is in bytes, not chars.
  let alias_str = "#" + "é".repeat(122) + server
  assert_eq(alias_str.length(), 135)
  assert_eq(id_err(() => @ids.RoomAlias::parse(alias_str)), Some(TooLong(257)))
}

///|
test "user id: new from parts" {
  let server = @ids.ServerName::parse("example.org")
  let u = @ids.UserId::new("carol", server)
  assert_eq(u.to_string(), "@carol:example.org")
  assert_true(rejects(() => @ids.UserId::new("ca:rol", server)))
}

///|
test "room alias_str" {
  let a = @ids.RoomAlias::parse("#room:example.org")
  assert_eq(a.localpart, "room")
  assert_eq(a.to_string(), "#room:example.org")
  let a = @ids.RoomAlias::parse("#café!:example.org")
  assert_eq(a.localpart, "café!")
  assert_true(rejects(() => @ids.RoomAlias::parse("#:example.org")))
  assert_true(rejects(() => @ids.RoomAlias::parse("!room:example.org")))
}

///|
test "room id: opaque, with and without server part" {
  let r = @ids.RoomId::parse("!636q39766251:example.com")
  assert_eq(r.as_str(), "!636q39766251:example.com")
  assert_eq(r.server_name().map(s => s.to_string()), Some("example.com"))
  // Room version 12 IDs carry no server name.
  let r = @ids.RoomId::parse("!31hneApxJ_1o-63DmFrpeqnkFfWppnzWso1JvH3ogLM")
  assert_eq(r.server_name(), None)
  assert_true(rejects(() => @ids.RoomId::parse("!")))
  assert_true(id_err(() => @ids.RoomId::parse("$abc")) is Some(BadSigil(..)))
}

///|
test "event id" {
  let e = @ids.EventId::parse("$acR1l0raoZnm60CBwAVgqbZqoO/mYU81xysh1u7XcJk")
  assert_eq(e.to_string(), "$acR1l0raoZnm60CBwAVgqbZqoO/mYU81xysh1u7XcJk")
  let e = @ids.EventId::parse("$143273582443PhrSn:example.org")
  assert_eq(e.as_str(), "$143273582443PhrSn:example.org")
  assert_true(rejects(() => @ids.EventId::parse("!abc")))
}

///|
test "json round trip" {
  let u : @ids.UserId = @json.from_json(Json::string("@alice:example.org"))
  assert_eq(u.to_json(), Json::string("@alice:example.org"))
  let r : @ids.RoomId = @json.from_json(Json::string("!abc:example.org"))
  assert_eq(r.to_json(), Json::string("!abc:example.org"))
  assert_true(rejects(() => (@json.from_json(Json::number(1.0)) : @ids.UserId)))
  assert_true(
    rejects(() => (@json.from_json(Json::string("x")) : @ids.EventId)),
  )
}
