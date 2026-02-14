<template>
  <div class="music-generate-root">
    <div class="viz-container" ref="containerRef">
      <div class="quadrant top-left">
        <StreamsRoll
          ref="pianoRollRef"
          :streamValues="chordPitchStreams"
          :stepWidth="computedStepWidth"
          :minValue="minPitch"
          :maxValue="maxPitch"
          :valueResolution="1"
          :highlightIndices="pianoHighlightedIndices"
          :highlightWindowSize="pianoHighlightedWindowSize"
          :playheadStep="playheadStepForRoll"
          title="Piano Roll"
          @scroll="onScroll"
        />
      </div>

      <div class="quadrant bottom-left">
        <div class="in-quadrant">
          <div v-if="analysedViewMode === 'Complexity'" class="row-in-quadrant">
            <StreamsRoll
              ref="dissonanceRollRef"
              :streamValues="dissonanceTargetStreams"
              :streamLabels="singleValueStreamLabel"
              :stepWidth="computedStepWidth"
              :minValue="0"
              :maxValue="1"
              :valueResolution="0.01"
              :playheadStep="playheadStepForRoll"
              title="DISSONANCE Params"
              @scroll="onScroll"
            />
          </div>

          <div class="row-in-quadrant">
            <ClustersRoll
              v-if="analysedViewMode === 'Cluster'"
              ref="velClustersRef"
              :clustersData="velocityClustersForView"
              :stepWidth="computedStepWidth"
              :maxSteps="stepCount"
              title="VOL Clusters"
              :highlightedIndices="leftHighlightedIndices"
              :highlightedWindowSize="leftHighlightedWindowSize"
              @hover-cluster="onHoverClusterLeftAndPiano"
              @scroll="onScroll"
            />
            <StreamsRoll
              v-else
              ref="velClustersRef"
              :streamValues="complexityStreams.vol"
              :streamLabels="complexityParamStreamLabels"
              :stepWidth="computedStepWidth"
              :minValue="0"
              :maxValue="1"
              :valueResolution="0.01"
              :playheadStep="playheadStepForRoll"
              title="VOL Params"
              @scroll="onScroll"
            />
          </div>

          <div class="row-in-quadrant">
            <ClustersRoll
              v-if="analysedViewMode === 'Cluster'"
              ref="chordRangeClustersRef"
              :clustersData="chordRangeClustersForView"
              :stepWidth="computedStepWidth"
              :maxSteps="stepCount"
              title="CHORD_RANGE Clusters"
              :highlightedIndices="leftHighlightedIndices"
              :highlightedWindowSize="leftHighlightedWindowSize"
              @hover-cluster="onHoverClusterLeftAndPiano"
              @scroll="onScroll"
            />
            <StreamsRoll
              v-else
              ref="chordRangeClustersRef"
              :streamValues="complexityStreams.chordRange"
              :streamLabels="complexityParamStreamLabels"
              :stepWidth="computedStepWidth"
              :minValue="0"
              :maxValue="1"
              :valueResolution="0.01"
              :playheadStep="playheadStepForRoll"
              title="CHORD_RANGE Params"
              @scroll="onScroll"
            />
          </div>

          <div class="row-in-quadrant">
            <ClustersRoll
              v-if="analysedViewMode === 'Cluster'"
              ref="areaClustersRef"
              :clustersData="areaClustersForView"
              :stepWidth="computedStepWidth"
              :maxSteps="stepCount"
              title="AREA Clusters"
              :highlightedIndices="leftHighlightedIndices"
              :highlightedWindowSize="leftHighlightedWindowSize"
              @hover-cluster="onHoverClusterLeftAndPiano"
              @scroll="onScroll"
            />
            <StreamsRoll
              v-else
              ref="areaClustersRef"
              :streamValues="complexityStreams.area"
              :streamLabels="complexityParamStreamLabels"
              :stepWidth="computedStepWidth"
              :minValue="0"
              :maxValue="1"
              :valueResolution="0.01"
              :playheadStep="playheadStepForRoll"
              title="AREA Params"
              @scroll="onScroll"
            />
          </div>

          <div class="row-in-quadrant">
            <ClustersRoll
              v-if="analysedViewMode === 'Cluster'"
              ref="densityClustersRef"
              :clustersData="densityClustersForView"
              :stepWidth="computedStepWidth"
              :maxSteps="stepCount"
              title="DENSITY Clusters"
              :highlightedIndices="leftHighlightedIndices"
              :highlightedWindowSize="leftHighlightedWindowSize"
              @hover-cluster="onHoverClusterLeftAndPiano"
              @scroll="onScroll"
            />
            <StreamsRoll
              v-else
              ref="densityClustersRef"
              :streamValues="complexityStreams.density"
              :streamLabels="complexityParamStreamLabels"
              :stepWidth="computedStepWidth"
              :minValue="0"
              :maxValue="1"
              :valueResolution="0.01"
              :playheadStep="playheadStepForRoll"
              title="DENSITY Params"
              @scroll="onScroll"
            />
          </div>

          <div class="row-in-quadrant">
            <ClustersRoll
              v-if="analysedViewMode === 'Cluster'"
              ref="sustainClustersRef"
              :clustersData="sustainClustersForView"
              :stepWidth="computedStepWidth"
              :maxSteps="stepCount"
              title="SUSTAIN Clusters"
              :highlightedIndices="leftHighlightedIndices"
              :highlightedWindowSize="leftHighlightedWindowSize"
              @hover-cluster="onHoverClusterLeft"
              @scroll="onScroll"
            />
            <StreamsRoll
              v-else
              ref="sustainClustersRef"
              :streamValues="complexityStreams.sustain"
              :streamLabels="complexityParamStreamLabels"
              :stepWidth="computedStepWidth"
              :minValue="0"
              :maxValue="1"
              :valueResolution="0.25"
              :playheadStep="playheadStepForRoll"
              title="SUSTAIN Params"
              @scroll="onScroll"
            />
          </div>

          <div class="row-in-quadrant">
            <ClustersRoll
              v-if="analysedViewMode === 'Cluster'"
              ref="briClustersRef"
              :clustersData="briClustersForView"
              :stepWidth="computedStepWidth"
              :maxSteps="stepCount"
              title="BRI Clusters"
              :highlightedIndices="rightHighlightedIndices"
              :highlightedWindowSize="rightHighlightedWindowSize"
              @hover-cluster="onHoverClusterRight"
              @scroll="onScroll"
            />
            <StreamsRoll
              v-else
              ref="briClustersRef"
              :streamValues="complexityStreams.bri"
              :streamLabels="complexityParamStreamLabels"
              :stepWidth="computedStepWidth"
              :minValue="0"
              :maxValue="1"
              :valueResolution="0.01"
              :playheadStep="playheadStepForRoll"
              title="BRI Params"
              @scroll="onScroll"
            />
          </div>

          <div class="row-in-quadrant">
            <ClustersRoll
              v-if="analysedViewMode === 'Cluster'"
              ref="hrdClustersRef"
              :clustersData="hrdClustersForView"
              :stepWidth="computedStepWidth"
              :maxSteps="stepCount"
              title="HRD Clusters"
              :highlightedIndices="rightHighlightedIndices"
              :highlightedWindowSize="rightHighlightedWindowSize"
              @hover-cluster="onHoverClusterRight"
              @scroll="onScroll"
            />
            <StreamsRoll
              v-else
              ref="hrdClustersRef"
              :streamValues="complexityStreams.hrd"
              :streamLabels="complexityParamStreamLabels"
              :stepWidth="computedStepWidth"
              :minValue="0"
              :maxValue="1"
              :valueResolution="0.01"
              :playheadStep="playheadStepForRoll"
              title="HRD Params"
              @scroll="onScroll"
            />
          </div>

          <div class="row-in-quadrant">
            <ClustersRoll
              v-if="analysedViewMode === 'Cluster'"
              ref="texClustersRef"
              :clustersData="texClustersForView"
              :stepWidth="computedStepWidth"
              :maxSteps="stepCount"
              title="TEX Clusters"
              :highlightedIndices="rightHighlightedIndices"
              :highlightedWindowSize="rightHighlightedWindowSize"
              @hover-cluster="onHoverClusterRight"
              @scroll="onScroll"
            />
            <StreamsRoll
              v-else
              ref="texClustersRef"
              :streamValues="complexityStreams.tex"
              :streamLabels="complexityParamStreamLabels"
              :stepWidth="computedStepWidth"
              :minValue="0"
              :maxValue="1"
              :valueResolution="0.01"
              :playheadStep="playheadStepForRoll"
              title="TEX Params"
              @scroll="onScroll"
            />
          </div>
        </div>
      </div>
    </div>

    <div class="bottom-scrollbar" ref="bottomScrollRef" @scroll="onScroll">
      <div class="bottom-scrollbar-track" :style="{ width: `${globalScrollTrackWidth}px` }"></div>
    </div>

    <MusicGenerateDialog
      ref="dialogRef"
      v-model="setDataDialog"
      @generated="handleGenerated"
      @dispatched="handleDispatched"
      @params-built="handleParamsBuilt"
      @params-updated="handleParamsUpdated"
    />
  </div>
</template>

<style scoped>
.viz-container {
  display: grid;
  grid-template-columns: 1fr;
  grid-template-rows: 0.7fr 1.3fr;
  width: 100%;
  flex: 1 1 auto;
  min-height: 0;
}
.quadrant {
  overflow: hidden;
  background: transparent;
}
.quadrant > * {
  height: 100%;
  min-height: 0;
}
.top-left, .bottom-left {
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
.music-generate-root {
  display: flex;
  flex-direction: column;
  height: calc(100vh - 80px);
  width: 100%;
  min-height: 0;
}
.bottom-scrollbar {
  overflow-x: auto;
  overflow-y: hidden;
  width: 100%;
  min-height: 14px;
  max-height: 14px;
  border-top: 1px solid #ccc;
  background: #fff;
}
.bottom-scrollbar-track {
  height: 1px;
}
</style>

<script setup lang="ts">
import { ref, nextTick, computed, onMounted, onUnmounted, watch } from 'vue'
import axios from 'axios'
import MusicGenerateDialog from '../dialog/MusicGenerateDialog.vue'
import StreamsRoll from '../visualizer/StreamsRoll.vue'
import ClustersRoll from '../visualizer/ClustersRoll.vue'
import { useScrollSync } from '../../composables/useScrollSync'
import { defineExpose } from 'vue'

// ===== refs =====
const pianoRollRef = ref<any>(null)
const dissonanceRollRef = ref<any>(null)
const velClustersRef = ref<any>(null)
const chordRangeClustersRef = ref<any>(null)
const areaClustersRef = ref<any>(null)
const densityClustersRef = ref<any>(null)
const sustainClustersRef = ref<any>(null)
const briClustersRef = ref<any>(null)
const hrdClustersRef = ref<any>(null)
const texClustersRef = ref<any>(null)
const bottomScrollRef = ref<HTMLElement | null>(null)
const dialogRef = ref<any>(null)

const containerRef = ref<HTMLElement | null>(null)
const soundFilePath = ref('')
const serverSoundFilePath = ref('')
const dispatchInfo = ref<any | null>(null)
const uploadedResultJsonFile = ref<File | null>(null)
const uploadedWavFile = ref<File | null>(null)
const uploadedParamsJsonFile = ref<File | null>(null)
let uploadedWavObjectUrl: string | null = null
let generatedAudioObjectUrl: string | null = null
let generatedAudioBlob: Blob | null = null
const scdFilePath = ref('')
const audio = ref<HTMLAudioElement | null>(null)
const nowPlaying = ref(false)
const lastResultJson = ref<any | null>(null)
const latestParamsPayload = ref<any | null>(null)
const analysedViewMode = ref<'Cluster' | 'Complexity'>('Cluster')

const containerWidth = ref(0)
let resizeObserver: ResizeObserver | null = null

const progress = ref({ percent: 0, status: 'idle' })
const setDataDialog = ref(false)
const complexityParamStreamLabels = ['global', 'conc', 'spread', 'center']
const singleValueStreamLabel = ['value']
const playheadStep = ref(-1)
let playheadTimerId: ReturnType<typeof setInterval> | null = null
const playheadStepForRoll = computed(() => (nowPlaying.value ? playheadStep.value : -1))
const currentPlaybackBpm = ref(240)
const normalizeBpm = (val: any): number => {
  const bpm = Number(val)
  return Number.isFinite(bpm) && bpm > 0 ? bpm : 240
}

const resolveGenerationBpm = (): number => {
  const payload = latestParamsPayload.value
  if (payload && typeof payload === 'object') {
    const gp = (payload as any).generate_polyphonic ?? payload
    if (gp?.bpm != null) return normalizeBpm(gp.bpm)
  }

  const result = lastResultJson.value as any
  if (result?.bpm != null) return normalizeBpm(result.bpm)

  return 240
}

const clearPlayheadTimer = () => {
  if (playheadTimerId) {
    clearInterval(playheadTimerId)
    playheadTimerId = null
  }
}

const stopPlayhead = () => {
  clearPlayheadTimer()
  playheadStep.value = -1
}

const startPlayhead = (bpm: number) => {
  const safeBpm = Number.isFinite(bpm) && bpm > 0 ? bpm : 240
  const stepMs = Math.max(20, Math.round((60 * 1000) / safeBpm))
  const totalSteps = Math.max(1, stepCount.value)

  playheadStep.value = 0
  clearPlayheadTimer()
  playheadTimerId = setInterval(() => {
    if (!nowPlaying.value) return
    playheadStep.value = Math.min(playheadStep.value + 1, totalSteps - 1)
  }, stepMs)
}

const startPlaybackVisual = (bpm = 240) => {
  nowPlaying.value = true
  startPlayhead(bpm)
}

const stopPlaybackVisual = () => {
  nowPlaying.value = false
  stopPlayhead()
}

const createAudioElement = (url: string) => {
  const a = new Audio(url)
  a.preload = 'auto'
  a.addEventListener('ended', () => { nowPlaying.value = false })
  a.addEventListener('error', () => {
    nowPlaying.value = false
    stopPlayhead()
  })
  return a
}

const openParams = () => { setDataDialog.value = true }
const setAnalysedViewMode = (mode: 'Cluster' | 'Complexity') => { analysedViewMode.value = mode }
const stopPlayingSound = () => {
  nowPlaying.value = false
  audio.value?.pause()
  if (audio.value) audio.value.currentTime = 0
  stopPlayhead()
}
const startPlayingSound = (bpm?: number) => {
  const safeBpm = normalizeBpm(bpm ?? resolveGenerationBpm())
  currentPlaybackBpm.value = safeBpm

  const sourceUrl = soundFilePath.value
  if (!sourceUrl) return

  if (!audio.value || audio.value.src !== sourceUrl) {
    audio.value = createAudioElement(sourceUrl)
  }
  if (!audio.value) return

  const a = audio.value
  a.currentTime = 0
  nowPlaying.value = true
  startPlayhead(currentPlaybackBpm.value)

  const tryPlay = (target: HTMLAudioElement, allowRetry: boolean) => {
    const playResult = target.play()
    if (!playResult || typeof (playResult as Promise<void>).catch !== 'function') return
    ;(playResult as Promise<void>).catch((err) => {
      if (allowRetry) {
        try { target.pause() } catch {}
        const retried = createAudioElement(sourceUrl)
        audio.value = retried
        retried.currentTime = 0
        tryPlay(retried, false)
        return
      }
      console.error('Audio play failed', err)
      nowPlaying.value = false
      stopPlayhead()
    })
  }

  tryPlay(a, true)
}

watch(nowPlaying, (playing) => {
  if (!playing) stopPlayhead()
})

// Keep audio element in sync with the latest soundFilePath (generated or uploaded)
watch(soundFilePath, (url) => {
  nowPlaying.value = false
  stopPlayhead()
  try { audio.value?.pause() } catch {}
  audio.value = null

  if (!url) return
  audio.value = createAudioElement(url)
})

// ===== scroll sync =====
const { syncScroll } = useScrollSync([
  pianoRollRef,
  dissonanceRollRef,
  velClustersRef,
  chordRangeClustersRef,
  areaClustersRef,
  densityClustersRef,
  sustainClustersRef,
  briClustersRef,
  hrdClustersRef,
  texClustersRef,
  bottomScrollRef
])
const onScroll = (e: Event) => syncScroll(e)

// ===== sizing =====
const stepCount = ref(0)
const maxSteps = computed(() => (stepCount.value > 0 ? stepCount.value : 100))
const rollTitleWidth = 80
const plotAreaWidth = computed(() => Math.max(1, containerWidth.value - rollTitleWidth))

const computedStepWidth = computed(() => {
  const widthPerStep = plotAreaWidth.value / maxSteps.value
  return Math.max(4, widthPerStep)
})

const updateWidth = () => {
  if (containerRef.value && containerRef.value.clientWidth > 0) {
    containerWidth.value = containerRef.value.clientWidth
  }
}

onMounted(() => {
  nextTick(() => {
    updateWidth()
    const payload = dialogRef.value?.buildParamsPayload?.()
    if (payload) latestParamsPayload.value = payload
  })
  if (containerRef.value) {
    resizeObserver = new ResizeObserver((entries) => {
      for (const entry of entries) {
        if (entry.contentRect.width > 0) containerWidth.value = entry.contentRect.width
      }
    })
    resizeObserver.observe(containerRef.value)
  }
})

onUnmounted(() => {
  if (resizeObserver) resizeObserver.disconnect()
  clearPlayheadTimer()
  if (uploadedWavObjectUrl) URL.revokeObjectURL(uploadedWavObjectUrl)
  if (generatedAudioObjectUrl) URL.revokeObjectURL(generatedAudioObjectUrl)
})

// ===== types =====
type ClusterData = {
  window_size: number
  cluster_id: string
  indices: number[]
}
type StepVecLegacy = [number, number[] | number, number, number, number, number]
// strict server: [abs_notes(Int[]), vol, bri, hrd, tex, chord_range(Int), density, sustain]
type StepVecStrict = [number[], number, number, number, number, number, number, number]
type StepVec = StepVecLegacy | StepVecStrict
type PolyphonicResponse = {
  timeSeries: StepVec[][];
  clusters: Record<string, { global: ClusterData[]; streams: Record<string, ClusterData[]> }>;
  processingTime: number;
}

// ===== state =====
const generate = ref({
  rawTimeSeries: [] as any[],
  notes: [] as (number | null)[][],
  velocities: [] as (number | null)[][],
  brightness: [] as (number | null)[][],
  hardness: [] as (number | null)[][],
  texture: [] as (number | null)[][],

  clusters: {
    area: { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    chord_range: { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    density: { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    note:   { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    vol:    { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    bri:    { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    hrd:    { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    tex:    { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    sustain:{ global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
  },
})

const DIM = {
  OCT: 0,
  NOTE: 1,
  VOL: 2,
  BRI: 3,
  HRD: 4,
  TEX: 5,
} as const

// ===== handle response =====
const applyPolyphonicResponse = (data: PolyphonicResponse) => {
  lastResultJson.value = data
  const ts = (data as any).timeSeries as any[]
  const { notes, vels, bris, hrds, texs } = expandTimeSeries(ts)

  generate.value.rawTimeSeries = ts as any
  generate.value.notes        = notes      // root（abs_notes[0] or pcs[0]）互換用途
  generate.value.velocities   = vels
  generate.value.brightness   = bris
  generate.value.hardness     = hrds
  generate.value.texture      = texs

  const clusters = ((data as any).clusters ?? {}) as any
  generate.value.clusters.vol         = clusters.vol         ?? { global: [], streams: {} }
  generate.value.clusters.area        = clusters.area        ?? { global: [], streams: {} }
  generate.value.clusters.chord_range = clusters.chord_range ?? { global: [], streams: {} }
  generate.value.clusters.density     = clusters.density     ?? { global: [], streams: {} }
  generate.value.clusters.note        = clusters.note        ?? { global: [], streams: {} }
  generate.value.clusters.bri         = clusters.bri         ?? { global: [], streams: {} }
  generate.value.clusters.hrd         = clusters.hrd         ?? { global: [], streams: {} }
  generate.value.clusters.tex         = clusters.tex         ?? { global: [], streams: {} }
  generate.value.clusters.sustain     = clusters.sustain     ?? { global: [], streams: {} }
}

const handleGenerated = (data: PolyphonicResponse) => {
  applyPolyphonicResponse(data)
  const ts = data.timeSeries
  const responseBpm = Number((data as any)?.bpm)
  renderPolyphonicAudio(ts, Number.isFinite(responseBpm) && responseBpm > 0 ? responseBpm : undefined)
}

const handleDispatched = (info: any) => {
  dispatchInfo.value = info
}

const handleParamsBuilt = (payload: any) => {
  latestParamsPayload.value = payload
}

const handleParamsUpdated = (payload: any) => {
  latestParamsPayload.value = payload
}

async function loadResultJsonFile(file: File | null) {
  uploadedResultJsonFile.value = file
  if (!file) return
  try {
    const text = await file.text()
    const obj = JSON.parse(text)
    applyPolyphonicResponse(obj as PolyphonicResponse)
  } catch (err) {
    console.error('Failed to load result.json', err)
  }
}

async function loadWavFile(file: File | null) {
  uploadedWavFile.value = file
  if (!file) return
  try {
    if (uploadedWavObjectUrl) URL.revokeObjectURL(uploadedWavObjectUrl)
    uploadedWavObjectUrl = URL.createObjectURL(file)
    generatedAudioBlob = null
    soundFilePath.value = uploadedWavObjectUrl
    serverSoundFilePath.value = ''
    scdFilePath.value = ''
  } catch (err) {
    console.error('Failed to load wav', err)
  }
}

async function loadParamsJsonFile(file: File | null) {
  uploadedParamsJsonFile.value = file
  if (!file) return
  try {
    const text = await file.text()
    const obj = JSON.parse(text)
    latestParamsPayload.value = obj
    await dialogRef.value?.applyParamsPayload?.(obj)
  } catch (err) {
    console.error('Failed to load params.json', err)
  }
}

const expandTimeSeries = (ts: any[]) => {
  stepCount.value = ts.length
  const maxStreams = Math.max(0, ...ts.map(step => step.length))
  const make2D = () => Array.from({ length: maxStreams }, () => Array(stepCount.value).fill(null))

  const notes = make2D()  // root互換: abs_notes[0] or pcs[0]
  const vels = make2D()
  const bris = make2D()
  const hrds = make2D()
  const texs = make2D()

  ts.forEach((stepStreams, stepIdx) => {
    stepStreams.forEach((vec, streamIdx) => {
      if (!vec) return

      // Strict: [abs_notes(Int[]), vol, bri, hrd, tex, chord_range, density, sustain]
      // Legacy: [oct(Int), pcs(Int|Int[]), vol, bri, hrd, tex]
      if (Array.isArray(vec[0])) {
        const absNotes = (vec[0] as any[]).map(n => Number(n)).filter(n => Number.isFinite(n))
        notes[streamIdx][stepIdx] = absNotes.length ? absNotes[0] : null
        vels[streamIdx][stepIdx]  = vec[1]
        bris[streamIdx][stepIdx]  = vec[2]
        hrds[streamIdx][stepIdx]  = vec[3]
        texs[streamIdx][stepIdx]  = vec[4]
      } else {
        const noteVal = vec[1]
        const pcs = Array.isArray(noteVal) ? noteVal : [noteVal]
        notes[streamIdx][stepIdx] = (pcs[0] ?? null)
        vels[streamIdx][stepIdx]  = vec[2]
        bris[streamIdx][stepIdx]  = vec[3]
        hrds[streamIdx][stepIdx]  = vec[4]
        texs[streamIdx][stepIdx]  = vec[5]
      }
    })
  })

  return { notes, vels, bris, hrds, texs, maxStreams }
}

const renderPolyphonicAudio = (timeSeries: any[][], bpmArg?: number) => {
  progress.value.status = 'rendering'
  const bpm = normalizeBpm(bpmArg ?? resolveGenerationBpm())

  // renderer は legacy 形式を想定していることが多いので、strict(abs_notes) の場合は変換して投げる
  const toLegacyForRender = (ts: any[][]) => {
    const out: any[] = []
    const chords: any[] = []

    const normAbs = (arr: any): number[] => {
      if (!Array.isArray(arr)) return []
      return arr.map(n => Number(n)).filter(n => Number.isFinite(n)).map(n => Math.round(n))
    }

    for (const step of ts) {
      const stepOut: any[] = []
      const stepChords: any[] = []

      for (const vec of step) {
        if (!vec) continue

        // Strict: [abs_notes, vol, bri, hrd, tex, chord_range, density, sustain]
        if (Array.isArray(vec[0])) {
          const absNotes = normAbs(vec[0])
          const vol = vec[1]
          const bri = vec[2]
          const hrd = vec[3]
          const tex = vec[4]
          const chordRange = Number(vec[5] ?? 0)
          const density = Number(vec[6] ?? 0)
          const sustain = Number(vec[7] ?? 0.0)

          // Keep strict stream shape so backend can tie by stream index reliably.
          stepOut.push([absNotes, vol, bri, hrd, tex, chordRange, density, sustain])

          const pcs = absNotes
            .map(n => ((n % 12) + 12) % 12)
            .sort((a, b) => a - b)
          stepChords.push(pcs)
        } else {
          // Legacy: [oct, pcs, vol, bri, hrd, tex, sustain?]
          const oct = vec[0]
          const pcs = Array.isArray(vec[1]) ? vec[1] : [vec[1]]
          const sustain = Number(vec[6] ?? 0.0)
          stepOut.push([oct, pcs, vec[2], vec[3], vec[4], vec[5], sustain])
          stepChords.push(pcs)
        }
      }

      out.push(stepOut)
      chords.push(stepChords)
    }

    return { out, chords }
  }

  const { out, chords } = toLegacyForRender(timeSeries)

  axios.post('/api/web/supercolliders/render_polyphonic', {
    time_series: out,
    bpm,
    note_chords_pitch_classes: chords,
  })
    .then(response => {
      const { sound_file_path, scd_file_path, audio_data } = response.data
      serverSoundFilePath.value = sound_file_path
      scdFilePath.value = scd_file_path

      // base64 wav -> Blob URL (browser playback)
      const base64 = audio_data.includes(',') ? audio_data.split(',')[1] : audio_data
      const binary = atob(base64)
      const len = binary.length
      const bytes = new Uint8Array(len)
      for (let i = 0; i < len; i++) bytes[i] = binary.charCodeAt(i)

      const blob = new Blob([bytes.buffer], { type: "audio/wav" })
      generatedAudioBlob = blob
      if (generatedAudioObjectUrl) URL.revokeObjectURL(generatedAudioObjectUrl)
      generatedAudioObjectUrl = URL.createObjectURL(blob)
      soundFilePath.value = generatedAudioObjectUrl

      progress.value.status = 'idle'
      cleanup()
    })
    .catch(error => {
      console.error("Rendering error:", error)
      progress.value.status = 'idle'
    })
}

const cleanup = () => {
  const data = {
    cleanup: {
      sound_file_path: serverSoundFilePath.value,
      scd_file_path: scdFilePath.value
    }
  }
  axios.delete("/api/web/supercolliders/cleanup", { data })
    .then(() => console.log('deleted temporary files'))
    .catch(error => console.error("音声削除エラー", error))
}

const triggerDownload = (blob: Blob, filename: string) => {
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  URL.revokeObjectURL(url)
}

const downloadResultJson = () => {
  if (uploadedResultJsonFile.value) {
    triggerDownload(uploadedResultJsonFile.value, 'result.json')
    return
  }
  if (lastResultJson.value) {
    const blob = new Blob([JSON.stringify(lastResultJson.value, null, 2)], { type: 'application/json' })
    triggerDownload(blob, 'result.json')
  }
}

const downloadResultWav = () => {
  if (uploadedWavFile.value) {
    triggerDownload(uploadedWavFile.value, 'result.wav')
    return
  }
  if (generatedAudioBlob) {
    triggerDownload(generatedAudioBlob, 'result.wav')
  }
}

const downloadParamsJson = () => {
  // Always prefer the latest values currently in the dialog UI.
  const fresh = dialogRef.value?.buildParamsPayload?.()
  if (fresh) {
    latestParamsPayload.value = fresh
  }

  const payload = latestParamsPayload.value
  if (!payload) {
    if (uploadedParamsJsonFile.value) {
      triggerDownload(uploadedParamsJsonFile.value, 'params.json')
    }
    return
  }

  const blob = new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json' })
  triggerDownload(blob, 'params.json')
}

const normalizeParamArray = (val: any): number[] => {
  if (Array.isArray(val)) {
    return val.map(v => Number(v)).filter(v => Number.isFinite(v))
  }
  if (val == null) return []
  const num = Number(val)
  return Number.isFinite(num) ? [num] : []
}

const buildComplexityStreams = (prefix: string) => {
  const payload = latestParamsPayload.value
  if (!payload || typeof payload !== 'object') return []
  const gp = (payload as any).generate_polyphonic ?? payload
  const ctx = gp?.initial_context
  const padLen = Array.isArray(ctx) ? ctx.length : 0
  const order = ['global', 'conc', 'spread', 'center'] as const

  const streams = order.map((suffix) => {
    const key = `${prefix}_${suffix}`
    const arr = normalizeParamArray(gp?.[key])
    const padded = Array(padLen).fill(null).concat(arr)
    return padded
  })

  const maxLen = Math.max(0, ...streams.map(s => s.length))
  return streams.map(s => {
    if (s.length >= maxLen) return s
    return s.concat(Array(maxLen - s.length).fill(null))
  })
}

const complexityStreams = computed(() => ({
  vol: buildComplexityStreams('vol'),
  chordRange: buildComplexityStreams('chord_range'),
  area: buildComplexityStreams('area'),
  bri: buildComplexityStreams('bri'),
  hrd: buildComplexityStreams('hrd'),
  tex: buildComplexityStreams('tex'),
  density: buildComplexityStreams('density'),
  sustain: buildComplexityStreams('sustain'),
}))

const dissonanceTargetStreams = computed(() => {
  const payload = latestParamsPayload.value
  if (!payload || typeof payload !== 'object') return []
  const gp = (payload as any).generate_polyphonic ?? payload
  const ctx = gp?.initial_context
  const padLen = Array.isArray(ctx) ? ctx.length : 0
  const arr = normalizeParamArray(gp?.dissonance_target)
  const padded = Array(padLen).fill(null).concat(arr)
  return [padded]
})

const maxSeriesLength = (series: unknown[][]) =>
  Math.max(0, ...series.map(stream => (Array.isArray(stream) ? stream.length : 0)))

const complexityMaxSteps = computed(() => {
  const byDimension = [
    ...(Object.values(complexityStreams.value) as unknown[][][]),
    dissonanceTargetStreams.value as unknown[][]
  ]
  return Math.max(0, ...byDimension.map(maxSeriesLength))
})

const globalScrollTrackWidth = computed(() => {
  const activeSteps = analysedViewMode.value === 'Cluster'
    ? Math.max(1, stepCount.value)
    : Math.max(1, stepCount.value, complexityMaxSteps.value)
  return Math.max(containerWidth.value, activeSteps * computedStepWidth.value)
})

// ===== pitch streams (chord) =====
const chordPitchStreams = computed(() => {
  const ts = generate.value.rawTimeSeries as any[]
  if (!ts.length) return []

  const streamCount = Math.max(0, ...ts.map(step => step.length))
  const stepLen = ts.length

  return Array.from({ length: streamCount }, (_, sIdx) =>
    Array.from({ length: stepLen }, (_, stepIdx) => {
      const vec = ts[stepIdx]?.[sIdx]
      if (!vec) return null

      // Strict: abs MIDI note numbers
      if (Array.isArray(vec[0])) {
        const absNotes = (vec[0] as any[])
          .map(n => Number(n))
          .filter(n => Number.isFinite(n))
          .map(n => Math.round(n))
        return absNotes.length ? absNotes : null
      }

      // Legacy: (oct + pcs) -> abs MIDI
      const oct = Number(vec[0])
      const noteVal = vec[1]
      const pcs = Array.isArray(noteVal) ? noteVal : [noteVal]
      const pcsSafe = pcs.filter(n => Number.isFinite(Number(n))).map(n => Number(n))

      if (!Number.isFinite(oct) || pcsSafe.length === 0) return null

      const baseC = (oct + 1) * 12
      return pcsSafe.map(pc => baseC + ((pc % 12) + 12) % 12)
    })
  )
})

// ===== cluster view switch =====
const velocityMode = ref<'global' | 'stream'>('global')
const velocityStreamId = ref<number>(0)
const velocityClustersForView = computed<ClusterData[]>(() => {
  const src = generate.value.clusters.vol
  if (!src) return []
  if (velocityMode.value === 'global') return src.global
  return src.streams[String(velocityStreamId.value)] || []
})

const chordRangeMode = ref<'global' | 'stream'>('global')
const chordRangeStreamId = ref<number>(0)
const chordRangeClustersForView = computed<ClusterData[]>(() => {
  const src = (generate.value.clusters as any).chord_range
  if (!src) return []
  if (chordRangeMode.value === 'global') return src.global
  return src.streams[String(chordRangeStreamId.value)] || []
})

const areaMode = ref<'global' | 'stream'>('global')
const areaStreamId = ref<number>(0)
const areaClustersForView = computed<ClusterData[]>(() => {
  const src = (generate.value.clusters as any).area
  if (!src) return []
  if (areaMode.value === 'global') return src.global
  return src.streams[String(areaStreamId.value)] || []
})

const densityMode = ref<'global' | 'stream'>('global')
const densityStreamId = ref<number>(0)
const densityClustersForView = computed<ClusterData[]>(() => {
  const src = (generate.value.clusters as any).density
  if (!src) return []
  if (densityMode.value === 'global') return src.global
  return src.streams[String(densityStreamId.value)] || []
})

const sustainMode = ref<'global' | 'stream'>('global')
const sustainStreamId = ref<number>(0)
const sustainClustersForView = computed<ClusterData[]>(() => {
  const src = (generate.value.clusters as any).sustain
  if (!src) return []
  if (sustainMode.value === 'global') return src.global
  return src.streams[String(sustainStreamId.value)] || []
})

const briMode = ref<'global' | 'stream'>('global')
const briStreamId = ref<number>(0)
const briClustersForView = computed<ClusterData[]>(() => {
  const src = generate.value.clusters.bri
  if (!src) return []
  if (briMode.value === 'global') return src.global
  return src.streams[String(briStreamId.value)] || []
})

const hrdMode = ref<'global' | 'stream'>('global')
const hrdStreamId = ref<number>(0)
const hrdClustersForView = computed<ClusterData[]>(() => {
  const src = generate.value.clusters.hrd
  if (!src) return []
  if (hrdMode.value === 'global') return src.global
  return src.streams[String(hrdStreamId.value)] || []
})

const texMode = ref<'global' | 'stream'>('global')
const texStreamId = ref<number>(0)
const texClustersForView = computed<ClusterData[]>(() => {
  const src = generate.value.clusters.tex
  if (!src) return []
  if (texMode.value === 'global') return src.global
  return src.streams[String(texStreamId.value)] || []
})

// ===== highlight =====
const leftHighlightedIndices = ref<number[]>([])
const leftHighlightedWindowSize = ref(0)
const pianoHighlightedIndices = ref<number[]>([])
const pianoHighlightedWindowSize = ref(0)
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
const onHoverClusterLeftAndPiano = (payload: { indices: number[]; windowSize: number } | null) => {
  if (!payload) {
    leftHighlightedIndices.value = []
    leftHighlightedWindowSize.value = 0
    pianoHighlightedIndices.value = []
    pianoHighlightedWindowSize.value = 0
  } else {
    leftHighlightedIndices.value = payload.indices
    leftHighlightedWindowSize.value = payload.windowSize
    pianoHighlightedIndices.value = payload.indices
    pianoHighlightedWindowSize.value = payload.windowSize
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

// ====== PianoRoll 用の固定レンジ ======
// strict(abs MIDI) を前提に 12..120 を表示レンジにする
const minPitch = computed(() => 12)
const maxPitch = computed(() => 120)
const getPlaybackBpm = () => resolveGenerationBpm()

defineExpose({
  openParams,
  stopPlayingSound,
  startPlayingSound,
  getPlaybackBpm,
  stopPlaybackVisual,
  startPlaybackVisual,
  soundFilePath,
  nowPlaying,
  dispatchInfo,
  loadResultJsonFile,
  loadWavFile,
  loadParamsJsonFile,
  downloadResultJson,
  downloadResultWav,
  downloadParamsJson,
  setAnalysedViewMode,
})
</script>
