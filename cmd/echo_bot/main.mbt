// Echo bot: replies to `!echo <text>` in every joined room.
//
//   MATRIX_HOMESERVER=https://matrix.example.org \
//   MATRIX_USER=@bot:example.org MATRIX_PASSWORD=... \
//   moon run --target native cmd/echo_bot
//
// With MATRIX_STATE=<file>, the session and the sync snapshot are saved
// there after every sync and the bot resumes from it on the next start,
// without logging in again or answering old messages. The file holds the
// access token; it is written with mode 0600.

///|
fn env(name : String) -> String raise {
  match @env.get_env_var(name) {
    Some(v) if !v.is_empty() => v
    _ => fail("missing environment variable \{name}")
  }
}

///|
async fn save(path : String, session : @api.Session, snapshot : Json) -> Unit {
  let doc : Json = { "session": session.to_json(), "client": snapshot }
  let tmp = path + ".tmp"
  @fs.write_file(
    tmp,
    doc.stringify(),
    create_mode=CreateOrTruncate,
    permission=0o600,
  )
  @fs.rename(tmp, path, replace=true)
}

///|
async fn load(homeserver : String, path : String) -> @client.Client? {
  if !@fs.exists(path) {
    return None
  }
  let doc = @fs.read_file(path).json()
  guard doc is Object(m) &&
    m.get("session") is Some(s) &&
    m.get("client") is Some(snap) else {
    return None
  }
  let session : @api.Session = @json.from_json(s)
  Some(@client.Client::restore(homeserver, session, snap))
}

///|
async fn login(homeserver : String) -> @client.Client {
  let user = env("MATRIX_USER")
  let req = @api.login_request(
    Password(User(user), password=env("MATRIX_PASSWORD")),
    initial_device_display_name="moonmtx echo bot",
  )
  let session = @api.parse_login(@transport.request(homeserver, req))
  println("logged in as \{session.user_id} on device \{session.device_id}")
  @client.Client::new(homeserver, session)
}

///|
async fn main {
  let homeserver = env("MATRIX_HOMESERVER")
  let state = @env.get_env_var("MATRIX_STATE")
  let restored = match state {
    Some(p) => load(homeserver, p)
    None => None
  }
  let c = match restored {
    Some(c) => {
      println("resuming from \{state.unwrap()}")
      c
    }
    None => login(homeserver)
  }
  let me = c.user_id().to_string()
  // History from the first sync is not answered.
  let mut live = c.store.since() is Some(_)
  let persist = match state {
    Some(p) => Some(async fn(snap : Json) { save(p, c.session(), snap) })
    None => None
  }
  @transport.run_sync_loop(
    c,
    summary => {
      if live {
        for r in summary.rooms {
          for e in r.events {
            guard e.sender != me && e.kind() is Message(m) else { continue }
            if m.body.strip_prefix("!echo ") is Some(text) {
              let reply = @events.notice(text.to_owned()).reply_to(e.event_id)
              ignore(c.send_message(r.room_id, reply))
            }
          }
        }
      }
      live = true
      true
    },
    persist?,
  )
}
