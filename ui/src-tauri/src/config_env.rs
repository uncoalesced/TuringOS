// Paths under ~/.turingos and values from ~/.turingos/config.env.
//
// The kiosk session starts this binary directly (not via `turingos ui`), so
// config.env is never sourced into our environment: read it ourselves. A
// real exported env var still wins.

use std::path::PathBuf;

pub fn home() -> PathBuf {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .unwrap_or_default()
}

pub fn data_dir() -> PathBuf {
    home().join(".turingos")
}

pub fn get(key: &str) -> Option<String> {
    if let Ok(v) = std::env::var(key) {
        if !v.is_empty() {
            return Some(v);
        }
    }
    let text = std::fs::read_to_string(data_dir().join("config.env")).ok()?;
    text.lines()
        .filter_map(|line| line.trim().split_once('='))
        .filter(|(k, _)| *k == key)
        .map(|(_, v)| unquote(v))
        .next_back()
        .filter(|v| !v.is_empty())
}

/// Undo the shell quoting `config::set` writes (`printf %q`): $'..', '..',
/// "..", or backslash-escaped bare words.
pub fn unquote(raw: &str) -> String {
    let raw = raw.trim();
    if let Some(inner) = raw.strip_prefix("$'").and_then(|s| s.strip_suffix('\'')) {
        return unescape(inner, |c| match c {
            'n' => Some('\n'),
            't' => Some('\t'),
            'r' => Some('\r'),
            '\\' | '\'' | '"' => Some(c),
            _ => None,
        });
    }
    if let Some(inner) = raw.strip_prefix('\'').and_then(|s| s.strip_suffix('\'')) {
        return inner.to_string();
    }
    if let Some(inner) = raw.strip_prefix('"').and_then(|s| s.strip_suffix('"')) {
        return unescape(inner, |c| matches!(c, '"' | '\\' | '$' | '`').then_some(c));
    }
    unescape(raw, Some)
}

fn unescape(s: &str, map: impl Fn(char) -> Option<char>) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some(n) => match map(n) {
                Some(m) => out.push(m),
                None => {
                    out.push('\\');
                    out.push(n);
                }
            },
            None => out.push('\\'),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::unquote;

    #[test]
    fn unquotes_printf_q_output() {
        assert_eq!(unquote("sk-ant-abc_123"), "sk-ant-abc_123");
        assert_eq!(unquote(r"a\ b\ \$\(touch\ x\)"), "a b $(touch x)");
        assert_eq!(unquote(r"$'line\nnext'"), "line\nnext");
        assert_eq!(unquote("'single quoted'"), "single quoted");
        assert_eq!(unquote(r#""dq \"x\"""#), r#"dq "x""#);
    }
}
