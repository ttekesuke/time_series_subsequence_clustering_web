<template>
  <div class="roll-container">
    <div class="label-column">
      <canvas ref="labelsCanvas" :style="{ height: viewportHeight + 'px' }"
        @click="onLabelClick" />
      <span class="title-label" :title="title">{{ title }}</span>
    </div>
    <div ref="scrollWrapper" class="scroll-wrapper" @scroll="onScroll">
      <div class="canvas-space" :style="{ width: contentWidth + 'px', height: contentHeight + 'px' }">
        <canvas ref="canvas" :style="{ width: viewportWidth + 'px', height: viewportHeight + 'px' }"
          @mousemove="onMouseMove" @mouseleave="onMouseLeave" @click="onClick" />
      </div>
    </div>
    <div v-if="selectedSpan" class="length-control" @click.stop>
      <span>Window {{ selectedWindow }} / {{ selectedSpan.window_min }}–{{ selectedSpan.window_max }}</span>
      <input v-model.number="selectedWindow" type="range" :min="selectedSpan.window_min"
        :max="selectedSpan.window_max" step="1" aria-label="Cluster window size" />
      <button type="button" aria-label="Close cluster details" @click="closeDetails">×</button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue'

type CompressedSpan = {
  window_min: number
  window_max: number
  cluster_ids: number[]
  indices: number[]
  fit_limits: number[]
  children: CompressedSpan[]
}
type SpanRow = {
  key: string
  span: CompressedSpan
  depth: number
  y: number
  detailY: number
  detailHeight: number
  items: DetailItem[]
  summaryStarts: number[]
  summaryPositions: number[]
}
type DetailItem = {
  x: number
  width: number
  y: number
  windowSize: number
  indices: number[]
  clusterId: string
}

const props = withDefaults(defineProps<{
  compressedData: CompressedSpan[]
  stepMap?: number[]
  title?: string
  stepWidth?: number
  rowHeight?: number
  maxSteps?: number
}>(), {
  title: '',
  stepWidth: 10,
  rowHeight: 12,
  maxSteps: 100,
})
const emit = defineEmits<{
  scroll: [event: Event]
  'hover-cluster': [cluster: { indices: number[]; windowSize: number; id: string } | null]
}>()

const scrollWrapper = ref<HTMLElement | null>(null)
const canvas = ref<HTMLCanvasElement | null>(null)
const labelsCanvas = ref<HTMLCanvasElement | null>(null)
const viewportWidth = ref(1)
const viewportHeight = ref(1)
const contentHeight = ref(1)
const contentWidth = computed(() => Math.max(viewportWidth.value, props.maxSteps * props.stepWidth))
const selectedKey = ref<string | null>(null)
const selectedWindow = ref(2)
const selectedSpan = computed(() => rows.find(row => row.key === selectedKey.value)?.span ?? null)
const summaryHeight = 24
let rows: SpanRow[] = []
let resizeObserver: ResizeObserver | null = null
let rafId: number | null = null

function flattenSpans(): Array<{ key: string; span: CompressedSpan; depth: number }> {
  const result: Array<{ key: string; span: CompressedSpan; depth: number }> = []
  function visit(spans: CompressedSpan[], parent: string, depth: number) {
    spans.forEach((span, index) => {
      const key = `${parent}/${index}`
      result.push({ key, span, depth })
      visit(span.children ?? [], key, depth + 1)
    })
  }
  visit(props.compressedData, '', 0)
  return result.sort((a, b) => a.span.window_min - b.span.window_min || a.depth - b.depth)
}

function occurrences(span: CompressedSpan, windowSize: number) {
  const offset = windowSize - span.window_min
  const fitLimit = span.fit_limits[offset]
  if (fitLimit === undefined || !Number.isFinite(fitLimit)) return []
  return span.indices.filter(start => start + windowSize <= fitLimit)
}

function detailItems(span: CompressedSpan, windowSize: number, y: number): { items: DetailItem[]; height: number } {
  const starts = occurrences(span, windowSize)
  const mapped = starts.flatMap(start => {
    const actualStart = props.stepMap ? props.stepMap[start] : start
    const actualEnd = props.stepMap ? props.stepMap[start + windowSize - 1] : start + windowSize - 1
    if (actualStart === undefined || actualEnd === undefined ||
      !Number.isFinite(actualStart) || !Number.isFinite(actualEnd) || actualEnd < actualStart) return []
    return [{ start: actualStart, end: actualEnd + 1, windowSize: actualEnd - actualStart + 1 }]
  }).sort((a, b) => a.start - b.start || a.end - b.end)
  const groups = new Map<number, number[]>()
  mapped.forEach(item => {
    const indices = groups.get(item.windowSize) ?? []
    indices.push(item.start)
    groups.set(item.windowSize, indices)
  })
  const lanes: number[] = []
  const items = mapped.map(item => {
    let lane = lanes.findIndex(end => end <= item.start)
    if (lane < 0) { lane = lanes.length; lanes.push(0) }
    lanes[lane] = item.end + 0.5
    return {
      x: item.start * props.stepWidth,
      width: (item.end - item.start) * props.stepWidth,
      y: y + lane * props.rowHeight,
      windowSize: item.windowSize,
      indices: groups.get(item.windowSize) ?? [],
      clusterId: String(span.cluster_ids[windowSize - span.window_min]),
    }
  })
  return { items, height: Math.max(lanes.length, 1) * props.rowHeight + 6 }
}

function calculateLayout() {
  let y = 28
  rows = flattenSpans().map(({ key, span, depth }) => {
    const summaryY = y
    const summaryStarts = occurrences(span, span.window_min)
    const summaryPositions = summaryStarts.flatMap(start => {
      const position = props.stepMap ? props.stepMap[start] : start
      return position === undefined || !Number.isFinite(position) ? [] : [position]
    })
    y += summaryHeight
    let detailY = y
    let detailHeight = 0
    let items: DetailItem[] = []
    if (key === selectedKey.value) {
      selectedWindow.value = Math.max(span.window_min, Math.min(span.window_max, selectedWindow.value))
      const detail = detailItems(span, selectedWindow.value, detailY)
      items = detail.items
      detailHeight = detail.height
      y += detailHeight
    }
    return { key, span, depth, y: summaryY, detailY, detailHeight, items, summaryStarts, summaryPositions }
  })
  contentHeight.value = Math.max(viewportHeight.value, y + 8)
}

function draw() {
  const element = canvas.value
  const wrapper = scrollWrapper.value
  if (!element || !wrapper) return
  const ratio = Math.min(window.devicePixelRatio || 1, 2)
  element.width = Math.ceil(viewportWidth.value * ratio)
  element.height = Math.ceil(viewportHeight.value * ratio)
  const ctx = element.getContext('2d')
  if (!ctx) return
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0)
  const left = wrapper.scrollLeft
  const top = wrapper.scrollTop
  const width = viewportWidth.value
  const height = viewportHeight.value
  ctx.clearRect(0, 0, width, height)
  const labels = labelsCanvas.value
  const labelCtx = labels?.getContext('2d')
  if (labels && labelCtx) {
    labels.width = Math.ceil(80 * ratio)
    labels.height = Math.ceil(height * ratio)
    labelCtx.setTransform(ratio, 0, 0, ratio, 0, 0)
    labelCtx.clearRect(0, 0, 80, height)
  }

  for (const row of rows) {
    if (row.y > top + height || row.y + summaryHeight + row.detailHeight < top) continue
    const sy = row.y - top
    ctx.fillStyle = row.key === selectedKey.value ? '#e3f2fd' : '#f5f8fb'
    ctx.fillRect(0, sy, width, summaryHeight - 2)
    ctx.fillStyle = '#1976d2'
    // The summary marks occurrences of the shortest logical window only.
    // Longer membership is displayed exactly after selecting a window size.
    for (const position of row.summaryPositions) {
      const x = position * props.stepWidth - left
      if (x >= -2 && x < width) ctx.fillRect(x, sy + 5, 2, summaryHeight - 12)
    }
    if (labelCtx) {
      labelCtx.fillStyle = row.key === selectedKey.value ? '#e3f2fd' : '#f5f8fb'
      labelCtx.fillRect(0, sy, 80, summaryHeight - 2)
      labelCtx.fillStyle = '#37474f'
      labelCtx.font = '10px sans-serif'
      labelCtx.fillText(
        `${row.key === selectedKey.value ? '▾' : '▸'} ${row.span.window_min}${row.span.window_max > row.span.window_min ? '–' + row.span.window_max : ''} ·${row.summaryStarts.length}`,
        Math.min(row.depth * 5, 15) + 2, sy + 15,
      )
    }
    if (!row.detailHeight) continue
    const dy = row.detailY - top
    ctx.fillStyle = 'rgba(25, 118, 210, 0.04)'
    ctx.fillRect(0, dy, width, row.detailHeight)
    if (labelCtx) {
      labelCtx.fillStyle = '#1976d2'
      labelCtx.font = '10px sans-serif'
      labelCtx.fillText(`w=${selectedWindow.value}`, 7, dy + 12)
    }
    ctx.fillStyle = 'rgba(100,181,246,0.45)'
    ctx.strokeStyle = '#1976d2'
    for (const item of row.items) {
      const x = item.x - left
      const iy = item.y - top
      if (x + item.width < 0 || x > width || iy + props.rowHeight < 0 || iy > height) continue
      ctx.fillRect(x, iy, item.width, props.rowHeight - 3)
      ctx.strokeRect(x, iy, item.width, props.rowHeight - 3)
    }
  }
}

function scheduleDraw() {
  if (rafId !== null) cancelAnimationFrame(rafId)
  rafId = requestAnimationFrame(() => { rafId = null; draw() })
}
function updateViewport() {
  if (!scrollWrapper.value) return
  viewportWidth.value = Math.max(1, scrollWrapper.value.clientWidth)
  viewportHeight.value = Math.max(1, scrollWrapper.value.clientHeight)
  calculateLayout()
  scheduleDraw()
}
function onScroll(event: Event) {
  emit('scroll', event)
  scheduleDraw()
}
function hit(event: MouseEvent) {
  const wrapper = scrollWrapper.value
  const element = canvas.value
  if (!wrapper || !element) return null
  const rect = element.getBoundingClientRect()
  const x = event.clientX - rect.left + wrapper.scrollLeft
  const y = event.clientY - rect.top + wrapper.scrollTop
  const row = rows.find(item => y >= item.y && y < item.y + summaryHeight + item.detailHeight)
  if (!row) return null
  if (y < row.detailY) return { row, item: null }
  const item = row.items.find(entry =>
    x >= entry.x && x <= entry.x + entry.width &&
    y >= entry.y && y <= entry.y + props.rowHeight - 3)
  return { row, item: item ?? null }
}
function onMouseMove(event: MouseEvent) {
  const target = hit(event)
  if (!target) { emit('hover-cluster', null); return }
  canvas.value!.style.cursor = 'pointer'
  if (target.item) {
    emit('hover-cluster', {
      indices: target.item.indices,
      windowSize: target.item.windowSize,
      id: target.item.clusterId,
    })
  } else if (target.row.detailHeight && event.clientY - canvas.value!.getBoundingClientRect().top +
    (scrollWrapper.value?.scrollTop ?? 0) >= target.row.detailY) {
    emit('hover-cluster', null)
  } else if (!props.stepMap?.length) {
    emit('hover-cluster', {
      indices: target.row.summaryStarts,
      windowSize: target.row.span.window_min,
      id: String(target.row.span.cluster_ids[0]),
    })
  } else {
    const localWindow = target.row.span.window_min
    const x = event.clientX - canvas.value!.getBoundingClientRect().left +
      (scrollWrapper.value?.scrollLeft ?? 0)
    const starts = target.row.summaryStarts
    const hovered = starts.find(start => {
      const mapped = props.stepMap?.[start]
      return mapped !== undefined && Math.abs(mapped * props.stepWidth - x) <= 4
    })
    const actualStart = hovered === undefined ? undefined : props.stepMap?.[hovered]
    const actualEnd = hovered === undefined ? undefined : props.stepMap?.[hovered + localWindow - 1]
    if (actualStart === undefined || actualEnd === undefined) {
      emit('hover-cluster', null)
      return
    }
    const actualWindow = actualEnd - actualStart + 1
    const indices = starts.flatMap(start => {
      const first = props.stepMap?.[start]
      const last = props.stepMap?.[start + localWindow - 1]
      return first !== undefined && last !== undefined && last - first + 1 === actualWindow
        ? [first] : []
    })
    emit('hover-cluster', {
      indices, windowSize: actualWindow,
      id: String(target.row.span.cluster_ids[0]),
    })
  }
}
function onClick(event: MouseEvent) {
  const target = hit(event)
  if (!target) return
  if (target.item) return
  const y = event.clientY - canvas.value!.getBoundingClientRect().top +
    (scrollWrapper.value?.scrollTop ?? 0)
  if (y >= target.row.detailY) return
  toggleDetails(target.row)
}
function onLabelClick(event: MouseEvent) {
  const wrapper = scrollWrapper.value
  const labels = labelsCanvas.value
  if (!wrapper || !labels) return
  const y = event.clientY - labels.getBoundingClientRect().top + wrapper.scrollTop
  const row = rows.find(item => y >= item.y && y < item.y + summaryHeight)
  if (row) toggleDetails(row)
}
function toggleDetails(row: SpanRow) {
  if (selectedKey.value === row.key) closeDetails()
  else {
    selectedKey.value = row.key
    selectedWindow.value = row.span.window_min
  }
}
function closeDetails() {
  selectedKey.value = null
  emit('hover-cluster', null)
}
function onMouseLeave() { emit('hover-cluster', null) }

watch(() => [props.compressedData, props.stepMap], () => {
  selectedKey.value = null
  emit('hover-cluster', null)
  calculateLayout()
  nextTick(scheduleDraw)
})
watch(() => [props.stepWidth, props.rowHeight, props.maxSteps, selectedKey.value, selectedWindow.value], () => {
  calculateLayout()
  nextTick(scheduleDraw)
}, { immediate: true })
onMounted(() => {
  nextTick(updateViewport)
  if (scrollWrapper.value) {
    resizeObserver = new ResizeObserver(updateViewport)
    resizeObserver.observe(scrollWrapper.value)
  }
})
onUnmounted(() => {
  resizeObserver?.disconnect()
  if (rafId !== null) cancelAnimationFrame(rafId)
})
defineExpose({ scrollWrapper })
</script>

<style scoped>
.roll-container { display: flex; border: 1px solid #ccc; background: white; height: 100%; position: relative; }
.label-column { width: 80px; min-width: 80px; position: relative; border-right: 1px solid #eee; overflow: hidden; }
.label-column canvas { position: absolute; top: 0; left: 0; cursor: pointer; }
.title-label { position: absolute; top: 0; left: 0; right: 0; height: 21px;
  display: flex; align-items: center; padding: 0 4px; color: #666; font-size: 10px;
  background: white; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  box-sizing: border-box; }
.scroll-wrapper { flex: 1; min-width: 0; min-height: 0; overflow: auto; scrollbar-width: none; }
.scroll-wrapper::-webkit-scrollbar { display: none; }
.canvas-space { position: relative; }
canvas { position: sticky; top: 0; left: 0; display: block; }
.length-control { position: absolute; right: 12px; top: 5px; display: flex; align-items: center; gap: 6px;
  padding: 3px 6px; background: rgba(255,255,255,.96); border: 1px solid #90caf9;
  border-radius: 4px; color: #263238; font: 11px sans-serif; z-index: 2; }
.length-control input { width: 110px; }
.length-control button { border: 0; background: transparent; cursor: pointer; font-size: 16px; }
</style>
