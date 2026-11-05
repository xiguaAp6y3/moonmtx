// Server discovery, Client-Server API v1.19 "Server Discovery" and
// "GET /_matrix/client/versions".

///|
/// The outcome of a `.well-known/matrix/client` lookup, following the
/// spec's IGNORE / FAIL_PROMPT / FAIL_ERROR states.
pub(all) enum Discovery {
  /// A usable homeserver (and optional identity server) base URL.
  Found(homeserver~ : String, identity_server~ : String?)
  /// No well-known file (404): keep using the server the user gave.
  Ignore
  /// The file is unusable; ask the user for a homeserver URL.
  FailPrompt(String)
  /// The file names an invalid server; stop and report the error.
  FailError(String)
} derive(Eq, Debug)

///|
/// Base URL for the well-known lookup: `https://` plus the hostname of the
/// server name. The port is dropped, as the spec requires.
pub fn well_known_base(server : @ids.ServerName) -> String {
  "https://\{server.host}"
}

///|
pub fn well_known_request() -> Request {
  Request::new(
    Get,
    path([Lit(".well-known"), Lit("matrix"), Lit("client")]),
    auth=false,
  )
}

///|
/// Whether `url` looks like an absolute http(s) URL with a host.
fn is_base_url(url : String) -> Bool {
  let rest = match url.strip_prefix("https://") {
    Some(r) => r
    None =>
      match url.strip_prefix("http://") {
        Some(r) => r
        None => return false
      }
  }
  let host = match rest.find("/") {
    Some(i) => rest.view(end_offset=i)
    None => rest
  }
  !host.is_empty() && !host.contains_any(chars=" ?#@")
}

///|
fn trim_slash(url : String) -> String {
  match url.strip_suffix("/") {
    Some(u) => u.to_owned()
    None => url
  }
}

///|
fn base_url_of(m : Map[String, Json], key : String) -> String?? {
  match m.get(key) {
    None => None
    Some(Object(o)) =>
      match o.get("base_url") {
        Some(String(u)) => Some(Some(u))
        _ => Some(None)
      }
    Some(_) => Some(None)
  }
}

///|
/// Interprets the response to `well_known_request`. A `Found` result still
/// has to be confirmed with `versions_request` before use.
pub fn parse_well_known(resp : Response) -> Discovery {
  if resp.status == 404 {
    return Ignore
  }
  if resp.status != 200 {
    return FailPrompt("well-known returned HTTP \{resp.status}")
  }
  let json = @json.parse(resp.body) catch {
    _ => return FailPrompt("well-known is not valid JSON")
  }
  guard json is Object(m) else {
    return FailPrompt("well-known is not a JSON object")
  }
  guard base_url_of(m, "m.homeserver") is Some(Some(hs)) else {
    return FailPrompt("well-known has no m.homeserver.base_url")
  }
  if !is_base_url(hs) {
    return FailError("invalid homeserver base_url: \{hs}")
  }
  let identity_server = match base_url_of(m, "m.identity_server") {
    None => None
    Some(Some(is_url)) if is_base_url(is_url) => Some(trim_slash(is_url))
    Some(_) => return FailError("invalid m.identity_server.base_url")
  }
  Found(homeserver=trim_slash(hs), identity_server~)
}

///|
/// Spec versions and unstable features advertised by a homeserver.
pub struct Versions {
  versions : Array[String]
  unstable_features : Map[String, Bool]
} derive(Eq, Debug)

///|
pub fn Versions::supports(self : Versions, version : String) -> Bool {
  self.versions.contains(version)
}

///|
pub fn Versions::has_feature(self : Versions, feature : String) -> Bool {
  self.unstable_features.get(feature) is Some(true)
}

///|
pub fn versions_request() -> Request {
  Request::new(
    Get,
    path([Lit("_matrix"), Lit("client"), Lit("versions")]),
    auth=false,
  )
}

///|
/// Parses `/versions`. Discovery treats a failure here as FAIL_ERROR.
pub fn parse_versions(resp : Response) -> Versions raise ApiError {
  decode_ok(resp, m => {
    let root = @jsonx.root()
    let versions : Array[String] = @jsonx.decode(m, "versions", root)
    let unstable_features : Map[String, Bool] = match
      @jsonx.opt_decode(m, "unstable_features", root) {
      Some(f) => f
      None => Map([])
    }
    { versions, unstable_features, }
  })
}
