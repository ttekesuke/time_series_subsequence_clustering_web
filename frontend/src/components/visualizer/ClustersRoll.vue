<template>
  <div class="roll-container" ref="container">
    <div class="label-column">
      <canvas
        ref="labelsCanvas"
        :style="{ height: viewportHeight + 'px' }"
        @mousemove="onLabelMouseMove"
        @mouseleave="onMouseLeave"
        @click="onLabelClick"
      />
      <span class="title-label" :title="title">{{ title }}</span>
    </div>

    <div ref="scrollWrapper" class="scroll-wrapper" @scroll="onScroll">
      <div class="canvas-space" :style="{ width: contentWidth + 'px', height: contentHeight + 'px' }">
        <canvas
          ref="canvas"
          :style="{ width: viewportWidth + 'px', height: viewportHeight + 'px' }"
          @mousemove="onMouseMove"
          @mouseleave="onMouseLeave"
          @click="onClick"
        />
      </div>
    </div>

    <div v-if="focusedSpan" class="focus-control" @click.stop>
      <span>Focus {{ spanLabel(focusedSpan) }}</span>
      <button type="button" class="show-all-button" @click="showAllClusters">
        Show all clusters
      </button>
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

type OccurrenceItem = {
  x: number
  width: number
  windowSize: number
  indices: number[]
  clusterId: string
}

type SpanRow = {
  key: string
  index: number
  span: CompressedSpan
  depth: number
  y: number
  items: OccurrenceItem[]
  maxItemWidth: number
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

const hoveredKey = ref<string | null>(null)
const focusedKey = ref<string | null>(null)
const focusedSpan = computed(() => {
  if (focusedKey.value === null) return null
  const index = Number(focusedKey.value)
  return Number.isInteger(index) ? props.compressedData[index] ?? null : null
})

const summaryHeight = 24
const labelColumnWidth = 80
const treeIndent = 7
const treeBaseX = 6
const treeMaxX = 30

let rows: SpanRow[] = []
let resizeObserver: ResizeObserver | null = null
let rafId: number | null = null

function lowerBoundItemX(items: OccurrenceItem[], target: number) {
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
    if (rows[mid]!.y + summaryHeight < top) lo = mid + 1
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
    else if (y >= row.y + summaryHeight) lo = mid + 1
    else return row
  }
  return null
}

function occurrences(span: CompressedSpan, windowSize: number) {
  const offset = windowSize - span.window_min
  const fitLimit = span.fit_limits[offset]
  if (fitLimit === undefined || !Number.isFinite(fitLimit)) return []
  return span.indices.filter(start => start + windowSize <= fitLimit)
}

function spanLabel(span: CompressedSpan) {
  const count = occurrences(span, span.window_max).length
  return span.window_min === span.window_max
    ? `${span.window_max}×${count}`
    : `${span.window_min}–${span.window_max}×${count}`
}

function buildChildren() {
  const children = new Map<number, number[]>()
  props.compressedData.forEach((_, index) => children.set(index, []))
  props.compressedData.forEach((span, index) => {
    if (span.parent_index === null) return
    const siblings = children.get(span.parent_index)
    if (siblings) siblings.push(index)
  })

  for (const siblings of children.values()) {
    siblings.sort((a, b) => {
      const aSpan = props.compressedData[a]!
      const bSpan = props.compressedData[b]!
      const aStart = occurrences(aSpan, aSpan.window_max)[0] ?? Number.MAX_SAFE_INTEGER
      const bStart = occurrences(bSpan, bSpan.window_max)[0] ?? Number.MAX_SAFE_INTEGER
      return aStart - bStart || aSpan.window_min - bSpan.window_min || a - b
    })
  }
  return children
}

function computeDepth(index: number, memo: number[], visiting = new Set<number>()): number {
  if (memo[index] !== undefined) return memo[index]!
  if (visiting.has(index)) return 0
  visiting.add(index)
  const parent = props.compressedData[index]?.parent_index ?? null
  const depth = parent === null || !props.compressedData[parent]
    ? 0
    : computeDepth(parent, memo, visiting) + 1
  visiting.delete(index)
  memo[index] = depth
  return depth
}

function lineageIndices(rootIndex: number) {
  const visible = new Set<number>([rootIndex])

  let parent = props.compressedData[rootIndex]?.parent_index ?? null
  while (parent !== null && !visible.has(parent)) {
    visible.add(parent)
    parent = props.compressedData[parent]?.parent_index ?? null
  }

  const children = buildChildren()
  const stack = [...(children.get(rootIndex) ?? [])]
  while (stack.length > 0) {
    const index = stack.pop()!
    if (visible.has(index)) continue
    visible.add(index)
    stack.push(...(children.get(index) ?? []))
  }
  return visible
}

function dfsOrder() {
  const children = buildChildren()
  const depths: number[] = []
  props.compressedData.forEach((_, index) => computeDepth(index, depths))

  const roots = props.compressedData
    .map((span, index) => ({ span, index }))
    .filter(({ span }) => span.parent_index === null || !props.compressedData[span.parent_index])
    .sort((a, b) => {
      const aStart = occurrences(a.span, a.span.window_max)[0] ?? Number.MAX_SAFE_INTEGER
      const bStart = occurrences(b.span, b.span.window_max)[0] ?? Number.MAX_SAFE_INTEGER
      return aStart - bStart || a.index - b.index
    })

  const order: Array<{ index: number; depth: number }> = []
  const seen = new Set<number>()

  const visit = (index: number) => {
    if (seen.has(index)) return
    seen.add(index)
    order.push({ index, depth: depths[index] ?? 0 })
    for (const child of children.get(index) ?? []) visit(child)
  }

  for (const root of roots) visit(root.index)
  props.compressedData.forEach((_, index) => {
    if (!seen.has(index)) visit(index)
  })
  return order
}

function visibleOrder() {
  const order = dfsOrder()
  if (focusedKey.value === null) return order
  const rootIndex = Number(focusedKey.value)
  if (!Number.isInteger(rootIndex) || !props.compressedData[rootIndex]) return order
  const lineage = lineageIndices(rootIndex)
  return order.filter(item => lineage.has(item.index))
}

function makeOccurrenceItems(span: CompressedSpan): OccurrenceItem[] {
  const logicalWindow = span.window_max
  const starts = occurrences(span, logicalWindow)
  const groups = new Map<number, number[]>()

  const mapped = starts.flatMap(start => {
    if (!props.stepMap?.length) {
      const windowSize = logicalWindow
      const indices = groups.get(windowSize) ?? []
      indices.push(start)
      groups.set(windowSize, indices)
      return [{
        start,
        end: start + logicalWindow,
        windowSize,
      }]
    }

    const actualStart = props.stepMap[start]
    const actualEnd = props.stepMap[start + logicalWindow - 1]
    if (
      actualStart === undefined || actualEnd === undefined ||
      !Number.isFinite(actualStart) || !Number.isFinite(actualEnd) ||
      actualEnd < actualStart
    ) return []

    const windowSize = actualEnd - actualStart + 1
    const indices = groups.get(windowSize) ?? []
    indices.push(actualStart)
    groups.set(windowSize, indices)
    return [{
      start: actualStart,
      end: actualEnd + 1,
      windowSize,
    }]
  }).sort((a, b) => a.start - b.start || a.end - b.end)

  const clusterId = String(span.cluster_ids[span.cluster_ids.length - 1] ?? span.cluster_ids[0] ?? '')
  return mapped.map(item => ({
    x: item.start * props.stepWidth,
    width: Math.max(props.stepWidth, (item.end - item.start) * props.stepWidth),
    windowSize: item.windowSize,
    indices: groups.get(item.windowSize) ?? [],
    clusterId,
  }))
}

function calculateLayout() {
  let y = 28
  rows = visibleOrder().map(({ index, depth }) => {
    const span = props.compressedData[index]!
    const items = makeOccurrenceItems(span)
    const row: SpanRow = {
      key: String(index),
      index,
      span,
      depth,
      y,
      items,
      maxItemWidth: items.reduce((max, item) => Math.max(max, item.width), 0),
    }
    y += summaryHeight
    return row
  })
  contentHeight.value = Math.max(viewportHeight.value, y + 8)
}

function treeX(depth: number) {
  return Math.min(treeBaseX + depth * treeIndent, treeMaxX)
}

function activeLineage() {
  const key = hoveredKey.value ?? focusedKey.value
  if (key === null) return null
  const index = Number(key)
  if (!Number.isInteger(index) || !props.compressedData[index]) return null
  return lineageIndices(index)
}

function drawTree(labelCtx: CanvasRenderingContext2D, top: number, height: number) {
  const active = activeLineage()
  const rowByIndex = new Map(rows.map(row => [row.index, row]))

  for (const row of rows) {
    const parentIndex = row.span.parent_index
    if (parentIndex === null) continue
    const parentRow = rowByIndex.get(parentIndex)
    if (!parentRow) continue

    const parentY = parentRow.y + summaryHeight / 2 - top
    const childY = row.y + summaryHeight / 2 - top
    if (Math.max(parentY, childY) < -summaryHeight || Math.min(parentY, childY) > height + summaryHeight) continue

    const parentX = treeX(parentRow.depth)
    const childX = treeX(row.depth)
    const related = !active || (active.has(parentIndex) && active.has(row.index))

    labelCtx.save()
    labelCtx.globalAlpha = related ? 1 : 0.16
    labelCtx.strokeStyle = related && active ? '#1976d2' : '#78909c'
    labelCtx.lineWidth = related && active ? 2 : 1.4
    labelCtx.beginPath()
    labelCtx.moveTo(parentX, parentY)
    labelCtx.lineTo(parentX, childY)
    labelCtx.lineTo(childX, childY)
    labelCtx.stroke()
    labelCtx.restore()
  }
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
    drawTree(labelCtx, top, height)
  }

  const active = activeLineage()
  const firstRow = firstVisibleRowIndex(top)

  for (let rowIndex = firstRow; rowIndex < rows.length; rowIndex++) {
    const row = rows[rowIndex]!
    if (row.y > top + height) break

    const sy = row.y - top
    const isHovered = hoveredKey.value === row.key
    const isFocused = focusedKey.value === row.key
    const related = !active || active.has(row.index)

    ctx.save()
    ctx.globalAlpha = related ? 1 : 0.16
    ctx.fillStyle = isHovered || isFocused ? '#e3f2fd' : '#f5f8fb'
    ctx.fillRect(0, sy, width, summaryHeight - 2)

    ctx.fillStyle = isHovered || isFocused ? 'rgba(66, 165, 245, 0.8)' : 'rgba(144, 202, 249, 0.72)'
    ctx.strokeStyle = isHovered || isFocused ? '#0d47a1' : '#1976d2'
    ctx.lineWidth = isHovered || isFocused ? 1.2 : 1

    const detailStartX = Math.max(0, left - row.maxItemWidth)
    for (
      let itemIndex = lowerBoundItemX(row.items, detailStartX);
      itemIndex < row.items.length && row.items[itemIndex]!.x <= left + width;
      itemIndex++
    ) {
      const item = row.items[itemIndex]!
      const x = item.x - left
      if (x + item.width < 0) continue
      ctx.fillRect(x, sy + 6, item.width, summaryHeight - 12)
      ctx.strokeRect(x, sy + 6, item.width, summaryHeight - 12)
    }
    ctx.restore()

    if (labelCtx) {
      labelCtx.save()
      labelCtx.globalAlpha = related ? 1 : 0.16
      labelCtx.fillStyle = isHovered || isFocused ? '#e3f2fd' : '#f5f8fb'
      labelCtx.fillRect(0, sy, labelColumnWidth, summaryHeight - 2)

      const x = treeX(row.depth)
      labelCtx.beginPath()
      labelCtx.arc(x, sy + summaryHeight / 2, 3.7, 0, Math.PI * 2)
      labelCtx.fillStyle = isHovered || isFocused ? '#1976d2' : '#ffffff'
      labelCtx.fill()
      labelCtx.strokeStyle = isHovered || isFocused ? '#0d47a1' : '#607d8b'
      labelCtx.lineWidth = 1.3
      labelCtx.stroke()

      labelCtx.fillStyle = '#37474f'
      labelCtx.font = '10px sans-serif'
      labelCtx.fillText(
        spanLabel(row.span),
        x + 7,
        sy + 15,
        Math.max(8, labelColumnWidth - x - 9),
      )
      labelCtx.restore()
    }
  }
}

function scheduleDraw() {
  if (rafId !== null) cancelAnimationFrame(rafId)
  rafId = requestAnimationFrame(() => {
    rafId = null
    draw()
  })
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

function rowOccurrenceForHover(row: SpanRow, x: number | null = null) {
  if (row.items.length === 0) return null

  let item = row.items[0]!
  if (x !== null) {
    const startIndex = lowerBoundItemX(row.items, Math.max(0, x - row.maxItemWidth))
    for (let index = startIndex; index < row.items.length && row.items[index]!.x <= x; index++) {
      const candidate = row.items[index]!
      if (x >= candidate.x && x <= candidate.x + candidate.width) {
        item = candidate
        break
      }
    }
  }

  return {
    indices: item.indices,
    windowSize: item.windowSize,
    id: item.clusterId,
  }
}

function applyHover(row: SpanRow | null, x: number | null = null) {
  const nextKey = row?.key ?? null
  const changed = hoveredKey.value !== nextKey
  hoveredKey.value = nextKey

  if (row) {
    emit('hover-cluster', rowOccurrenceForHover(row, x))
  } else if (focusedKey.value !== null) {
    const focusedRow = rows.find(candidate => candidate.key === focusedKey.value)
    emit('hover-cluster', focusedRow ? rowOccurrenceForHover(focusedRow) : null)
  } else {
    emit('hover-cluster', null)
  }

  if (changed) scheduleDraw()
}

function onMouseMove(event: MouseEvent) {
  const wrapper = scrollWrapper.value
  const element = canvas.value
  if (!wrapper || !element) return

  const rect = element.getBoundingClientRect()
  const x = event.clientX - rect.left + wrapper.scrollLeft
  const y = event.clientY - rect.top + wrapper.scrollTop
  const row = rowAtY(y)
  element.style.cursor = row ? 'pointer' : 'default'
  applyHover(row, x)
}

function onLabelMouseMove(event: MouseEvent) {
  const wrapper = scrollWrapper.value
  const labels = labelsCanvas.value
  if (!wrapper || !labels) return

  const y = event.clientY - labels.getBoundingClientRect().top + wrapper.scrollTop
  const row = rowAtY(y)
  labels.style.cursor = row ? 'pointer' : 'default'
  applyHover(row)
}

function focusRow(row: SpanRow) {
  focusedKey.value = row.key
  hoveredKey.value = null
  calculateLayout()
  const focusedRow = rows.find(candidate => candidate.key === row.key)
  emit('hover-cluster', focusedRow ? rowOccurrenceForHover(focusedRow) : null)
  nextTick(scheduleDraw)
}

function onClick(event: MouseEvent) {
  const wrapper = scrollWrapper.value
  const element = canvas.value
  if (!wrapper || !element) return
  const y = event.clientY - element.getBoundingClientRect().top + wrapper.scrollTop
  const row = rowAtY(y)
  if (row) focusRow(row)
}

function onLabelClick(event: MouseEvent) {
  const wrapper = scrollWrapper.value
  const labels = labelsCanvas.value
  if (!wrapper || !labels) return
  const y = event.clientY - labels.getBoundingClientRect().top + wrapper.scrollTop
  const row = rowAtY(y)
  if (row) focusRow(row)
}

function showAllClusters() {
  focusedKey.value = null
  hoveredKey.value = null
  emit('hover-cluster', null)
  calculateLayout()
  nextTick(scheduleDraw)
}

function onMouseLeave() {
  applyHover(null)
}

const resizeBy = (delta: number) => {
  if (container.value) {
    emit('resize-height', Math.max(92, Math.round(container.value.getBoundingClientRect().height + delta)))
  }
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

watch(() => [props.compressedData, props.stepMap], () => {
  hoveredKey.value = null
  focusedKey.value = null
  emit('hover-cluster', null)
  calculateLayout()
  nextTick(scheduleDraw)
})

watch(
  () => [props.stepWidth, props.rowHeight, props.maxSteps, focusedKey.value],
  () => {
    calculateLayout()
    nextTick(scheduleDraw)
  },
  { immediate: true },
)

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
.roll-container {
  display: flex;
  border: 1px solid #ccc;
  background: white;
  height: 100%;
  position: relative;
}

.resize-handle {
  position: absolute;
  bottom: 0;
  left: 80px;
  right: 0;
  height: 9px;
  cursor: ns-resize;
  touch-action: none;
  z-index: 3;
  background: linear-gradient(to bottom, transparent 3px, #999 4px, transparent 5px);
}

.resize-handle:focus-visible {
  outline: 2px solid #1976d2;
  outline-offset: -2px;
}

.label-column {
  width: 80px;
  min-width: 80px;
  position: relative;
  border-right: 1px solid #eee;
  overflow: hidden;
}

.label-column canvas {
  position: absolute;
  top: 0;
  left: 0;
}

.title-label {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  height: 21px;
  display: flex;
  align-items: center;
  padding: 0 4px;
  color: #666;
  font-size: 10px;
  background: white;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  box-sizing: border-box;
  z-index: 2;
}

.scroll-wrapper {
  flex: 1;
  min-width: 0;
  min-height: 0;
  overflow: auto;
  scrollbar-width: none;
}

.scroll-wrapper::-webkit-scrollbar {
  display: none;
}

.canvas-space {
  position: relative;
}

canvas {
  position: sticky;
  top: 0;
  left: 0;
  display: block;
}

.focus-control {
  position: absolute;
  right: 12px;
  top: 5px;
  display: flex;
  align-items: center;
  gap: 7px;
  padding: 3px 6px;
  background: rgba(255, 255, 255, .96);
  border: 1px solid #90caf9;
  border-radius: 4px;
  color: #263238;
  font: 11px sans-serif;
  z-index: 4;
}

.focus-control .show-all-button {
  border: 1px solid #90caf9;
  border-radius: 3px;
  background: #fff;
  color: #1565c0;
  padding: 2px 7px;
  font-size: 11px;
  cursor: pointer;
  white-space: nowrap;
}
</style>
