// Transport-neutral HTTP request and response descriptions.
//
// The SDK core never performs I/O. Endpoint functions return a `Request`; the
// caller sends it with any HTTP client and hands the `Response` back to the
// matching parser.

///|
pub(all) enum Method {
  Get
  Post
  Put
  Delete
} derive(Eq, Debug)

///|
pub fn Method::as_str(self : Method) -> String {
  match self {
    Get => "GET"
    Post => "POST"
    Put => "PUT"
    Delete => "DELETE"
  }
}

///|
/// A request relative to a homeserver base URL. `path` is already
/// percent-encoded; `query` values are encoded when the URL is built.
///
/// `Request` deliberately does not derive `Debug`: bodies may hold passwords
/// and tokens.
pub struct Request {
  verb : Method
  path : String
  query : Array[(String, String)]
  body : Json?
  /// Whether the access token must be sent in the `Authorization` header.
  auth : Bool
}

///|
/// One entry of a request path.
pub(all) enum Seg {
  /// A fixed path segment, written as is.
  Lit(String)
  /// A variable segment, percent-encoded as one URI component.
  Var(String)
}

///|
/// Joins segments into a path starting with `/`. `Var` segments are
/// percent-encoded so that IDs such as `!room:example.org` or event types
/// containing `/` stay a single segment.
pub fn path(segs : Array[Seg]) -> String {
  let sb = StringBuilder()
  for s in segs {
    sb.write_char('/')
    match s {
      Lit(l) => sb.write_string(l)
      Var(v) => sb.write_string(@percent.encode(v))
    }
  }
  sb.to_string()
}

///|
/// Path under the Client-Server API v3 prefix, `/_matrix/client/v3`.
pub fn client_v3(segs : Array[Seg]) -> String {
  path([Lit("_matrix"), Lit("client"), Lit("v3"), ..segs])
}

///|
pub fn Request::new(
  verb : Method,
  path : String,
  query~ : Array[(String, String)] = [],
  body? : Json,
  auth~ : Bool = true,
) -> Request {
  { verb, path, query, body, auth, }
}

///|
/// Full URL for this request against `base_url`, e.g.
/// `https://matrix.example.org`. A trailing `/` on the base is ignored.
pub fn Request::url(self : Request, base_url : String) -> String {
  let sb = StringBuilder()
  let base = match base_url.strip_suffix("/") {
    Some(b) => b
    None => base_url.view()
  }
  sb.write_view(base)
  sb.write_string(self.path)
  for i, kv in self.query {
    sb.write_char(if i == 0 { '?' } else { '&' })
    sb.write_string(@percent.encode(kv.0))
    sb.write_char('=')
    sb.write_string(@percent.encode(kv.1))
  }
  sb.to_string()
}

///|
/// Headers to send: `Authorization` when the request needs a token and one
/// is given, and `Content-Type` when there is a body.
pub fn Request::headers(
  self : Request,
  access_token? : String,
) -> Array[(String, String)] {
  let h = []
  if self.auth && access_token is Some(t) {
    h.push(("Authorization", "Bearer \{t}"))
  }
  if self.body is Some(_) {
    h.push(("Content-Type", "application/json"))
  }
  h
}

///|
/// The body serialised as JSON text, if any.
pub fn Request::body_text(self : Request) -> String? {
  self.body.map(b => b.stringify())
}

///|
/// An HTTP response as seen by the SDK.
pub struct Response {
  status : Int32
  body : String
  /// Value of the `Retry-After` header in seconds, if the transport saw one.
  retry_after_s : Int32?
} derive(Debug)

///|
pub fn Response::new(
  status : Int32,
  body : String,
  retry_after_s? : Int32,
) -> Response {
  { status, body, retry_after_s, }
}
