// Small helpers for hand-written JSON decoders.
//
// Matrix payloads add fields over time, so decoders read the keys they need
// and ignore the rest. Missing optional keys and explicit `null` both decode
// to `None`; a key that is present with the wrong type is an error.

///|
pub fn[T] fail(
  path : @json.JsonPath,
  msg : String,
) -> T raise @json.JsonDecodeError {
  raise @json.JsonDecodeError((path, msg))
}

///|
pub fn object(
  json : Json,
  path : @json.JsonPath,
) -> Map[String, Json] raise @json.JsonDecodeError {
  guard json is Object(m) else { fail(path, "expected an object") }
  m
}

///|
fn present(m : Map[String, Json], key : String) -> Json? {
  match m.get(key) {
    None | Some(Null) => None
    v => v
  }
}

///|
pub fn opt_string(
  m : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> String? raise @json.JsonDecodeError {
  match present(m, key) {
    None => None
    Some(String(s)) => Some(s)
    Some(_) => fail(path.add_key(key), "expected a string")
  }
}

///|
pub fn string(
  m : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> String raise @json.JsonDecodeError {
  guard opt_string(m, key, path) is Some(s) else {
    fail(path.add_key(key), "missing required string")
  }
  s
}

///|
pub fn opt_int(
  m : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> Int64? raise @json.JsonDecodeError {
  match present(m, key) {
    None => None
    Some(Number(d, ..)) => {
      let i = d.to_int64()
      if i.to_double() != d {
        fail(path.add_key(key), "expected an integer")
      }
      Some(i)
    }
    Some(_) => fail(path.add_key(key), "expected a number")
  }
}

///|
pub fn int(
  m : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> Int64 raise @json.JsonDecodeError {
  guard opt_int(m, key, path) is Some(i) else {
    fail(path.add_key(key), "missing required integer")
  }
  i
}

///|
pub fn opt_bool(
  m : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> Bool? raise @json.JsonDecodeError {
  match present(m, key) {
    None => None
    Some(True) => Some(true)
    Some(False) => Some(false)
    Some(_) => fail(path.add_key(key), "expected a boolean")
  }
}

///|
pub fn opt_object(
  m : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> Map[String, Json]? raise @json.JsonDecodeError {
  match present(m, key) {
    None => None
    Some(Object(o)) => Some(o)
    Some(_) => fail(path.add_key(key), "expected an object")
  }
}

///|
/// An array field; missing or `null` decodes to an empty array.
pub fn array(
  m : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> Array[Json] raise @json.JsonDecodeError {
  match present(m, key) {
    None => []
    Some(Array(a)) => a
    Some(_) => fail(path.add_key(key), "expected an array")
  }
}

///|
/// Decodes an optional field with its `FromJson` implementation.
pub fn[T : @json.FromJson] opt_decode(
  m : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> T? raise @json.JsonDecodeError {
  match present(m, key) {
    None => None
    Some(v) => Some(@json.FromJson::from_json(v, path.add_key(key)))
  }
}

///|
pub fn[T : @json.FromJson] decode(
  m : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> T raise @json.JsonDecodeError {
  guard present(m, key) is Some(v) else {
    fail(path.add_key(key), "missing required field")
  }
  @json.FromJson::from_json(v, path.add_key(key))
}

///|
/// Builds a JSON object, dropping `None` values.
pub fn build(fields : Array[(String, Json?)]) -> Json {
  let m : Map[String, Json] = Map([])
  for f in fields {
    if f.1 is Some(v) {
      m[f.0] = v
    }
  }
  Json::object(m)
}

///|
priv struct PathGrab(@json.JsonPath)

///|
impl @json.FromJson for PathGrab with fn from_json(_, path) {
  PathGrab(path)
}

///|
/// The root JSON path. `@json.JsonPath` has no public constructor, so it is
/// taken from the default argument of `@json.from_json`.
pub fn root() -> @json.JsonPath {
  let g : PathGrab = @json.from_json(Json::null()) catch { _ => panic() }
  g.0
}
