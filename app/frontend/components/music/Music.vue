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

<script setup lang="ts">
import { ref, onMounted, nextTick, watch } from 'vue'

// Props定義
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
const pixelsPerSecond = 64
const midiDurationSec = ref(0)
const scrollCoreWidth = ref(0)
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
  if (!canvas.value || !props.midiData || !props.midiData.tracks) return
  const ctx = canvas.value.getContext('2d')
  if (!ctx) return

  ctx.clearRect(0, 0, canvas.value.width, canvas.value.height)

  const visibleOffsetX = scrollTime * pixelsPerSecond
  const marginTop = 10
  const marginLeft = 70
  const plotH = props.height - 20 // 上下マージン10ずつ

  // --- Y軸ラベル ---
  ctx.fillStyle = '#000000'
  ctx.font = '12px monospace'
  ctx.textAlign = 'right'

  for (let midi = 24; midi <= 127; midi += 12) {
    const yPosition = (127 - midi + 1) * noteHeight + marginTop
    ctx.fillText(midi.toString(), marginLeft - 8, yPosition)
    ctx.strokeStyle = '#e0e0e0'
    ctx.beginPath()
    ctx.moveTo(marginLeft, yPosition)
    ctx.lineTo(canvas.value.width, yPosition)
    ctx.stroke()
  }

  // 枠線
  ctx.strokeStyle = '#000000'
  ctx.beginPath()
  ctx.moveTo(marginLeft, marginTop)
  ctx.lineTo(marginLeft, marginTop + plotH)
  ctx.stroke()

  // --- ノート描画 ---
  props.midiData.tracks.forEach(track => {
    console.log(track)
    const color = track.color || '#FF0000' // デフォルト色

    track.notes.forEach(note => {
      const startTime = note.ticks * props.secondsPerTick
      const duration = note.durationTicks * props.secondsPerTick

      const xPosition = startTime * pixelsPerSecond - visibleOffsetX + marginLeft
      const yPosition = (127 - note.midi) * noteHeight + marginTop
      const width = duration * pixelsPerSecond
      const height = noteHeight

      // 画面内にある場合のみ描画
      if (xPosition + width >= 0 && xPosition <= props.width) {
        // 修正: velocity を透明度に反映 (0.0 ~ 1.0)
        const velocity = note.velocity !== undefined ? note.velocity : 1.0
        const originalAlpha = ctx.globalAlpha
        ctx.globalAlpha = Math.max(0.2, velocity) // 最低でも少し見えるように

        ctx.fillStyle = color
        ctx.fillRect(xPosition, yPosition, width, height)

        // 枠線は不透明で描くかは好みだが、ここでは枠線も合わせて薄くする
        ctx.strokeStyle = 'black'
        ctx.lineWidth = 1
        ctx.strokeRect(xPosition, yPosition, width, height)

        // アルファ値を戻す
        ctx.globalAlpha = originalAlpha
      }
    })
  })
}

const animate = () => {
  if (!isPlaying.value) return
  const elapsedMs = performance.now() - startTime.value
  const elapsedSec = elapsedMs / 1000
  scrollHandler(elapsedSec)

  if (elapsedSec < midiDurationSec.value + 1.0) { // 少し余裕を持たせる
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

// データ変更検知
watch(() => props.midiData, () => {
    if (!props.midiData) return
    // MIDI全体の長さを計算
    let maxTick = 0
    props.midiData.tracks.forEach(track => {
      track.notes.forEach(note => {
        const endTick = note.ticks + note.durationTicks
        if (endTick > maxTick) maxTick = endTick
      })
    })
    midiDurationSec.value = maxTick * props.secondsPerTick

    nextTick(() => {
      // スクロール領域確保
      scrollCoreWidth.value = midiDurationSec.value * pixelsPerSecond + props.width
      drawPianoRoll(0)
    })
  }, { deep: true }
)

defineExpose({ start, stop })
</script>

<style scoped>
canvas {
  width: 100%;
  height: 436px;
}
.scroll-wrapper {
    overflow-y: hidden;
    overflow-x: auto;
}
.scroll-core {
    height: 1px;
}
</style>
