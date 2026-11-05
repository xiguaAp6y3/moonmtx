///|
fn rid(s : String) -> @ids.RoomId raise {
  @ids.RoomId::parse(s)
}

///|
fn ok_event(id : String) -> @api.Response {
  @api.Response::new(200, "{\"event_id\":\"\{id}\"}")
}

///|
fn echo(id : String, txn : String) -> @events.Event raise {
  @events.Event::parse(
    "{\"type\":\"m.room.message\",\"event_id\":\"\{id}\",\"sender\":\"@me:b.c\",\"origin_server_ts\":1,\"content\":{\"msgtype\":\"m.text\",\"body\":\"x\"},\"unsigned\":{\"transaction_id\":\"\{txn}\"}}",
  )
}

///|
fn next_txn(o : @send.Outbox, now : Int64) -> String? {
  o.next_request(now).map(r => r.0)
}

///|
test "messages to one room go out in order, one at a time" {
  let o = @send.Outbox::new("DEV.1700")
  let a = rid("!a:b.c")
  let t1 = o.enqueue(a, "m.room.message", { "msgtype": "m.text", "body": "1" })
  let t2 = o.enqueue(a, "m.room.message", { "msgtype": "m.text", "body": "2" })
  assert_eq(t1, "DEV.1700.1")
  assert_eq(t2, "DEV.1700.2")
  guard o.next_request(0) is Some((txn, req)) else {
    fail("expected a request")
  }
  assert_eq(txn, t1)
  assert_true(req.path.has_suffix("/send/m.room.message/DEV.1700.1"))
  // t2 waits while t1 is in flight.
  assert_eq(next_txn(o, 0), None)
  assert_eq(
    o.on_response(t1, ok_event("$e1"), 0),
    Sent(@ids.EventId::parse("$e1")),
  )
  assert_eq(next_txn(o, 0), Some(t2))
}

///|
test "different rooms do not block each other" {
  let o = @send.Outbox::new("D")
  let t1 = o.enqueue(rid("!a:b.c"), "m.room.message", {})
  let t2 = o.enqueue(rid("!b:b.c"), "m.room.message", {})
  assert_eq(next_txn(o, 0), Some(t1))
  assert_eq(next_txn(o, 0), Some(t2))
  assert_eq(next_txn(o, 0), None)
}

///|
test "rate limit: retried after the server's delay with the same txn id" {
  let o = @send.Outbox::new("D")
  let t1 = o.enqueue(rid("!a:b.c"), "m.room.message", {})
  ignore(o.next_request(1000))
  let limited = @api.Response::new(
    429, "{\"errcode\":\"M_LIMIT_EXCEEDED\",\"error\":\"slow down\",\"retry_after_ms\":2500}",
  )
  assert_eq(o.on_response(t1, limited, 1000), WillRetry(at_ms=3500))
  assert_eq(next_txn(o, 3499), None)
  guard o.next_request(3500) is Some((txn, req)) else { fail("expected retry") }
  assert_eq(txn, t1)
  assert_true(req.path.has_suffix("/" + t1))
  assert_eq(o.get(t1).map(p => p.attempts()), Some(2))
}

///|
test "server errors back off exponentially, then fail" {
  let o = @send.Outbox::new("D", max_attempts=3, base_delay_ms=100)
  let t = o.enqueue(rid("!a:b.c"), "m.room.message", {})
  let err = @api.Response::new(502, "Bad Gateway")
  ignore(o.next_request(0))
  assert_eq(o.on_response(t, err, 0), WillRetry(at_ms=100))
  ignore(o.next_request(100))
  assert_eq(o.on_response(t, err, 100), WillRetry(at_ms=300))
  ignore(o.next_request(300))
  assert_true(o.on_response(t, err, 300) is Failed(_))
  // A failed message does not block later ones in the room.
  let t2 = o.enqueue(rid("!a:b.c"), "m.room.message", {})
  assert_eq(next_txn(o, 300), Some(t2))
  // retry() queues it again with the same txn id.
  assert_true(o.retry(t))
  assert_eq(o.get(t).map(p => p.state()), Some(Queued))
}

///|
test "client errors fail at once" {
  let o = @send.Outbox::new("D")
  let t = o.enqueue(rid("!a:b.c"), "m.room.message", {})
  ignore(o.next_request(0))
  let forbidden = @api.Response::new(
    403, "{\"errcode\":\"M_FORBIDDEN\",\"error\":\"not in room\"}",
  )
  guard o.on_response(t, forbidden, 0) is Failed(reason) else { fail("failed") }
  assert_true(reason.contains("M_FORBIDDEN"), msg=reason)
}

///|
test "transport errors are retried" {
  let o = @send.Outbox::new("D", base_delay_ms=10)
  let t = o.enqueue(rid("!a:b.c"), "m.room.message", {})
  ignore(o.next_request(0))
  assert_eq(o.on_transport_error(t, "connection reset", 5), WillRetry(at_ms=15))
  assert_eq(next_txn(o, 15), Some(t))
}

///|
test "local echo before or after the response completes the message" {
  let o = @send.Outbox::new("D")
  let a = rid("!a:b.c")
  let t1 = o.enqueue(a, "m.room.message", {})
  let t2 = o.enqueue(a, "m.room.message", {})
  // t1: response first, then echo.
  ignore(o.next_request(0))
  ignore(o.on_response(t1, ok_event("$e1"), 0))
  assert_eq(o.pending().length(), 2)
  let matched = o.on_echo(a, [echo("$other", "someone-else"), echo("$e1", t1)])
  assert_eq(matched.map(m => m.0), [t1])
  // t2: echo arrives while the request is still in flight.
  ignore(o.next_request(0))
  ignore(o.on_echo(a, [echo("$e2", t2)]))
  assert_eq(o.pending().length(), 0)
  assert_eq(o.on_response(t2, ok_event("$e2"), 0), Ignored)
  // An echo in another room with the same txn id does not match.
  let t3 = o.enqueue(a, "m.room.message", {})
  assert_eq(o.on_echo(rid("!b:b.c"), [echo("$e3", t3)]), [])
}

///|
test "cancel only before the server has the message" {
  let o = @send.Outbox::new("D")
  let a = rid("!a:b.c")
  let t1 = o.enqueue(a, "m.room.message", {})
  let t2 = o.enqueue(a, "m.room.message", {})
  ignore(o.next_request(0))
  assert_false(o.cancel(t1))
  assert_true(o.cancel(t2))
  assert_eq(o.pending().map(p => p.txn_id), [t1])
  assert_false(o.cancel("nope"))
}

///|
test "snapshot: in-flight messages are restored as queued with their txn id" {
  let o = @send.Outbox::new("D")
  let a = rid("!a:b.c")
  let t1 = o.enqueue(a, "m.room.message", { "msgtype": "m.text", "body": "1" })
  let t2 = o.enqueue(rid("!b:b.c"), "m.reaction", {})
  ignore(o.next_request(0))
  ignore(o.next_request(0))
  ignore(o.on_response(t2, ok_event("$e2"), 0))
  let back = @send.Outbox::from_json(@json.parse(o.to_json().stringify()))
  assert_eq(back.get(t1).map(p => p.state()), Some(Queued))
  assert_eq(
    back.get(t2).map(p => p.state()),
    Some(Sent(@ids.EventId::parse("$e2"))),
  )
  guard back.next_request(0) is Some((txn, req)) else {
    fail("expected resend")
  }
  assert_eq(txn, t1)
  assert_eq(req.body, Some({ "msgtype": "m.text", "body": "1" }))
  // The counter continues, so new txn ids do not collide.
  assert_eq(back.enqueue(a, "m.room.message", {}), "D.3")
}
