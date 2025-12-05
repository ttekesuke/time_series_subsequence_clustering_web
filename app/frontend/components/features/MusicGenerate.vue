<template>
  <div>
    <div class="viz-container" ref="containerRef">
      <div class="quadrant top-left">
        <StreamsRoll
          ref="pianoRollRef"
          :streamValues="pitchStreams"
          :streamVelocities="generate.velocities"
          :minValue="minPitch"
          :maxValue="maxPitch"
          :valueResolution="1"
          :highlightIndices="leftHighlightedIndices"
          :highlightWindowSize="leftHighlightedWindowSize"
          :stepWidth="computedStepWidth"
          @scroll="onScroll"
        />
      </div>
      <div class="quadrant top-right">
        <div class="in-quadrant">
          <div class="row-in-quadrant">
            <StreamsRoll
              ref="briRollRef"
              :streamValues="generate.brightness"
              :minValue="0"
              :maxValue="1"
              :valueResolution="0.1"
              :stepWidth="computedStepWidth"
              :highlightIndices="rightHighlightedIndices"
              :highlightWindowSize="rightHighlightedWindowSize"
              @scroll="onScroll"
            />
          </div>
          <div class="row-in-quadrant">
            <StreamsRoll
              ref="hrdRollRef"
              :streamValues="generate.hardness"
              :minValue="0"
              :maxValue="1"
              :valueResolution="0.1"
              :stepWidth="computedStepWidth"
              :highlightIndices="rightHighlightedIndices"
              :highlightWindowSize="rightHighlightedWindowSize"
              @scroll="onScroll"
            />
          </div>
          <div class="row-in-quadrant">
            <StreamsRoll
              ref="texRollRef"
              :streamValues="generate.texture"
              :minValue="0"
              :maxValue="1"
              :valueResolution="0.1"
              :stepWidth="computedStepWidth"
              :highlightIndices="rightHighlightedIndices"
              :highlightWindowSize="rightHighlightedWindowSize"
              @scroll="onScroll"
            />
          </div>
        </div>
      </div>
      <div class="quadrant bottom-left">
        <div class="in-quadrant">
          <div class="row-in-quadrant">
            <ClustersRoll
              ref="velClustersRef"
              :clustersData="velocityClustersForView"
              :stepWidth="computedStepWidth"
              :maxSteps="stepCount"
              @scroll="onScroll"
              @hover-cluster="onHoverClusterLeft"
            />
          </div>
          <div class="row-in-quadrant">
            <ClustersRoll
              ref="octClustersRef"
              :clustersData="octaveClustersForView"
              :stepWidth="computedStepWidth"
              :maxSteps="stepCount"
              @scroll="onScroll"
              @hover-cluster="onHoverClusterLeft"
            />
          </div>
          <div class="row-in-quadrant">
            <ClustersRoll
              ref="noteClustersRef"
              :clustersData="noteClustersForView"
              :stepWidth="computedStepWidth"
              :maxSteps="stepCount"
              @scroll="onScroll"
              @hover-cluster="onHoverClusterLeft"
            />
          </div>
        </div>
      </div>
      <div class="quadrant bottom-right">
        <div class="in-quadrant">
          <div class="row-in-quadrant">
            <ClustersRoll
              ref="briClustersRef"
              :clustersData="briClustersForView"
              :stepWidth="computedStepWidth"
              :maxSteps="stepCount"
              @scroll="onScroll"
              @hover-cluster="onHoverClusterRight"
            />
          </div>
          <div class="row-in-quadrant">
            <ClustersRoll
              ref="hrdClustersRef"
              :clustersData="hrdClustersForView"
              :stepWidth="computedStepWidth"
              :maxSteps="stepCount"
              @scroll="onScroll"
              @hover-cluster="onHoverClusterRight"
            />
          </div>
          <div class="row-in-quadrant">
            <ClustersRoll
              ref="texClustersRef"
              :clustersData="texClustersForView"
              :stepWidth="computedStepWidth"
              :maxSteps="stepCount"
              @scroll="onScroll"
              @hover-cluster="onHoverClusterRight"
            />
          </div>
        </div>
      </div>
    </div>
    <MusicGenerateDialog
      v-model="setDataDialog"
      :progress="progress"
      @generated-polyphonic="handleGenerated"
    />
  </div>
</template>

<style scoped>
.viz-container {
  display: grid;
  grid-template-columns: 1fr 1fr;
  grid-template-rows: 1fr 1fr;
  height: calc(100vh - 80px);
  width: 100%;
}
.quadrant {
  overflow: hidden;
  background: transparent;
}
.quadrant > * {
  height: 100%;
  min-height: 0;
}
.top-left, .top-right, .bottom-left, .bottom-right {
  padding: 0;
}
.in-quadrant {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;

}
.row-in-quadrant {
  flex: 1;
  min-height: 0;
  overflow: auto;
}

</style>

<script setup lang="ts">
import { ref, nextTick, computed, watch, onMounted, onUnmounted } from 'vue'
import MusicGenerateDialog from '../dialog/MusicGenerateDialog.vue'
import axios from 'axios'
import { v4 as uuidv4 } from 'uuid'
import { useJobChannel } from '../../composables/useJobChannel'
import StreamsRoll from '../visualizer/StreamsRoll.vue'
import ClustersRoll from '../visualizer/ClustersRoll.vue'
import { useScrollSync } from '../../composables/useScrollSync'
// スクロール同期
const pianoRollRef = ref(null)
const briRollRef = ref(null)
const hrdRollRef = ref(null)
const texRollRef = ref(null)
const velClustersRef = ref(null)
const octClustersRef = ref(null)
const noteClustersRef = ref(null)
const briClustersRef = ref(null)
const hrdClustersRef = ref(null)
const texClustersRef = ref(null)
const containerRef = ref<HTMLElement | null>(null)

const containerWidth = ref(containerRef.value ? containerRef.value.clientWidth : 0)
let resizeObserver: ResizeObserver | null = null

// 最大ステップ数の計算
const maxSteps = computed(() => {
  if (!generate.value.octaves[0]) return 100
  return generate.value.octaves[0].length
})

const { syncScroll } = useScrollSync([
  pianoRollRef,
  briRollRef,
  hrdRollRef,
  texRollRef,
  velClustersRef,
  octClustersRef,
  noteClustersRef,
  briClustersRef,
  hrdClustersRef,
  texClustersRef
])
const onScroll = (e) => syncScroll(e)
// 画面幅に合わせてステップ幅を計算
const computedStepWidth = computed(() => {
  const widthPerStep = containerWidth.value / 2 / maxSteps.value
  return Math.max(4, widthPerStep)
})
const updateWidth = () => {
  if (containerRef.value && containerRef.value.clientWidth > 0) containerWidth.value = containerRef.value.clientWidth
}

onMounted(() => {
  nextTick(updateWidth)
  if (containerRef.value) {
    resizeObserver = new ResizeObserver((entries) => {
      for (const entry of entries) {
        if (entry.contentRect.width > 0) containerWidth.value = entry.contentRect.width
      }
    })
    resizeObserver.observe(containerRef.value)
  }
})

onUnmounted(() => { if (resizeObserver) resizeObserver.disconnect() })

type ClusterData = {
  window_size: number;
  cluster_id: string;
  indices: number[];
}
type PolyphonicResponse = {
  timeSeries: number[][][]; // [step][stream][6]
  clusters: {
    [key: string]: {
      global: ClusterData[];
      streams: { [streamId: string]: ClusterData[] };
    }
  };
  processingTime: number;
}
const generate = ref({
  rawTimeSeries: [] as number[][][],        // そのまま受け取る
  // 各次元ごとの [stream][step] 配列
  octaves: [] as number[][],
  notes: [] as number[][],
  velocities: [] as number[][],
  brightness: [] as number[][],
  hardness: [] as number[][],
  texture: [] as number[][],

  clusters: {
    octave: { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    note:   { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    vol:    { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    bri:    { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    hrd:    { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    tex:    { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
  },
})
const progress = ref({ percent: 0, status: 'idle' })
const setDataDialog = ref(false)
const DIM = {
  OCT: 0,
  NOTE: 1,
  VOL: 2,
  BRI: 3,
  HRD: 4,
  TEX: 5,
} as const
const stepCount = ref(0)

const expandTimeSeries = (ts: number[][][]) => {
  stepCount.value   = ts.length
  const maxStreams  = Math.max(0, ...ts.map(step => step.length))

  const make2D = () =>
    Array.from({ length: maxStreams }, () => Array(stepCount.value).fill(null))

  const octs = make2D()
  const notes = make2D()
  const vels = make2D()
  const bris = make2D()
  const hrds = make2D()
  const texs = make2D()

  ts.forEach((stepStreams, stepIdx) => {
    stepStreams.forEach((vec, streamIdx) => {
      octs[streamIdx][stepIdx]  = vec[DIM.OCT]
      notes[streamIdx][stepIdx] = vec[DIM.NOTE]
      vels[streamIdx][stepIdx]  = vec[DIM.VOL]
      bris[streamIdx][stepIdx]  = vec[DIM.BRI]
      hrds[streamIdx][stepIdx]  = vec[DIM.HRD]
      texs[streamIdx][stepIdx]  = vec[DIM.TEX]
    })
  })

  return { octs, notes, vels, bris, hrds, texs, maxStreams }
}
const velocityMode = ref<'global' | 'stream'>('global')
const velocityStreamId = ref<number>(0)
const velocityClustersForView = computed<ClusterData[]>(() => {
  const src = generate.value.clusters.vol
  if (!src) return []

  if (velocityMode.value === 'global') {
    return src.global
  } else {
    const sid = String(velocityStreamId.value)
    return src.streams[sid] || []
  }
})

const octaveMode    = ref<'global' | 'stream'>('global')
const octaveStreamId = ref<number>(0)
const octaveClustersForView  = computed<ClusterData[]>(() => {
  const src = generate.value.clusters.octave
  if (!src) return []

  if (octaveMode.value === 'global') {
    return src.global
  } else {
    const sid = String(octaveStreamId.value)
    return src.streams[sid] || []
  }
})

const noteMode      = ref<'global' | 'stream'>('global')
const noteStreamId   = ref<number>(0)
const noteClustersForView  = computed<ClusterData[]>(() => {
  const src = generate.value.clusters.note
  if (!src) return []

  if (noteMode.value === 'global') {
    return src.global
  } else {
    const sid = String(noteStreamId.value)
    return src.streams[sid] || []
  }
})

const briMode = ref<'global' | 'stream'>('global')
const briStreamId = ref<number>(0)
const briClustersForView = computed<ClusterData[]>(() => {
  const src = generate.value.clusters.bri
  if (!src) return []

  if (briMode.value === 'global') {
    return src.global
  } else {
    const sid = String(briStreamId.value)
    return src.streams[sid] || []
  }
})

const hrdMode    = ref<'global' | 'stream'>('global')
const hrdStreamId = ref<number>(0)
const hrdClustersForView  = computed<ClusterData[]>(() => {
  const src = generate.value.clusters.hrd
  if (!src) return []

  if (hrdMode.value === 'global') {
    return src.global
  } else {
    const sid = String(hrdStreamId.value)
    return src.streams[sid] || []
  }
})

const texMode      = ref<'global' | 'stream'>('global')
const texStreamId   = ref<number>(0)
const texClustersForView  = computed<ClusterData[]>(() => {
  const src = generate.value.clusters.tex
  if (!src) return []

  if (texMode.value === 'global') {
    return src.global
  } else {
    const sid = String(texStreamId.value)
    return src.streams[sid] || []
  }
})

// Separate highlight state for left (piano) and right (brightness/hardness/texture)
const leftHighlightedIndices = ref<number[]>([])
const leftHighlightedWindowSize = ref(0)
const rightHighlightedIndices = ref<number[]>([])
const rightHighlightedWindowSize = ref(0)

const onHoverClusterLeft = (payload: { indices: number[]; windowSize: number } | null) => {
  if (!payload) {
    leftHighlightedIndices.value = []
    leftHighlightedWindowSize.value = 0
  } else {
    leftHighlightedIndices.value = payload.indices
    leftHighlightedWindowSize.value = payload.windowSize
  }
}

const onHoverClusterRight = (payload: { indices: number[]; windowSize: number } | null) => {
  if (!payload) {
    rightHighlightedIndices.value = []
    rightHighlightedWindowSize.value = 0
  } else {
    rightHighlightedIndices.value = payload.indices
    rightHighlightedWindowSize.value = payload.windowSize
  }
}

const openParams = () => { setDataDialog.value = true }
import { defineExpose } from 'vue'
defineExpose({ openParams })

const handleGenerated = (data: PolyphonicResponse) => {
  const ts = data.timeSeries

  const { octs, notes, vels, bris, hrds, texs } = expandTimeSeries(ts)

  generate.value.rawTimeSeries = ts
  generate.value.octaves      = octs
  generate.value.notes        = notes
  generate.value.velocities   = vels
  generate.value.brightness   = bris
  generate.value.hardness     = hrds
  generate.value.texture      = texs

  generate.value.clusters.octave = data.clusters.octave
  generate.value.clusters.note   = data.clusters.note
  generate.value.clusters.vol    = data.clusters.vol
  generate.value.clusters.bri    = data.clusters.bri
  generate.value.clusters.hrd    = data.clusters.hrd
  generate.value.clusters.tex    = data.clusters.tex
}

const pitchStreams = computed(() => {
  if (!generate.value.octaves.length) return []
  return generate.value.octaves.map((octStream, sIdx) =>
    octStream.map((oct, stepIdx) => {
      const note = generate.value.notes[sIdx]?.[stepIdx]
      if (oct == null || note == null) return null
      return oct * 12 + note
    })
  )
})

const minPitch = computed(() => 0)
const maxPitch = computed(() => 12 * 8 - 1) // 0..7oct を想定
</script>
