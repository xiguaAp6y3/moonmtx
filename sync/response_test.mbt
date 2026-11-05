// Fixtures follow the shape of the `GET /sync` response example in the
// Client-Server API v1.19, trimmed and with IDs shortened.

///|
let initial_sync : String =
  #|{
  #|  "next_batch": "s72595_4483_1934",
  #|  "account_data": {"events": [{"type": "org.example.custom.config", "content": {"custom_config_key": "custom_config_value"}}]},
  #|  "rooms": {
  #|    "join": {
  #|      "!726s6s6q:example.com": {
  #|        "summary": {"m.heroes": ["@alice:example.com", "@bob:example.com"], "m.joined_member_count": 2, "m.invited_member_count": 0},
  #|        "state": {"events": [
  #|          {"type": "m.room.member", "state_key": "@alice:example.com", "event_id": "$m_alice", "sender": "@alice:example.com", "origin_server_ts": 1432735820000, "content": {"membership": "join", "displayname": "Alice"}}
  #|        ]},
  #|        "timeline": {
  #|          "limited": true,
  #|          "prev_batch": "t34-23535_0_0",
  #|          "events": [
  #|            {"type": "m.room.member", "state_key": "@bob:example.com", "event_id": "$m_bob", "sender": "@bob:example.com", "origin_server_ts": 1432735824653, "content": {"membership": "join"}},
  #|            {"type": "m.room.message", "event_id": "$msg1", "sender": "@bob:example.com", "origin_server_ts": 1432735824654, "content": {"msgtype": "m.text", "body": "hello"}, "unsigned": {"age": 1234}}
  #|          ]
  #|        },
  #|        "ephemeral": {"events": [{"type": "m.typing", "content": {"user_ids": ["@alice:example.com"]}}]},
  #|        "account_data": {"events": [{"type": "m.tag", "content": {"tags": {"work": {"order": 1}}}}]},
  #|        "unread_notifications": {"highlight_count": 1, "notification_count": 2}
  #|      }
  #|    },
  #|    "invite": {
  #|      "!696r7674:example.com": {
  #|        "invite_state": {"events": [
  #|          {"type": "m.room.name", "state_key": "", "sender": "@alice:example.com", "content": {"name": "My Room Name"}},
  #|          {"type": "m.room.member", "state_key": "@bob:example.com", "sender": "@alice:example.com", "content": {"membership": "invite"}}
  #|        ]}
  #|      }
  #|    },
  #|    "knock": {
  #|      "!223asd456:example.com": {"knock_state": {"events": [{"type": "m.room.name", "state_key": "", "sender": "@alice:example.com", "content": {"name": "A room"}}]}}
  #|    },
  #|    "leave": {
  #|      "!old:example.com": {"timeline": {"events": [{"type": "m.room.member", "state_key": "@me:example.com", "event_id": "$left", "sender": "@me:example.com", "origin_server_ts": 1, "content": {"membership": "leave"}}]}}
  #|    }
  #|  }
  #|}

///|
test "filter: inline json" {
  let f = @sync.Filter::new(timeline_limit=20, lazy_load_members=true, timeline_not_types=[
    "m.room.call.invite",
  ])
  assert_eq(f.to_json(), {
    "room": {
      "timeline": {
        "limit": 20,
        "not_types": ["m.room.call.invite"],
        "lazy_load_members": true,
      },
      "state": { "lazy_load_members": true },
    },
  })
  assert_eq(@sync.Filter::new().to_json(), {
    "room": { "timeline": {}, "state": {} },
  })
}

///|
test "sync request: initial and incremental" {
  let r = @sync.sync_request()
  assert_eq(r.url("https://hs"), "https://hs/_matrix/client/v3/sync?timeout=0")
  assert_true(r.auth)
  let r = @sync.sync_request(
    since="s72595_4483_1934",
    filter=Inline(@sync.Filter::new(timeline_limit=10)),
    timeout_ms=30000,
  )
  assert_eq(
    r.url("https://hs"),
    "https://hs/_matrix/client/v3/sync?since=s72595_4483_1934&filter=%7B%22room%22%3A%7B%22timeline%22%3A%7B%22limit%22%3A10%7D%2C%22state%22%3A%7B%7D%7D%7D&timeout=30000",
  )
  let r = @sync.sync_request(filter=Id("66696p746572"), full_state=true)
  assert_eq(r.query, [
    ("filter", "66696p746572"),
    ("timeout", "0"),
    ("full_state", "true"),
  ])
  let user = @ids.UserId::parse("@alice:example.com")
  let up = @sync.upload_filter_request(user, @sync.Filter::new())
  assert_eq(up.path, "/_matrix/client/v3/user/%40alice%3Aexample.com/filter")
  assert_eq(
    @sync.parse_filter_id(@api.Response::new(200, "{\"filter_id\":\"abc\"}")),
    "abc",
  )
}

///|
test "sync response: all room sections" {
  let s = @sync.parse_sync(@api.Response::new(200, initial_sync))
  assert_eq(s.next_batch, "s72595_4483_1934")
  assert_eq(s.invalid, [])
  assert_eq(s.account_data.length(), 1)
  assert_eq(s.join.length(), 1)
  let j = s.join[0]
  assert_eq(j.room_id.as_str(), "!726s6s6q:example.com")
  assert_eq(j.summary.heroes, Some(["@alice:example.com", "@bob:example.com"]))
  assert_eq(j.summary.joined_member_count, Some(2L))
  assert_eq(j.state.map(e => e.event_id.as_str()), ["$m_alice"])
  assert_true(j.timeline.limited)
  assert_eq(j.timeline.prev_batch, Some("t34-23535_0_0"))
  assert_eq(j.timeline.events.map(e => e.event_id.as_str()), ["$m_bob", "$msg1"])
  assert_eq(j.ephemeral.length(), 1)
  assert_eq(j.account_data.length(), 1)
  assert_eq(j.notification_count, Some(2L))
  assert_eq(j.highlight_count, Some(1L))
  assert_eq(s.invite.length(), 1)
  assert_eq(s.invite[0].invite_state.map(e => e.kind_str), [
    "m.room.name", "m.room.member",
  ])
  assert_eq(s.knock[0].room_id.as_str(), "!223asd456:example.com")
  assert_eq(s.leave[0].timeline.events[0].event_id.as_str(), "$left")
}

///|
test "sync response: empty incremental sync" {
  let s = @sync.parse_sync(@api.Response::new(200, "{\"next_batch\":\"s2\"}"))
  assert_eq(s.next_batch, "s2")
  assert_eq(s.join, [])
  assert_eq(s.invalid, [])
}

///|
test "sync response: bad entries are skipped and reported" {
  let body =
    #|{"next_batch": "s3", "rooms": {"join": {
    #|  "not-a-room-id": {},
    #|  "!ok:example.com": {"timeline": {"events": [
    #|    {"type": "m.room.message", "sender": "@a:example.com", "origin_server_ts": 1, "content": {}},
    #|    {"type": "m.room.message", "event_id": "$good", "sender": "@a:example.com", "origin_server_ts": 2, "content": {}},
    #|    "garbage"
    #|  ]}, "ephemeral": {"events": [{"content": {}}]}}
    #|}}}
  let s = @sync.parse_sync(@api.Response::new(200, body))
  assert_eq(s.join.length(), 1)
  assert_eq(s.join[0].timeline.events.map(e => e.event_id.as_str()), ["$good"])
  assert_eq(s.join[0].ephemeral, [])
  assert_eq(s.invalid.length(), 4)
  assert_true(s.invalid[0].contains("not-a-room-id"), msg=s.invalid[0])
  assert_true(s.invalid[1].contains("event_id"), msg=s.invalid[1])
}

///|
test "sync response: missing next_batch is an error" {
  let r = try
    @sync.parse_sync(@api.Response::new(200, "{\"rooms\":{}}"))
  catch {
    e => Some(e)
  } noraise {
    _ => None
  }
  assert_true(r is Some(Decode(_)))
  let r = try
    @sync.parse_sync(
      @api.Response::new(
        401, "{\"errcode\":\"M_UNKNOWN_TOKEN\",\"error\":\"x\",\"soft_logout\":true}",
      ),
    )
  catch {
    e => Some(e)
  } noraise {
    _ => None
  }
  assert_true(r is Some(Matrix({ soft_logout: true, .. })))
}
