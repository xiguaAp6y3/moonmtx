// The sync state store.
//
// `Store::apply` folds a `/sync` response into room state and the stored
// timeline, and advances the sync token in the same step. The token and the
// state are serialised together by `Store::to_json`, so a client that
// persists the snapshot as one write and resumes from `Store::since` never
// skips events. If it crashes before persisting, it syncs again from the
// older token; the server sends the same events again and the store drops
// the ones it has already seen.

///|
/// What one `Store::apply` changed in a room.
pub struct RoomUpdate {
  room_id : @ids.RoomId
  membership : @events.Membership
  /// Timeline events not seen before, oldest first.
  events : Array[@events.Event]
  /// Set when the timeline was `limited`: events are missing before
  /// `events`. Pass to `messages_request` and then `Store::fill_gap`.
  gap : String?
} derive(Eq, Debug)

///|
pub struct SyncSummary {
  next_batch : String
  rooms : Array[RoomUpdate]
  /// Rooms with a new or updated invite.
  invited : Array[@ids.RoomId]
  /// Entries skipped while parsing the response.
  invalid : Array[String]
} derive(Eq, Debug)

///|
pub(all) suberror StoreError {
  UnknownRoom(@ids.RoomId)
  /// The page does not continue any gap or the start of the timeline.
  StaleToken(String)
  BadSnapshot(String)
} derive(Eq, Debug)

///|
pub impl Show for StoreError with fn output(self, logger) {
  let msg = match self {
    UnknownRoom(r) => "unknown room \{r}"
    StaleToken(t) => "no gap or timeline start matches token \{t}"
    BadSnapshot(m) => "bad snapshot: \{m}"
  }
  logger.write_string(msg)
}

///|
pub extend StoreError with Show::{to_string}

///|
pub struct Store {
  priv mut next_batch : String?
  priv rooms : Map[@ids.RoomId, Room]
  priv invites : Map[@ids.RoomId, Array[@events.StrippedState]]
  priv knocks : Map[@ids.RoomId, Array[@events.StrippedState]]
  priv account_data : Map[String, Json]
  /// Rooms keep at least this many timeline events; older chunks are
  /// dropped whole.
  priv timeline_cap : Int32
}

///|
pub fn Store::new(timeline_cap~ : Int32 = 200) -> Store {
  {
    next_batch: None,
    rooms: Map([]),
    invites: Map([]),
    knocks: Map([]),
    account_data: Map([]),
    timeline_cap,
  }
}

///|
/// The token for the next `/sync`; `None` before the first sync.
pub fn Store::since(self : Store) -> String? {
  self.next_batch
}

///|
pub fn Store::room(self : Store, room_id : @ids.RoomId) -> Room? {
  self.rooms.get(room_id)
}

///|
/// Known rooms, in the order they were first seen.
pub fn Store::rooms(self : Store) -> Array[Room] {
  self.rooms.values().to_array()
}

///|
pub fn Store::invites(
  self : Store,
) -> Map[@ids.RoomId, Array[@events.StrippedState]] {
  self.invites
}

///|
pub fn Store::knocks(
  self : Store,
) -> Map[@ids.RoomId, Array[@events.StrippedState]] {
  self.knocks
}

///|
/// Global account data content of `event_type`, e.g. `m.direct`.
pub fn Store::account_data(self : Store, event_type : String) -> Json? {
  self.account_data.get(event_type)
}

///|
/// Folds `{type, content}` objects into a map, keeping the latest.
fn merge_typed(into : Map[String, Json], items : Array[Json]) -> Unit {
  for item in items {
    if item is Object(o) && o.get("type") is Some(String(t)) {
      into[t] = o.get("content").unwrap_or(Json::empty_object())
    }
  }
}

///|
fn Room::apply_state(self : Room, state : Array[@events.Event]) -> Unit {
  for e in state {
    // An already-seen state event is either a repeat of what is stored or
    // older than it; applying it again could only move state backwards.
    if !self.has_seen(e.event_id) {
      self.mark_seen(e.event_id)
      self.set_state(e)
    }
  }
}

///|
/// Appends a sync timeline. Returns the new events and the gap token, if a
/// gap was opened.
fn Room::apply_timeline(
  self : Room,
  tl : Timeline,
) -> (Array[@events.Event], String?) {
  let fresh = tl.events.filter(e => !self.has_seen(e.event_id))
  if fresh.is_empty() {
    if self.chunks.is_empty() {
      self.chunks.push({
        prev_batch: tl.prev_batch,
        gap_before: false,
        events: [],
      })
    }
    return ([], None)
  }
  // A limited timeline whose first event is already stored is a repeat of
  // an applied response, not a gap.
  let first_known = self.has_seen(tl.events[0].event_id)
  let gap = tl.limited && !first_known && !self.chunks.is_empty()
  let chunk : Chunk = if self.chunks.is_empty() ||
    gap ||
    tl.prev_batch is Some(_) {
    let c = { prev_batch: tl.prev_batch, gap_before: gap, events: [], }
    self.chunks.push(c)
    c
  } else {
    self.chunks[self.chunks.length() - 1]
  }
  for e in fresh {
    self.mark_seen(e.event_id)
    chunk.events.push(e)
    if e.is_state() {
      self.set_state(e)
    }
  }
  for e in fresh {
    if e.kind_str == "m.room.redaction" {
      self.apply_redaction(e)
    }
  }
  (fresh, if gap { tl.prev_batch } else { None })
}

///|
/// Drops whole chunks from the front while at least `cap` events remain.
fn Room::trim(self : Room, cap : Int32) -> Unit {
  let mut total = 0
  for c in self.chunks {
    total += c.events.length()
  }
  while self.chunks.length() > 1 &&
        total - self.chunks[0].events.length() >= cap {
    total -= self.chunks[0].events.length()
    ignore(self.chunks.remove(0))
  }
  if self.chunks.get(0) is Some(front) {
    front.gap_before = false
  }
}

///|
fn Store::room_or_new(self : Store, room_id : @ids.RoomId) -> Room {
  self.rooms.get_or_init(room_id, () => Room::new(room_id))
}

///|
/// Applies a `/sync` response and advances the sync token. Applying the
/// response that produced the current token again changes nothing.
pub fn Store::apply(self : Store, resp : SyncResponse) -> SyncSummary {
  let summary = {
    next_batch: resp.next_batch,
    rooms: [],
    invited: [],
    invalid: resp.invalid,
  }
  if self.next_batch == Some(resp.next_batch) {
    return summary
  }
  merge_typed(self.account_data, resp.account_data)
  for j in resp.join {
    let room = self.room_or_new(j.room_id)
    room.membership = Join
    self.invites.remove(j.room_id)
    self.knocks.remove(j.room_id)
    if j.summary.heroes is Some(h) {
      room.heroes = h
    }
    if j.summary.joined_member_count is Some(n) {
      room.joined_count = Some(n)
    }
    if j.summary.invited_member_count is Some(n) {
      room.invited_count = Some(n)
    }
    if j.notification_count is Some(n) {
      room.notification_count = n
    }
    if j.highlight_count is Some(n) {
      room.highlight_count = n
    }
    room.apply_state(j.state)
    let (events, gap) = room.apply_timeline(j.timeline)
    merge_typed(room.ephemeral, j.ephemeral)
    merge_typed(room.account_data, j.account_data)
    room.trim(self.timeline_cap)
    summary.rooms.push({ room_id: j.room_id, membership: Join, events, gap, })
  }
  for l in resp.leave {
    let room = self.room_or_new(l.room_id)
    room.membership = Leave
    self.invites.remove(l.room_id)
    self.knocks.remove(l.room_id)
    room.apply_state(l.state)
    let (events, gap) = room.apply_timeline(l.timeline)
    merge_typed(room.account_data, l.account_data)
    room.trim(self.timeline_cap)
    summary.rooms.push({ room_id: l.room_id, membership: Leave, events, gap, })
  }
  for i in resp.invite {
    self.invites[i.room_id] = i.invite_state
    summary.invited.push(i.room_id)
  }
  for k in resp.knock {
    self.knocks[k.room_id] = k.knock_state
  }
  self.next_batch = Some(resp.next_batch)
  summary
}
