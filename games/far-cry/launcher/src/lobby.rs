// Lobby before the game: the host's launcher listens on TCP 49002, friends' launchers connect to
// it. One JSON object per line.
//   client -> host: {"t":"me","me":{"name","color","weapons"}} whenever the player changes them
//   host -> all:    {"t":"state","players":[me...],"map","loadout"} after every change
//                   {"t":"start"} everyone starts the game, the host loads the map
//                   {"t":"go"}    the host's server is up (UDP 49001 taken): clients connect
// The UI gets every state as the "lobby" event; {"t":"closed"} when the host is gone.
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Emitter};

pub const PORT: u16 = 49002;

struct Lobby {
    host: bool,
    players: Vec<(u32, Value)>, // the host is id 0
    conns: Vec<(u32, TcpStream)>, // host: the clients; client: the host (id 0)
    map: String,
    loadout: bool,
    next_id: u32,
    host_ip: String,
    started: bool, // "start" happens once; a client acts on "go" only after it
    game: u32,     // client: pid of the game it started, which gets the "connect" line
}

static LOBBY: Mutex<Option<Lobby>> = Mutex::new(None);

// a player as the host accepts it: the name is shown to everyone, the rest goes to prefs.lua
pub fn clean_me(me: &Value) -> Value {
    let name = clean_name(me["name"].as_str().unwrap_or(""));
    let color = me["color"].as_u64().filter(|c| *c <= 9).unwrap_or(1);
    let weapons: Vec<&str> = me["weapons"]
        .as_array()
        .map(|a| a.iter().filter_map(|w| w.as_str()).filter(|w| crate::WEAPONS.contains(w)).take(4).collect())
        .unwrap_or_default();
    let difficulty = me["difficulty"].as_u64().filter(|d| *d <= 4).unwrap_or(1);
    json!({ "name": name, "color": color, "weapons": weapons, "difficulty": difficulty })
}

// a player name the game can take: it goes into a console line (p_name, a Lua string) and the
// game font has Latin letters only. Printable ASCII without quotes, `;`, `#`, `%` and backslash,
// Cyrillic transliterated, anything else dropped; up to 24 characters, "Player" if nothing is left
pub fn clean_name(s: &str) -> String {
    const RU: [&str; 32] = [
        "a", "b", "v", "g", "d", "e", "zh", "z", "i", "y", "k", "l", "m", "n", "o", "p",
        "r", "s", "t", "u", "f", "kh", "ts", "ch", "sh", "sch", "", "y", "", "e", "yu", "ya",
    ];
    let mut out = String::new();
    for c in s.chars() {
        let lower = c.to_lowercase().next().unwrap_or(c);
        let t: String = match lower {
            ' '..='~' if !"\"';#%\\".contains(c) => c.to_string(),
            'а'..='я' => RU[(lower as u32 - 'а' as u32) as usize].to_string(),
            'ё' | 'є' => "e".into(),
            'і' | 'ї' => "i".into(),
            'ґ' => "g".into(),
            _ => String::new(),
        };
        // keep the case of a capital Cyrillic letter on the first Latin letter
        if c != lower && !c.is_ascii() {
            let mut t = t.chars();
            if let Some(f) = t.next() {
                out.extend(f.to_uppercase());
                out.push_str(t.as_str());
            }
        } else {
            out.push_str(&t);
        }
    }
    let name: String = out.trim().chars().take(24).collect();
    let name = name.trim_end().to_string();
    if name.is_empty() { "Player".into() } else { name }
}

#[cfg(test)]
mod tests {
    use super::clean_name;

    #[test]
    fn names() {
        assert_eq!(clean_name("Jack Carver"), "Jack Carver");
        assert_eq!(clean_name("  "), "Player");
        assert_eq!(clean_name("a\"b;c#d%e\\f'g"), "abcdefg");
        assert_eq!(clean_name("Вася Пупкин"), "Vasya Pupkin");
        assert_eq!(clean_name("ЩУКА"), "SchUKA");
        assert_eq!(clean_name("日本"), "Player");
        assert_eq!(clean_name("x\u{7}y"), "xy");
        assert_eq!(clean_name("123456789012345678901234567"), "123456789012345678901234");
    }
}

// every write happens with LOBBY locked: a peer that stops reading must not hang the lobby,
// so writes time out and that peer is dropped
const WRITE_TIMEOUT: Duration = Duration::from_secs(2);

fn send(s: &mut TcpStream, v: &Value) -> bool {
    s.write_all(format!("{}\n", v).as_bytes()).is_ok()
}

fn state(l: &Lobby) -> Value {
    json!({ "t": "state", "players": l.players.iter().map(|p| &p.1).collect::<Vec<_>>(),
            "map": l.map, "loadout": l.loadout })
}

// host: send to every client (dropping the dead ones) and show it in our own UI
fn broadcast(app: &AppHandle, l: &mut Lobby, v: &Value) {
    l.conns.retain_mut(|(_, s)| send(s, v));
    let _ = app.emit("lobby", v);
}

fn broadcast_state(app: &AppHandle, l: &mut Lobby) {
    let v = state(l);
    broadcast(app, l, &v);
}

// lines longer than 4 KB end the connection: nobody sends that much
fn read_lines(s: TcpStream, mut on_line: impl FnMut(Value)) {
    let mut r = BufReader::new(s);
    loop {
        let mut line = String::new();
        match r.by_ref().take(4096).read_line(&mut line) {
            Ok(n) if n > 0 && line.ends_with('\n') => {
                if let Ok(v) = serde_json::from_str::<Value>(&line) {
                    on_line(v);
                }
            }
            _ => return,
        }
    }
}

pub fn host(app: AppHandle, me: Value, map: String, loadout: bool) -> Result<(), String> {
    let listener = TcpListener::bind(("0.0.0.0", PORT)).map_err(|e| format!("TCP {}: {}", PORT, e))?;
    let mut l = Lobby { host: true, players: vec![(0, clean_me(&me))], conns: vec![], map, loadout, next_id: 1, host_ip: String::new(),
        started: false, game: 0 };
    broadcast_state(&app, &mut l);
    *LOBBY.lock().unwrap() = Some(l);
    std::thread::spawn(move || {
        for s in listener.incoming().flatten() {
            let mut guard = LOBBY.lock().unwrap();
            let Some(l) = guard.as_mut().filter(|l| l.host) else { return };
            let id = l.next_id;
            l.next_id += 1;
            let _ = s.set_write_timeout(Some(WRITE_TIMEOUT));
            let Ok(w) = s.try_clone() else { continue };
            l.conns.push((id, w));
            drop(guard);
            let app = app.clone();
            std::thread::spawn(move || {
                read_lines(s, |v| {
                    if v["t"] == "me" {
                        if let Some(l) = LOBBY.lock().unwrap().as_mut() {
                            let me = clean_me(&v["me"]);
                            match l.players.iter_mut().find(|p| p.0 == id) {
                                Some(p) => p.1 = me,
                                None => l.players.push((id, me)),
                            }
                            broadcast_state(&app, l);
                        }
                    }
                });
                if let Some(l) = LOBBY.lock().unwrap().as_mut() {
                    l.players.retain(|p| p.0 != id);
                    l.conns.retain(|c| c.0 != id);
                    broadcast_state(&app, l);
                }
            });
        }
    });
    Ok(())
}

pub fn join(app: AppHandle, ip: String, me: Value) -> Result<(), String> {
    crate::connect_line(&ip, &me)?; // the address goes into the game console later: check it now
    let addr = format!("{}:{}", ip, PORT);
    let sock = std::net::ToSocketAddrs::to_socket_addrs(&addr).map_err(|e| e.to_string())?.next().ok_or("bad address")?;
    let mut s = TcpStream::connect_timeout(&sock, Duration::from_secs(5)).map_err(|e| format!("{}: {}", addr, e))?;
    let _ = s.set_write_timeout(Some(WRITE_TIMEOUT));
    send(&mut s, &json!({ "t": "me", "me": me }));
    let r = s.try_clone().map_err(|e| e.to_string())?;
    *LOBBY.lock().unwrap() = Some(Lobby { host: false, players: vec![], conns: vec![(0, s)], map: String::new(),
        loadout: false, next_id: 0, host_ip: ip, started: false, game: 0 });
    std::thread::spawn(move || {
        read_lines(r, |v| {
            let mut guard = LOBBY.lock().unwrap();
            let Some(l) = guard.as_mut() else { return };
            match v["t"].as_str() {
                Some("state") => {
                    l.map = v["map"].as_str().unwrap_or("").into();
                    l.loadout = v["loadout"].as_bool().unwrap_or(false);
                }
                Some("start") if !l.started => {
                    l.started = true;
                    let me = crate::me();
                    l.game = crate::start_game(&me, l.loadout, None).unwrap_or(0);
                }
                Some("go") if l.game != 0 => {
                    if let Ok(line) = crate::connect_line(&l.host_ip, &crate::me()) {
                        let _ = crate::write_join(l.game, &line);
                    }
                }
                _ => {}
            }
            let _ = app.emit("lobby", &v);
        });
        *LOBBY.lock().unwrap() = None;
        let _ = app.emit("lobby", json!({ "t": "closed" }));
    });
    Ok(())
}

// our own color, weapons or name changed; the host may also change the map or the loadout mode
pub fn update(app: &AppHandle, me: Value, map: String, loadout: bool) {
    let mut guard = LOBBY.lock().unwrap();
    let Some(l) = guard.as_mut() else { return };
    if l.host {
        l.players[0].1 = clean_me(&me);
        l.map = map;
        l.loadout = loadout;
        broadcast_state(app, l);
    } else {
        let v = json!({ "t": "me", "me": me });
        l.conns.retain_mut(|(_, s)| send(s, &v));
    }
}

// host: everyone starts the game; the host loads the map, then tells the clients to connect
// once its server has taken UDP 49001
pub fn start(app: AppHandle) -> Result<(), String> {
    let (map, loadout) = {
        let mut guard = LOBBY.lock().unwrap();
        let l = guard.as_mut().filter(|l| l.host).ok_or("not hosting a lobby")?;
        if l.started {
            return Err("already started".into());
        }
        l.started = true;
        broadcast(&app, l, &json!({ "t": "start" }));
        (l.map.clone(), l.loadout)
    };
    let me = crate::me();
    crate::start_game(&me, loadout, Some(crate::host_line(&map, &me, loadout)?))?;
    std::thread::spawn(move || {
        for _ in 0..300 {
            std::thread::sleep(Duration::from_secs(1));
            if crate::server_up() {
                if let Some(l) = LOBBY.lock().unwrap().as_mut() {
                    broadcast(&app, l, &json!({ "t": "go" }));
                }
                return;
            }
        }
    });
    Ok(())
}

pub fn leave(app: &AppHandle) {
    if let Some(l) = LOBBY.lock().unwrap().take() {
        for (_, s) in l.conns {
            let _ = s.shutdown(std::net::Shutdown::Both);
        }
        if l.host {
            let _ = TcpStream::connect(("127.0.0.1", PORT)); // wakes the accept loop: it sees no lobby and frees the port
        }
    }
    let _ = app.emit("lobby", json!({ "t": "closed" }));
}
