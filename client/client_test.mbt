// Drives a client against a scripted fake homeserver: no network.

///|
fn session() -> @api.Session raise {
  @api.parse_login(
    @api.Response::new(
      200, "{\"user_id\":\"@me:example.org\",\"access_token\":\"tok\",\"device_id\":\"DEV\"}",
    ),
  )
}

///|
let room : String = "!r:example.org"

///|
fn sync_body(next : String, events : Array[Json]) -> String {
  let j : Json = {
    "next_batch": Json(next),
    "rooms": {
      "join": Json::object(
        Map([(room, { "timeline": { "events": Json::array(events) } })]),
      ),
    },
  }
  j.stringify()
}

///|
fn message(id : String, txn? : String) -> Json {
  let m : Map[String, Json] = {
    "type": "m.room.message",
    "event_id": Json(id),
    "sender": "@me:example.org",
    "origin_server_ts": 1,
    "content": { "msgtype": "m.text", "body": "hello" },
  }
  if txn is Some(t) {
    m["unsigned"] = { "transaction_id": Json(t) }
  }
  Json::object(m)
}

///|
test "prepare adds the base url and token" {
  let c = @client.Client::new("https://hs.example.org/", session())
  let p = c.prepare(@api.whoami_request())
  assert_eq(p.verb, "GET")
  assert_eq(p.url, "https://hs.example.org/_matrix/client/v3/account/whoami")
  assert_eq(p.headers, [("Authorization", "Bearer tok")])
  assert_eq(p.body, None)
  let p = c.prepare(@api.login_flows_request())
  assert_eq(p.headers, [])
}

///|
test "sync loop: initial then long-poll from the stored token" {
  let c = @client.Client::new("https://hs", session())
  let first = c.prepare(c.sync_request())
  assert_true(first.url.contains("timeout=0"), msg=first.url)
  assert_false(first.url.contains("since="))
  let s = c.on_sync_response(
    @api.Response::new(200, sync_body("s1", [message("$1")])),
  )
  assert_eq(s.rooms[0].events.length(), 1)
  let next = c.prepare(c.sync_request())
  assert_true(next.url.contains("since=s1"), msg=next.url)
  assert_true(next.url.contains("timeout=30000"), msg=next.url)
}

///|
test "send, then the echo arrives through sync" {
  let c = @client.Client::new("https://hs", session())
  ignore(c.on_sync_response(@api.Response::new(200, sync_body("s1", []))))
  let r = @ids.RoomId::parse(room)
  let txn = c.send_text(r, "hello")
  guard c.next_send(0) is Some((t, p)) else { fail("expected a send") }
  assert_eq(t, txn)
  assert_eq(p.verb, "PUT")
  assert_true(p.url.has_suffix("/send/m.room.message/" + txn), msg=p.url)
  assert_eq(p.body, Some("{\"msgtype\":\"m.text\",\"body\":\"hello\"}"))
  assert_eq(
    c.on_send_response(
      txn,
      @api.Response::new(200, "{\"event_id\":\"$mine\"}"),
      0,
    ),
    Sent(@ids.EventId::parse("$mine")),
  )
  assert_eq(c.outbox.pending().length(), 1)
  ignore(
    c.on_sync_response(
      @api.Response::new(200, sync_body("s2", [message("$mine", txn~)])),
    ),
  )
  assert_eq(c.outbox.pending().length(), 0)
  let events = c.store.room(r).unwrap().events()
  assert_eq(events.map(e => e.event_id.as_str()), ["$mine"])
}

///|
test "snapshot and restore resume both sync and sending" {
  let c = @client.Client::new("https://hs", session())
  ignore(
    c.on_sync_response(
      @api.Response::new(200, sync_body("s1", [message("$1")])),
    ),
  )
  let r = @ids.RoomId::parse(room)
  let txn = c.send_text(r, "queued before the crash")
  ignore(c.next_send(0))
  let snap = c.snapshot().stringify()
  let c2 = @client.Client::restore("https://hs", session(), @json.parse(snap))
  assert_true(c2.prepare(c2.sync_request()).url.contains("since=s1"))
  guard c2.next_send(0) is Some((t, _)) else { fail("expected a resend") }
  assert_eq(t, txn)
  let bad = try
    @client.Client::restore("https://hs", session(), Json::null())
  catch {
    _ => true
  } noraise {
    _ => false
  }
  assert_true(bad)
}

///|
test "auth errors from sync surface as api errors" {
  let c = @client.Client::new("https://hs", session())
  let r = try
    c.on_sync_response(
      @api.Response::new(
        401, "{\"errcode\":\"M_UNKNOWN_TOKEN\",\"error\":\"expired\",\"soft_logout\":true}",
      ),
    )
  catch {
    Matrix(e) => e.is_unknown_token() && e.soft_logout
    _ => false
  } noraise {
    _ => false
  }
  assert_true(r)
  // The store is untouched.
  assert_eq(c.store.since(), None)
}
