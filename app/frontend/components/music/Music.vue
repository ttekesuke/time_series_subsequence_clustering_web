<script setup lang="ts">
import { ref, onMounted, nextTick, watch } from 'vue'
import * as Tone from 'tone'
const props = defineProps<{
  midiData: any;
  secondsPerTick: number;
}>()

const canvas = ref<HTMLCanvasElement | null>(null)
const isPlaying = ref(false)
const startTime = ref(0)
const scrollOffset = ref(0)



const canvasWidth = 3000  // 長めに確保
const canvasHeight = 600
const noteHeight = 6
const pixelsPerSecond = 100
const barOffsetX = 0  // 再生バーのX位置（スクロール固定）

let animationFrameId: number | null = null



const drawPianoRoll = (scrollTime) => {
  if (!canvas.value) return;
  const ctx = canvas.value.getContext('2d')
  if (!ctx) return;
  ctx.clearRect(0, 0, canvas.value.width, canvas.value.height)

  const visibleOffsetX = scrollTime * pixelsPerSecond

  props.midiData.tracks.forEach((track, trackIndex) => {
    const color = ['#f44336', '#2196f3', '#4caf50', '#ff9800'][trackIndex % 4]


    track.notes.forEach(note => {
      const startTime = note.ticks * props.secondsPerTick
      const duration = note.durationTicks * props.secondsPerTick

      const x = startTime * pixelsPerSecond - visibleOffsetX + barOffsetX
      const y = (127 - note.midi) * noteHeight
      const width = duration * pixelsPerSecond
      const height = noteHeight

      if (x + width >= 0 && x <= canvasWidth) {
        ctx.fillStyle = color
        ctx.fillRect(x, y, width, height)
      }
    })

  })

  // 再生バー
  ctx.strokeStyle = 'black'
  ctx.beginPath()
  ctx.moveTo(barOffsetX, 0)
  ctx.lineTo(barOffsetX, canvasHeight)
  ctx.stroke()
}

const playMidi = async () => {
  if (!props.midiData) return

  await Tone.start()
  const now = Tone.now() + 0.5

  // 再生用シンセ
  const synth = new Tone.PolySynth().toDestination()

  props.midiData.tracks.forEach(track => {
    track.notes.forEach(note => {

      const duration = note.durationTicks * props.secondsPerTick

      synth.triggerAttackRelease(
        note.name,      // 例: 'C4'
        duration,       // 秒に変換した長さ
        now + note.ticks * props.secondsPerTick // 開始時間
      )
    })
  })

  isPlaying.value = true
  startTime.value = performance.now()
  animate()
}

const animate = () => {
  const elapsedMs = performance.now() - startTime.value
  const elapsedSec = elapsedMs / 1000

  drawPianoRoll(elapsedSec)

  // duration を計算
  const allNotes = props.midiData.tracks.flatMap(track => track.notes)
  const maxTick = Math.max(...allNotes.map(note => note.ticks + note.durationTicks))
  const midiDurationSec = maxTick * props.secondsPerTick

  if (elapsedSec < midiDurationSec) {
    animationFrameId = requestAnimationFrame(animate)
  } else {
    isPlaying.value = false
    if (animationFrameId !== null) {
      cancelAnimationFrame(animationFrameId)
    }
  }
}


watch(() => props.midiData, () => drawPianoRoll(0), { deep: true })

</script>

<template>
  <v-container>
    <v-row>
      <v-col cols="2">
        <v-btn color="primary" @click="playMidi" :disabled="!midiData || isPlaying">
          ▶️ Play
        </v-btn>
      </v-col>
    </v-row>
    <div style="overflow-x: hidden; border: 1px solid #ccc; margin-top: 20px;">
      <canvas
        ref="canvas"
        :width="canvasWidth"
        :height="canvasHeight"
        style="display: block;"
      ></canvas>
    </div>
  </v-container>
</template>


<style scoped>
canvas {
  width: 100%;
  height: 600px;
  background-color: #fafafa;
}
</style>
