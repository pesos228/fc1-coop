// FarCryCoop launcher: a lobby where friends see each other's shirt color and loadout, then the
// host starts the game for everyone; or wait for a Steam invite. Talks to the game only through
// files the mod already reads: Mods\FarCryCoop\prefs.lua (COOP ClientStuff) and
// Mods\FarCryCoop\join_<pid>.txt (FarCryCoopNet.asi in that game runs its one console line).
// Lives in the game folder, next to Bin32.
#![windows_subsystem = "windows"]

mod lobby;

use serde_json::Value;
use std::path::PathBuf;
use std::process::Command;
use tauri::AppHandle;

const WEAPONS: [&str; 11] = ["Machete", "Falcon", "MP5", "P90", "M4", "AG36", "OICW", "Shotgun", "SniperRifle", "M249", "RL"];

fn exe_dir() -> PathBuf {
    std::env::current_exe().unwrap().parent().unwrap().to_path_buf()
}

// Bin32 folder of the game. The launcher lives in the game folder, not in Bin32: Windows loads
// DLLs from the exe's folder first, and the game's old version.dll / dbghelp.dll there crashed it.
// FARCRYCOOP_GAME points to the game folder for development.
fn bin32() -> Result<PathBuf, String> {
    let dev = PathBuf::from(std::env::var("FARCRYCOOP_GAME").unwrap_or_default());
    [exe_dir(), dev]
        .iter()
        .map(|d| d.join("Bin32"))
        .find(|b| b.join("FarCry.exe").exists())
        .ok_or_else(|| "FarCry.exe not found: put the launcher into the Far Cry folder (next to Bin32)".into())
}

fn mod_dir() -> Result<PathBuf, String> {
    Ok(bin32()?.parent().unwrap().join("Mods").join("FarCryCoop"))
}

#[tauri::command]
fn load_settings() -> String {
    std::fs::read_to_string(exe_dir().join("FarCryCoopLauncher.json")).unwrap_or_else(|_| "{}".into())
}

#[tauri::command]
fn save_settings(json: String) -> Result<(), String> {
    std::fs::write(exe_dir().join("FarCryCoopLauncher.json"), json).map_err(|e| e.to_string())
}

// our player as saved by the UI: name, color, weapons; plus the key the host keeps our progress
// under (COOP gamerules COOP_Progress): the SteamID of the logged-in Steam user, else the name
fn me() -> Value {
    let mut me = lobby::clean_me(&serde_json::from_str(&load_settings()).unwrap_or_default());
    let key = steam_user().map(|(id, _)| id).unwrap_or_else(|| me["name"].as_str().unwrap_or("Player").to_string());
    me["key"] = key.into();
    me
}

#[link(name = "advapi32")]
extern "system" {
    fn RegGetValueW(key: isize, sub: *const u16, value: *const u16, flags: u32, ty: *mut u32, data: *mut u8, len: *mut u32) -> i32;
}
const HKEY_CURRENT_USER: isize = 0x8000_0001u32 as i32 as isize;

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

// a value under HKEY_CURRENT_USER: RRF_RT_REG_DWORD (0x10) or RRF_RT_REG_SZ (0x2)
fn reg(sub: &str, value: &str, flags: u32) -> Option<Vec<u8>> {
    let (sub, value) = (wide(sub), wide(value));
    let mut len = 0u32;
    if unsafe { RegGetValueW(HKEY_CURRENT_USER, sub.as_ptr(), value.as_ptr(), flags, std::ptr::null_mut(), std::ptr::null_mut(), &mut len) } != 0 {
        return None;
    }
    let mut data = vec![0u8; len as usize];
    if unsafe { RegGetValueW(HKEY_CURRENT_USER, sub.as_ptr(), value.as_ptr(), flags, std::ptr::null_mut(), data.as_mut_ptr(), &mut len) } != 0 {
        return None;
    }
    data.truncate(len as usize);
    Some(data)
}

// the Steam user logged in right now: (SteamID64, persona name). The game needs Steam running
// anyway. No Steam API here: Steam keeps the account id of the running user in the registry
// (ActiveProcess\ActiveUser, 0 when nobody is logged in) and the persona in loginusers.vdf
fn steam_user() -> Option<(String, String)> {
    let user = reg("Software\\Valve\\Steam\\ActiveProcess", "ActiveUser", 0x10)?;
    let account = u32::from_le_bytes(user.get(..4)?.try_into().ok()?);
    if account == 0 {
        return None;
    }
    let id = (76561197960265728u64 + account as u64).to_string();
    let path: Vec<u16> = reg("Software\\Valve\\Steam", "SteamPath", 0x2)?.chunks(2).map(|b| u16::from_le_bytes([b[0], b[1]])).take_while(|c| *c != 0).collect();
    let vdf = std::fs::read_to_string(PathBuf::from(String::from_utf16_lossy(&path)).join("config").join("loginusers.vdf")).unwrap_or_default();
    // "users" { "<SteamID64>" { ... "PersonaName" "<name>" ... } }
    let mut ours = false;
    let mut persona = String::new();
    for l in vdf.lines().map(str::trim) {
        if l == format!("\"{}\"", id) {
            ours = true;
        } else if ours && l.starts_with("\"PersonaName\"") {
            persona = l.split('"').nth(3).unwrap_or("").to_string();
            break;
        } else if ours && l == "}" {
            break;
        }
    }
    Some((id, persona))
}

// default player name: the Steam persona name, else p_name from the game's system.cfg
#[tauri::command]
fn game_name() -> String {
    if let Some((_, persona)) = steam_user().filter(|(_, p)| !p.is_empty()) {
        return lobby::clean_name(&persona);
    }
    let cfg = bin32().map(|b| b.parent().unwrap().join("system.cfg")).unwrap_or_default();
    let name = std::fs::read_to_string(cfg)
        .unwrap_or_default()
        .lines()
        .find_map(|l| l.trim().strip_prefix("p_name").map(|r| r.trim_start_matches([' ', '=']).trim_matches('"').to_string()))
        .unwrap_or_default();
    lobby::clean_name(&name)
}

const STORY: [&str; 20] = [
    "Training", "Carrier", "Fort", "Pier", "Research", "Treehouse", "Bunker", "Steam", "Regulator", "Control",
    "Rebellion", "Archive", "Cooler", "Boat", "Catacombs", "River", "Swamp", "Factory", "Dam", "Volcano",
];

// campaign levels: folders of Levels without the multiplayer maps
#[tauri::command]
fn list_maps() -> Result<Vec<String>, String> {
    let levels = bin32()?.parent().unwrap().join("Levels");
    let mut maps: Vec<String> = std::fs::read_dir(&levels)
        .map_err(|e| format!("{}: {}", levels.display(), e))?
        .filter_map(|e| e.ok())
        .filter(|e| e.path().is_dir())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| !n.to_lowercase().starts_with("mp_") && n != "Demo" && n != "newcontrol")
        .collect();
    // the story order of the campaign (DEFIANT in defiant.lua); folders it does not list stay at the end
    maps.sort_by_key(|m| (STORY.iter().position(|s| s.eq_ignore_ascii_case(m)).unwrap_or(usize::MAX), m.to_lowercase()));
    // co-op saves (Mods\FarCryCoop\save_<name>.lua, written by the host's game) follow as "save:<name>"
    if let Ok(dir) = mod_dir().and_then(|d| std::fs::read_dir(d).map_err(|e| e.to_string())) {
        let mut saves: Vec<String> = dir
            .filter_map(|e| e.ok())
            .filter_map(|e| e.file_name().to_string_lossy().strip_prefix("save_")?.strip_suffix(".lua").map(String::from))
            .filter(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'))
            .map(|n| format!("save:{}", n))
            .collect();
        saves.sort();
        maps.extend(saves);
    }
    Ok(maps)
}

// launcher settings as Lua: written to prefs.lua and put in front of the console line too.
// Two games on one PC share prefs.lua, so each game gets its own settings in its own line
// (COOP ClientStuff reads prefs.lua only when the line did not set them).
// The name becomes the game's p_name, the key COOP_PlayerKey (sent to the host as COOPID).
// Both went through clean_name or are digits: nothing in them can end the Lua string.
fn prefs(me: &Value, loadout: bool) -> String {
    let weapons: Vec<&str> = me["weapons"].as_array().map(|a| a.iter().filter_map(|w| w.as_str()).collect()).unwrap_or_default();
    let name = lobby::clean_name(me["name"].as_str().unwrap_or(""));
    let key = lobby::clean_name(me["key"].as_str().unwrap_or(name.as_str()));
    format!(
        "COOP_Color={} COOP_Weapons=\"{}\" COOP_LoadoutMode={} COOP_Difficulty={} COOP_PlayerKey=\"{}\" setglobal(\"p_name\",\"{}\")",
        me["color"].as_u64().unwrap_or(1),
        weapons.join(" "),
        loadout as u8,
        me["difficulty"].as_u64().unwrap_or(1),
        key,
        name
    )
}

// the lines go into the game console as is: allow only map name and address characters
fn host_line(map: &str, me: &Value, loadout: bool) -> Result<String, String> {
    let (call, name) = match map.strip_prefix("save:") {
        Some(n) => ("CoopLoad", n),
        None => ("CoopMap", map),
    };
    if name.is_empty() || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return Err("bad map".into());
    }
    Ok(format!("#{} {}(\"{}\")", prefs(me, loadout), call, name))
}

// the host's line with the number of players the map start waits for (coop_minplayers)
fn expect_players(line: &str, players: usize) -> String {
    line.replacen('#', &format!("#COOP_ExpectPlayers={} ", players.max(1)), 1)
}

fn connect_line(ip: &str, me: &Value) -> Result<String, String> {
    if ip.is_empty() || !ip.chars().all(|c| c.is_ascii_alphanumeric() || ".:-".contains(c)) {
        return Err("bad address".into());
    }
    let addr = if ip.contains(':') { ip.to_string() } else { format!("{}:49001", ip) };
    Ok(format!("#{} Game:Connect(\"{}\",1)", prefs(me, false), addr))
}

// the line for one game we started: FarCryCoopNet.asi in that process reads join_<pid>.txt
// (join.txt is shared by every game on the PC; the Steam bridge writes that one)
fn write_join(pid: u32, line: &str) -> Result<(), String> {
    std::fs::write(mod_dir()?.join(format!("join_{}.txt", pid)), line).map_err(|e| e.to_string())
}

// write prefs.lua, then start the Steam bridge and the game; `line` runs in the game console
fn start_game(me: &Value, loadout: bool, line: Option<String>) -> Result<u32, String> {
    let bin = bin32()?;
    let moddir = mod_dir()?;
    // Lua 4 reads it: plain ASCII, no BOM
    std::fs::write(moddir.join("prefs.lua"), prefs(me, loadout)).map_err(|e| e.to_string())?;
    let _ = std::fs::remove_file(moddir.join("join.txt")); // an old line must not run
    // one bridge per PC: a second one cannot bind UDP 49011 and just stays open
    let steam = moddir.join("Steam");
    if steam.join("FarCryCoopSteam.exe").exists() && !running("FarCryCoopSteam.exe") {
        Command::new(steam.join("FarCryCoopSteam.exe")).current_dir(&steam).spawn().map_err(|e| e.to_string())?;
    }
    let game = Command::new(bin.join("FarCry.exe"))
        .args(["-DEVMODE", "-MOD:FarCryCoop"])
        .current_dir(&bin)
        .spawn()
        .map_err(|e| e.to_string())?;
    if let Some(l) = line {
        write_join(game.id(), &l)?;
    }
    Ok(game.id())
}

// a Far Cry server on this PC holds UDP 49001
fn server_up() -> bool {
    std::net::UdpSocket::bind(("0.0.0.0", 49001)).is_err()
}

#[link(name = "user32")]
extern "system" {
    fn EnumWindows(f: extern "system" fn(isize, isize) -> i32, l: isize) -> i32;
    fn GetWindowThreadProcessId(w: isize, pid: *mut u32) -> u32;
    fn IsWindowVisible(w: isize) -> i32;
    fn GetWindowRect(w: isize, r: *mut [i32; 4]) -> i32;
    fn MoveWindow(w: isize, x: i32, y: i32, cx: i32, cy: i32, repaint: i32) -> i32;
    fn SystemParametersInfoW(action: u32, p1: u32, p2: *mut [i32; 4], ini: u32) -> i32;
}

// visible top-level window of a process (l points to [pid, found window])
extern "system" fn find_window(w: isize, l: isize) -> i32 {
    let want = unsafe { &mut *(l as *mut (u32, isize)) };
    let mut pid = 0;
    unsafe { GetWindowThreadProcessId(w, &mut pid) };
    if pid == want.0 && unsafe { IsWindowVisible(w) } != 0 {
        want.1 = w;
        return 0;
    }
    1
}

// put the game window of `pid` at the left or right edge of the work area, as tools/launch-two.ps1
fn place_window(pid: u32, left: bool) {
    let mut found = (pid, 0isize);
    for _ in 0..60 {
        unsafe { EnumWindows(find_window, &mut found as *mut _ as isize) };
        if found.1 != 0 {
            break;
        }
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
    if found.1 == 0 {
        return;
    }
    std::thread::sleep(std::time::Duration::from_secs(5)); // the game resizes its window once after it appears
    let (mut area, mut r) = ([0i32; 4], [0i32; 4]);
    unsafe {
        SystemParametersInfoW(0x30, 0, &mut area, 0); // SPI_GETWORKAREA
        GetWindowRect(found.1, &mut r);
    }
    let (w, h) = (r[2] - r[0], r[3] - r[1]);
    let x = if left { area[0] } else { area[2] - w };
    unsafe { MoveWindow(found.1, x, area[1], w, h, 1) };
}

// test on one PC: the host's game on the left loads the map; once its server is up, a second
// game on the right connects to 127.0.0.1 (started only then, so there is a server to connect
// to). Each game gets its line in its own join_<pid>.txt. The client gets the next shirt color.
#[tauri::command]
fn launch_test(map: String, loadout: bool) -> Result<(), String> {
    let me = me();
    let host = start_game(&me, loadout, Some(expect_players(&host_line(&map, &me, loadout)?, 2)))?;
    std::thread::spawn(move || {
        place_window(host, true);
        for _ in 0..300 {
            if server_up() {
                let mut friend = me.clone();
                friend["color"] = ((me["color"].as_u64().unwrap_or(1) + 1) % 10).into();
                // the same Steam user plays both games: the second one needs a key of its own
                friend["key"] = format!("{}-2", me["key"].as_str().unwrap_or("Player")).into();
                if let Ok(line) = connect_line("127.0.0.1", &friend) {
                    if let Ok(pid) = start_game(&friend, loadout, Some(line)) {
                        place_window(pid, false);
                    }
                }
                return;
            }
            std::thread::sleep(std::time::Duration::from_secs(1));
        }
    });
    Ok(())
}

fn running(exe: &str) -> bool {
    use std::os::windows::process::CommandExt;
    Command::new("tasklist")
        .args(["/NH", "/FI", &format!("IMAGENAME eq {}", exe)])
        .creation_flags(0x0800_0000) // CREATE_NO_WINDOW
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).contains(exe))
        .unwrap_or(false)
}

// wait for a Steam invite: the bridge writes join.txt when the player accepts it
#[tauri::command]
fn launch_steam() -> Result<(), String> {
    start_game(&me(), false, None).map(|_| ())
}

#[tauri::command]
fn lobby_host(app: AppHandle, map: String, loadout: bool) -> Result<(), String> {
    lobby::host(app, me(), map, loadout)
}

#[tauri::command]
fn lobby_join(app: AppHandle, ip: String) -> Result<(), String> {
    lobby::join(app, ip.trim().to_string(), me())
}

#[tauri::command]
fn lobby_update(app: AppHandle, map: String, loadout: bool) {
    lobby::update(&app, me(), map, loadout)
}

#[tauri::command]
fn lobby_start(app: AppHandle) -> Result<(), String> {
    lobby::start(app)
}

#[tauri::command]
fn lobby_leave(app: AppHandle) {
    lobby::leave(&app)
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            load_settings, save_settings, game_name, list_maps, launch_steam, launch_test,
            lobby_host, lobby_join, lobby_update, lobby_start, lobby_leave
        ])
        .setup(|app| {
            // WebView2 keeps its profile in %LOCALAPPDATA% by default: keep it next to the launcher
            tauri::WebviewWindowBuilder::new(app, "main", tauri::WebviewUrl::App("index.html".into()))
                .title("Far Cry Coop")
                .inner_size(900.0, 620.0)
                .resizable(false)
                .data_directory(exe_dir().join("FarCryCoopLauncherData"))
                .build()?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("tauri");
}

#[cfg(test)]
mod tests {
    // reads this PC's Steam login: cargo test -- --ignored --nocapture
    #[test]
    fn host_line_waits_for_the_lobby() {
        let me = serde_json::json!({"name": "A", "color": 1, "weapons": [], "difficulty": 1});
        let line = super::expect_players(&super::host_line("pier", &me, false).unwrap(), 3);
        assert!(line.starts_with("#COOP_ExpectPlayers=3 COOP_Color=1 "), "{}", line);
        assert!(line.ends_with("CoopMap(\"pier\")"), "{}", line);
    }

    #[test]
    #[ignore]
    fn steam_user_here() {
        let user = super::steam_user();
        println!("steam user: {:?}, default name: {}", user.as_ref().map(|(id, _)| id), super::game_name());
        assert!(user.is_some(), "no Steam user logged in");
    }
}
