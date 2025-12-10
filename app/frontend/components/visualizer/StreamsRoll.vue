<template>
  <div class="roll-container" ref="container">
    <!-- スクロールエリア -->
    <div
      class="scroll-wrapper"
      ref="scrollWrapper"
      @scroll="onScroll"
      :style="{ cursor: cursorStyle }"
    >
      <canvas
        ref="canvas"
        :height="height"
        @mousemove="onMouseMove"
        @mouseleave="onMouseLeave"
      ></canvas>
    </div>

    <!-- ホバー時ツールチップ -->
    <div
      v-if="hoverInfo"
      ref="tooltipEl"
      class="tooltip"
      :style="{ left: hoverInfo.x + 'px', top: hoverInfo.y + 'px' }"
    >
      <div>Stream: S{{ hoverInfo.streamIndex + 1 }}</div>
      <div>Step: {{ hoverInfo.step }}</div>
      <div>Value: {{ hoverInfo.value }}</div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted, watch, nextTick } from 'vue'

const props = defineProps({
  streamValues: { type: [Array, Object], required: true },
  streamVelocities: { type: [Array, Object], required: false, default: () => [] },
  minValue: { type: Number, default: 0 },
  maxValue: { type: Number, default: 127 },
  stepWidth: { type: Number, default: 10 },
  height: { type: Number, default: null },
  highlightIndices: { type: Array as () => number[], default: () => [] },
  highlightWindowSize: { type: Number, default: 0 },
  valueResolution: { type: Number, default: 1 }
})

const emit = defineEmits(['scroll'])

const container = ref<HTMLElement | null>(null)
const scrollWrapper = ref<HTMLElement | null>(null)
const canvas = ref<HTMLCanvasElement | null>(null)
const tooltipEl = ref<HTMLElement | null>(null)

type RectInfo = {
  x: number
  y: number
  width: number
  height: number
  step: number
  value: number
  streamIndex: number
}

const rects = ref<RectInfo[]>([])
const hoverInfo = ref<null | { x: number; y: number; step: number; value: number; streamIndex: number }>(null)
const cursorStyle = ref<string>('default')

const onScroll = (e: Event) => {
  emit('scroll', e)
}

const draw = () => {
  if (!canvas.value || !scrollWrapper.value) return
  const ctx = canvas.value.getContext('2d')
  if (!ctx) return

  const values = props.streamValues as any[]
  const velocities = props.streamVelocities as any[]

  rects.value = []

  const maxStep = Math.max(0, ...values.map(s => s.length))

  const wrapperWidth = scrollWrapper.value.clientWidth
  const contentWidth = maxStep * props.stepWidth
  const width = Math.max(wrapperWidth, contentWidth)

  const baseCanvasHeight =
    props.height && props.height > 0
      ? props.height
      : (scrollWrapper.value.clientHeight || 200)

  const steps = Math.max(
    1,
    Math.floor((props.maxValue - props.minValue) / props.valueResolution) + 1
  )

  const minSlotHeight = 4
  let slotHeight = Math.floor(baseCanvasHeight / steps)
  let actualPlotHeight = baseCanvasHeight
  if (slotHeight < minSlotHeight) {
    slotHeight = minSlotHeight
    actualPlotHeight = slotHeight * steps
  }

  canvas.value.width = width
  canvas.value.height = actualPlotHeight
  const canvasHeight = actualPlotHeight

  // 背景
  ctx.fillStyle = '#f9f9f9'
  ctx.fillRect(0, 0, width, canvasHeight)

  // グリッド線
  ctx.strokeStyle = '#eeeeee'
  ctx.lineWidth = 1
  for (let i = 0; i <= maxStep; i++) {
    const x = i * props.stepWidth
    ctx.beginPath()
    ctx.moveTo(x, 0)
    ctx.lineTo(x, canvasHeight)
    ctx.stroke()
  }

  // 矩形描画＋記録
  values.forEach((stream, sIdx) => {
    const hue = (sIdx * 137.5) % 360
    const baseColor = `hsla(${hue}, 70%, 45%, 1)`

    stream.forEach((val: any, step: number) => {
      if (val === null || val === undefined || isNaN(Number(val))) return

      const numVal = Number(val)
      const clampedVal = Math.max(props.minValue, Math.min(props.maxValue, numVal))

      const normalizedIndex = Math.round(
        (clampedVal - props.minValue) / props.valueResolution
      )
      const slotIndex = (steps - 1) - normalizedIndex
      const yCenter = slotIndex * slotHeight + slotHeight / 2

      const x = step * props.stepWidth

      let alpha = 0.8
      if (velocities[sIdx] && velocities[sIdx][step] !== undefined) {
        const vel = Number(velocities[sIdx][step])
        if (!isNaN(vel)) {
          alpha = 0.3 + vel * 0.7
        }
      }

      const isHighlighted = props.highlightIndices.some(
        hIdx => step >= hIdx && step < hIdx + props.highlightWindowSize
      )

      ctx.fillStyle = isHighlighted ? 'red' : baseColor
      ctx.globalAlpha = alpha

      const barHeight = Math.max(2, Math.floor(slotHeight - 2))
      const barWidth = Math.max(1, props.stepWidth - 2)

      const rectX = x + 1
      const rectY = yCenter - barHeight / 2

      ctx.fillRect(rectX, rectY, barWidth, barHeight)
      ctx.globalAlpha = 1.0

      rects.value.push({
        x: rectX,
        y: rectY,
        width: barWidth,
        height: barHeight,
        step,
        value: numVal,
        streamIndex: sIdx
      })
    })
  })

  if (props.highlightIndices.length > 0 && props.highlightWindowSize > 0) {
    ctx.fillStyle = 'rgba(255, 200, 200, 0.25)'
    props.highlightIndices.forEach(idx => {
      const x = idx * props.stepWidth
      const w = props.highlightWindowSize * props.stepWidth
      ctx.fillRect(x, 0, w, canvasHeight)
    })
  }
}

/** マウス移動 → ヒットテスト + ツールチップ位置(上下切り替え) */
const onMouseMove = (e: MouseEvent) => {
  if (!canvas.value || !container.value) return

  const canvasRect = canvas.value.getBoundingClientRect()
  const containerRect = container.value.getBoundingClientRect()

  const xInCanvas = e.clientX - canvasRect.left
  const yInCanvas = e.clientY - canvasRect.top

  const hit = rects.value.find(r =>
    xInCanvas >= r.x &&
    xInCanvas <= r.x + r.width &&
    yInCanvas >= r.y &&
    yInCanvas <= r.y + r.height
  )

  if (hit) {
    cursorStyle.value = 'pointer'

    const baseOffset = 10
    const tooltipHeight = tooltipEl.value?.offsetHeight ?? 24

    // マウス位置をコンテナ基準に変換
    const mouseXInContainer = e.clientX - containerRect.left
    const mouseYInContainer = e.clientY - containerRect.top

    const canvasBottomInContainer = canvasRect.bottom - containerRect.top

    // デフォルトはマウスの下
    let tipX = mouseXInContainer + baseOffset
    let tipY = mouseYInContainer + baseOffset

    // 下にはみ出す場合はマウスの「上」に移動
    if (tipY + tooltipHeight > canvasBottomInContainer) {
      tipY = mouseYInContainer - tooltipHeight - baseOffset
      if (tipY < 0) tipY = 0
    }

    hoverInfo.value = {
      step: hit.step,
      value: hit.value,
      streamIndex: hit.streamIndex,
      x: tipX,
      y: tipY
    }
  } else {
    cursorStyle.value = 'default'
    hoverInfo.value = null
  }
}

const onMouseLeave = () => {
  cursorStyle.value = 'default'
  hoverInfo.value = null
}

watch(
  () => [
    props.streamValues,
    props.streamVelocities,
    props.highlightIndices,
    props.stepWidth,
    props.minValue,
    props.maxValue,
    props.valueResolution
  ],
  () => { nextTick(draw) },
  { deep: true }
)

onMounted(() => {
  setTimeout(draw, 100)
})

defineExpose({ scrollWrapper, redraw: draw })
</script>

<style scoped>
.roll-container {
  display: flex;
  border: 1px solid #ccc;
  background: white;
  position: relative;
  height: 100%;
}

.scroll-wrapper {
  flex-grow: 1;
  overflow-x: auto;
  overflow-y: auto;
}

/* ツールチップ */
.tooltip {
  position: absolute;
  pointer-events: none;
  background: rgba(0, 0, 0, 0.8);
  color: #fff;
  font-size: 10px;
  padding: 4px 6px;
  border-radius: 4px;
  white-space: nowrap;
  z-index: 10;
}
</style>
