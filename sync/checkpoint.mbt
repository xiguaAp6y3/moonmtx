// Store snapshots.
//
// A snapshot holds the sync token and all room state in one JSON document.
// Write it with one atomic operation (e.g. write a temporary file and
// rename it) so the token never gets ahead of the state it belongs to.

///|
/// Snapshot format version written by `Store::to_json`.
pub const SNAPSHOT_VERSION : Int32 = 1

///|
fn events_json(es : Array[@events.Event]) -> Json {
  Json::array(es.map(e => e.to_json()))
}

///|
fn stripped_map_json(
  m : Map[@ids.RoomId, Array[@events.StrippedState]],
) -> Json {
  let out : Map[String, Json] = Map([])
  for id, s in m {
    out[id.as_str()] = Json::array(s.map(x => x.to_json()))
  }
  Json::object(out)
}

///|
fn int_json(i : Int64) -> Json {
  Json::number(i.to_double())
}

///|
fn Room::to_json(self : Room) -> Json {
  let state = []
  for _, by_key in self.state {
    for _, e in by_key {
      state.push(e)
    }
  }
  let chunks = self.chunks.map(c => {
    @jsonx.build([
      ("prev_batch", c.prev_batch.map(Json::string)),
      ("gap_before", Some(Json::boolean(c.gap_before))),
      ("events", Some(events_json(c.events))),
    ])
  })
  @jsonx.build([
    ("membership", Some(Json::string(self.membership.as_str()))),
    ("state", Some(events_json(state))),
    ("chunks", Some(Json::array(chunks))),
    ("recent", Some(Json::array(self.recent.map(Json::string)))),
    ("account_data", Some(Json::object(self.account_data))),
    ("ephemeral", Some(Json::object(self.ephemeral))),
    ("heroes", Some(Json::array(self.heroes.map(Json::string)))),
    ("joined_count", self.joined_count.map(int_json)),
    ("invited_count", self.invited_count.map(int_json)),
    ("notification_count", Some(int_json(self.notification_count))),
    ("highlight_count", Some(int_json(self.highlight_count))),
  ])
}

///|
/// Serialises the whole store, including the sync token. Restore with
/// `Store::from_json`.
pub impl ToJson for Store with fn to_json(self) {
  let rooms : Map[String, Json] = Map([])
  for id, r in self.rooms {
    rooms[id.as_str()] = r.to_json()
  }
  @jsonx.build([
    ("version", Some(Json::number(SNAPSHOT_VERSION.to_double()))),
    ("next_batch", self.next_batch.map(Json::string)),
    ("timeline_cap", Some(Json::number(self.timeline_cap.to_double()))),
    ("account_data", Some(Json::object(self.account_data))),
    ("rooms", Some(Json::object(rooms))),
    ("invites", Some(stripped_map_json(self.invites))),
    ("knocks", Some(stripped_map_json(self.knocks))),
  ])
}

///|
pub extend Store with ToJson::{to_json}

///|
fn decode_events(
  m : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> Array[@events.Event] raise @json.JsonDecodeError {
  let p = path.add_key(key)
  @jsonx.array(m, key, path).mapi((i, j) => {
    @events.Event::decode(j, p.add_index(i))
  })
}

///|
fn decode_strings(
  m : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> Array[String] raise @json.JsonDecodeError {
  @jsonx.opt_decode(m, key, path).unwrap_or([])
}

///|
fn decode_room(
  room_id : @ids.RoomId,
  m : Map[String, Json],
  path : @json.JsonPath,
) -> Room raise @json.JsonDecodeError {
  let room = Room::new(room_id)
  room.membership = @events.Membership::parse(
    @jsonx.string(m, "membership", path),
  )
  for e in decode_events(m, "state", path) {
    room.set_state(e)
  }
  let cp = path.add_key("chunks")
  for i, c in @jsonx.array(m, "chunks", path) {
    let p = cp.add_index(i)
    let o = @jsonx.object(c, p)
    room.chunks.push({
      prev_batch: @jsonx.opt_string(o, "prev_batch", p),
      gap_before: @jsonx.opt_bool(o, "gap_before", p).unwrap_or(false),
      events: decode_events(o, "events", p),
    })
  }
  for id in decode_strings(m, "recent", path) {
    room.seen[id] = ()
    room.recent.push(id)
  }
  for k, v in @jsonx.opt_object(m, "account_data", path).unwrap_or(Map([])) {
    room.account_data[k] = v
  }
  for k, v in @jsonx.opt_object(m, "ephemeral", path).unwrap_or(Map([])) {
    room.ephemeral[k] = v
  }
  room.heroes = decode_strings(m, "heroes", path)
  room.joined_count = @jsonx.opt_int(m, "joined_count", path)
  room.invited_count = @jsonx.opt_int(m, "invited_count", path)
  room.notification_count = @jsonx.opt_int(m, "notification_count", path).unwrap_or(
    0,
  )
  room.highlight_count = @jsonx.opt_int(m, "highlight_count", path).unwrap_or(0)
  room
}

///|
fn decode_stripped_map(
  m : Map[String, Json],
  key : String,
  path : @json.JsonPath,
  into : Map[@ids.RoomId, Array[@events.StrippedState]],
) -> Unit raise @json.JsonDecodeError {
  let p = path.add_key(key)
  for id, v in @jsonx.opt_object(m, key, path).unwrap_or(Map([])) {
    let room_id : @ids.RoomId = @json.from_json(Json::string(id), path=p)
    into[room_id] = @json.from_json(v, path=p.add_key(id))
  }
}

///|
fn decode_store(json : Json) -> Store raise @json.JsonDecodeError {
  let root = @jsonx.root()
  let m = @jsonx.object(json, root)
  let version = @jsonx.int(m, "version", root)
  if version != SNAPSHOT_VERSION.to_int64() {
    @jsonx.fail(root.add_key("version"), "unsupported version \{version}")
  }
  let cap = @jsonx.opt_int(m, "timeline_cap", root).unwrap_or(200)
  let store = Store::new(timeline_cap=cap.to_int())
  store.next_batch = @jsonx.opt_string(m, "next_batch", root)
  for k, v in @jsonx.opt_object(m, "account_data", root).unwrap_or(Map([])) {
    store.account_data[k] = v
  }
  let rp = root.add_key("rooms")
  for id, v in @jsonx.opt_object(m, "rooms", root).unwrap_or(Map([])) {
    let p = rp.add_key(id)
    let room_id : @ids.RoomId = @json.from_json(Json::string(id), path=p)
    store.rooms[room_id] = decode_room(room_id, @jsonx.object(v, p), p)
  }
  decode_stripped_map(m, "invites", root, store.invites)
  decode_stripped_map(m, "knocks", root, store.knocks)
  store
}

///|
/// Restores a store from `Store::to_json` output.
pub fn Store::from_json(json : Json) -> Store raise StoreError {
  decode_store(json) catch {
    e => raise BadSnapshot(e.to_string())
  }
}
