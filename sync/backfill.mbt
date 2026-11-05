// History pagination with `GET /rooms/{roomId}/messages`, used both to fill
// gaps left by limited sync timelines and to load older history.

///|
/// Builds a backwards `GET /rooms/{roomId}/messages` from `from`, which is a
/// gap token or `Room::back_token`.
pub fn messages_request(
  room_id : @ids.RoomId,
  from : String,
  limit~ : Int32 = 50,
  filter? : Filter,
) -> @api.Request {
  let q = [("from", from), ("dir", "b"), ("limit", limit.to_string())]
  if filter is Some(f) {
    q.push(("filter", f.to_json().stringify()))
  }
  @api.Request::new(
    Get,
    @api.client_v3([Lit("rooms"), Var(room_id.as_str()), Lit("messages")]),
    query=q,
  )
}

///|
/// A page of `/messages`, as sent: for backwards pagination `chunk` is
/// newest first.
pub struct Messages {
  /// Echoes the `from` token of the request.
  start : String
  /// Token for the next page; `None` when there is no more history.
  end : String?
  chunk : Array[@events.Event]
  /// State needed to display `chunk`, e.g. lazy-loaded members.
  state : Array[@events.Event]
  invalid : Array[String]
} derive(Eq, Debug)

///|
pub fn parse_messages(resp : @api.Response) -> Messages raise @api.ApiError {
  @api.decode_ok(resp, m => {
    let root = @jsonx.root()
    let ctx = { invalid: [], }
    {
      start: @jsonx.string(m, "start", root),
      end: @jsonx.opt_string(m, "end", root),
      chunk: ctx.each(
        @jsonx.array(m, "chunk", root),
        root.add_key("chunk"),
        @events.Event::decode,
      ),
      state: ctx.each(
        @jsonx.array(m, "state", root),
        root.add_key("state"),
        @events.Event::decode,
      ),
      invalid: ctx.invalid,
    }
  })
}

///|
/// Lazy-loaded state from a page fills in members the store does not have;
/// it never replaces newer state.
fn Room::apply_page_state(self : Room, state : Array[@events.Event]) -> Unit {
  for e in state {
    guard e.state_key is Some(key) else { continue }
    if self.state_event(e.kind_str, state_key=key) is None {
      self.mark_seen(e.event_id)
      self.set_state(e)
    }
  }
}

///|
/// IDs of the events stored in `chunks[from:to]`.
fn Room::stored_ids(self : Room, from : Int32, to : Int32) -> Map[String, Unit] {
  let out : Map[String, Unit] = Map([])
  for c in self.chunks[from:to] {
    for e in c.events {
      out[e.event_id.as_str()] = ()
    }
  }
  out
}

///|
/// Events of a backwards page, oldest first. Stops at the first event in
/// `stop_at` and skips events in `skip`. Overlap is decided from the stored
/// timeline, not from the de-duplication ring: the ring also holds state
/// events and events that trimming dropped, which a page must not hide.
fn Room::take_page(
  self : Room,
  page : Messages,
  stop_at~ : Map[String, Unit],
  skip~ : Map[String, Unit],
) -> (Array[@events.Event], Bool) {
  let out = []
  let mut hit_known = false
  for e in page.chunk {
    let id = e.event_id.as_str()
    if stop_at.contains(id) {
      hit_known = true
      break
    }
    if !skip.contains(id) {
      out.push(e)
    }
  }
  let out = out.rev()
  for e in out {
    self.mark_seen(e.event_id)
  }
  for e in out {
    if e.kind_str == "m.room.redaction" {
      self.apply_redaction(e)
    }
  }
  (out, hit_known)
}

///|
/// Applies a page fetched with a gap token. Returns the recovered events,
/// oldest first. The gap is closed when the page reaches an event stored
/// before the gap or the start of the room; otherwise it moves back and
/// `Room::gaps` returns the token for the next page.
pub fn Store::fill_gap(
  self : Store,
  room_id : @ids.RoomId,
  page : Messages,
) -> Array[@events.Event] raise StoreError {
  guard self.rooms.get(room_id) is Some(room) else {
    raise UnknownRoom(room_id)
  }
  let idx = for i, c in room.chunks {
    if i > 0 && c.gap_before && c.prev_batch == Some(page.start) {
      break i
    }
  } nobreak {
    raise StaleToken(page.start)
  }
  room.apply_page_state(page.state)
  let n = room.chunks.length()
  let (events, hit_known) = room.take_page(
    page,
    stop_at=room.stored_ids(0, idx),
    skip=room.stored_ids(idx, n),
  )
  let after = room.chunks[idx]
  if hit_known || page.end is None {
    // Contiguous with the chunk before the gap: append there and join up.
    let before = room.chunks[idx - 1]
    before.events.append(events)
    after.gap_before = false
  } else if !events.is_empty() {
    room.chunks.insert(idx, { prev_batch: page.end, gap_before: true, events, })
    after.gap_before = false
  } else {
    after.prev_batch = page.end
  }
  events
}

///|
/// Applies a page fetched with `Room::back_token`, prepending older history.
/// Returns the new events, oldest first.
pub fn Store::paginate_back(
  self : Store,
  room_id : @ids.RoomId,
  page : Messages,
) -> Array[@events.Event] raise StoreError {
  guard self.rooms.get(room_id) is Some(room) else {
    raise UnknownRoom(room_id)
  }
  guard room.chunks.get(0) is Some(front) &&
    front.prev_batch == Some(page.start) else {
    raise StaleToken(page.start)
  }
  room.apply_page_state(page.state)
  let (events, _) = room.take_page(
    page,
    stop_at=Map([]),
    skip=room.stored_ids(0, room.chunks.length()),
  )
  if events.is_empty() {
    front.prev_batch = page.end
  } else {
    room.chunks.insert(0, { prev_batch: page.end, gap_before: false, events, })
  }
  events
}
