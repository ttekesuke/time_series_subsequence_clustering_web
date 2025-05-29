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
const canvasWidth = 3000  // 長めに確保
const canvasHeight = 800
const noteHeight = 8
const pixelsPerSecond = 100
const barOffsetX = 0  // 再生バーのX位置（スクロール固定）

let animationFrameId: number | null = null


// 再生開始
const start = () => {
  if (isPlaying.value) return
  startTime.value = performance.now()
  isPlaying.value = true
  animationFrameId = requestAnimationFrame(animate)
}

// 停止
const stop = () => {
  isPlaying.value = false
  if (animationFrameId !== null) {
    cancelAnimationFrame(animationFrameId)
    animationFrameId = null
  }
}
const drawPianoRoll = (scrollTime) => {
  if (!canvas.value || !props.midiData.tracks) return;
  const ctx = canvas.value.getContext('2d')
  if (!ctx) return;
  ctx.clearRect(0, 0, canvas.value.width, canvas.value.height)

  const visibleOffsetX = scrollTime * pixelsPerSecond

  props.midiData.tracks.forEach((track, trackIndex) => {
    const color = track.color
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

        ctx.strokeStyle = 'black'
        ctx.lineWidth = 1
        ctx.strokeRect(x, y, width, height)
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

const animate = () => {
  if (!isPlaying.value) return

  const elapsedMs = performance.now() - startTime.value
  const elapsedSec = elapsedMs / 1000

  drawPianoRoll(elapsedSec)

  // MIDI全体の長さを計算
  const allNotes = props.midiData.tracks.flatMap(track => track.notes)
  const maxTick = Math.max(...allNotes.map(note => note.ticks + note.durationTicks))
  const midiDurationSec = maxTick * props.secondsPerTick

  if (elapsedSec < midiDurationSec) {
    animationFrameId = requestAnimationFrame(animate)
  } else {
    stop()
  }
}

watch(() => props.midiData, () => drawPianoRoll(0), { deep: true })
defineExpose({
  start, stop
})
</script>

<template>
  <v-container>
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
  height: 800px;
  background-color: #fafafa;
}
</style>
