// GitHub widget: my open PRs and review requests via the `gh` CLI. No new
// credentials: assumes `gh auth login` was done on this machine.

use serde_json::{json, Value};
use std::process::Command;

fn gh(args: &[&str]) -> Option<Value> {
    let out = Command::new("gh").args(args).output().ok()?;
    if !out.status.success() {
        return None;
    }
    serde_json::from_slice(&out.stdout).ok()
}

/// None when gh is missing or unauthenticated (the caller keeps the last reading)
pub fn fetch() -> Option<Value> {
    let mine = gh(&[
        "pr",
        "list",
        "--author",
        "@me",
        "--json",
        "number,title,headRefName,additions,deletions,statusCheckRollup,reviewDecision,url",
    ]);
    let reviews = gh(&[
        "search",
        "prs",
        "--review-requested=@me",
        "--state",
        "open",
        "--json",
        "number,title,repository,url",
    ]);
    if mine.is_none() && reviews.is_none() {
        return None;
    }
    Some(json!({ "mine": mine.unwrap_or(json!([])), "reviews": reviews.unwrap_or(json!([])) }))
}
