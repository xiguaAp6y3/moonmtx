///|
fn[T] api_err(f : () -> T raise @api.ApiError) -> @api.ApiError? {
  try f() catch {
    e => Some(e)
  } noraise {
    _ => None
  }
}

///|
fn ok(body : String) -> @api.Response {
  @api.Response::new(200, body)
}

///|
test "path: variable segments are percent-encoded" {
  let p = @api.client_v3([
    Lit("rooms"),
    Var("!abc:example.org"),
    Lit("send"),
    Var("m.room.message"),
    Var("txn/1 2"),
  ])
  assert_eq(
    p, "/_matrix/client/v3/rooms/%21abc%3Aexample.org/send/m.room.message/txn%2F1%202",
  )
}

///|
test "request: url, query and headers" {
  let r = @api.Request::new(Get, @api.client_v3([Lit("sync")]), query=[
    ("since", "s72594_4483_1934"),
    ("filter", "{\"room\":{}}"),
  ])
  assert_eq(
    r.url("https://matrix.example.org/"),
    "https://matrix.example.org/_matrix/client/v3/sync?since=s72594_4483_1934&filter=%7B%22room%22%3A%7B%7D%7D",
  )
  assert_eq(r.headers(access_token="tok"), [("Authorization", "Bearer tok")])
  assert_eq(r.body_text(), None)
  let r = @api.Request::new(Post, "/x", body={ "a": 1 }, auth=false)
  assert_eq(r.headers(access_token="tok"), [
    ("Content-Type", "application/json"),
  ])
  assert_eq(r.body_text(), Some("{\"a\":1}"))
  assert_eq(r.verb.as_str(), "POST")
}

///|
test "error: standard matrix error body" {
  let resp = @api.Response::new(
    403, "{\"errcode\":\"M_FORBIDDEN\",\"error\":\"You are not invited to this room.\"}",
  )
  guard api_err(() => @api.expect_ok(resp)) is Some(Matrix(e)) else {
    fail("expected a Matrix error")
  }
  assert_eq(e.status, 403)
  assert_eq(e.errcode, @api.M_FORBIDDEN)
  assert_eq(e.error, "You are not invited to this room.")
  assert_false(e.is_rate_limited())
}

///|
test "error: rate limit and retry delay" {
  let body = "{\"errcode\":\"M_LIMIT_EXCEEDED\",\"error\":\"Too many requests\",\"retry_after_ms\":2000}"
  let resp = @api.Response::new(429, body)
  guard api_err(() => @api.expect_ok(resp)) is Some(Matrix(e)) else {
    fail("expected a Matrix error")
  }
  assert_true(e.is_rate_limited())
  assert_eq(e.retry_after_ms, Some(2000L))
  assert_eq(@api.retry_delay_ms(resp), Some(2000L))
  // The Retry-After header wins over the deprecated body field.
  let resp = @api.Response::new(429, body, retry_after_s=5)
  assert_eq(@api.retry_delay_ms(resp), Some(5000L))
}

///|
test "error: soft logout" {
  let resp = @api.Response::new(
    401, "{\"errcode\":\"M_UNKNOWN_TOKEN\",\"error\":\"Token expired\",\"soft_logout\":true}",
  )
  guard api_err(() => @api.expect_ok(resp)) is Some(Matrix(e)) else {
    fail("expected a Matrix error")
  }
  assert_true(e.is_unknown_token())
  assert_true(e.soft_logout)
}

///|
test "error: non-matrix bodies and decode failures" {
  let resp = @api.Response::new(502, "<html>Bad Gateway</html>")
  assert_eq(
    api_err(() => @api.expect_ok(resp)),
    Some(Http(status=502, body="<html>Bad Gateway</html>")),
  )
  assert_true(api_err(() => @api.expect_ok(ok("[1,2]"))) is Some(Decode(_)))
  assert_true(api_err(() => @api.expect_ok(ok("{"))) is Some(Decode(_)))
  assert_eq(@api.expect_ok(ok("")).length(), 0)
  assert_eq(
    api_err(() => @api.expect_ok(ok("{}"))).map(e => e.to_string()),
    None,
  )
}

///|
test "discovery: well-known states" {
  let server = @ids.ServerName::parse("example.org:8448")
  assert_eq(@api.well_known_base(server), "https://example.org")
  assert_eq(
    @api.well_known_request().url(@api.well_known_base(server)),
    "https://example.org/.well-known/matrix/client",
  )
  assert_eq(@api.parse_well_known(@api.Response::new(404, "")), Ignore)
  assert_true(
    @api.parse_well_known(@api.Response::new(500, "")) is FailPrompt(_),
  )
  assert_true(@api.parse_well_known(ok("not json")) is FailPrompt(_))
  assert_true(@api.parse_well_known(ok("{}")) is FailPrompt(_))
  assert_true(
    @api.parse_well_known(ok("{\"m.homeserver\":{\"base_url\":\"matrix\"}}"))
    is FailError(_),
  )
  assert_eq(
    @api.parse_well_known(
      ok(
        "{\"m.homeserver\":{\"base_url\":\"https://matrix.example.com/\"},\"m.identity_server\":{\"base_url\":\"https://identity.example.com\"},\"org.example.custom.property\":{\"app_url\":\"https://custom.app.example.org\"}}",
      ),
    ),
    Found(
      homeserver="https://matrix.example.com",
      identity_server=Some("https://identity.example.com"),
    ),
  )
  assert_true(
    @api.parse_well_known(
      ok(
        "{\"m.homeserver\":{\"base_url\":\"https://a.example\"},\"m.identity_server\":{}}",
      ),
    )
    is FailError(_),
  )
}

///|
test "versions" {
  let v = @api.parse_versions(
    ok(
      "{\"unstable_features\":{\"org.example.my_feature\":true,\"org.example.off\":false},\"versions\":[\"r0.0.1\",\"v1.1\",\"v1.19\"]}",
    ),
  )
  assert_true(v.supports("v1.19"))
  assert_false(v.supports("v1.20"))
  assert_true(v.has_feature("org.example.my_feature"))
  assert_false(v.has_feature("org.example.off"))
  assert_false(v.has_feature("missing"))
  assert_true(api_err(() => @api.parse_versions(ok("{}"))) is Some(Decode(_)))
}

///|
test "login: flows" {
  let flows = @api.parse_login_flows(
    ok(
      "{\"flows\":[{\"type\":\"m.login.password\"},{\"type\":\"m.login.token\",\"get_login_token\":true}]}",
    ),
  )
  assert_eq(flows.map(f => f.kind), ["m.login.password", "m.login.token"])
  assert_eq(flows[1].raw.get("get_login_token"), Some(Json::boolean(true)))
}

///|
test "login: request bodies" {
  let r = @api.login_request(
    Password(User("cheeky_monkey"), password="ilovebananas"),
    initial_device_display_name="Jungle Phone",
  )
  assert_false(r.auth)
  assert_eq(r.path, "/_matrix/client/v3/login")
  assert_eq(
    r.body,
    Some({
      "type": "m.login.password",
      "identifier": { "type": "m.id.user", "user": "cheeky_monkey" },
      "password": "ilovebananas",
      "initial_device_display_name": "Jungle Phone",
    }),
  )
  let r = @api.login_request(
    Token("abc"),
    device_id="GHTYAJCE",
    refresh_token=true,
  )
  assert_eq(
    r.body,
    Some({
      "type": "m.login.token",
      "token": "abc",
      "device_id": "GHTYAJCE",
      "refresh_token": true,
    }),
  )
  let r = @api.login_request(
    Password(ThirdParty(medium="email", address="a@example.org"), password="x"),
  )
  guard r.body is Some(Object(b)) else { fail("expected a body") }
  assert_eq(
    b.get("identifier"),
    Some({
      "type": "m.id.thirdparty",
      "medium": "email",
      "address": "a@example.org",
    }),
  )
}

///|
test "login: session parse and storage round trip" {
  let s = @api.parse_login(
    ok(
      "{\"access_token\":\"abc123\",\"device_id\":\"GHTYAJCE\",\"expires_in_ms\":60000,\"refresh_token\":\"def456\",\"user_id\":\"@cheeky_monkey:matrix.org\",\"well_known\":{\"m.homeserver\":{\"base_url\":\"https://example.org\"}}}",
    ),
  )
  assert_eq(s.user_id.to_string(), "@cheeky_monkey:matrix.org")
  assert_eq(s.access_token, "abc123")
  assert_eq(s.device_id, "GHTYAJCE")
  assert_eq(s.refresh_token, Some("def456"))
  assert_eq(s.expires_in_ms, Some(60000L))
  assert_eq(s.homeserver, Some("https://example.org"))
  let back : @api.Session = @json.from_json(s.to_json())
  assert_true(back == s)
  let bad = @api.Response::new(
    200, "{\"access_token\":\"x\",\"device_id\":\"D\",\"user_id\":\"nope\"}",
  )
  assert_true(api_err(() => @api.parse_login(bad)) is Some(Decode(_)))
}

///|
test "whoami, logout, refresh" {
  let w = @api.parse_whoami(
    ok("{\"device_id\":\"ABCDEF\",\"user_id\":\"@joe:example.org\"}"),
  )
  assert_eq(w.user_id.localpart, "joe")
  assert_eq(w.device_id, Some("ABCDEF"))
  assert_false(w.is_guest)
  assert_true(@api.whoami_request().auth)
  assert_eq(@api.logout_all_request().path, "/_matrix/client/v3/logout/all")
  @api.parse_empty(ok("{}"))
  let s = @api.parse_login(
    ok(
      "{\"access_token\":\"old\",\"device_id\":\"D\",\"refresh_token\":\"r1\",\"user_id\":\"@a:b.c\"}",
    ),
  )
  let r = @api.parse_refresh(
    ok("{\"access_token\":\"new\",\"expires_in_ms\":1000}"),
  )
  let s2 = s.refreshed(r)
  assert_eq(s2.access_token, "new")
  assert_eq(s2.refresh_token, Some("r1"))
  assert_eq(s2.expires_in_ms, Some(1000L))
  assert_eq(@api.refresh_request("r1").body, Some({ "refresh_token": "r1" }))
}
