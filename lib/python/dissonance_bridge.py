from dissonant import pitch_to_freq, harmonic_tone, dissonance

def compute_dissonance(midi_notes, n_partials=10, model='sethares1993'):
    freqs = pitch_to_freq(midi_notes)
    freqs, amps = harmonic_tone(freqs, n_partials=n_partials)
    return dissonance(freqs, amps, model=model)
