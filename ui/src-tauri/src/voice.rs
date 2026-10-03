// Voice input for the composer's mic button.
//
// Records the default microphone, then transcribes with local Whisper
// (whisper.cpp; the ggml base.en model downloads on first use), or with
// Wispr Flow when `turingos voice backend wispr` is set — falling back to
// Whisper if Wispr fails for any reason.

use crate::config_env;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, SizedSample};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{mpsc, Arc, Mutex};
use std::thread::JoinHandle;
use tauri::{AppHandle, Emitter};
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

const MODEL_URL: &str =
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin";
const MODEL_SHA256: &str = "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002";
const RATE: u32 = 16_000;

type Captured = Result<(Vec<f32>, u32), String>;

struct Recording {
    stop: mpsc::Sender<()>,
    thread: JoinHandle<Captured>,
}

#[derive(Default)]
pub struct Recorder(Mutex<Option<Recording>>);

fn ok_text(text: &str) -> Value {
    json!({ "ok": true, "text": text })
}

fn fail(msg: &str) -> Value {
    json!({ "ok": false, "error": msg })
}

fn model_path() -> PathBuf {
    config_env::data_dir()
        .join("models")
        .join("ggml-base.en.bin")
}

fn backend() -> String {
    config_env::get("TURINGOS_VOICE_BACKEND").unwrap_or_else(|| "whisper".into())
}

// ─── Commands ─────────────────────────────────────────────────────────────────

#[tauri::command]
pub async fn voice_start(
    app: AppHandle,
    recorder: tauri::State<'_, Recorder>,
) -> Result<Value, ()> {
    if recorder.0.lock().unwrap().is_some() {
        return Ok(json!({ "ok": true }));
    }
    if backend() != "wispr" {
        if let Err(e) = ensure_model(&app).await {
            return Ok(fail(&e));
        }
    }

    let (stop_tx, stop_rx) = mpsc::channel();
    let (ready_tx, ready_rx) = mpsc::channel();
    let thread = std::thread::spawn(move || record(stop_rx, ready_tx));
    let ready = tauri::async_runtime::spawn_blocking(move || ready_rx.recv())
        .await
        .ok()
        .and_then(Result::ok)
        .unwrap_or_else(|| Err("The microphone stopped unexpectedly".into()));
    match ready {
        Ok(()) => {
            *recorder.0.lock().unwrap() = Some(Recording {
                stop: stop_tx,
                thread,
            });
            Ok(json!({ "ok": true }))
        }
        Err(e) => Ok(fail(&e)),
    }
}

#[tauri::command]
pub async fn voice_stop(app: AppHandle, recorder: tauri::State<'_, Recorder>) -> Result<Value, ()> {
    let Some(rec) = recorder.0.lock().unwrap().take() else {
        return Ok(fail("Not recording"));
    };
    let _ = rec.stop.send(());
    let captured = tauri::async_runtime::spawn_blocking(move || rec.thread.join())
        .await
        .ok()
        .and_then(Result::ok)
        .unwrap_or_else(|| Err("The microphone stopped unexpectedly".into()));
    let (samples, rate) = match captured {
        Ok(c) => c,
        Err(e) => return Ok(fail(&e)),
    };
    let samples = resample(&samples, rate);
    // Whisper "hears" words like "you" in silence: don't transcribe it
    if samples.len() < (RATE / 4) as usize || is_silent(&samples) {
        return Ok(ok_text(""));
    }

    if backend() == "wispr" {
        let wav = samples.clone();
        if let Ok(Ok(text)) =
            tauri::async_runtime::spawn_blocking(move || transcribe_wispr(&wav)).await
        {
            return Ok(ok_text(&text));
        }
        // Any Wispr failure: fall back to local Whisper
    }
    let model = match ensure_model(&app).await {
        Ok(m) => m,
        Err(e) => return Ok(fail(&e)),
    };
    Ok(
        match tauri::async_runtime::spawn_blocking(move || transcribe_whisper(&model, &samples))
            .await
        {
            Ok(Ok(text)) => ok_text(&text),
            _ => fail("Couldn't transcribe that — try again"),
        },
    )
}

// ─── Recording ────────────────────────────────────────────────────────────────

type Setup = (cpal::Stream, Arc<Mutex<Vec<f32>>>, u32);

/// Runs on its own thread (a cpal stream can't move between threads):
/// records mono f32 until `stop` fires
fn record(stop: mpsc::Receiver<()>, ready: mpsc::Sender<Result<(), String>>) -> Captured {
    match open_mic() {
        Ok((stream, buf, rate)) => {
            let _ = ready.send(Ok(()));
            let _ = stop.recv();
            drop(stream);
            let samples = std::mem::take(&mut *buf.lock().unwrap());
            Ok((samples, rate))
        }
        Err(e) => {
            let _ = ready.send(Err(e.clone()));
            Err(e)
        }
    }
}

fn open_mic() -> Result<Setup, String> {
    let device = cpal::default_host()
        .default_input_device()
        .ok_or("No microphone found")?;
    let config = device
        .default_input_config()
        .map_err(|_| "The microphone isn't available")?;
    let rate = config.sample_rate().0;
    let channels = usize::from(config.channels());
    let buf = Arc::new(Mutex::new(Vec::new()));
    let cfg = config.config();
    let stream = match config.sample_format() {
        cpal::SampleFormat::F32 => build::<f32>(&device, &cfg, channels, buf.clone()),
        cpal::SampleFormat::I16 => build::<i16>(&device, &cfg, channels, buf.clone()),
        cpal::SampleFormat::U16 => build::<u16>(&device, &cfg, channels, buf.clone()),
        cpal::SampleFormat::I32 => build::<i32>(&device, &cfg, channels, buf.clone()),
        _ => return Err("Unsupported microphone format".into()),
    }
    .map_err(|_| "Couldn't open the microphone")?;
    stream.play().map_err(|_| "Couldn't start the microphone")?;
    Ok((stream, buf, rate))
}

fn build<T>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    channels: usize,
    buf: Arc<Mutex<Vec<f32>>>,
) -> Result<cpal::Stream, cpal::BuildStreamError>
where
    T: SizedSample,
    f32: FromSample<T>,
{
    device.build_input_stream(
        config,
        move |data: &[T], _: &cpal::InputCallbackInfo| {
            // Downmix each frame to mono as it arrives
            let mut b = buf.lock().unwrap();
            b.extend(data.chunks(channels).map(|frame| {
                frame.iter().map(|s| s.to_sample::<f32>()).sum::<f32>() / channels as f32
            }));
        },
        |e| eprintln!("turingos-ui: microphone error: {e}"),
        None,
    )
}

/// Linear resample to 16 kHz, what Whisper expects
fn resample(input: &[f32], from: u32) -> Vec<f32> {
    if from == RATE || input.is_empty() {
        return input.to_vec();
    }
    let ratio = f64::from(from) / f64::from(RATE);
    let len = (input.len() as f64 / ratio) as usize;
    (0..len)
        .map(|i| {
            let pos = i as f64 * ratio;
            let j = pos as usize;
            let a = input[j];
            let b = *input.get(j + 1).unwrap_or(&a);
            a + (b - a) * (pos - j as f64) as f32
        })
        .collect()
}

// ─── Whisper ──────────────────────────────────────────────────────────────────

async fn ensure_model(app: &AppHandle) -> Result<PathBuf, String> {
    let path = model_path();
    if path.exists() {
        return Ok(path);
    }
    const OFFLINE: &str = "Couldn't download the speech model — check the network and try again";
    std::fs::create_dir_all(path.parent().unwrap_or(Path::new("."))).map_err(|_| OFFLINE)?;
    let part = path.with_extension("bin.part");

    let mut res = reqwest::get(MODEL_URL).await.map_err(|_| OFFLINE)?;
    if !res.status().is_success() {
        return Err(OFFLINE.into());
    }
    let total = res.content_length().unwrap_or(0);
    let mut file = std::fs::File::create(&part).map_err(|_| OFFLINE)?;
    let mut hasher = Sha256::new();
    let (mut done, mut last_pct) = (0u64, u64::MAX);
    while let Some(chunk) = res.chunk().await.map_err(|_| OFFLINE)? {
        hasher.update(&chunk);
        file.write_all(&chunk).map_err(|_| OFFLINE)?;
        done += chunk.len() as u64;
        let pct = (done * 100).checked_div(total).unwrap_or(0);
        if pct != last_pct {
            last_pct = pct;
            let _ = app.emit("voice", json!({ "downloading": pct }));
        }
    }
    drop(file);
    if format!("{:x}", hasher.finalize()) != MODEL_SHA256 {
        let _ = std::fs::remove_file(&part);
        return Err("The speech model download was corrupted — try again".into());
    }
    std::fs::rename(&part, &path).map_err(|_| OFFLINE)?;
    Ok(path)
}

fn transcribe_whisper(model: &Path, samples: &[f32]) -> Result<String, String> {
    let model = model
        .to_str()
        .ok_or("Speech model path isn't valid UTF-8")?;
    let ctx = WhisperContext::new_with_params(model, WhisperContextParameters::default())
        .map_err(|e| e.to_string())?;
    let mut state = ctx.create_state().map_err(|e| e.to_string())?;
    let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
    params.set_language(Some("en"));
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_special(false);
    params.set_print_timestamps(false);
    let threads = std::thread::available_parallelism()
        .map(|n| n.get().min(8))
        .unwrap_or(4);
    params.set_n_threads(threads as i32);
    state.full(params, samples).map_err(|e| e.to_string())?;
    let text: String = (0..state.full_n_segments())
        .filter_map(|i| state.get_segment(i))
        .filter_map(|s| s.to_str_lossy().ok().map(|t| t.into_owned()))
        .collect();
    Ok(text.trim().to_string())
}

// ─── Wispr Flow (unofficial, opt-in) ─────────────────────────────────────────

fn transcribe_wispr(samples: &[f32]) -> Result<String, String> {
    let dir = config_env::data_dir().join("wispr");
    let python = dir.join("venv").join("bin").join("python");
    let root = std::env::var_os("TURINGOS_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| "/usr/lib/turingos".into());
    let wav = std::env::temp_dir().join(format!("turingos-voice-{}.wav", std::process::id()));
    write_wav(&wav, samples).map_err(|e| e.to_string())?;
    let out = Command::new(python)
        .arg(root.join("voice").join("wispr_transcribe.py"))
        .arg(dir.join("session.json"))
        .arg(&wav)
        .output();
    let _ = std::fs::remove_file(&wav);
    let out = out.map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).into_owned());
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// 16 kHz mono PCM16 WAV
fn write_wav(path: &Path, samples: &[f32]) -> std::io::Result<()> {
    let data_len = (samples.len() * 2) as u32;
    let mut out = Vec::with_capacity(44 + data_len as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_len).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes()); // fmt chunk size
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&1u16.to_le_bytes()); // mono
    out.extend_from_slice(&RATE.to_le_bytes());
    out.extend_from_slice(&(RATE * 2).to_le_bytes()); // byte rate
    out.extend_from_slice(&2u16.to_le_bytes()); // block align
    out.extend_from_slice(&16u16.to_le_bytes()); // bits per sample
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_len.to_le_bytes());
    for s in samples {
        out.extend_from_slice(&((s.clamp(-1.0, 1.0) * f32::from(i16::MAX)) as i16).to_le_bytes());
    }
    std::fs::write(path, out)
}

/// Peak below about -40 dBFS: nothing a speaker said reached the mic
fn is_silent(samples: &[f32]) -> bool {
    samples.iter().all(|s| s.abs() < 0.01)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn silence_is_not_transcribed() {
        assert!(is_silent(&vec![0.002f32; 16_000]));
        let mut speech = vec![0.0f32; 16_000];
        speech[8_000] = 0.3;
        assert!(!is_silent(&speech));
    }

    #[test]
    fn resamples_to_16k() {
        let one_second_48k = vec![0.5f32; 48_000];
        let out = resample(&one_second_48k, 48_000);
        assert_eq!(out.len(), 16_000);
        assert!(out.iter().all(|s| (s - 0.5).abs() < 1e-6));
        assert_eq!(resample(&[0.1, 0.2], RATE), vec![0.1, 0.2]);
    }

    #[test]
    fn writes_a_valid_wav_header() {
        let path = std::env::temp_dir().join("turingos-wav-test.wav");
        write_wav(&path, &[0.0, 1.0, -1.0]).unwrap();
        let bytes = std::fs::read(&path).unwrap();
        let _ = std::fs::remove_file(&path);
        assert_eq!(bytes.len(), 44 + 6);
        assert_eq!(&bytes[..4], b"RIFF");
        assert_eq!(u32::from_le_bytes(bytes[24..28].try_into().unwrap()), RATE);
        assert_eq!(
            i16::from_le_bytes(bytes[46..48].try_into().unwrap()),
            i16::MAX
        );
    }
}
