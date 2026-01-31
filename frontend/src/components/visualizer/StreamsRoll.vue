<template>
  <div class="roll-container" ref="container">
    <div
      class="scroll-wrapper"
      ref="scrollWrapper"
      @scroll="onScroll"
      :style="{ cursor: cursorStyle }"
    >
      <canvas
        ref="canvas"
        @mousemove="onMouseMove"
        @mouseleave="onMouseLeave"
      ></canvas>
    </div>

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

type StreamCellValue = number | number[] | null | undefined

const props = defineProps({
  streamValues: { type: [Array, Object], required: true },
  streamVelocities: { type: [Array, Object], required: false, default: () => [] },
  minValue: { type: Number, default: 0 },
  maxValue: { type: Number, default: 127 },
  stepWidth: { type: Number, default: 10 },
  highlightIndices: { type: Array as () => number[], default: () => [] },
  highlightWindowSize: { type: Number, default: 0 },

  // Optional background title (watermark-like). May be omitted.
  title: { type: String, default: '' },

  // ここが「小数のステップ（0.1など）」に相当
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

const onScroll = (e: Event) => emit('scroll', e)

const clamp = (v: number, min: number, max: number) => Math.max(min, Math.min(max, v))

/**
 * 小数ステップ対策:
 * valueResolution が整数になるまで 10倍して、整数世界で index 計算する
 * (0.1, 0.01, 0.25 などでも "だいたい整数" になるまで最大6桁)
 */
const calcScale = (step: number) => {
  let s = 1
  const eps = 1e-9
  const target = Math.abs(Number(step))
  if (!Number.isFinite(target) || target <= 0) return 1
  for (let i = 0; i < 6; i++) {
    const v = target * s
    if (Math.abs(v - Math.round(v)) < eps) return s
    s *= 10
  }
  return s
}

const draw = () => {
  if (!canvas.value || !scrollWrapper.value) return
  const ctx = canvas.value.getContext('2d')
  if (!ctx) return

  const values = props.streamValues as StreamCellValue[][]
  const velocities = props.streamVelocities as any[]

  rects.value = []

  const maxStep = Math.max(0, ...values.map(s => (Array.isArray(s) ? s.length : 0)))

  const wrapperWidth = scrollWrapper.value.clientWidth
  const contentWidth = maxStep * props.stepWidth
  const width = Math.max(wrapperWidth, contentWidth)

  const baseCanvasHeight = scrollWrapper.value.clientHeight || 200

  // =========================
  // 小数 valueResolution を安定処理
  // =========================
  const valueRes = Number(props.valueResolution)
  const safeValueRes = Number.isFinite(valueRes) && valueRes > 0 ? valueRes : 1

  const scale = calcScale(safeValueRes)

  const minV = Number(props.minValue)
  const maxV = Number(props.maxValue)
  const minRaw = Number.isFinite(minV) ? minV : 0
  const maxRaw = Number.isFinite(maxV) ? maxV : 0

  const rangeMin = Math.min(minRaw, maxRaw)
  const rangeMax = Math.max(minRaw, maxRaw)

  const scaledMin = Math.round(rangeMin * scale)
  const scaledMax = Math.round(rangeMax * scale)
  const scaledRes = Math.max(1, Math.round(safeValueRes * scale))

  // Y方向の段数（整数で計算するのでズレない）
  const stepsY = Math.max(1, Math.floor((scaledMax - scaledMin) / scaledRes) + 1)

  const slotHeight = baseCanvasHeight / stepsY
  const actualPlotHeight = baseCanvasHeight

  canvas.value.width = width
  canvas.value.height = actualPlotHeight
  const canvasHeight = actualPlotHeight

  // 背景
  ctx.fillStyle = '#f9f9f9'
  ctx.fillRect(0, 0, width, canvasHeight)

  // グリッド線（縦）
  ctx.strokeStyle = '#eeeeee'
  ctx.lineWidth = 1
  for (let i = 0; i <= maxStep; i++) {
    const x = i * props.stepWidth
    ctx.beginPath()
    ctx.moveTo(x, 0)
    ctx.lineTo(x, canvasHeight)
    ctx.stroke()
  }

  // 背景テキスト（キャンバス左端から開始。矩形の背面に描画）
  if (props.title) {
    ctx.save()
    const text = String(props.title)
    const fontSize = 30
    ctx.font = `${fontSize}px sans-serif`
    ctx.textAlign = 'left'
    ctx.textBaseline = 'middle'
    ctx.fillStyle = 'rgba(0,0,0,0.5)'
    ctx.fillText(text, 0, canvasHeight / 2)
    ctx.restore()
  }

  // 矩形描画（val が number[] の場合は複数描画）
  values.forEach((stream, sIdx) => {
    const hue = (sIdx * 137.5) % 360
    const baseColor = `hsla(${hue}, 70%, 45%, 1)`

    stream.forEach((cellVal: StreamCellValue, step: number) => {
      if (cellVal == null) return

      const notes: number[] = Array.isArray(cellVal)
        ? cellVal.map(n => Number(n)).filter(n => Number.isFinite(n))
        : [Number(cellVal)].filter(n => Number.isFinite(n))

      if (notes.length === 0) return

      const xBase = step * props.stepWidth

      let alpha = 0.8
      if (velocities[sIdx] && velocities[sIdx][step] !== undefined) {
        const vel = Number(velocities[sIdx][step])
        if (!isNaN(vel)) alpha = 0.3 + vel * 0.7
      }

      const isHighlighted = props.highlightIndices.some(
        hIdx => step >= hIdx && step < hIdx + props.highlightWindowSize
      )

      const fullBarWidth = Math.max(1, props.stepWidth - 2)
      const rectX = xBase + 1
      const barHeight = Math.min(slotHeight, Math.max(0.5, slotHeight * 0.8))

      notes.forEach((numVal) => {
        // 値をレンジにクランプ
        const clampedVal = clamp(numVal, rangeMin, rangeMax)

        // ここが重要：整数スケールで index を出す
        const scaledVal = Math.round(clampedVal * scale)
        const rawIndex = Math.round((scaledVal - scaledMin) / scaledRes)
        const normalizedIndex = clamp(rawIndex, 0, stepsY - 1)

        const slotIndex = (stepsY - 1) - normalizedIndex
        const yCenter = slotIndex * slotHeight + slotHeight / 2
        const rectY = yCenter - barHeight / 2

        ctx.fillStyle = isHighlighted ? 'red' : baseColor
        ctx.globalAlpha = alpha
        ctx.fillRect(rectX, rectY, fullBarWidth, barHeight)
        ctx.globalAlpha = 1.0

        rects.value.push({
          x: rectX,
          y: rectY,
          width: fullBarWidth,
          height: barHeight,
          step,
          value: numVal,
          streamIndex: sIdx
        })
      })
    })
  })

  // ハイライト領域
  if (props.highlightIndices.length > 0 && props.highlightWindowSize > 0) {
    ctx.fillStyle = 'rgba(255, 200, 200, 0.25)'
    props.highlightIndices.forEach(idx => {
      const x = idx * props.stepWidth
      const w = props.highlightWindowSize * props.stepWidth
      ctx.fillRect(x, 0, w, canvasHeight)
    })
  }
}

/** マウス移動 → ヒットテスト + ツールチップ位置 */
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

    const mouseXInContainer = e.clientX - containerRect.left
    const mouseYInContainer = e.clientY - containerRect.top
    const canvasBottomInContainer = canvasRect.bottom - containerRect.top

    let tipX = mouseXInContainer + baseOffset
    let tipY = mouseYInContainer + baseOffset
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
    props.valueResolution,
    props.title
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
