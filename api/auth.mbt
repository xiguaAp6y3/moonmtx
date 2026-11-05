// Login, logout, whoami and token refresh, Client-Server API v1.19
// "Client Authentication".

///|
/// A login type advertised by `GET /login`, e.g. `m.login.password`.
pub struct LoginFlow {
  kind : String
  raw : Map[String, Json]
} derive(Eq, Debug)

///|
pub fn login_flows_request() -> Request {
  Request::new(Get, client_v3([Lit("login")]), auth=false)
}

///|
pub fn parse_login_flows(resp : Response) -> Array[LoginFlow] raise ApiError {
  decode_ok(resp, m => {
    let root = @jsonx.root()
    let flows = []
    for i, f in @jsonx.array(m, "flows", root) {
      let p = root.add_key("flows").add_index(i)
      let o = @jsonx.object(f, p)
      flows.push({ kind: @jsonx.string(o, "type", p), raw: o, })
    }
    flows
  })
}

///|
/// How the user is identified in a password login.
pub(all) enum Identifier {
  /// `m.id.user`: a full user ID or just the localpart.
  User(String)
  /// `m.id.thirdparty`, e.g. medium `email`.
  ThirdParty(medium~ : String, address~ : String)
}

///|
fn Identifier::to_json(self : Identifier) -> Json {
  match self {
    User(u) => { "type": "m.id.user", "user": u }
    ThirdParty(medium~, address~) =>
      { "type": "m.id.thirdparty", "medium": medium, "address": address }
  }
}

///|
/// Credentials for `POST /login`. Not `Debug`: it holds secrets.
pub(all) enum Credentials {
  Password(Identifier, password~ : String)
  /// `m.login.token`, e.g. from SSO.
  Token(String)
}

///|
/// Builds `POST /login`. `device_id` reuses an existing device; without it
/// the server creates one. `refresh_token` asks for a refresh token.
pub fn login_request(
  creds : Credentials,
  device_id? : String,
  initial_device_display_name? : String,
  refresh_token~ : Bool = false,
) -> Request {
  let (kind, extra) : (String, Array[(String, Json?)]) = match creds {
    Password(id, password~) =>
      (
        "m.login.password",
        [
          ("identifier", Some(id.to_json())),
          ("password", Some(Json::string(password))),
        ],
      )
    Token(t) => ("m.login.token", [("token", Some(Json::string(t)))])
  }
  let body = @jsonx.build(
    [
      ("type", Some(Json::string(kind))),
      ..extra,
      ("device_id", device_id.map(Json::string)),
      (
        "initial_device_display_name",
        initial_device_display_name.map(Json::string),
      ),
      (
        "refresh_token",
        if refresh_token {
          Some(Json::boolean(true))
        } else {
          None
        },
      ),
    ],
  )
  Request::new(Post, client_v3([Lit("login")]), body~, auth=false)
}

///|
/// An authenticated session. Not `Debug`: it holds the access token.
pub struct Session {
  user_id : @ids.UserId
  access_token : String
  device_id : String
  refresh_token : String?
  /// Lifetime of `access_token` when it was issued, in milliseconds.
  expires_in_ms : Int64?
  /// Homeserver base URL suggested by the login response, if any.
  homeserver : String?
} derive(Eq)

///|
fn decode_session(
  m : Map[String, Json],
  path : @json.JsonPath,
) -> Session raise @json.JsonDecodeError {
  let homeserver = match @jsonx.opt_object(m, "well_known", path) {
    Some(wk) =>
      match wk.get("m.homeserver") {
        Some(Object(hs)) => @jsonx.opt_string(hs, "base_url", path)
        _ => None
      }
    None => @jsonx.opt_string(m, "homeserver", path)
  }
  {
    user_id: @jsonx.decode(m, "user_id", path),
    access_token: @jsonx.string(m, "access_token", path),
    device_id: @jsonx.string(m, "device_id", path),
    refresh_token: @jsonx.opt_string(m, "refresh_token", path),
    expires_in_ms: @jsonx.opt_int(m, "expires_in_ms", path),
    homeserver,
  }
}

///|
pub fn parse_login(resp : Response) -> Session raise ApiError {
  decode_ok(resp, m => decode_session(m, @jsonx.root()))
}

///|
/// Serialises a session for storage. The output contains the access token;
/// store it as a secret.
pub impl ToJson for Session with fn to_json(self) {
  @jsonx.build([
    ("user_id", Some(self.user_id.to_json())),
    ("access_token", Some(Json::string(self.access_token))),
    ("device_id", Some(Json::string(self.device_id))),
    ("refresh_token", self.refresh_token.map(Json::string)),
    (
      "expires_in_ms",
      self.expires_in_ms.map(ms => Json::number(ms.to_double())),
    ),
    ("homeserver", self.homeserver.map(Json::string)),
  ])
}

///|
pub impl @json.FromJson for Session with fn from_json(json, path) {
  decode_session(@jsonx.object(json, path), path)
}

///|
/// `POST /logout`: invalidates the current access token and device.
pub fn logout_request() -> Request {
  Request::new(Post, client_v3([Lit("logout")]), body=Json::empty_object())
}

///|
/// `POST /logout/all`: invalidates every token of the user.
pub fn logout_all_request() -> Request {
  Request::new(
    Post,
    client_v3([Lit("logout"), Lit("all")]),
    body=Json::empty_object(),
  )
}

///|
pub fn parse_empty(resp : Response) -> Unit raise ApiError {
  ignore(expect_ok(resp))
}

///|
pub struct WhoAmI {
  user_id : @ids.UserId
  device_id : String?
  is_guest : Bool
} derive(Eq, Debug)

///|
pub fn whoami_request() -> Request {
  Request::new(Get, client_v3([Lit("account"), Lit("whoami")]))
}

///|
pub fn parse_whoami(resp : Response) -> WhoAmI raise ApiError {
  decode_ok(resp, m => {
    let root = @jsonx.root()
    {
      user_id: @jsonx.decode(m, "user_id", root),
      device_id: @jsonx.opt_string(m, "device_id", root),
      is_guest: @jsonx.opt_bool(m, "is_guest", root).unwrap_or(false),
    }
  })
}

///|
/// New tokens from `POST /refresh`. Not `Debug`: it holds tokens.
pub struct Refreshed {
  access_token : String
  /// A new refresh token; when absent, keep using the old one.
  refresh_token : String?
  expires_in_ms : Int64?
} derive(Eq)

///|
pub fn refresh_request(refresh_token : String) -> Request {
  Request::new(
    Post,
    client_v3([Lit("refresh")]),
    body={ "refresh_token": Json::string(refresh_token) },
    auth=false,
  )
}

///|
pub fn parse_refresh(resp : Response) -> Refreshed raise ApiError {
  decode_ok(resp, m => {
    let root = @jsonx.root()
    {
      access_token: @jsonx.string(m, "access_token", root),
      refresh_token: @jsonx.opt_string(m, "refresh_token", root),
      expires_in_ms: @jsonx.opt_int(m, "expires_in_ms", root),
    }
  })
}

///|
/// Applies a refresh result to a session.
pub fn Session::refreshed(self : Session, r : Refreshed) -> Session {
  {
    ..self,
    access_token: r.access_token,
    refresh_token: if r.refresh_token is Some(_) {
      r.refresh_token
    } else {
      self.refresh_token
    },
    expires_in_ms: r.expires_in_ms,
  }
}
