// Standard error responses, Client-Server API v1.19 "Standard error response".

///|
pub const M_FORBIDDEN : String = "M_FORBIDDEN"

///|
pub const M_UNKNOWN_TOKEN : String = "M_UNKNOWN_TOKEN"

///|
pub const M_MISSING_TOKEN : String = "M_MISSING_TOKEN"

///|
pub const M_BAD_JSON : String = "M_BAD_JSON"

///|
pub const M_NOT_JSON : String = "M_NOT_JSON"

///|
pub const M_NOT_FOUND : String = "M_NOT_FOUND"

///|
pub const M_LIMIT_EXCEEDED : String = "M_LIMIT_EXCEEDED"

///|
pub const M_UNRECOGNIZED : String = "M_UNRECOGNIZED"

///|
pub const M_UNKNOWN : String = "M_UNKNOWN"

///|
/// A Matrix error body `{"errcode": ..., "error": ...}` with the HTTP status.
pub struct MatrixError {
  status : Int32
  errcode : String
  error : String
  /// `retry_after_ms` from the body, sent with `M_LIMIT_EXCEEDED`.
  retry_after_ms : Int64?
  /// `soft_logout` from the body, sent with `M_UNKNOWN_TOKEN`.
  soft_logout : Bool
  /// The whole error object, for fields this type does not model.
  raw : Map[String, Json]
} derive(Eq, Debug)

///|
pub(all) suberror ApiError {
  /// The server answered with a standard Matrix error body.
  Matrix(MatrixError)
  /// A non-2xx status without a Matrix error body.
  Http(status~ : Int32, body~ : String)
  /// A 2xx response whose body could not be decoded.
  Decode(String)
} derive(Eq, Debug)

///|
pub impl Show for ApiError with fn output(self, logger) {
  let msg = match self {
    Matrix(e) => "\{e.status} \{e.errcode}: \{e.error}"
    Http(status~, body~) => "HTTP \{status}: \{body}"
    Decode(m) => "bad response: \{m}"
  }
  logger.write_string(msg)
}

///|
pub extend ApiError with Show::{to_string}

///|
pub fn MatrixError::is_rate_limited(self : MatrixError) -> Bool {
  self.status == 429 || self.errcode == M_LIMIT_EXCEEDED
}

///|
/// Whether the access token is no longer valid. With `soft_logout` the
/// client may log in again on the same device and keep its local state.
pub fn MatrixError::is_unknown_token(self : MatrixError) -> Bool {
  self.errcode == M_UNKNOWN_TOKEN
}

///|
fn parse_matrix_error(status : Int32, body : String) -> MatrixError? {
  let json = @json.parse(body) catch { _ => return None }
  guard json is Object(m) else { return None }
  guard m.get("errcode") is Some(String(errcode)) else { return None }
  let error = match m.get("error") {
    Some(String(e)) => e
    _ => ""
  }
  let retry_after_ms = match m.get("retry_after_ms") {
    Some(Number(d, ..)) => Some(d.to_int64())
    _ => None
  }
  let soft_logout = m.get("soft_logout") is Some(True)
  Some({ status, errcode, error, retry_after_ms, soft_logout, raw: m, })
}

///|
/// How long to wait before retrying a rate-limited request, in milliseconds.
/// The `Retry-After` header takes precedence over the body field, as the
/// spec deprecates `retry_after_ms` in its favour.
pub fn retry_delay_ms(resp : Response) -> Int64? {
  if resp.retry_after_s is Some(s) {
    return Some(s.to_int64() * 1000L)
  }
  parse_matrix_error(resp.status, resp.body).bind(e => e.retry_after_ms)
}

///|
/// Checks the status and returns the decoded JSON object of a successful
/// response. An empty 2xx body decodes as `{}`.
pub fn expect_ok(resp : Response) -> Map[String, Json] raise ApiError {
  if resp.status < 200 || resp.status >= 300 {
    match parse_matrix_error(resp.status, resp.body) {
      Some(e) => raise Matrix(e)
      None => raise Http(status=resp.status, body=resp.body)
    }
  }
  if resp.body.is_empty() {
    return Map([])
  }
  let json = @json.parse(resp.body) catch { e => raise Decode(e.to_string()) }
  guard json is Object(m) else { raise Decode("expected a JSON object") }
  m
}

///|
/// Runs a decoder over a successful response and maps decode failures to
/// `ApiError::Decode`.
pub fn[T] decode_ok(
  resp : Response,
  f : (Map[String, Json]) -> T raise @json.JsonDecodeError,
) -> T raise ApiError {
  let m = expect_ok(resp)
  f(m) catch {
    e => raise Decode(e.to_string())
  }
}
