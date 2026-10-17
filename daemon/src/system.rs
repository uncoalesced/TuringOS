// Machine readings for the menu bar and corners, plus process helpers.
// Linux-first (/proc, /sys, nmcli); elsewhere the readings come back empty.

use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;

pub fn host() -> String {
    std::fs::read_to_string("/proc/sys/kernel/hostname")
        .map(|s| s.trim().to_string())
        .or_else(|_| std::env::var("COMPUTERNAME"))
        .unwrap_or_default()
}

/// First name for the greeting: the account's full name, else the login name.
pub fn first_name() -> Option<String> {
    let user = std::env::var("USER")
        .or_else(|_| std::env::var("USERNAME"))
        .ok()?;
    let full = std::fs::read_to_string("/etc/passwd")
        .ok()
        .and_then(|p| {
            p.lines()
                .find(|l| l.starts_with(&format!("{user}:")))
                .and_then(|l| l.split(':').nth(4))
                .map(|g| g.split(',').next().unwrap_or("").to_string())
        })
        .filter(|g| !g.trim().is_empty())
        .unwrap_or(user);
    let first = full.split_whitespace().next()?.to_string();
    let mut chars = first.chars();
    Some(chars.next()?.to_uppercase().chain(chars).collect())
}

/// CPU busy %, measured since the previous call
pub fn cpu(prev: &Mutex<Option<(u64, u64)>>) -> u64 {
    let Some((total, idle)) = std::fs::read_to_string("/proc/stat").ok().and_then(|s| {
        let nums: Vec<u64> = s
            .lines()
            .next()?
            .split_whitespace()
            .skip(1)
            .filter_map(|n| n.parse().ok())
            .collect();
        // idle + iowait count as idle
        Some((nums.iter().sum(), nums.get(3)? + nums.get(4).unwrap_or(&0)))
    }) else {
        return 0;
    };
    let mut prev = prev.lock().unwrap();
    let (pt, pi) = prev.replace((total, idle)).unwrap_or((0, 0));
    let (dt, di) = (total.saturating_sub(pt), idle.saturating_sub(pi));
    // Rounded busy share; 0 before there's a previous sample to diff against
    (100 * (dt - di.min(dt)) + dt / 2)
        .checked_div(dt)
        .unwrap_or(0)
}

pub fn mem() -> u64 {
    let info = std::fs::read_to_string("/proc/meminfo").unwrap_or_default();
    let field = |name: &str| -> u64 {
        info.lines()
            .find(|l| l.starts_with(name))
            .and_then(|l| l.split_whitespace().nth(1)?.parse().ok())
            .unwrap_or(0)
    };
    let (total, avail) = (field("MemTotal:"), field("MemAvailable:"));
    (100 * (total - avail.min(total)) + total / 2)
        .checked_div(total)
        .unwrap_or(0)
}

pub fn battery() -> Value {
    let base = Path::new("/sys/class/power_supply");
    let Some(bat) = std::fs::read_dir(base).ok().and_then(|d| {
        d.flatten().map(|e| e.path()).find(|p| {
            p.file_name()
                .is_some_and(|n| n.to_string_lossy().starts_with("BAT"))
        })
    }) else {
        return Value::Null;
    };
    let read = |f: &str| {
        std::fs::read_to_string(bat.join(f))
            .map(|s| s.trim().to_string())
            .unwrap_or_default()
    };
    match read("capacity").parse::<u64>() {
        Ok(level) => {
            let status = read("status");
            json!({ "level": level, "charging": status == "Charging" || status == "Full" })
        }
        Err(_) => Value::Null,
    }
}

// ─── Wi-Fi ───────────────────────────────────────────────────────────────────
// All through nmcli (NetworkManager), args never through a shell: an SSID or
// a password is data, not code. Terse mode escapes ':' and '\' in values, so
// lines are split on unescaped separators only.

/// One `nmcli -t` line split on unescaped ':' (`--escape yes`, the default)
fn split_terse(line: &str) -> Vec<String> {
    let mut fields = vec![String::new()];
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\\' => match chars.next() {
                Some(escaped) => fields.last_mut().unwrap().push(escaped),
                None => fields.last_mut().unwrap().push('\\'),
            },
            ':' => fields.push(String::new()),
            other => fields.last_mut().unwrap().push(other),
        }
    }
    fields
}

/// IN-USE: '*' in nmcli's own output; "yes" accepted for good measure
fn is_active(field: &str) -> bool {
    matches!(field, "*" | "yes")
}

/// Wi-Fi SSID via NetworkManager; Null when nmcli is missing or nothing
/// is in use. `--rescan no`: this runs on the 10s state poll, a scan of
/// its own would wake the radio for nothing.
pub fn wifi() -> Value {
    let Ok(out) = Command::new("nmcli")
        .args([
            "-t",
            "-f",
            "IN-USE,SSID",
            "dev",
            "wifi",
            "list",
            "--rescan",
            "no",
        ])
        .output()
    else {
        return Value::Null;
    };
    if !out.status.success() {
        return Value::Null;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let ssid = text.lines().find_map(|l| {
        let fields = split_terse(l);
        if fields.len() >= 2 && is_active(&fields[0]) {
            Some(fields[1].clone())
        } else {
            None
        }
    });
    json!({ "ssid": ssid })
}

/// Terse `nmcli dev wifi list` output → the network list for a scan.
/// Same SSID twice (dual-band, several APs): one entry, active if any of
/// them is, with the strongest signal seen.
fn parse_scan(text: &str) -> Vec<Value> {
    let mut nets: Vec<Value> = Vec::new();
    for line in text.lines() {
        let f = split_terse(line);
        if f.len() < 4 || f[1].is_empty() {
            continue; // hidden SSID or a line that isn't a network
        }
        let entry = json!({
            "ssid": f[1],
            "signal": f[2].parse::<u64>().unwrap_or(0).min(100),
            "secure": !(f[3].is_empty() || f[3] == "--"),
            "active": is_active(&f[0]),
        });
        match nets
            .iter_mut()
            .find(|n| n["ssid"].as_str() == Some(f[1].as_str()))
        {
            Some(existing) => {
                let signal = existing["signal"]
                    .as_u64()
                    .unwrap_or(0)
                    .max(entry["signal"].as_u64().unwrap_or(0));
                let active =
                    existing["active"] == Value::Bool(true) || entry["active"] == Value::Bool(true);
                let secure =
                    existing["secure"] == Value::Bool(true) || entry["secure"] == Value::Bool(true);
                *existing =
                    json!({ "ssid": f[1], "signal": signal, "secure": secure, "active": active });
            }
            None => nets.push(entry),
        }
    }
    nets.sort_by(|a, b| {
        let act = b["active"]
            .as_bool()
            .unwrap_or(false)
            .cmp(&a["active"].as_bool().unwrap_or(false));
        act.then_with(|| b["signal"].as_u64().cmp(&a["signal"].as_u64()))
            .then_with(|| {
                a["ssid"]
                    .as_str()
                    .unwrap_or("")
                    .cmp(b["ssid"].as_str().unwrap_or(""))
            })
    });
    nets
}

fn nmcli_error(out: &std::process::Output, fallback: &str) -> Value {
    let text = String::from_utf8_lossy(&out.stderr);
    let text = text.trim();
    let text = if text.is_empty() {
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    } else {
        text.to_string()
    };
    json!({ "ok": false, "error": if text.is_empty() { fallback.to_string() } else { text } })
}

/// Nearby networks for the panel: { ok, networks: [{ssid, signal, secure, active}] }
pub fn wifi_scan() -> Value {
    let Ok(out) = Command::new("nmcli")
        .args([
            "-t",
            "-f",
            "IN-USE,SSID,SIGNAL,SECURITY",
            "dev",
            "wifi",
            "list",
            "--rescan",
            "auto",
        ])
        .output()
    else {
        return json!({ "ok": false, "error": "NetworkManager (nmcli) is not installed." });
    };
    if !out.status.success() {
        return nmcli_error(&out, "Could not scan for networks.");
    }
    json!({ "ok": true, "networks": parse_scan(&String::from_utf8_lossy(&out.stdout)) })
}

/// Join (or create and join) a network. The profile NM saves lives with the
/// system like any other NM connection. `--wait 30` caps a slow activation —
/// nmcli's own default is 90 seconds.
pub fn wifi_connect(ssid: &str, password: Option<&str>) -> Value {
    let mut cmd = Command::new("nmcli");
    cmd.args(["--wait", "30", "device", "wifi", "connect", ssid]);
    if let Some(password) = password.filter(|p| !p.is_empty()) {
        cmd.args(["password", password]);
    }
    let Ok(out) = cmd.output() else {
        return json!({ "ok": false, "error": "NetworkManager (nmcli) is not installed." });
    };
    if out.status.success() {
        json!({ "ok": true })
    } else {
        nmcli_error(&out, "Could not connect to the network.")
    }
}

pub fn pid_alive(pid: &str) -> bool {
    !pid.is_empty()
        && pid.chars().all(|c| c.is_ascii_digit())
        && Path::new("/proc").join(pid).exists()
}

/// Full path of COMMAND on PATH
pub fn which(cmd: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH")?)
        .map(|dir| dir.join(cmd))
        .find(|p| p.is_file())
}

/// The live ISO session, with the Calamares installer: the dock offers "Install"
pub fn installer_available() -> bool {
    Path::new("/run/live/medium").is_dir() && which("turingos-install").is_some()
}

/// Start a program detached from the service; a thread reaps it so it never
/// lingers as a zombie
pub fn spawn_detached(program: &Path, args: &[&str], envs: &[(&str, &str)]) -> std::io::Result<()> {
    let mut child = Command::new(program)
        .args(args)
        .envs(envs.iter().copied())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    std::thread::spawn(move || child.wait());
    Ok(())
}

/// `systemd-run` arguments that start PROGRAM in a scope of its own
fn scope_args<'a>(program: &'a str, args: &[&'a str]) -> Vec<&'a str> {
    let mut all = vec!["--user", "--scope", "--quiet", "--collect", "--", program];
    all.extend_from_slice(args);
    all
}

/// Start something the user keeps (a terminal, the browser, an agent run):
/// in its own systemd scope, so restarting this service doesn't take it
/// down with it. Without a systemd user session, a plain detached start.
pub fn spawn_lasting(program: &Path, args: &[&str], envs: &[(&str, &str)]) -> std::io::Result<()> {
    let user_session =
        std::env::var_os("XDG_RUNTIME_DIR").is_some_and(|d| Path::new(&d).join("systemd").is_dir());
    if let (true, Some(run), Some(program_str)) =
        (user_session, which("systemd-run"), program.to_str())
    {
        if spawn_detached(&run, &scope_args(program_str, args), envs).is_ok() {
            return Ok(());
        }
    }
    spawn_detached(program, args, envs)
}

/// Open an http(s) URL in the system browser
pub fn open_url(url: &str) -> bool {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return false;
    }
    ["xdg-open", "x-www-browser"]
        .iter()
        .find_map(|c| which(c))
        .is_some_and(|bin| spawn_lasting(&bin, &[url], &[]).is_ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scope_keeps_the_command_after_the_separator() {
        assert_eq!(
            scope_args("/usr/bin/xterm", &["-T", "--user"]),
            [
                "--user",
                "--scope",
                "--quiet",
                "--collect",
                "--",
                "/usr/bin/xterm",
                "-T",
                "--user"
            ]
        );
    }

    #[test]
    fn only_web_links_open() {
        assert!(!open_url("file:///etc/passwd"));
        assert!(!open_url("javascript:alert(1)"));
        assert!(!open_url(""));
    }

    #[test]
    fn pid_alive_takes_digits_only() {
        assert!(!pid_alive(""));
        assert!(!pid_alive("12; rm"));
        assert!(!pid_alive("../1"));
    }

    #[test]
    fn terse_lines_split_on_unescaped_separators_only() {
        assert_eq!(
            split_terse("*:Studio:87:WPA2"),
            ["*", "Studio", "87", "WPA2"]
        );
        assert_eq!(split_terse(r"\:back\:.hidden"), [":back:.hidden"]);
        assert_eq!(split_terse(r"Cafe\: Two:54:"), ["Cafe: Two", "54", ""]);
        assert!(is_active("*"));
        assert!(is_active("yes"));
        assert!(!is_active(""));
    }

    #[test]
    fn scan_output_parses_sorts_and_dedupes() {
        let out = "\
*:Studio:87:WPA2
:Cafe\\: Two:54:WPA1 WPA2
:Other:61:--
*:Studio:40:WPA2
::70:WPA2
";
        let nets = parse_scan(out);
        // Active first, then by signal; hidden SSIDs dropped; Studio's two
        // APs merge into one active row at the stronger signal
        let ssids: Vec<&str> = nets.iter().map(|n| n["ssid"].as_str().unwrap()).collect();
        assert_eq!(ssids, ["Studio", "Other", "Cafe: Two"]);
        assert_eq!(nets[0]["active"], json!(true));
        assert_eq!(nets[0]["signal"], json!(87));
        assert_eq!(nets[1]["secure"], json!(false));
        assert_eq!(nets[2]["secure"], json!(true));
    }

    #[test]
    fn aps_of_one_ssid_merge_into_one_row() {
        let nets = parse_scan("*:Home:30:WPA2\n:Home:90:WPA2\n");
        assert_eq!(nets.len(), 1);
        assert_eq!(nets[0]["signal"], json!(90));
        assert_eq!(nets[0]["active"], json!(true));
    }
}
