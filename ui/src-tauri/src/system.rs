// Machine readings for the menu bar and corners, plus process helpers.
// Linux-first (/proc, /sys, nmcli); elsewhere the readings come back empty.

use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;

/// VMs without 3D acceleration have no render node: draw in software, or
/// WebKitGTK shows a black window. Must run before the webview starts.
pub fn prepare_webview_env() {
    let has_render_node = std::fs::read_dir("/dev/dri")
        .map(|d| {
            d.flatten()
                .any(|e| e.file_name().to_string_lossy().starts_with("renderD"))
        })
        .unwrap_or(false);
    if cfg!(target_os = "linux")
        && (!has_render_node || std::env::var("LITE").as_deref() == Ok("1"))
    {
        std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
        std::env::set_var("WEBKIT_DISABLE_COMPOSITING_MODE", "1");
    }
}

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

/// Wi-Fi SSID via NetworkManager; Null when nmcli is missing
pub fn wifi() -> Value {
    let Ok(out) = Command::new("nmcli")
        .args(["-t", "-f", "ACTIVE,SSID", "dev", "wifi"])
        .output()
    else {
        return Value::Null;
    };
    if !out.status.success() {
        return Value::Null;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let ssid = text
        .lines()
        .find_map(|l| l.strip_prefix("yes:"))
        .map(str::to_string);
    json!({ "ssid": ssid })
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

/// Start a program detached from the UI; a thread reaps it so it never
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

/// Open an http(s) URL in the system browser
pub fn open_url(url: &str) -> bool {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return false;
    }
    ["xdg-open", "x-www-browser"]
        .iter()
        .find_map(|c| which(c))
        .is_some_and(|bin| spawn_detached(&bin, &[url], &[]).is_ok())
}
