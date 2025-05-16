// PianoRoll.vue
<template>
  <div :style="{height: height + 'px', width: '100%', position: 'relative'}">
    <canvas ref="canvas" :width="width" :height="height" class="border" style="z-index: 1; position: absolute"></canvas>
    <PlayHead :x="playheadX" :height="height" />
  </div>
</template>

<script setup lang="ts">
import { onMounted, ref, computed } from 'vue';
import PlayHead from './PlayHead.vue';
import type { Voice, TimeSignature } from '../../types/types';
import { drawPianoRoll } from '../../utils/piano-utils';

const props = defineProps<{
  voices: Voice[];
  timeSignature: TimeSignature;
  beatWidth: number;
  playheadTime: number;
  pixelsPerSecond: number;
}>();

const canvas = ref<HTMLCanvasElement | null>(null);
const width = 2000;
const height = 300;

const playheadX = computed(() => props.playheadTime * props.pixelsPerSecond);


onMounted(() => {
  const ctx = canvas.value!.getContext('2d')!;
  drawPianoRoll(ctx, props.voices, props.timeSignature, props.beatWidth, width, height);
});
</script>
