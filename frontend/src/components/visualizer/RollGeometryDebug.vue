<template>
  <pre class="roll-geometry-debug" :aria-label="`${title} geometry diagnostics`">{{ report }}</pre>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'

const props = defineProps<{
  title: string
  rootElement: HTMLElement | null
  labelElement: HTMLElement | null
  labelTitleElement?: HTMLElement | null
  scrollElement: HTMLElement | null
  contentElement: HTMLElement | null
  canvasElement: HTMLCanvasElement | null
  labelCanvasElement?: HTMLCanvasElement | null
  stepWidth: number
  maxSteps: number
  dataSteps: number
  viewportWidth: number
  viewportHeight: number
  contentWidth: number
  contentHeight?: number
}>()

const revision = ref(0)
let resizeObserver: ResizeObserver | null = null
let observedScrollElement: HTMLElement | null = null
let windowResizeHandler: (() => void) | null = null

const refresh = () => {
  revision.value += 1
}

const onScroll = () => refresh()

const observeElements = () => {
  resizeObserver?.disconnect()
  resizeObserver = new ResizeObserver(refresh)

  const elements = [
    props.rootElement,
    props.rootElement?.parentElement ?? null,
    props.labelElement,
    props.labelTitleElement ?? null,
    props.scrollElement,
    props.contentElement,
    props.canvasElement,
    props.labelCanvasElement ?? null,
  ]
  for (const element of new Set(elements)) {
    if (element) resizeObserver.observe(element)
  }

  if (observedScrollElement !== props.scrollElement) {
    observedScrollElement?.removeEventListener('scroll', onScroll)
    observedScrollElement = props.scrollElement
    observedScrollElement?.addEventListener('scroll', onScroll, { passive: true })
  }
  refresh()
}

watch(
  () => [
    props.rootElement,
    props.labelElement,
    props.labelTitleElement,
    props.scrollElement,
    props.contentElement,
    props.canvasElement,
    props.labelCanvasElement,
  ],
  observeElements,
)

onMounted(() => {
  observeElements()
  windowResizeHandler = refresh
  window.addEventListener('resize', windowResizeHandler)
})

onBeforeUnmount(() => {
  resizeObserver?.disconnect()
  resizeObserver = null
  observedScrollElement?.removeEventListener('scroll', onScroll)
  observedScrollElement = null
  if (windowResizeHandler) window.removeEventListener('resize', windowResizeHandler)
  windowResizeHandler = null
})

const round = (value: number) => Number.isFinite(value) ? value.toFixed(2) : String(value)
const rect = (element: Element | null) => {
  if (!element) return 'missing'
  const r = element.getBoundingClientRect()
  return `x=${round(r.x)} y=${round(r.y)} w=${round(r.width)} h=${round(r.height)} right=${round(r.right)}`
}
const dimensions = (element: HTMLElement | null) => {
  if (!element) return 'missing'
  return `client=${element.clientWidth}×${element.clientHeight} offset=${element.offsetWidth}×${element.offsetHeight} scroll=${element.scrollWidth}×${element.scrollHeight}`
}
const styleInfo = (element: HTMLElement | null) => {
  if (!element) return 'missing'
  const style = window.getComputedStyle(element)
  return `display=${style.display} flex=${style.flex} minW=${style.minWidth} width=${style.width} overflowX=${style.overflowX} box=${style.boxSizing}`
}

const report = computed(() => {
  // Read this ref so DOM-only changes (scroll, resize, font/layout changes) refresh the snapshot.
  revision.value

  const root = props.rootElement
  const parent = root?.parentElement ?? null
  const label = props.labelElement
  const titleLabel = props.labelTitleElement ?? null
  const scroll = props.scrollElement
  const content = props.contentElement
  const canvas = props.canvasElement
  const labelCanvas = props.labelCanvasElement ?? null

  const timelineWidth = props.maxSteps * props.stepWidth
  const scrollClientWidth = scroll?.clientWidth ?? 0
  const actualScrollWidth = scroll?.scrollWidth ?? 0
  const contentClientWidth = content?.clientWidth ?? 0
  const canvasRect = canvas?.getBoundingClientRect()
  const scrollRect = scroll?.getBoundingClientRect()
  const rootRect = root?.getBoundingClientRect()
  const parentRect = parent?.getBoundingClientRect()
  const dpr = window.devicePixelRatio || 1
  const canvasCssWidth = canvasRect?.width ?? 0
  const canvasBackingScale = canvas && canvasCssWidth > 0 ? canvas.width / canvasCssWidth : 0

  const lines = [
    `[${props.title}] geometry snapshot`,
    `PROPS   stepWidth=${round(props.stepWidth)}px  maxSteps=${props.maxSteps}  dataSteps=${props.dataSteps}`,
    `MATH    maxSteps×stepWidth=${round(timelineWidth)}px  contentWidth(JS)=${round(props.contentWidth)}px  viewport(JS)=${round(props.viewportWidth)}×${round(props.viewportHeight)}px`,
    `ROOT    rect: ${rect(root)}`,
    `        ${dimensions(root)}`,
    `PARENT  rect: ${rect(parent)}`,
    `LABEL   rect: ${rect(label)}`,
    `        ${dimensions(label)}  css: ${styleInfo(label)}`,
    `TITLE   rect: ${rect(titleLabel)}`,
    `SCROLL  rect: ${rect(scroll)}`,
    `        ${dimensions(scroll)}  left=${round(scroll?.scrollLeft ?? 0)}  css: ${styleInfo(scroll)}`,
    `SPACE   rect: ${rect(content)}`,
    `        ${dimensions(content)}  inlineWidth=${content?.style.width || '-'} inlineHeight=${content?.style.height || '-'}`,
    `CANVAS  rect: ${rect(canvas)}`,
    `        css=${canvas?.style.width || '-'}×${canvas?.style.height || '-'} backing=${canvas?.width ?? 0}×${canvas?.height ?? 0} scaleX=${round(canvasBackingScale)}`,
    `LABELCANVAS rect: ${rect(labelCanvas)} backing=${labelCanvas?.width ?? 0}×${labelCanvas?.height ?? 0}`,
    `DELTA   root.clientW - label.clientW - scroll.clientW = ${round((root?.clientWidth ?? 0) - (label?.clientWidth ?? 0) - scrollClientWidth)}px`,
    `        scroll.scrollW - scroll.clientW = ${round(actualScrollWidth - scrollClientWidth)}px`,
    `        space.clientW - expectedTimelineW = ${round(contentClientWidth - timelineWidth)}px`,
    `        scrollW - JS contentWidth = ${round(actualScrollWidth - props.contentWidth)}px`,
    `        canvas.right - scroll.right = ${round((canvasRect?.right ?? 0) - (scrollRect?.right ?? 0))}px`,
    `        root.right - scroll.right = ${round((rootRect?.right ?? 0) - (scrollRect?.right ?? 0))}px`,
    `        parent.width - root.width = ${round((parentRect?.width ?? 0) - (rootRect?.width ?? 0))}px  DPR=${round(dpr)}`,
  ]

  if (props.contentHeight !== undefined) {
    lines.splice(3, 0, `HEIGHT  contentHeight(JS)=${round(props.contentHeight)}px`)
  }

  return lines.join('\n')
})
</script>

<style scoped>
.roll-geometry-debug {
  position: absolute;
  top: 3px;
  right: 8px;
  z-index: 50;
  box-sizing: border-box;
  width: min(510px, calc(100% - 96px));
  max-height: calc(100% - 18px);
  overflow: auto;
  margin: 0;
  padding: 6px 8px;
  border: 1px solid #d18b28;
  border-radius: 3px;
  background: rgba(255, 255, 235, 0.94);
  color: #202020;
  box-shadow: 0 1px 4px rgba(0, 0, 0, 0.18);
  font: 10px/1.35 Consolas, 'Courier New', monospace;
  letter-spacing: 0;
  white-space: pre;
  text-align: left;
  user-select: text;
}
</style>
