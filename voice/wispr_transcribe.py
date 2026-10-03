"""Transcribe a WAV file with Wispr Flow via the unofficial wisprflow-re client.

Usage: wispr_transcribe.py SESSION_JSON AUDIO_WAV
Prints the transcript on stdout. Any failure exits non-zero, and the desktop
UI falls back to local Whisper.
"""

import sys
from pathlib import Path

from wisprflow import WisprClient


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    session, audio = (Path(arg) for arg in sys.argv[1:])
    client = WisprClient.from_desktop(session_path=session, auto_discover=False)
    print(client.transcribe(audio).final)
    return 0


if __name__ == "__main__":
    sys.exit(main())
