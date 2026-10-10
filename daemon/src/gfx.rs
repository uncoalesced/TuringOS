// Graphics level hint for the page. The session launcher works out whether
// this machine draws with a GPU or in software (session/turingos-gfx-detect),
// leaves the answer in the runtime dir, and puts it in the page's URL too so
// the level is set before anything paints. The page also gets it in `hello`.

use serde_json::{json, Value};
use std::path::Path;

const PATHS: [&str; 2] = ["gpu", "sw"];
const TIERS: [&str; 3] = ["full", "lite", "minimal"];

/// Parse the launcher's `GFX_PATH=sw` / `GFX_TIER=lite` lines. Anything
/// missing or unknown falls back to a GPU at full quality, and the page
/// steps itself down if frames turn out slow.
fn parse(env: &str) -> Value {
    let field = |name: &str, allowed: &[&'static str], default: &'static str| {
        env.lines()
            .filter_map(|l| l.trim().split_once('='))
            .find(|(k, _)| k.trim() == name)
            .map(|(_, v)| v.trim().trim_matches(|c| c == '"' || c == '\''))
            .and_then(|v| allowed.iter().find(|a| **a == v).copied())
            .unwrap_or(default)
    };
    json!({ "path": field("GFX_PATH", &PATHS, "gpu"), "tier": field("GFX_TIER", &TIERS, "full") })
}

pub fn hint(runtime_dir: &Path) -> Value {
    parse(&std::fs::read_to_string(runtime_dir.join("gfx.env")).unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_launcher_hint() {
        assert_eq!(
            parse("GFX_PATH=sw\nGFX_TIER=lite\n"),
            json!({ "path": "sw", "tier": "lite" })
        );
        assert_eq!(
            parse("GFX_TIER=\"minimal\"\nGFX_PATH='sw'"),
            json!({ "path": "sw", "tier": "minimal" })
        );
    }

    #[test]
    fn unknown_values_fall_back() {
        let default = json!({ "path": "gpu", "tier": "full" });
        assert_eq!(parse(""), default);
        assert_eq!(parse("GFX_PATH=cuda\nGFX_TIER=ultra"), default);
        assert_eq!(parse("GFX_TIER=</script>"), default);
    }
}
