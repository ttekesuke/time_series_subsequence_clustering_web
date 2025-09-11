<script setup lang="ts">
import { ref, onMounted, nextTick, watch } from 'vue'
const props = defineProps<{
  midiData: any;
  secondsPerTick: number;
}>()

const canvas = ref<HTMLCanvasElement | null>(null)
const scrollWrapper = ref<HTMLDivElement | null>(null)
const isPlaying = ref(false)
const startTime = ref(0)
const canvasWidth = 1766
const canvasHeight = 800
const noteHeight = 8
const pixelsPerSecond = 64
const midiDurationSec = ref(0) // MIDI全体の長さ（秒）
const scrollCoreWidth = ref(0) // スクロール領域の幅（ピクセル）
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
const drawPianoRoll = (scrollTime: number) => {
  if (!canvas.value || !props.midiData.tracks) return;
  const ctx = canvas.value.getContext('2d')
  if (!ctx) return;
  ctx.clearRect(0, 0, canvas.value.width, canvas.value.height)

  // 描画領域の左端のピクセル数
  const visibleOffsetX = scrollTime * pixelsPerSecond

  props.midiData.tracks.forEach((track, trackIndex) => {
    const color = track.color
    track.notes.forEach(note => {
      // 1tickの秒数を元に、noteの開始時間と長さを計算
      const startTime = note.ticks * props.secondsPerTick
      const duration = note.durationTicks * props.secondsPerTick

      // 描画x座標は開始時間×1秒あたりのピクセル数−スクロール量
      const xPosition = startTime * pixelsPerSecond - visibleOffsetX
      const yPosition = (127 - note.midi) * noteHeight
      const width = duration * pixelsPerSecond
      const height = noteHeight

      if (0 <= xPosition + width && xPosition <= canvasWidth) {
        ctx.fillStyle = color
        ctx.fillRect(xPosition, yPosition, width, height)

        ctx.strokeStyle = 'black'
        ctx.lineWidth = 1
        ctx.strokeRect(xPosition, yPosition, width, height)
      }
    })
  })
}

const animate = () => {
  if (!isPlaying.value) return

  const elapsedMs = performance.now() - startTime.value
  const elapsedSec = elapsedMs / 1000
  scrollHandler(elapsedSec)
  // midi全体の長さより経過時間が短かったら次のフレーム
  if (elapsedSec < midiDurationSec.value) {
    animationFrameId = requestAnimationFrame(animate)
  } else {
    stop()
  }
}

const scrollHandler = (elapsedSec: number) => {
  if (!scrollWrapper.value) return
  scrollWrapper.value.scrollTo(elapsedSec * pixelsPerSecond, 0)
}

const onScroll = (event: Event) => {
  const target = event.target as HTMLElement
  const scrollTime = target.scrollLeft / pixelsPerSecond
  drawPianoRoll(scrollTime)
}

// 初期描画
watch(() =>
  props.midiData, () => {
    // MIDI全体の長さを計算
    const allNotes = props.midiData.tracks.flatMap(track => track.notes)
    const maxTick = Math.max(...allNotes.map(note => note.ticks + note.durationTicks))
    midiDurationSec.value = maxTick * props.secondsPerTick

    // スクロール領域の幅をMIDIの長さに合わせて調整
    nextTick(() => {
      scrollCoreWidth.value = midiDurationSec.value * pixelsPerSecond
    })
    drawPianoRoll(0)
  }, { deep: true }
)
defineExpose({
  start, stop
})
</script>

<template>
  <v-container>
    <div style="border: 1px solid #ccc; margin-top: 20px;">
      <canvas
        ref="canvas"
        :width="canvasWidth"
        :height="canvasHeight"
        style="display: block;"
      ></canvas>
      <div class="scroll-wrapper" @scroll="onScroll" ref="scrollWrapper">
        <div class="scroll-core" :style="{ width: scrollCoreWidth + 'px' }"></div>
      </div>
    </div>
  </v-container>
</template>


<style scoped>
canvas {
  width: 100%;
  height: 800px;
  background-color: #fafafa;
}
.scroll-wrapper {
    overflow-y: hidden;
}

.scroll-core {
    height: 1px;
}
</style>
