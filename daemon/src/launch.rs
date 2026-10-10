// Dock launchers and external links.

use crate::{config_env, system};
use serde_json::{json, Value};

type Commands = Vec<(&'static str, Vec<String>)>;

/// Fixed, curated dock apps: the first installed command wins
fn dock_commands(id: &str) -> Option<(&'static str, Commands)> {
    let home = config_env::home().to_string_lossy().into_owned();
    let with_home = |cmd: &'static str| (cmd, vec![home.clone()]);
    Some(match id {
        "terminal" => (
            "Terminal",
            vec![
                ("x-terminal-emulator", vec![]),
                ("xterm", vec![]),
                ("konsole", vec![]),
            ],
        ),
        "files" => (
            "Files",
            [
                "xdg-open", "dolphin", "nautilus", "pcmanfm", "nemo", "thunar",
            ]
            .map(with_home)
            .to_vec(),
        ),
        "browser" => (
            "Browser",
            vec![
                ("x-www-browser", vec![]),
                ("xdg-open", vec!["https://".into()]),
            ],
        ),
        "install" => ("Installer", vec![("turingos-install", vec![])]),
        "settings" => (
            "Settings",
            vec![
                ("lxqt-config", vec![]),
                ("systemsettings", vec![]),
                ("systemsettings5", vec![]),
            ],
        ),
        _ => return None,
    })
}

pub fn dock_launch(id: &str) -> Value {
    let Some((label, commands)) = dock_commands(id) else {
        return json!({ "ok": false, "error": format!("Unknown dock app: {id}") });
    };
    let Some((bin, args)) = commands
        .iter()
        .find_map(|(cmd, args)| system::which(cmd).map(|b| (b, args)))
    else {
        return json!({ "ok": false, "error": format!("{label} isn't installed on this machine.") });
    };
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    match system::spawn_lasting(&bin, &args, &[]) {
        Ok(()) => json!({ "ok": true }),
        Err(e) => json!({ "ok": false, "error": format!("Couldn't start {label}: {e}") }),
    }
}

/// Web links from the page open in the system browser, never in the shell
pub fn open_external(url: &str) -> bool {
    system::open_url(url)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_dock_apps_are_refused() {
        assert_eq!(dock_launch("rm -rf /")["ok"], false);
        assert!(dock_commands("terminal").is_some());
        assert!(dock_commands("../terminal").is_none());
    }
}
