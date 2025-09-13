<script setup lang="ts">
import { ref, onMounted, nextTick, watch } from 'vue'
const props = defineProps({
  midiData: {
    type: Object,
    default: null
  },
  secondsPerTick: {
    type: Number,
    default: 0
  },
  width: {
    type: Number,
    default: 1920,
  },
  height: {
    type: Number,
    default: 436, // 104 * 4 + 10(margintop) + 10(marginbottom)
  },
})
const canvas = ref<HTMLCanvasElement | null>(null)
const scrollWrapper = ref<HTMLDivElement | null>(null)
const isPlaying = ref(false)
const startTime = ref(0)
const noteHeight = 4
const midiNoteNumberMin = 24
const midiNoteNumberMax = 127
const midiNoteNumberRange = midiNoteNumberMax - midiNoteNumberMin + 1
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
  if (!canvas.value || !props.midiData.tracks) return
  const ctx = canvas.value.getContext('2d')
  if (!ctx) return

  ctx.clearRect(0, 0, canvas.value.width, canvas.value.height)

  // 経過時間に応じたオフセット
  const visibleOffsetX = scrollTime * pixelsPerSecond
  const w = props.width
  const h = props.height
  const marginLeft = 70
  const marginBottom = 10
  const marginTop = 10
  const plotW = w - marginLeft - 10
  const plotH = h - marginTop - marginBottom

  // --- Y軸ラベルの描画 ---
  ctx.fillStyle = '#000000'
  ctx.font = '12px monospace'
  ctx.textAlign = 'right'

  for (let midi = 24; midi <= 127; midi += 12) {
    const yPosition = (127 - midi + 1) * noteHeight + marginTop
    console.log(yPosition)
    ctx.fillText(midi.toString(), marginLeft - 8, yPosition)
    ctx.strokeStyle = '#000000'
    ctx.beginPath()
    ctx.moveTo(marginLeft, yPosition)
    ctx.lineTo(canvas.value.width, yPosition)
    ctx.stroke()
  }
  ctx.moveTo(marginLeft, marginTop)
  ctx.lineTo(marginLeft, marginTop + plotH)
  ctx.stroke()

  // --- ノート描画 ---
  props.midiData.tracks.forEach(track => {
    const color = track.color
    track.notes.forEach(note => {
      const startTime = note.ticks * props.secondsPerTick
      const duration = note.durationTicks * props.secondsPerTick

      const xPosition = startTime * pixelsPerSecond - visibleOffsetX + marginLeft
      const yPosition = (127 - note.midi) * noteHeight + marginTop
      const width = duration * pixelsPerSecond
      const height = noteHeight

      if (0 <= xPosition + width && xPosition <= props.width) {
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
      scrollCoreWidth.value = midiDurationSec.value * pixelsPerSecond + props.width
    })
    drawPianoRoll(0)
  }, { deep: true }
)
defineExpose({
  start, stop
})
</script>

<template>

  <div>
    <canvas
      ref="canvas"
      :width="props.width"
      :height="props.height"
      style="display: block;"
    ></canvas>
    <div class="scroll-wrapper" @scroll="onScroll" ref="scrollWrapper">
      <div class="scroll-core" :style="{ width: scrollCoreWidth + 'px' }"></div>
    </div>
  </div>
</template>


<style scoped>
canvas {
  width: 100%;
  height: 436px;
}
.scroll-wrapper {
    overflow-y: hidden;
}

.scroll-core {
    height: 1px;
}
</style>
