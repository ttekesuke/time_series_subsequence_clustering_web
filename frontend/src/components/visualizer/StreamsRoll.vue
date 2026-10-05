<template>
  <div class="roll-container" ref="container">
    <span class="title-label" :title="props.title">{{ props.title }}</span>
    <div
      class="scroll-wrapper"
      ref="scrollWrapper"
      @scroll="onScroll"
      :style="{ cursor: cursorStyle }"
    >
      <div class="canvas-space" :style="{ width: contentWidth + 'px', height: viewportHeight + 'px' }">
        <canvas
          ref="canvas"
          :style="{ width: viewportWidth + 'px', height: viewportHeight + 'px' }"
          @mousemove="onMouseMove"
          @mouseleave="onMouseLeave"
        ></canvas>
      </div>
    </div>

    <div
      v-if="hoverInfo"
      ref="tooltipEl"
      class="tooltip"
      :style="{ left: hoverInfo.x + 'px', top: hoverInfo.y + 'px' }"
    >
      <div>Stream: {{ getStreamLabel(hoverInfo.streamIndex) }}</div>
      <div>Step: {{ hoverInfo.step }}</div>
      <div>Value: {{ hoverInfo.value }}</div>
    </div>
    <div
      v-if="resizable"
      class="resize-handle"
      role="separator"
      aria-label="Resize roll height"
      aria-orientation="horizontal"
      tabindex="0"
      @pointerdown="startResize"
      @keydown.up.prevent="resizeBy(-16)"
      @keydown.down.prevent="resizeBy(16)"
    ></div>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted, onBeforeUnmount, watch, nextTick } from 'vue'

type StreamCellValue = number | number[] | null | undefined

const props = defineProps({
  streamValues: { type: [Array, Object], required: true },
  streamVelocities: { type: [Array, Object], required: false, default: () => [] },
  minValue: { type: Number, default: 0 },
  maxValue: { type: Number, default: 127 },
  stepWidth: { type: Number, default: 10 },
  highlightIndices: { type: Array as () => number[], default: () => [] },
  highlightWindowSize: { type: Number, default: 0 },
  playheadStep: { type: Number, default: -1 },
  streamLabels: { type: Array as () => string[], default: () => [] },
  hiddenStreamIndices: { type: Array as () => number[], default: () => [] },
  resizable: { type: Boolean, default: false },

  // Left label text
  title: { type: String, default: '' },

  // ここが「小数のステップ（0.1など）」に相当
  valueResolution: { type: Number, default: 1 }
})

const emit = defineEmits<{
  scroll: [event: Event]
  'resize-height': [height: number]
}>()

const container = ref<HTMLElement | null>(null)
const scrollWrapper = ref<HTMLElement | null>(null)
const canvas = ref<HTMLCanvasElement | null>(null)
const tooltipEl = ref<HTMLElement | null>(null)
const viewportWidth = ref(1)
const viewportHeight = ref(1)
const contentWidth = ref(1)
const effectiveStepWidth = ref(1)
const maxStepCount = ref(0)

const hoverInfo = ref<null | { x: number; y: number; step: number; value: number; streamIndex: number }>(null)
const cursorStyle = ref<string>('default')
let resizeObserver: ResizeObserver | null = null
let rafId: number | null = null

const scheduleDraw = () => {
  if (rafId !== null) cancelAnimationFrame(rafId)
  rafId = requestAnimationFrame(() => {
    rafId = null
    draw()
  })
}

const onScroll = (e: Event) => {
  emit('scroll', e)
  scheduleDraw()
}
const getStreamLabel = (streamIndex: number) => {
  const label = props.streamLabels?.[streamIndex]
  return (typeof label === 'string' && label.length > 0) ? label : `S${streamIndex + 1}`
}

const clamp = (v: number, min: number, max: number) => Math.max(min, Math.min(max, v))
const resizeBy = (delta: number) => {
  if (container.value) emit('resize-height', Math.max(92, Math.round(container.value.getBoundingClientRect().height + delta)))
}

let resizeStartY = 0
let resizeStartHeight = 0
const stopResize = () => {
  window.removeEventListener('pointermove', moveResize)
  window.removeEventListener('pointerup', stopResize)
  window.removeEventListener('pointercancel', stopResize)
}
const moveResize = (event: PointerEvent) => {
  emit('resize-height', Math.max(92, Math.round(resizeStartHeight + event.clientY - resizeStartY)))
}
const startResize = (event: PointerEvent) => {
  if (event.button !== 0 || !container.value) return
  event.preventDefault()
  stopResize()
  resizeStartY = event.clientY
  resizeStartHeight = container.value.getBoundingClientRect().height
  window.addEventListener('pointermove', moveResize)
  window.addEventListener('pointerup', stopResize)
  window.addEventListener('pointercancel', stopResize)
}
const MAX_CANVAS_WIDTH = 30000

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

const updateGeometry = () => {
  if (!scrollWrapper.value) return
  const values = props.streamValues as StreamCellValue[][]
  maxStepCount.value = Math.max(0, ...values.map(stream => Array.isArray(stream) ? stream.length : 0))
  const rawStepWidth = Number(props.stepWidth)
  const safeStepWidth = Number.isFinite(rawStepWidth) && rawStepWidth > 0 ? rawStepWidth : 1
  effectiveStepWidth.value = maxStepCount.value > 0
    ? Math.max(1, Math.min(safeStepWidth, MAX_CANVAS_WIDTH / maxStepCount.value))
    : safeStepWidth
  viewportWidth.value = Math.max(1, scrollWrapper.value.clientWidth)
  viewportHeight.value = Math.max(1, scrollWrapper.value.clientHeight || 200)
  contentWidth.value = Math.max(viewportWidth.value, maxStepCount.value * effectiveStepWidth.value)
}

const plotMetrics = () => {
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
  const stepsY = Math.max(1, Math.floor((scaledMax - scaledMin) / scaledRes) + 1)
  const slotHeight = viewportHeight.value / stepsY
  const barHeight = Math.min(slotHeight, Math.max(0.5, slotHeight * 0.8))
  return { scale, rangeMin, rangeMax, scaledMin, scaledRes, stepsY, slotHeight, barHeight }
}

const draw = () => {
  if (!canvas.value || !scrollWrapper.value) return
  updateGeometry()
  const ctx = canvas.value.getContext('2d')
  if (!ctx) return

  const ratio = Math.min(window.devicePixelRatio || 1, 2)
  const width = viewportWidth.value
  const height = viewportHeight.value
  canvas.value.width = Math.ceil(width * ratio)
  canvas.value.height = Math.ceil(height * ratio)
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0)

  const left = scrollWrapper.value.scrollLeft
  const stepWidth = effectiveStepWidth.value
  const firstStep = Math.max(0, Math.floor(left / stepWidth) - 1)
  const lastStep = Math.min(
    maxStepCount.value - 1,
    Math.ceil((left + width) / stepWidth) + 1,
  )
  const values = props.streamValues as StreamCellValue[][]
  const velocities = props.streamVelocities as any[]
  const hiddenStreams = new Set(props.hiddenStreamIndices.map(index => Number(index)))
  const metrics = plotMetrics()

  const visibleStepCount = Math.max(0, lastStep - firstStep + 1)
  const highlightedVisibleSteps = new Uint8Array(visibleStepCount)
  if (props.highlightIndices.length > 0 && props.highlightWindowSize > 0) {
    const windowSize = props.highlightWindowSize
    for (const start of props.highlightIndices) {
      const end = start + windowSize - 1
      if (end < firstStep || start > lastStep) continue
      const overlapStart = Math.max(firstStep, start)
      const overlapEnd = Math.min(lastStep, end)
      for (let step = overlapStart; step <= overlapEnd; step++) {
        highlightedVisibleSteps[step - firstStep] = 1
      }
    }
  }

  ctx.fillStyle = '#f9f9f9'
  ctx.fillRect(0, 0, width, height)

  ctx.strokeStyle = '#eeeeee'
  ctx.lineWidth = 1
  for (let step = firstStep; step <= lastStep + 1; step++) {
    const x = step * stepWidth - left
    ctx.beginPath()
    ctx.moveTo(x, 0)
    ctx.lineTo(x, height)
    ctx.stroke()
  }

  // Paint the union of highlighted windows exactly once. Overlapping matches
  // therefore keep a flat tint instead of becoming progressively darker.
  if (visibleStepCount > 0) {
    ctx.fillStyle = 'rgba(255, 200, 200, 0.25)'
    let runStart = -1
    for (let offset = 0; offset <= visibleStepCount; offset++) {
      const highlighted = offset < visibleStepCount && highlightedVisibleSteps[offset] === 1
      if (highlighted && runStart < 0) runStart = offset
      if (!highlighted && runStart >= 0) {
        const x = (firstStep + runStart) * stepWidth - left
        const w = (offset - runStart) * stepWidth
        ctx.fillRect(x, 0, w, height)
        runStart = -1
      }
    }
  }

  values.forEach((stream, sIdx) => {
    if (hiddenStreams.has(sIdx) || !Array.isArray(stream)) return
    const hue = (sIdx * 137.5) % 360
    const baseColor = `hsla(${hue}, 70%, 45%, 1)`
    const streamLast = Math.min(lastStep, stream.length - 1)

    for (let step = firstStep; step <= streamLast; step++) {
      const cellVal = stream[step]
      if (cellVal == null) continue
      const notes = Array.isArray(cellVal)
        ? cellVal.map(n => Number(n)).filter(n => Number.isFinite(n))
        : [Number(cellVal)].filter(n => Number.isFinite(n))
      if (notes.length === 0) continue

      let alpha = 0.8
      if (velocities[sIdx] && velocities[sIdx][step] !== undefined) {
        const vel = Number(velocities[sIdx][step])
        if (!Number.isNaN(vel)) alpha = 0.3 + vel * 0.7
      }

      const xBase = step * stepWidth - left
      const fullBarWidth = Math.max(1, stepWidth - 2)
      const rectX = xBase + 1
      ctx.fillStyle = highlightedVisibleSteps[step - firstStep] ? 'red' : baseColor
      ctx.globalAlpha = alpha

      for (const numVal of notes) {
        const clampedVal = clamp(numVal, metrics.rangeMin, metrics.rangeMax)
        const scaledVal = Math.round(clampedVal * metrics.scale)
        const rawIndex = Math.round((scaledVal - metrics.scaledMin) / metrics.scaledRes)
        const normalizedIndex = clamp(rawIndex, 0, metrics.stepsY - 1)
        const slotIndex = (metrics.stepsY - 1) - normalizedIndex
        const yCenter = slotIndex * metrics.slotHeight + metrics.slotHeight / 2
        const rectY = yCenter - metrics.barHeight / 2
        ctx.fillRect(rectX, rectY, fullBarWidth, metrics.barHeight)
      }
      ctx.globalAlpha = 1
    }
  })


  if (props.playheadStep >= 0) {
    const x = props.playheadStep * stepWidth - left
    if (x >= -2 && x <= width + 2) {
      ctx.save()
      ctx.beginPath()
      ctx.moveTo(x, 0)
      ctx.lineTo(x, height)
      ctx.strokeStyle = 'rgba(20, 20, 20, 0.9)'
      ctx.lineWidth = 2
      ctx.stroke()
      ctx.restore()
    }
  }
}

/** マウス移動 → step を逆算し、その step の値だけをヒットテスト */
const onMouseMove = (e: MouseEvent) => {
  if (!canvas.value || !container.value || !scrollWrapper.value) return

  const canvasRect = canvas.value.getBoundingClientRect()
  const containerRect = container.value.getBoundingClientRect()
  const xInViewport = e.clientX - canvasRect.left
  const yInCanvas = e.clientY - canvasRect.top
  const xInContent = xInViewport + scrollWrapper.value.scrollLeft
  const stepWidth = effectiveStepWidth.value
  const step = Math.floor(xInContent / stepWidth)

  let hit: { step: number; value: number; streamIndex: number } | null = null
  if (step >= 0 && step < maxStepCount.value) {
    const metrics = plotMetrics()
    const values = props.streamValues as StreamCellValue[][]
    const hiddenStreams = new Set(props.hiddenStreamIndices.map(index => Number(index)))
    const withinBarX = xInContent - step * stepWidth
    if (withinBarX >= 1 && withinBarX <= Math.max(1, stepWidth - 1)) {
      for (let sIdx = 0; sIdx < values.length && !hit; sIdx++) {
        if (hiddenStreams.has(sIdx)) continue
        const stream = values[sIdx]
        if (!Array.isArray(stream)) continue
        const cellVal = stream[step]
        if (cellVal == null) continue
        const notes = Array.isArray(cellVal)
          ? cellVal.map(n => Number(n)).filter(n => Number.isFinite(n))
          : [Number(cellVal)].filter(n => Number.isFinite(n))

        for (const numVal of notes) {
          const clampedVal = clamp(numVal, metrics.rangeMin, metrics.rangeMax)
          const scaledVal = Math.round(clampedVal * metrics.scale)
          const rawIndex = Math.round((scaledVal - metrics.scaledMin) / metrics.scaledRes)
          const normalizedIndex = clamp(rawIndex, 0, metrics.stepsY - 1)
          const slotIndex = (metrics.stepsY - 1) - normalizedIndex
          const yCenter = slotIndex * metrics.slotHeight + metrics.slotHeight / 2
          const rectY = yCenter - metrics.barHeight / 2
          // Thin piano-roll bars can be only a pixel or two high. Give hover
          // a small vertical tolerance while still reporting the exact value.
          const hoverPadding = Math.max(2, Math.min(5, metrics.slotHeight * 0.4))
          if (yInCanvas >= rectY - hoverPadding && yInCanvas <= rectY + metrics.barHeight + hoverPadding) {
            hit = { step, value: numVal, streamIndex: sIdx }
            break
          }
        }
      }
    }
  }

  if (hit) {
    cursorStyle.value = 'pointer'
    const baseOffset = 10
    const tooltipHeight = tooltipEl.value?.offsetHeight ?? 24
    const mouseXInContainer = e.clientX - containerRect.left
    const mouseYInContainer = e.clientY - containerRect.top
    const canvasBottomInContainer = canvasRect.bottom - containerRect.top
    const tipX = mouseXInContainer + baseOffset
    let tipY = mouseYInContainer + baseOffset
    if (tipY + tooltipHeight > canvasBottomInContainer) {
      tipY = Math.max(0, mouseYInContainer - tooltipHeight - baseOffset)
    }
    hoverInfo.value = { ...hit, x: tipX, y: tipY }
  } else {
    cursorStyle.value = 'default'
    hoverInfo.value = null
  }
}

const onMouseLeave = () => {
  cursorStyle.value = 'default'
  hoverInfo.value = null
}

const scrollToStep = (step: number, windowSize = 1) => {
  if (!scrollWrapper.value) return
  const safeStep = Math.max(0, Number(step) || 0)
  const safeWindow = Math.max(1, Number(windowSize) || 1)
  const highlightCenter = (safeStep + safeWindow / 2) * effectiveStepWidth.value
  const nextLeft = highlightCenter - scrollWrapper.value.clientWidth / 2
  const maxLeft = Math.max(0, scrollWrapper.value.scrollWidth - scrollWrapper.value.clientWidth)
  scrollWrapper.value.scrollLeft = clamp(nextLeft, 0, maxLeft)
}

watch(
  () => [
    props.streamValues,
    props.streamVelocities,
    props.highlightIndices,
    props.highlightWindowSize,
    props.playheadStep,
    props.hiddenStreamIndices,
    props.stepWidth,
    props.minValue,
    props.maxValue,
    props.valueResolution,
    props.title,
  ],
  () => { nextTick(() => { updateGeometry(); scheduleDraw() }) },
)

onMounted(() => {
  nextTick(() => {
    updateGeometry()
    scheduleDraw()
  })
  if (scrollWrapper.value) {
    resizeObserver = new ResizeObserver(() => {
      nextTick(() => {
        updateGeometry()
        scheduleDraw()
      })
    })
    resizeObserver.observe(scrollWrapper.value)
  }
})

onBeforeUnmount(() => {
  stopResize()
  resizeObserver?.disconnect()
  resizeObserver = null
  if (rafId !== null) cancelAnimationFrame(rafId)
})

defineExpose({ scrollWrapper, redraw: draw, scrollToStep })
</script>

<style scoped>
.roll-container {
  display: flex;
  border: 1px solid #ccc;
  background: white;
  position: relative;
  height: 100%;
}

.title-label {
  width: 80px;
  min-width: 80px;
  max-width: 80px;
  display: flex;
  align-items: center;
  justify-content: flex-start;
  padding: 0 4px;
  border-right: 1px solid #eee;
  color: #666;
  font-size: 10px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  box-sizing: border-box;
  user-select: none;
}

.scroll-wrapper {
  flex-grow: 1;
  min-width: 0;
  min-height: 0;
  overflow-x: auto;
  overflow-y: auto;
  -ms-overflow-style: none;
  scrollbar-width: none;
}

.canvas-space {
  position: relative;
}
.scroll-wrapper canvas {
  position: sticky;
  top: 0;
  left: 0;
  display: block;
}

.scroll-wrapper::-webkit-scrollbar {
  width: 0;
  height: 0;
  display: none;
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
.resize-handle {
  position: absolute;
  bottom: 0;
  left: 80px;
  right: 0;
  height: 9px;
  cursor: ns-resize;
  touch-action: none;
  background: linear-gradient(to bottom, transparent 3px, #999 4px, transparent 5px);
  z-index: 11;
}
.resize-handle:focus-visible {
  outline: 2px solid #1976d2;
  outline-offset: -2px;
}
</style>
