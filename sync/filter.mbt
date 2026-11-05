// `GET /sync` request and inline filters, Client-Server API v1.19
// "Syncing" and "Filtering".

///|
/// A subset of the filter language that a sync loop usually needs.
pub struct Filter {
  /// Maximum number of events per room timeline.
  timeline_limit : Int32?
  /// Only send membership events for senders the client has not seen.
  lazy_load_members : Bool
  /// Timeline event types to include; `None` means all.
  timeline_types : Array[String]?
  /// Timeline event types to exclude.
  timeline_not_types : Array[String]
  /// Rooms to include; `None` means all.
  rooms : Array[@ids.RoomId]?
} derive(Eq, Debug)

///|
pub fn Filter::new(
  timeline_limit? : Int32,
  lazy_load_members~ : Bool = false,
  timeline_types? : Array[String],
  timeline_not_types~ : Array[String] = [],
  rooms? : Array[@ids.RoomId],
) -> Filter {
  {
    timeline_limit,
    lazy_load_members,
    timeline_types,
    timeline_not_types,
    rooms,
  }
}

///|
fn strings(xs : Array[String]) -> Json {
  Json::array(xs.map(Json::string))
}

///|
pub impl ToJson for Filter with fn to_json(self) {
  let lazy_members = if self.lazy_load_members {
    Some(Json::boolean(true))
  } else {
    None
  }
  let timeline = @jsonx.build([
    ("limit", self.timeline_limit.map(l => Json::number(l.to_double()))),
    ("types", self.timeline_types.map(strings)),
    (
      "not_types",
      if self.timeline_not_types.is_empty() {
        None
      } else {
        Some(strings(self.timeline_not_types))
      },
    ),
    ("lazy_load_members", lazy_members),
  ])
  let state = @jsonx.build([("lazy_load_members", lazy_members)])
  @jsonx.build([
    (
      "room",
      Some(
        @jsonx.build([
          ("rooms", self.rooms.map(rs => Json::array(rs.map(r => r.to_json())))),
          ("timeline", Some(timeline)),
          ("state", Some(state)),
        ]),
      ),
    ),
  ])
}

///|
pub extend Filter with ToJson::{to_json}

///|
/// `POST /user/{userId}/filter`: uploads a filter and returns its ID via
/// `parse_filter_id`. Inline filters in `sync_request` avoid this step.
pub fn upload_filter_request(
  user_id : @ids.UserId,
  filter : Filter,
) -> @api.Request {
  @api.Request::new(
    Post,
    @api.client_v3([Lit("user"), Var(user_id.to_string()), Lit("filter")]),
    body=filter.to_json(),
  )
}

///|
pub fn parse_filter_id(resp : @api.Response) -> String raise @api.ApiError {
  @api.decode_ok(resp, m => @jsonx.string(m, "filter_id", @jsonx.root()))
}

///|
/// Which filter `sync_request` sends.
pub(all) enum FilterRef {
  Inline(Filter)
  Id(String)
}

///|
/// Builds `GET /sync`. Without `since` this is an initial sync. Use
/// `timeout_ms=0` for the initial sync and a long-poll timeout (e.g. 30000)
/// afterwards.
pub fn sync_request(
  since? : String,
  filter? : FilterRef,
  timeout_ms~ : Int32 = 0,
  full_state~ : Bool = false,
  set_presence? : String,
) -> @api.Request {
  let q = []
  if since is Some(s) {
    q.push(("since", s))
  }
  match filter {
    Some(Inline(f)) => q.push(("filter", f.to_json().stringify()))
    Some(Id(id)) => q.push(("filter", id))
    None => ()
  }
  q.push(("timeout", timeout_ms.to_string()))
  if full_state {
    q.push(("full_state", "true"))
  }
  if set_presence is Some(p) {
    q.push(("set_presence", p))
  }
  @api.Request::new(Get, @api.client_v3([Lit("sync")]), query=q)
}
