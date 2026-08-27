# VOICEVOX integration

VOICEVOX is provided by the `voicevox` Docker service. Set `VOICEVOX_SPEAKER` in
`.env` to the speaker style ID exposed by the VOICEVOX `/speakers` endpoint.

The voice inventory is generated offline from WAV files using
`scripts/build_voice_inventory.py`.
