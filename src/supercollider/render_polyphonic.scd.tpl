// Auto-generated SuperCollider script (NRT render)
// Placeholders injected by Julia:
//   {{SCORE_EVENTS}}: Score bundles for /s_new
//   {{SOUND_FILE_PATH}}: output wav path
//   {{STEP_DURATION}}: time step duration (sec)
//   {{TOTAL_DURATION_PAD}}: total render duration incl. tail (sec)

(
var server = Server(\nrt,
    options: ServerOptions.new
        .numOutputBusChannels_(2)
        .numInputBusChannels_(2)
        .sampleRate_(44100)
);

var score;
var outPath = "{{SOUND_FILE_PATH}}";

score = Score([
  [0.0, ['/d_recv',
    SynthDef(\polySynth, {
        |out=0, freq=440, dur={{STEP_DURATION}}, amp=0.5,
         brightness=0.5, hardness=0.5, texture=0.0, resonance=0.2|

        var sig, env, core, sub;
        var attackTime, releaseTime, cutoff, rq, feedback, pulseWidth, noiseSig;

        attackTime = (1.0 - hardness).linexp(0.0, 1.0, 0.001, 0.2).min(dur * 0.5);
        releaseTime = dur * (1.0 + (resonance * 2.0));
        env = EnvGen.ar(Env.perc(attackTime, releaseTime, 1.0, -4), doneAction: 2);

        feedback = texture.linlin(0.0, 1.0, 0.0, 2.5);
        core = SinOscFB.ar(freq, feedback);

        pulseWidth = 0.5 + (texture * 0.4);
        core = core * (1.0 - (texture * 0.5)) + (Pulse.ar(freq, pulseWidth) * (texture * 0.5));

        noiseSig = PinkNoise.ar() * (texture - 0.7).max(0) * 0.5;
        sub = SinOsc.ar(freq) * (1.0 - texture).max(0.2) * 0.5;
        sig = core + noiseSig + sub;

        cutoff = freq * (1 + (brightness * 20));
        cutoff = cutoff.clip(20, 20000);

        rq = (1.0 - (resonance * 0.95)).clip(0.02, 1.0);

        sig = RLPF.ar(sig, cutoff, rq);
        sig = BHiShelf.ar(sig, 3000, 1.0, (brightness - 0.5) * 12);

        sig = sig * env * amp;
        sig = sig.tanh;

        Out.ar(out, sig ! 2);
    }).asBytes;
  ]],

  {{SCORE_EVENTS}}
]);

score.recordNRT(
    outputFilePath: outPath,
    headerFormat: "wav",
    sampleFormat: "int16",
    options: server.options,
    duration: {{TOTAL_DURATION_PAD}},
    action: { "done".postln; 0.exit; }
);

server.remove;
)
