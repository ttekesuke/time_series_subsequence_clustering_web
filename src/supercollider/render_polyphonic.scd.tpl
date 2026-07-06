// Auto-generated SuperCollider script (NRT render)
// Julia injects score events, output path, step duration, and total duration below.

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
        |outBus=16, freq=440, dur={{STEP_DURATION}}, amp=0.3,
         brightness=0.5, noise=0.2, harmonicity=1.0, attack=0.05,
         decay=0.20, sustainRelease=0.75|

        var sig, env;
        var bri, noi, harCtl, atkCtl, decCtl, srCtl;
        var tonalSig, noiseSig;
        var ratios, partialAmps, cutoff, sustainLevel, harmonicBlend, cleanMix;
        var totalCtl, timeScale, attackTime, decayTime, sustainTime, releaseTime;

        bri = brightness.clip(0,1);
        noi = noise.clip(0,1);
        harCtl = harmonicity.clip(0,1);
        atkCtl = attack.clip(0,1);
        decCtl = decay.clip(0,1);
        srCtl = sustainRelease.clip(0,1);

        totalCtl = atkCtl + decCtl + srCtl;
        timeScale = dur / totalCtl.max(1.0);

        attackTime = atkCtl * timeScale;
        decayTime = decCtl * timeScale;
        sustainTime = (srCtl * 0.7) * timeScale;
        releaseTime = (srCtl * 0.3) * timeScale;

        sustainLevel = 0.65;
        env = EnvGen.kr(Env([0, 1, sustainLevel, sustainLevel, 0], [attackTime, decayTime, sustainTime, releaseTime], [-4, -2, 0, -4]), doneAction:2);

        ratios = [
          1.0,
          2.65 - (0.65 * harCtl),
          4.10 - (1.10 * harCtl),
          5.80 - (1.80 * harCtl)
        ];
        partialAmps = [1.0, 0.55 * bri, 0.32 * bri.squared, 0.20 * bri.squared];
        tonalSig = Mix.fill(4, { |i| SinOsc.ar(freq * ratios[i], 0, partialAmps[i]) });
        harmonicBlend = bri.squared;
        tonalSig = XFade2.ar(SinOsc.ar(freq, 0, 1.0), tonalSig, (harmonicBlend * 2) - 1);

        cutoff = 500 + (bri * 16000);
        tonalSig = LPF.ar(tonalSig, cutoff.clip(80, 18000));
        tonalSig = BHiShelf.ar(tonalSig, 3500, 0.8, (bri - 0.5) * 18);
        noiseSig = WhiteNoise.ar(0.7 * noi);
        sig = tonalSig + noiseSig;
        cleanMix = (1.0 - noi).clip(0, 1);
        sig = (sig * cleanMix) + (tanh(sig * 1.4) * (1.0 - cleanMix));
        sig = LeakDC.ar(sig);

        sig = sig * env * amp;
        Out.ar(outBus, sig ! 2);
    }).asBytes;
  ]],

  [0.0, ['/d_recv',
    SynthDef(\masterOut, {
        |inBus=16, out=0, masterGain=0.92|
        var sig;
        sig = In.ar(inBus, 2);
        sig = LeakDC.ar(sig);
        sig = CompanderD.ar(sig, thresh: 0.65, slopeBelow: 1.0, slopeAbove: 0.5, clampTime: 0.003, relaxTime: 0.10);
        sig = Limiter.ar(sig, 0.92, 0.005);
        Out.ar(out, sig * masterGain);
    }).asBytes;
  ]],

  [0.0, ['/s_new', \masterOut, 900, 1, 0, \inBus, 16, \out, 0, \masterGain, 0.92]],

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
