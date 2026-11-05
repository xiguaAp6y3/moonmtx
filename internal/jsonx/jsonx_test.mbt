///|
test "missing and null optional fields are None" {
  let m : Map[String, Json] = { "a": Json::null(), "s": "x", "n": 3, "b": true }
  let root = @jsonx.root()
  assert_eq(@jsonx.opt_string(m, "a", root), None)
  assert_eq(@jsonx.opt_string(m, "missing", root), None)
  assert_eq(@jsonx.opt_string(m, "s", root), Some("x"))
  assert_eq(@jsonx.opt_int(m, "n", root), Some(3L))
  assert_eq(@jsonx.opt_bool(m, "b", root), Some(true))
  assert_eq(@jsonx.array(m, "a", root), [])
}

///|
test "wrong types and non-integers are errors with a path" {
  let m : Map[String, Json] = { "s": 1, "f": 1.5, "big": 1700000000000.0 }
  let root = @jsonx.root()
  let msg = try @jsonx.opt_string(m, "s", root) catch {
    e => e.to_string()
  } noraise {
    _ => "no error"
  }
  assert_true(msg.contains("/s"), msg~)
  let r = try @jsonx.opt_int(m, "f", root) catch {
    _ => None
  } noraise {
    v => Some(v)
  }
  assert_eq(r, None)
  // Millisecond timestamps exceed Int32 and must survive as Int64.
  assert_eq(@jsonx.opt_int(m, "big", root), Some(1700000000000L))
}

///|
test "build drops None" {
  let j = @jsonx.build([("a", Some(Json::number(1.0))), ("b", None)])
  assert_eq(j, { "a": 1 })
}
