<template>
  <div class="roll-container" ref="container">
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
      <button
        v-if="lineageRootKey !== null"
        type="button"
        class="show-all-button"
        @click="showAllClusters"
      >
        Show all clusters
      </button>
      <button type="button" aria-label="Close cluster details" @click="closeDetails">×</button>
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
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue'

type CompressedSpan = {
  window_min: number
  window_max: number
  cluster_ids: number[]
  indices: number[]
  fit_limits: number[]
  parent_index: number | null
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
  summaryMappedStarts: number[]
  summaryPositions: number[]
  summaryIndicesByActualWindow: Map<number, number[]>
  maxItemWidth: number
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
  resizable?: boolean
}>(), {
  title: '',
  stepWidth: 10,
  rowHeight: 12,
  maxSteps: 100,
  resizable: false,
})
const emit = defineEmits<{
  scroll: [event: Event]
  'hover-cluster': [cluster: { indices: number[]; windowSize: number; id: string } | null]
  'resize-height': [height: number]
}>()

const container = ref<HTMLElement | null>(null)
const scrollWrapper = ref<HTMLElement | null>(null)
const canvas = ref<HTMLCanvasElement | null>(null)
const labelsCanvas = ref<HTMLCanvasElement | null>(null)
const viewportWidth = ref(1)
const viewportHeight = ref(1)
const contentHeight = ref(1)
const contentWidth = computed(() => Math.max(viewportWidth.value, props.maxSteps * props.stepWidth))
const selectedKey = ref<string | null>(null)
const lineageRootKey = ref<string | null>(null)
const selectedWindow = ref(2)
const selectedSpan = computed(() => {
  const key = selectedKey.value
  return key === null ? null : rows.find(row => row.key === key)?.span ?? null
})
const summaryHeight = 24
const labelColumnWidth = 260
let rows: SpanRow[] = []
let resizeObserver: ResizeObserver | null = null
let rafId: number | null = null

function lowerBound(values: number[], target: number) {
  let lo = 0
  let hi = values.length
  while (lo < hi) {
    const mid = (lo + hi) >> 1
    if (values[mid]! < target) lo = mid + 1
    else hi = mid
  }
  return lo
}

function lowerBoundItemX(items: DetailItem[], target: number) {
  let lo = 0
  let hi = items.length
  while (lo < hi) {
    const mid = (lo + hi) >> 1
    if (items[mid]!.x < target) lo = mid + 1
    else hi = mid
  }
  return lo
}

function firstVisibleRowIndex(top: number) {
  let lo = 0
  let hi = rows.length
  while (lo < hi) {
    const mid = (lo + hi) >> 1
    const row = rows[mid]!
    const bottom = row.y + summaryHeight + row.detailHeight
    if (bottom < top) lo = mid + 1
    else hi = mid
  }
  return lo
}

function rowAtY(y: number) {
  let lo = 0
  let hi = rows.length
  while (lo < hi) {
    const mid = (lo + hi) >> 1
    const row = rows[mid]!
    if (y < row.y) hi = mid
    else if (y >= row.y + summaryHeight + row.detailHeight) lo = mid + 1
    else return row
  }
  return null
}

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

function lineageIndices(rootIndex: number) {
  const visible = new Set<number>([rootIndex])

  // Ancestors.
  let parentIndex = props.compressedData[rootIndex]?.parent_index ?? null
  while (parentIndex !== null && !visible.has(parentIndex)) {
    visible.add(parentIndex)
    parentIndex = props.compressedData[parentIndex]?.parent_index ?? null
  }

  // Descendants.
  const children = new Map<number, number[]>()
  props.compressedData.forEach((span, index) => {
    if (span.parent_index === null) return
    const siblings = children.get(span.parent_index) ?? []
    siblings.push(index)
    children.set(span.parent_index, siblings)
  })
  const stack = [...(children.get(rootIndex) ?? [])]
  while (stack.length > 0) {
    const index = stack.pop()!
    if (visible.has(index)) continue
    visible.add(index)
    stack.push(...(children.get(index) ?? []))
  }
  return visible
}

function flattenSpans(): Array<{ key: string; span: CompressedSpan; depth: number }> {
  const result: Array<{ key: string; span: CompressedSpan; depth: number }> = []
  const depths: number[] = []
  const rootIndex = lineageRootKey.value === null ? null : Number(lineageRootKey.value)
  const visibleIndices = rootIndex === null || !Number.isInteger(rootIndex)
    ? null
    : lineageIndices(rootIndex)

  props.compressedData.forEach((span, index) => {
    const depth = span.parent_index === null ? 0 : (depths[span.parent_index] ?? -1) + 1
    depths.push(depth)
    if (visibleIndices && !visibleIndices.has(index)) return
    result.push({ key: String(index), span, depth })
  })
  return result.sort((a, b) => a.span.window_min - b.span.window_min || a.depth - b.depth)
}

function occurrences(span: CompressedSpan, windowSize: number) {
  const offset = windowSize - span.window_min
  const fitLimit = span.fit_limits[offset]
  if (fitLimit === undefined || !Number.isFinite(fitLimit)) return []
  return span.indices.filter(start => start + windowSize <= fitLimit)
}

function logicalWindowCountLabel(span: CompressedSpan) {
  const entries: string[] = []
  for (let windowSize = span.window_min; windowSize <= span.window_max; windowSize++) {
    entries.push(`${windowSize}·${occurrences(span, windowSize).length}`)
  }
  if (entries.length <= 5) return entries.join('  ')
  return [...entries.slice(0, 2), '…', ...entries.slice(-2)].join('  ')
}

function summaryLabel(row: SpanRow) {
  return `${row.key === selectedKey.value ? '▾' : '▸'} ${logicalWindowCountLabel(row.span)}`
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
    const summaryPairs = summaryStarts.flatMap(start => {
      const position = props.stepMap ? props.stepMap[start] : start
      return position === undefined || !Number.isFinite(position)
        ? []
        : [{ start, position }]
    }).sort((a, b) => a.position - b.position)
    const summaryMappedStarts = summaryPairs.map(pair => pair.start)
    const summaryPositions = summaryPairs.map(pair => pair.position)
    const summaryIndicesByActualWindow = new Map<number, number[]>()
    if (props.stepMap?.length) {
      for (const start of summaryStarts) {
        const first = props.stepMap[start]
        const last = props.stepMap[start + span.window_min - 1]
        if (first === undefined || last === undefined) continue
        const actualWindow = last - first + 1
        const indices = summaryIndicesByActualWindow.get(actualWindow) ?? []
        indices.push(first)
        summaryIndicesByActualWindow.set(actualWindow, indices)
      }
    }
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
    const maxItemWidth = items.reduce((maxWidth, item) => Math.max(maxWidth, item.width), 0)
    return {
      key, span, depth, y: summaryY, detailY, detailHeight, items,
      summaryStarts, summaryMappedStarts, summaryPositions, summaryIndicesByActualWindow, maxItemWidth,
    }
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
    labels.width = Math.ceil(labelColumnWidth * ratio)
    labels.height = Math.ceil(height * ratio)
    labelCtx.setTransform(ratio, 0, 0, ratio, 0, 0)
    labelCtx.clearRect(0, 0, labelColumnWidth, height)
  }

  const firstRow = firstVisibleRowIndex(top)
  for (let rowIndex = firstRow; rowIndex < rows.length; rowIndex++) {
    const row = rows[rowIndex]!
    if (row.y > top + height) break
    const sy = row.y - top
    ctx.fillStyle = row.key === selectedKey.value ? '#e3f2fd' : '#f5f8fb'
    ctx.fillRect(0, sy, width, summaryHeight - 2)
    ctx.fillStyle = '#1976d2'
    // The summary marks occurrences of the shortest logical window only.
    // Longer membership is displayed exactly after selecting a window size.
    const minPosition = (left - 2) / props.stepWidth
    const maxPosition = (left + width + 2) / props.stepWidth
    for (
      let positionIndex = lowerBound(row.summaryPositions, minPosition);
      positionIndex < row.summaryPositions.length &&
        row.summaryPositions[positionIndex]! <= maxPosition;
      positionIndex++
    ) {
      const x = row.summaryPositions[positionIndex]! * props.stepWidth - left
      ctx.fillRect(x, sy + 5, 2, summaryHeight - 12)
    }
    if (labelCtx) {
      labelCtx.fillStyle = row.key === selectedKey.value ? '#e3f2fd' : '#f5f8fb'
      labelCtx.fillRect(0, sy, labelColumnWidth, summaryHeight - 2)
      labelCtx.fillStyle = '#37474f'
      labelCtx.font = '10px sans-serif'
      labelCtx.fillText(
        summaryLabel(row),
        Math.min(row.depth * 8, 32) + 2, sy + 15,
        labelColumnWidth - Math.min(row.depth * 8, 32) - 6,
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
    const detailStartX = Math.max(0, left - row.maxItemWidth)
    for (
      let itemIndex = lowerBoundItemX(row.items, detailStartX);
      itemIndex < row.items.length && row.items[itemIndex]!.x <= left + width;
      itemIndex++
    ) {
      const item = row.items[itemIndex]!
      const x = item.x - left
      const iy = item.y - top
      if (x + item.width < 0 || iy + props.rowHeight < 0 || iy > height) continue
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
  const row = rowAtY(y)
  if (!row) return null
  if (y < row.detailY) return { row, item: null }
  const startIndex = lowerBoundItemX(row.items, Math.max(0, x - row.maxItemWidth))
  let item: DetailItem | null = null
  for (let index = startIndex; index < row.items.length && row.items[index]!.x <= x; index++) {
    const entry = row.items[index]!
    if (
      x >= entry.x && x <= entry.x + entry.width &&
      y >= entry.y && y <= entry.y + props.rowHeight - 3
    ) {
      item = entry
      break
    }
  }
  return { row, item }
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
    const targetPosition = x / props.stepWidth
    const insertion = lowerBound(target.row.summaryPositions, targetPosition)
    const candidates = [insertion - 1, insertion].filter(
      index => index >= 0 && index < target.row.summaryPositions.length,
    )
    const nearest = candidates.reduce<number | null>((best, index) => {
      if (best === null) return index
      return Math.abs(target.row.summaryPositions[index]! - targetPosition) <
        Math.abs(target.row.summaryPositions[best]! - targetPosition) ? index : best
    }, null)
    const hovered = nearest !== null &&
      Math.abs(target.row.summaryPositions[nearest]! * props.stepWidth - x) <= 4
        ? target.row.summaryMappedStarts[nearest]!
        : undefined
    const actualStart = hovered === undefined ? undefined : props.stepMap?.[hovered]
    const actualEnd = hovered === undefined ? undefined : props.stepMap?.[hovered + localWindow - 1]
    if (actualStart === undefined || actualEnd === undefined) {
      emit('hover-cluster', null)
      return
    }
    const actualWindow = actualEnd - actualStart + 1
    const indices = target.row.summaryIndicesByActualWindow.get(actualWindow) ?? []
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
  const row = rowAtY(y)
  if (row && y < row.y + summaryHeight) toggleDetails(row)
}
function toggleDetails(row: SpanRow) {
  selectedKey.value = row.key
  lineageRootKey.value = row.key
  selectedWindow.value = row.span.window_min
}
function showAllClusters() {
  lineageRootKey.value = null
  emit('hover-cluster', null)
}
function closeDetails() {
  selectedKey.value = null
  lineageRootKey.value = null
  emit('hover-cluster', null)
}
function onMouseLeave() { emit('hover-cluster', null) }

watch(() => [props.compressedData, props.stepMap], () => {
  selectedKey.value = null
  lineageRootKey.value = null
  emit('hover-cluster', null)
  calculateLayout()
  nextTick(scheduleDraw)
})
watch(() => [props.stepWidth, props.rowHeight, props.maxSteps, selectedKey.value, selectedWindow.value, lineageRootKey.value], () => {
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
  stopResize()
  resizeObserver?.disconnect()
  if (rafId !== null) cancelAnimationFrame(rafId)
})
defineExpose({ scrollWrapper })
</script>

<style scoped>
.roll-container { display: flex; border: 1px solid #ccc; background: white; height: 100%; position: relative; }
.resize-handle { position: absolute; bottom: 0; left: 260px; right: 0; height: 9px;
  cursor: ns-resize; touch-action: none; z-index: 3;
  background: linear-gradient(to bottom, transparent 3px, #999 4px, transparent 5px); }
.resize-handle:focus-visible { outline: 2px solid #1976d2; outline-offset: -2px; }
.label-column { width: 260px; min-width: 260px; position: relative; border-right: 1px solid #eee; overflow: hidden; }
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
.length-control .show-all-button {
  border: 1px solid #90caf9;
  border-radius: 3px;
  background: #fff;
  color: #1565c0;
  padding: 2px 7px;
  font-size: 11px;
  white-space: nowrap;
}
</style>
