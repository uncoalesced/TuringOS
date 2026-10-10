// Weather: location from the public IP (ipapi.co, fallback ipwho.is),
// weather from Open-Meteo. No API keys. Override with
// TURINGOS_WEATHER="lat,lon,City", or turn it off with TURINGOS_WEATHER=off.

use serde_json::{json, Value};
use std::sync::OnceLock;
use std::time::Duration;

static PLACE: OnceLock<(f64, f64, Option<String>)> = OnceLock::new();

async fn get_json(url: &str) -> Option<Value> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(6))
        .build()
        .ok()?;
    let res = client.get(url).send().await.ok()?;
    if !res.status().is_success() {
        return None;
    }
    res.json().await.ok()
}

async fn locate() -> Option<(f64, f64, Option<String>)> {
    if let Ok(env) = std::env::var("TURINGOS_WEATHER") {
        let mut parts = env.splitn(3, ',');
        let lat = parts.next()?.trim().parse().ok()?;
        let lon = parts.next()?.trim().parse().ok()?;
        return Some((
            lat,
            lon,
            parts
                .next()
                .map(|c| c.trim().to_string())
                .filter(|c| !c.is_empty()),
        ));
    }
    for url in ["https://ipapi.co/json/", "https://ipwho.is/"] {
        if let Some(j) = get_json(url).await {
            if let (Some(lat), Some(lon)) = (j["latitude"].as_f64(), j["longitude"].as_f64()) {
                return Some((lat, lon, j["city"].as_str().map(str::to_string)));
            }
        }
    }
    None
}

pub async fn fetch() -> Option<Value> {
    if std::env::var("TURINGOS_WEATHER").as_deref() == Ok("off") {
        return None;
    }
    let place = match PLACE.get() {
        Some(p) => p.clone(),
        None => {
            let p = locate().await?;
            PLACE.get_or_init(|| p).clone()
        }
    };
    let (lat, lon, city) = place;
    let url = format!(
        "https://api.open-meteo.com/v1/forecast?latitude={lat}&longitude={lon}&timezone=auto&current=\
         temperature_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m,wind_direction_10m,is_day"
    );
    let c = get_json(&url).await?.get("current")?.clone();
    let round = |k: &str| c[k].as_f64().map(f64::round);
    Some(json!({
        "city": city,
        "temp": round("temperature_2m")?,
        "feels": round("apparent_temperature")?,
        "rain": c["precipitation"],
        "wind": round("wind_speed_10m")?,
        "windDir": c["wind_direction_10m"],
        "code": c["weather_code"],
        "day": c["is_day"].as_i64() == Some(1),
    }))
}
