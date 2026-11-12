// End-to-end over real HTTP against a scripted fake homeserver on
// 127.0.0.1. It checks wire behaviour (paths, token header, bodies, rate
// limit handling), not Matrix semantics, which the core tests cover.

///|
let room : String = "!r:example.org"

///|
fn session() -> @api.Session raise {
  @api.parse_login(
    @api.Response::new(
      200, "{\"user_id\":\"@me:example.org\",\"access_token\":\"tok\",\"device_id\":\"DEV\"}",
    ),
  )
}

///|
fn sync_json(next : String, events : Array[Json]) -> String {
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
fn msg(id : String, sender : String, body : String, txn? : String) -> Json {
  let m : Map[String, Json] = {
    "type": "m.room.message",
    "event_id": Json(id),
    "sender": Json(sender),
    "origin_server_ts": 1,
    "content": { "msgtype": "m.text", "body": Json(body) },
  }
  if txn is Some(t) {
    m["unsigned"] = { "transaction_id": Json(t) }
  }
  Json::object(m)
}

///|
async test "sync loop with rate limit, send and echo over http" {
  let log = StringBuilder()
  let mut syncs = 0
  let mut sent_txn = ""
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((request, body, conn) => {
        let auth = request.headers.get("authorization").unwrap_or("none")
        let text = body.read_all().text()
        let path = request.path
        if path.has_prefix("/_matrix/client/v3/sync") {
          syncs += 1
          log.write_string(
            "sync \{syncs} since=\{path.contains("since=")} auth=\{auth}\n",
          )
          match syncs {
            1 =>
              conn
              ..send_response(429, "Too Many Requests")
              .write(
                "{\"errcode\":\"M_LIMIT_EXCEEDED\",\"error\":\"slow\",\"retry_after_ms\":5}",
              )
            2 =>
              conn
              ..send_response(200, "OK")
              .write(
                sync_json("s1", [
                  msg("$hi", "@alice:example.org", "!echo hello"),
                ]),
              )
            _ =>
              conn
              ..send_response(200, "OK")
              .write(
                sync_json("s2", [
                  msg("$mine", "@me:example.org", "hello", txn=sent_txn),
                ]),
              )
          }
        } else if path.contains("/send/m.room.message/") {
          sent_txn = path.split("/").to_array().last().unwrap().to_owned()
          log.write_string("send \{sent_txn} \{text}\n")
          conn..send_response(200, "OK").write("{\"event_id\":\"$mine\"}")
        } else {
          conn..send_response(404, "Not Found").write("{}")
        }
      })
    }
    let c = @client.Client::new(
      "http://127.0.0.1:\{port}",
      session(),
      txn_prefix="test",
    )
    let mut saved = Json::null()
    @transport.run_sync_loop(
      c,
      summary => {
        for r in summary.rooms {
          for e in r.events {
            if e.kind() is Message(m) &&
              m.body.strip_prefix("!echo ") is Some(rest) {
              ignore(c.send_text(r.room_id, rest.to_owned()))
            }
          }
        }
        summary.next_batch != "s2"
      },
      persist=snap => saved = snap,
      timeout_ms=0,
    )
    assert_eq(c.store.since(), Some("s2"))
    assert_eq(c.outbox.pending().length(), 0)
    let restored = @client.Client::restore("http://x", session(), saved)
    assert_eq(restored.store.since(), Some("s2"))
    let ids = c.store
      .room(@ids.RoomId::parse(room))
      .unwrap()
      .events()
      .map(e => e.event_id.as_str())
    assert_eq(ids, ["$hi", "$mine"])
  }
  assert_eq(
    log.to_string(),
    (
      #|sync 1 since=false auth=Bearer tok
      #|sync 2 since=false auth=Bearer tok
      #|send DEV.test.1 {"msgtype":"m.text","body":"hello"}
      #|sync 3 since=true auth=Bearer tok
      #|
    ),
  )
}

///|
async test "perform reports status, body and Retry-After" {
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((_request, body, conn) => {
        ignore(body.read_all())
        conn
        ..send_response(429, "Too Many Requests", extra_headers={
          "Retry-After": "3",
        })
        .write("{\"errcode\":\"M_LIMIT_EXCEEDED\",\"error\":\"x\"}")
      })
    }
    let c = @client.Client::new(
      "http://127.0.0.1:\{port}",
      session(),
      txn_prefix="test",
    )
    let resp = @transport.perform(c.prepare(@api.whoami_request()))
    assert_eq(resp.status, 429)
    assert_eq(resp.retry_after_s, Some(3))
    assert_eq(@api.retry_delay_ms(resp), Some(3000L))
  }
}

///|
async test "sync commits callback replies together with the token, including stop" {
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let hs = "http://127.0.0.1:\{server.addr.port()}"
    let mut sends = 0
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((req, body, conn) => {
        ignore(body.read_all())
        if req.path.contains("/send/") {
          sends += 1
        }
        conn
        ..send_response(200, "OK")
        .write(sync_json("s1", [msg("$hi", "@alice:example.org", "hello")]))
      })
    }
    for phase in 0..<3 {
      let c = @client.Client::new(hs, session(), txn_prefix="test")
      let mut saved = c.snapshot()
      let failed = try {
        @transport.run_sync_loop(
          c,
          _ => {
            ignore(c.send_text(@ids.RoomId::parse(room), "reply"))
            if phase == 0 {
              fail("callback interrupted")
            }
            false
          },
          persist=snap => {
            if phase == 1 {
              fail("save failed before commit")
            }
            saved = snap
          },
        )
        false
      } catch {
        _ => true
      }
      assert_eq(failed, phase != 2)
      let restored = @client.Client::restore(hs, session(), saved)
      if phase == 2 {
        assert_eq(restored.store.since(), Some("s1"))
        assert_eq(restored.outbox.pending().length(), 1)
      } else {
        assert_eq(restored.store.since(), None)
        assert_eq(restored.outbox.pending().length(), 0)
        // Restart from disk: the callback must see the uncommitted event again.
        @transport.run_sync_loop(
          restored,
          summary => {
            assert_eq(summary.rooms[0].events[0].event_id.as_str(), "$hi")
            ignore(restored.send_text(@ids.RoomId::parse(room), "reply"))
            false
          },
          persist=snap => saved = snap,
        )
        let committed = @client.Client::restore(hs, session(), saved)
        assert_eq(committed.store.since(), Some("s1"))
        assert_eq(committed.outbox.pending().length(), 1)
      }
    }
    // Queuing in a callback must not send before the checkpoint is committed.
    assert_eq(sends, 0)
  }
}

///|
async test "send checkpoints survive a lost response without reusing transaction ids" {
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let hs = "http://127.0.0.1:\{server.addr.port()}"
    let requests : Array[String] = []
    let delivered : Map[String, Unit] = Map([])
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((req, body, conn) => {
        ignore(body.read_all())
        let txn = req.path.split("/").to_array().last().unwrap().to_owned()
        requests.push(txn)
        delivered[txn] = ()
        conn..send_response(200, "OK").write("{\"event_id\":\"$sent\"}")
      })
    }
    let c = @client.Client::new(hs, session(), txn_prefix="test")
    let first = c.send_text(@ids.RoomId::parse(room), "first")
    let mut saved = c.snapshot()
    @transport.flush_sends(c, persist=snap => saved = snap)
    assert_eq(requests, [first])
    // Die after the server accepted the send, before saving its response.
    let restored = @client.Client::restore(hs, session(), saved)
    let second = restored.send_text(@ids.RoomId::parse(room), "second")
    assert_true(first != second)
    @transport.flush_sends(restored, persist=snap => saved = snap)
    assert_eq(requests, [first, first, second])
    assert_eq(delivered.length(), 2)
    let resumed = @client.Client::restore(hs, session(), saved)
    let third = resumed.send_text(@ids.RoomId::parse(room), "third")
    assert_true(third != first && third != second)
  }
}

///|
async test "a failed send checkpoint prevents network IO" {
  let c = @client.Client::new(
    "http://127.0.0.1:1",
    session(),
    txn_prefix="test",
  )
  let txn = c.send_text(@ids.RoomId::parse(room), "unsaved")
  let failed = try {
    @transport.flush_sends(c, persist=_ => fail("disk unavailable"))
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  // A transport attempt would have changed this to Retrying.
  assert_true(c.outbox.get(txn).unwrap().state() is InFlight)
}
