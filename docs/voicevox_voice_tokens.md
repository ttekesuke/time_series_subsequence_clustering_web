# VOICEVOX voice integration

The generation pipeline keeps voice-token clustering and MFCC inventory
calculation unchanged. VOICEVOX supplies the audio engine in two places:

1. Offline, render each token text (for example `あ` and `え`) through the
   VOICEVOX Engine API and pass the resulting WAV files to
   `scripts/build_voice_inventory.py`.
2. At composition render time, the generated `voicePlan` tokens and their
   MIDI carrier notes are sent to the local worker. It calls
   `/sing_frame_audio_query` then `/frame_synthesis`, returning one sung WAV
   stem per stream. Generator tokens are one Japanese mora, matching Song's
   per-note lyric restriction.

## Docker

The development Compose stack starts `voicevox/voicevox_engine` and a small
HTTP adapter at `voicevox-worker:9120`. Configure the speaker style ID with:

```dotenv
VOICEVOX_ENABLED=true
VOICEVOX_RENDER_MODE=sing
VOICEVOX_SINGING_TEACHER=6000
VOICEVOX_SINGER=3003
```

Use `/singers` to list Song IDs. The query ID must be `sing`/`singing_teacher`
(6000 is the bundled 波音リツ); the render ID must be `frame_decode` (3003 is
ずんだもん・ノーマル). `VOICEVOX_RENDER_MODE=talk` retains the prior TTS path.
Production deployments without the engine should set `VOICEVOX_ENABLED=false`.

Song is monophonic: this app uses the median chord note as the carrier. The
worker passes that MIDI note to Song unchanged. A singer-specific range shift,
when needed, must be an explicit adjustment of the returned `f0` values rather
than an implicit change to the composition's notes.

## Build an inventory

Create WAV samples with consistent speaker, text, duration, and loudness. Then
use the existing extractor:

```bash
python3 -m venv .venv-voice
.venv-voice/bin/pip install -r scripts/requirements-voice-inventory.txt
.venv-voice/bin/python scripts/build_voice_inventory.py \
  path/to/manifest.json config/voice_inventories/my_voicevox.json
```

The extractor computes MFCC and spectral/temporal features, applies robust
scaling and PCA, and writes normalized vectors. Runtime generation loads this
JSON; it does not analyze WAV files.
