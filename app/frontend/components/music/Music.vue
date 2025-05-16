<template>
  <div class="p-4">
    <PianoRoll
      :voices="voices"
      :timeSignature="timeSignature"
      :beatWidth="beatWidth"
      :playheadTime="playheadTime"
      :pixelsPerSecond="pixelsPerSecond"
    />
    <Controls @play="handlePlay" @stop="handleStop" />
  </div>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import * as Tone from 'tone';
import PianoRoll from './PianoRoll.vue';
import Controls from './Controls.vue';
import { getVoiceColor } from '../../utils/note-color';

const timeSignature = { numerator: 4, denominator: 4 };
const beatWidth = 50;
const pixelsPerSecond = 100;

const playheadTime = ref(0);
let animationId: number;

const voices = ref([
  {
    color: getVoiceColor(0),
    timeline: [
      { pitches: [60, 64, 67], duration: 0.5 },
      { rest: true, duration: 0.5 },
      { pitches: [62], duration: 1 },
    ],
  },
  {
    color: getVoiceColor(1),
    timeline: [
      { pitches: [55], duration: 1 },
      { rest: true, duration: 0.5 },
      { pitches: [57], duration: 0.5 },
    ],
  },
]);

function handlePlay() {
  Tone.start();
  const now = Tone.now();
  playheadTime.value = 0;
  schedulePlayback(voices.value, now);

  const start = performance.now();
  function updatePlayhead(time: number) {
    playheadTime.value = (time - start) / 1000;
    animationId = requestAnimationFrame(updatePlayhead);
  }
  animationId = requestAnimationFrame(updatePlayhead);
}

function handleStop() {
  cancelAnimationFrame(animationId);
  Tone.Transport.stop();
  playheadTime.value = 0;
}

function schedulePlayback(voices, now) {
  voices.forEach((voice) => {
    const synth = new Tone.PolySynth().toDestination();
    let t = now;
    voice.timeline.forEach((group) => {
      if ('pitches' in group) {
        synth.triggerAttackRelease(
          group.pitches.map((p) => Tone.Frequency(p, 'midi')),
          group.duration + 'n',
          t
        );
      }
      t += Tone.Time(group.duration + 'n').toSeconds();
    });
  });
}
</script>
