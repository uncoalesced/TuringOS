// Mic button: dictation into the composer.
// In the app, the backend records and transcribes (local Whisper, or Wispr
// Flow when set up with `turingos voice`). In a plain browser, the Web Speech
// API is used where the browser has one.

const micButton = $('#composer-mic');
let micListening = false;

function setMicListening(on) {
  micListening = on;
  micButton.setAttribute('aria-pressed', String(on));
  micButton.querySelector('use').setAttribute('href', on ? '#ic-mic-off' : '#ic-mic');
  micButton.setAttribute('aria-label', on ? 'Stop dictation' : 'Dictate');
}

function appendTranscript(base, text) {
  input.value = base + text;
  sync();
}

if (window.shell?.voiceStart) {
  let baseText = '';
  window.shell.onVoice((v) => {
    if (v.downloading != null) setHint(`Downloading the speech model… ${v.downloading}%`);
  });
  micButton.addEventListener('click', async () => {
    if (!micListening) {
      baseText = input.value ? `${input.value.trim()} ` : '';
      setMicListening(true);
      const res = await window.shell.voiceStart();
      if (!res.ok) {
        setMicListening(false);
        setHint(res.error, 'error');
      } else {
        setHint('Listening… click the mic again to stop');
      }
      return;
    }
    setMicListening(false);
    setHint('Transcribing…');
    const res = await window.shell.voiceStop();
    if (!res.ok) {
      setHint(res.error, 'error');
      return;
    }
    appendTranscript(baseText, res.text);
    setHint(res.text ? 'Done' : 'Didn’t catch that');
  });
} else {
  const SpeechRecognitionCtor = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!SpeechRecognitionCtor) {
    micButton.disabled = true;
    micButton.title = 'Voice input is not available here';
  } else {
    let recognizer = null;
    micButton.addEventListener('click', () => {
      if (micListening) {
        recognizer?.stop();
        return;
      }
      recognizer = new SpeechRecognitionCtor();
      recognizer.continuous = true;
      recognizer.interimResults = false;
      recognizer.lang = navigator.language || 'en-US';
      const baseText = input.value ? `${input.value.trim()} ` : '';
      recognizer.onstart = () => setMicListening(true);
      recognizer.onresult = (e) => {
        let transcript = '';
        for (let i = e.resultIndex; i < e.results.length; i++) transcript += e.results[i][0].transcript;
        appendTranscript(baseText, transcript);
      };
      recognizer.onerror = (e) => {
        setHint(e.error === 'not-allowed' ? 'Microphone access was denied' : 'Voice input isn’t working right now', 'error');
      };
      recognizer.onend = () => setMicListening(false);
      recognizer.start();
    });
  }
}
