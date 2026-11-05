// Matrix identifier grammar, Matrix spec v1.19, appendix "Identifier Grammar".
//
// Parsing is lenient where the spec asks clients to be lenient: user IDs accept
// the historical character set, and room/event IDs are treated as opaque.

///|
/// Maximum length of any identifier, in UTF-8 bytes, including the sigil.
pub const MAX_ID_BYTES : Int32 = 255

///|
pub(all) suberror IdError {
  Empty
  BadSigil(expected~ : Char, input~ : String)
  TooLong(Int32)
  MissingServerName(String)
  InvalidServerName(String)
  InvalidLocalpart(String)
} derive(Eq, Debug)

///|
pub impl Show for IdError with fn output(self, logger) {
  let msg = match self {
    Empty => "empty identifier"
    BadSigil(expected~, input~) => "expected sigil '\{expected}': \{input}"
    TooLong(n) => "identifier is \{n} bytes, limit is \{MAX_ID_BYTES}"
    MissingServerName(s) => "missing server name: \{s}"
    InvalidServerName(s) => "invalid server name: \{s}"
    InvalidLocalpart(s) => "invalid localpart: \{s}"
  }
  logger.write_string(msg)
}

///|
fn utf8_len(s : StringView) -> Int32 {
  let mut n = 0
  for c in s {
    let cp = c.to_int()
    n += if cp < 0x80 {
      1
    } else if cp < 0x800 {
      2
    } else if cp < 0x10000 {
      3
    } else {
      4
    }
  }
  n
}

///|
fn check_len(s : String) -> Unit raise IdError {
  let n = utf8_len(s)
  if n > MAX_ID_BYTES {
    raise TooLong(n)
  }
}

///|
fn is_dns_char(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '-' ||
  c == '.'
}

///|
fn is_ipv6_char(c : Char) -> Bool {
  (c >= '0' && c <= '9') ||
  (c >= 'a' && c <= 'f') ||
  (c >= 'A' && c <= 'F') ||
  c == ':' ||
  c == '.'
}

///|
/// A server name: `hostname [ ":" port ]`, where the hostname is a DNS name,
/// an IPv4 literal, or a bracketed IPv6 literal.
pub struct ServerName {
  /// The host as written, including brackets for IPv6 literals.
  host : String
  port : Int32?
} derive(Eq, Hash, Debug)

///|
pub impl Show for ServerName with fn output(self, logger) {
  logger.write_string(self.host)
  if self.port is Some(p) {
    logger.write_char(':')
    logger.write_string(p.to_string())
  }
}

///|
fn parse_port(s : StringView, input : String) -> Int32 raise IdError {
  if s.length() < 1 || s.length() > 5 {
    raise InvalidServerName(input)
  }
  let mut v = 0
  for c in s {
    if c < '0' || c > '9' {
      raise InvalidServerName(input)
    }
    v = v * 10 + (c.to_int() - '0'.to_int())
  }
  v
}

///|
/// Parses a server name such as `example.org`, `1.2.3.4:8448` or `[::1]:8448`.
pub fn ServerName::parse(s : String) -> ServerName raise IdError {
  if s.is_empty() {
    raise InvalidServerName(s)
  }
  if s.has_prefix("[") {
    guard s.find("]") is Some(close) else { raise InvalidServerName(s) }
    let inner = s.view(start_offset=1, end_offset=close)
    if inner.length() < 2 || inner.length() > 45 {
      raise InvalidServerName(s)
    }
    for c in inner {
      if !is_ipv6_char(c) {
        raise InvalidServerName(s)
      }
    }
    let host = s.view(end_offset=close + 1).to_owned()
    let rest = s.view(start_offset=close + 1)
    if rest.is_empty() {
      return { host, port: None, }
    }
    guard rest.strip_prefix(":") is Some(port) else {
      raise InvalidServerName(s)
    }
    return { host, port: Some(parse_port(port, s)), }
  }
  let (host, port) = match s.split_once(":") {
    Some((h, p)) => (h, Some(parse_port(p, s)))
    None => (s.view(), None)
  }
  if host.is_empty() || host.length() > 255 {
    raise InvalidServerName(s)
  }
  for c in host {
    if !is_dns_char(c) {
      raise InvalidServerName(s)
    }
  }
  { host: host.to_owned(), port, }
}

///|
/// Splits `<sigil><localpart>:<server>` and validates the sigil, length and
/// server name. Returns the localpart and server.
fn split_qualified(
  s : String,
  sigil : Char,
) -> (String, ServerName) raise IdError {
  if s.is_empty() {
    raise Empty
  }
  if s.get_char(0) != Some(sigil) {
    raise BadSigil(expected=sigil, input=s)
  }
  check_len(s)
  guard s.find(":") is Some(colon) else { raise MissingServerName(s) }
  let localpart = s.view(start_offset=1, end_offset=colon).to_owned()
  let server = ServerName::parse(s.view(start_offset=colon + 1).to_owned())
  (localpart, server)
}

///|
/// A user ID: `@localpart:server`.
pub struct UserId {
  localpart : String
  server : ServerName
} derive(Eq, Hash, Debug)

///|
pub impl Show for UserId with fn output(self, logger) {
  logger.write_char('@')
  logger.write_string(self.localpart)
  logger.write_char(':')
  Show::output(self.server, logger)
}

///|
fn is_user_char(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= '0' && c <= '9') ||
  c == '.' ||
  c == '_' ||
  c == '=' ||
  c == '-' ||
  c == '/' ||
  c == '+'
}

///|
fn is_historical_user_char(c : Char) -> Bool {
  let cp = c.to_int()
  cp >= 0x21 && cp <= 0x7E && c != ':'
}

///|
/// Parses a user ID. Localparts from the historical character set (printable
/// ASCII except `:`) are accepted, as the spec requires clients to tolerate
/// them; use `is_compliant` to check against the current grammar.
pub fn UserId::parse(s : String) -> UserId raise IdError {
  let (localpart, server) = split_qualified(s, '@')
  if localpart.is_empty() {
    raise InvalidLocalpart(s)
  }
  for c in localpart {
    if !is_historical_user_char(c) {
      raise InvalidLocalpart(s)
    }
  }
  { localpart, server, }
}

///|
/// Builds a user ID from parts, validating it as `UserId::parse` does.
pub fn UserId::new(
  localpart : String,
  server : ServerName,
) -> UserId raise IdError {
  UserId::parse("@\{localpart}:\{server}")
}

///|
/// Whether the localpart uses only the characters allowed for new user IDs:
/// `a-z 0-9 . _ = - / +`.
pub fn UserId::is_compliant(self : UserId) -> Bool {
  for c in self.localpart {
    if !is_user_char(c) {
      return false
    }
  }
  true
}

///|
/// A room alias: `#alias:server`.
pub struct RoomAlias {
  localpart : String
  server : ServerName
} derive(Eq, Hash, Debug)

///|
pub impl Show for RoomAlias with fn output(self, logger) {
  logger.write_char('#')
  logger.write_string(self.localpart)
  logger.write_char(':')
  Show::output(self.server, logger)
}

///|
pub fn RoomAlias::parse(s : String) -> RoomAlias raise IdError {
  let (localpart, server) = split_qualified(s, '#')
  if localpart.is_empty() || localpart.contains_char('\u{0}') {
    raise InvalidLocalpart(s)
  }
  { localpart, server, }
}

///|
/// A room ID: `!opaque`. Room versions before 12 append `:server`; newer ones
/// do not, so the ID is kept opaque.
pub struct RoomId {
  raw : String
} derive(Eq, Hash, Compare, Debug)

///|
pub impl Show for RoomId with fn output(self, logger) {
  logger.write_string(self.raw)
}

///|
fn parse_opaque(s : String, sigil : Char) -> String raise IdError {
  if s.is_empty() {
    raise Empty
  }
  if s.get_char(0) != Some(sigil) {
    raise BadSigil(expected=sigil, input=s)
  }
  if s.length() < 2 {
    raise InvalidLocalpart(s)
  }
  check_len(s)
  s
}

///|
pub fn RoomId::parse(s : String) -> RoomId raise IdError {
  { raw: parse_opaque(s, '!'), }
}

///|
pub fn RoomId::as_str(self : RoomId) -> String {
  self.raw
}

///|
/// The server part of a room ID created before room version 12, if present
/// and well formed. Do not use it for routing; it is informational only.
pub fn RoomId::server_name(self : RoomId) -> ServerName? {
  guard self.raw.find(":") is Some(colon) else { return None }
  try
    ServerName::parse(self.raw.view(start_offset=colon + 1).to_owned())
  catch {
    _ => None
  } noraise {
    name => Some(name)
  }
}

///|
/// An event ID: `$opaque`.
pub struct EventId {
  raw : String
} derive(Eq, Hash, Compare, Debug)

///|
pub impl Show for EventId with fn output(self, logger) {
  logger.write_string(self.raw)
}

///|
pub fn EventId::parse(s : String) -> EventId raise IdError {
  { raw: parse_opaque(s, '$'), }
}

///|
pub fn EventId::as_str(self : EventId) -> String {
  self.raw
}

///|
fn decode_string(
  json : Json,
  path : @json.JsonPath,
) -> String raise @json.JsonDecodeError {
  guard json is String(s) else {
    raise @json.JsonDecodeError((path, "expected a string"))
  }
  s
}

///|
pub impl ToJson for ServerName with fn to_json(self) {
  Json::string(self.to_string())
}

///|
pub impl @json.FromJson for ServerName with fn from_json(json, path) {
  ServerName::parse(decode_string(json, path)) catch {
    e => raise @json.JsonDecodeError((path, e.to_string()))
  }
}

///|
pub impl ToJson for UserId with fn to_json(self) {
  Json::string(self.to_string())
}

///|
pub impl @json.FromJson for UserId with fn from_json(json, path) {
  UserId::parse(decode_string(json, path)) catch {
    e => raise @json.JsonDecodeError((path, e.to_string()))
  }
}

///|
pub impl ToJson for RoomAlias with fn to_json(self) {
  Json::string(self.to_string())
}

///|
pub impl @json.FromJson for RoomAlias with fn from_json(json, path) {
  RoomAlias::parse(decode_string(json, path)) catch {
    e => raise @json.JsonDecodeError((path, e.to_string()))
  }
}

///|
pub impl ToJson for RoomId with fn to_json(self) {
  Json::string(self.raw)
}

///|
pub impl @json.FromJson for RoomId with fn from_json(json, path) {
  RoomId::parse(decode_string(json, path)) catch {
    e => raise @json.JsonDecodeError((path, e.to_string()))
  }
}

///|
pub impl ToJson for EventId with fn to_json(self) {
  Json::string(self.raw)
}

///|
pub impl @json.FromJson for EventId with fn from_json(json, path) {
  EventId::parse(decode_string(json, path)) catch {
    e => raise @json.JsonDecodeError((path, e.to_string()))
  }
}

// Display strings are part of the public API: they are the wire form.

///|
pub extend ServerName with Show::{to_string}

///|
pub extend UserId with Show::{to_string}

///|
pub extend RoomAlias with Show::{to_string}

///|
pub extend RoomId with Show::{to_string}

///|
pub extend EventId with Show::{to_string}

///|
pub extend IdError with Show::{to_string}
