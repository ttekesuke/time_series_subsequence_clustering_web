<template>
  <div class="music-generate-root">
    <div class="viz-container" ref="containerRef">
      <div class="quadrant top-left">
        <StreamsRoll
          v-if="resultViewMode === 'pianoRoll'"
          ref="pianoRollRef"
          :streamValues="chordPitchStreams"
          :streamLabels="pianoResultStreamLabels"
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
        <StreamsRoll
          v-else-if="resultViewMode === 'timbreRoll'"
          ref="timbreRollRef"
          :streamValues="timbreResultStreams"
          :streamLabels="timbreResultStreamLabels"
          :stepWidth="computedStepWidth"
          :minValue="0"
          :maxValue="1"
          :valueResolution="0.01"
          :playheadStep="playheadStepForRoll"
          title="Timbre Roll (BRI/NOI/HAR/ATK/DEC/SR/TIE)"
          @scroll="onScroll"
        />
        <StreamsRoll
          v-else-if="resultViewMode === 'volRoll'"
          ref="volRollRef"
          :streamValues="volResultStreams"
          :streamLabels="volResultStreamLabels"
          :stepWidth="computedStepWidth"
          :minValue="0"
          :maxValue="1"
          :valueResolution="0.01"
          :playheadStep="playheadStepForRoll"
          title="VOL Roll"
          @scroll="onScroll"
        />
        <StreamsRoll
          v-else-if="resultViewMode === 'chordRangeRoll'"
          ref="chordRangeRollRef"
          :streamValues="generate.chordRange"
          :streamLabels="chordRangeResultStreamLabels"
          :stepWidth="computedStepWidth"
          :minValue="0"
          :maxValue="12"
          :valueResolution="1"
          :playheadStep="playheadStepForRoll"
          title="CHORD_RANGE Roll"
          @scroll="onScroll"
        />
        <StreamsRoll
          v-else
          ref="densityRollRef"
          :streamValues="generate.density"
          :streamLabels="densityResultStreamLabels"
          :stepWidth="computedStepWidth"
          :minValue="0"
          :maxValue="1"
          :valueResolution="0.01"
          :playheadStep="playheadStepForRoll"
          title="DENSITY Roll"
          @scroll="onScroll"
        />
      </div>

      <div class="quadrant bottom-left">
        <div class="in-quadrant">
          <template v-if="analysedViewMode === 'Cluster'">
            <div class="analysis-toolbar">
              <label for="music-cluster-scope">Cluster scope</label>
              <select id="music-cluster-scope" v-model="clusterScope">
                <option value="global">Global</option>
                <option v-for="id in generate.stableStreamIds" :key="id" :value="String(id)">
                  Stream {{ id }}
                </option>
              </select>
            </div>
            <div v-for="(section, index) in clusterSections" :key="section.key" class="row-in-quadrant">
              <ClustersRoll
                :ref="el => setAnalysisRollRef(el, index)"
                :clustersData="section.clusters"
                :stepWidth="computedStepWidth"
                :maxSteps="stepCount"
                :title="`${section.title} Clusters (${clusterScopeLabel})`"
                @hover-cluster="onHoverClusterLeftAndPiano"
                @scroll="onScroll"
              />
            </div>
          </template>
          <template v-else>
            <div v-for="(section, index) in parameterSections" :key="section.key" class="row-in-quadrant">
              <StreamsRoll
                :ref="el => setAnalysisRollRef(el, index)"
                :streamValues="section.streams"
                :streamLabels="section.labels"
                :stepWidth="computedStepWidth"
                :minValue="section.min"
                :maxValue="section.max"
                :valueResolution="section.resolution"
                :playheadStep="playheadStepForRoll"
                :title="section.title"
                @scroll="onScroll"
              />
            </div>
          </template>
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
  overflow: hidden;
}
.row-in-quadrant {
  flex: 1 1 0;
  height: 0;
  min-height: 0;
  overflow: hidden;
}
.analysis-toolbar {
  flex: 0 0 34px;
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 4px 8px;
  border-bottom: 1px solid #ddd;
  background: #fafafa;
  color: #555;
  font-size: 12px;
}
.analysis-toolbar select {
  min-width: 110px;
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
const timbreRollRef = ref<any>(null)
const volRollRef = ref<any>(null)
const chordRangeRollRef = ref<any>(null)
const densityRollRef = ref<any>(null)
const analysisRollRefs = ref<any[]>([])
const setAnalysisRollRef = (el: any, index: number) => {
  analysisRollRefs.value[index] = el ?? null
}
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
const analysedViewMode = ref<'Cluster' | 'Complexity'>('Complexity')
type ResultViewMode = 'pianoRoll' | 'timbreRoll' | 'volRoll' | 'chordRangeRoll' | 'densityRoll'
const resultViewMode = ref<ResultViewMode>('pianoRoll')
const clusterScope = ref('global')
const clusterScopeLabel = computed(() =>
  clusterScope.value === 'global' ? 'Global' : `Stream ${clusterScope.value}`
)

const containerWidth = ref(0)
let resizeObserver: ResizeObserver | null = null

const progress = ref({ percent: 0, status: 'idle' })
const setDataDialog = ref(false)
const playheadStep = ref(-1)
let playheadTimerId: ReturnType<typeof setInterval> | null = null
const playheadStepForRoll = computed(() => (nowPlaying.value ? playheadStep.value : -1))
const DEFAULT_BPM = 480
const currentPlaybackBpm = ref(DEFAULT_BPM)
const normalizeBpm = (val: any): number => {
  const bpm = Number(val)
  return Number.isFinite(bpm) && bpm > 0 ? bpm : DEFAULT_BPM
}

const normalizeBpmSeries = (
  val: any,
  expectedLength: number,
  align: 'head' | 'tail' = 'head'
): number[] => {
  const source = Array.isArray(val)
    ? val
    : (val == null ? [] : [val])
  const targetLength = Math.max(1, expectedLength)

  if (source.length === 0) {
    return Array(targetLength).fill(DEFAULT_BPM)
  }

  const normalized = source.map(normalizeBpm)
  if (normalized.length >= targetLength) {
    const start = align === 'tail' ? normalized.length - targetLength : 0
    return normalized.slice(start, start + targetLength)
  }

  const fallback = normalized[normalized.length - 1] ?? DEFAULT_BPM
  return Array.from({ length: targetLength }, (_, idx) => normalized[idx] ?? fallback)
}

const combineBpmSeries = (initialRaw: any, futureRaw: any, expectedLength: number): number[] | null => {
  const hasInitial = initialRaw != null
  const hasFuture = futureRaw != null
  if (!hasInitial && !hasFuture) return null

  const initial = hasInitial ? normalizeBpmSeries(initialRaw, Math.max(1, Array.isArray(initialRaw) ? initialRaw.length : 1)) : []
  const future = hasFuture ? normalizeBpmSeries(futureRaw, Math.max(1, Array.isArray(futureRaw) ? futureRaw.length : 1)) : []
  const combined = [...initial, ...future]
  return normalizeBpmSeries(combined, expectedLength, 'tail')
}

const resolveGenerationBpmSeries = (preferred: any, expectedLength: number): number[] => {
  if (preferred != null) {
    const align = Array.isArray(preferred) ? 'tail' : 'head'
    return normalizeBpmSeries(preferred, expectedLength, align)
  }

  const payload = latestParamsPayload.value
  if (payload && typeof payload === 'object') {
    const gp = (payload as any).generate_polyphonic ?? payload
    const combined = combineBpmSeries(gp?.initial_context_bpm, gp?.future_bpm, expectedLength)
    if (combined != null) return combined
    if (gp?.future_bpm != null) return normalizeBpmSeries(gp.future_bpm, expectedLength)
    if (gp?.bpm_series != null) return normalizeBpmSeries(gp.bpm_series, expectedLength, 'tail')
    if (gp?.bpm != null) return normalizeBpmSeries(gp.bpm, expectedLength)
  }

  const result = lastResultJson.value as any
  if (result?.bpmSeries != null) return normalizeBpmSeries(result.bpmSeries, expectedLength, 'tail')
  const combined = combineBpmSeries(result?.initialContextBpm, result?.futureBpm, expectedLength)
  if (combined != null) return combined
  if (result?.futureBpm != null) return normalizeBpmSeries(result.futureBpm, expectedLength)
  if (result?.bpm != null) return normalizeBpmSeries(result.bpm, expectedLength)

  return normalizeBpmSeries(null, expectedLength)
}

const resolveGenerationBpm = (): number => {
  return resolveGenerationBpmSeries(null, 1)[0] ?? DEFAULT_BPM
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
  const safeBpm = Number.isFinite(bpm) && bpm > 0 ? bpm : DEFAULT_BPM
  const stepMs = Math.max(20, Math.round((60 * 1000) / safeBpm))
  const totalSteps = Math.max(1, stepCount.value)

  playheadStep.value = 0
  clearPlayheadTimer()
  playheadTimerId = setInterval(() => {
    if (!nowPlaying.value) return
    playheadStep.value = Math.min(playheadStep.value + 1, totalSteps - 1)
  }, stepMs)
}

const startPlaybackVisual = (bpm = DEFAULT_BPM) => {
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
const setResultViewMode = (mode: ResultViewMode) => {
  const supported: ResultViewMode[] = ['pianoRoll', 'timbreRoll', 'volRoll', 'chordRangeRoll', 'densityRoll']
  resultViewMode.value = supported.includes(mode) ? mode : 'pianoRoll'
}
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

watch(analysedViewMode, () => {
  analysisRollRefs.value = []
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
  timbreRollRef,
  volRollRef,
  chordRangeRollRef,
  densityRollRef,
  analysisRollRefs,
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
// strict server: [abs_notes(Int[]), vol, brightness, noise, harmonicity, attack, decay_sustain, release, chord_range(Int), density, tie]
type StepVecStrict = [number[], number, number, number, number, number, number, number, number, number, number]
type StepVec = StepVecStrict
type PolyphonicResponse = {
  timeSeries: StepVec[][];
  streamIds?: number[][];
  clusters: Record<string, { global: ClusterData[]; streams: Record<string, ClusterData[]> }>;
  timbreSeries?: {
    brightness?: number[][]
    noise?: number[][]
    harmonicity?: number[][]
    attack?: number[][]
    decay_sustain?: number[][]
    release?: number[][]
    tie?: number[][]
  }
  processingTime: number;
}

// ===== state =====
const generate = ref({
  rawTimeSeries: [] as any[],
  streamIds: [] as number[][],
  stableStreamIds: [] as number[],
  chords: [] as (number[] | null)[][],
  notes: [] as (number | null)[][],
  velocities: [] as (number | null)[][],
  brightness: [] as (number | null)[][],
  noise: [] as (number | null)[][],
  harmonicity: [] as (number | null)[][],
  attack: [] as (number | null)[][],
  decay_sustain: [] as (number | null)[][],
  release: [] as (number | null)[][],
  chordRange: [] as (number | null)[][],
  density: [] as (number | null)[][],
  tie: [] as (number | null)[][],

  clusters: {
    area: { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    chord_range: { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    density: { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    note:   { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    vol:    { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    brightness: { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    noise: { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    harmonicity: { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    attack: { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    decay_sustain: { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    release:{ global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    tie:    { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
  },
})

// ===== handle response =====
const applyPolyphonicResponse = (data: PolyphonicResponse) => {
  lastResultJson.value = data
  const ts = Array.isArray((data as any).timeSeries) ? (data as any).timeSeries as any[] : []
  const expanded = expandTimeSeries(ts, data.streamIds)

  generate.value.rawTimeSeries = ts as any
  generate.value.streamIds = expanded.streamIds
  generate.value.stableStreamIds = expanded.stableStreamIds
  generate.value.chords = expanded.chords
  generate.value.notes = expanded.notes
  generate.value.velocities = expanded.vels
  generate.value.brightness = expanded.brightnesses
  generate.value.noise = expanded.noises
  generate.value.harmonicity = expanded.harmonicities
  generate.value.attack = expanded.attacks
  generate.value.decay_sustain = expanded.decaySustains
  generate.value.release = expanded.releases
  generate.value.chordRange = expanded.chordRanges
  generate.value.density = expanded.densities
  generate.value.tie = expanded.ties

  const clusters = ((data as any).clusters ?? {}) as any
  generate.value.clusters.vol         = clusters.vol         ?? { global: [], streams: {} }
  generate.value.clusters.area        = clusters.area        ?? { global: [], streams: {} }
  generate.value.clusters.chord_range = clusters.chord_range ?? { global: [], streams: {} }
  generate.value.clusters.density     = clusters.density     ?? { global: [], streams: {} }
  generate.value.clusters.note        = clusters.note        ?? { global: [], streams: {} }
  generate.value.clusters.brightness  = clusters.brightness  ?? { global: [], streams: {} }
  generate.value.clusters.noise       = clusters.noise       ?? { global: [], streams: {} }
  generate.value.clusters.harmonicity = clusters.harmonicity ?? { global: [], streams: {} }
  generate.value.clusters.attack      = clusters.attack      ?? { global: [], streams: {} }
  generate.value.clusters.decay_sustain = clusters.decay_sustain ?? { global: [], streams: {} }
  generate.value.clusters.release     = clusters.release     ?? { global: [], streams: {} }
  generate.value.clusters.tie         = clusters.tie         ?? { global: [], streams: {} }
}

const handleGenerated = (data: PolyphonicResponse) => {
  applyPolyphonicResponse(data)
  const ts = data.timeSeries
  const responseBpmSeries = (data as any)?.bpmSeries ?? (data as any)?.futureBpm ?? (data as any)?.bpm
  renderPolyphonicAudio(ts, responseBpmSeries, data.streamIds)
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

const expandTimeSeries = (ts: any[], rawStreamIds?: number[][]) => {
  stepCount.value = ts.length
  const streamIds = ts.map((step, stepIdx) => {
    const ids = Array.isArray(rawStreamIds?.[stepIdx]) ? rawStreamIds![stepIdx] : []
    return (Array.isArray(step) ? step : []).map((_: any, slot: number) => {
      const parsed = Number(ids[slot])
      return Number.isInteger(parsed) && parsed > 0 ? parsed : slot + 1
    })
  })
  const stableStreamIds = Array.from(new Set(streamIds.flat())).sort((a, b) => a - b)
  const laneById = new Map(stableStreamIds.map((id, lane) => [id, lane]))
  const make2D = () => Array.from({ length: stableStreamIds.length }, () => Array(stepCount.value).fill(null))

  const chords = make2D() as (number[] | null)[][]
  const notes = make2D()  // root互換: abs_notes[0] or pcs[0]
  const vels = make2D()
  const brightnesses = make2D()
  const noises = make2D()
  const harmonicities = make2D()
  const attacks = make2D()
  const decaySustains = make2D()
  const releases = make2D()
  const chordRanges = make2D()
  const densities = make2D()
  const ties = make2D()

  ts.forEach((stepStreams, stepIdx) => {
    if (!Array.isArray(stepStreams)) return
    stepStreams.forEach((vec, slotIdx) => {
      if (!vec) return
      const streamId = streamIds[stepIdx]?.[slotIdx]
      if (streamId == null) return
      const streamIdx = laneById.get(streamId)
      if (streamIdx == null) return

      // Strict: [abs_notes, vol, brightness, noise, harmonicity, attack, decay_sustain, release, chord_range, density, tie]
      if (Array.isArray(vec[0]) && vec.length === 11) {
        const absNotes = (vec[0] as any[]).map(n => Number(n)).filter(n => Number.isFinite(n))
        const lanes = {
          chords: chords[streamIdx], notes: notes[streamIdx], vels: vels[streamIdx],
          brightnesses: brightnesses[streamIdx], noises: noises[streamIdx],
          harmonicities: harmonicities[streamIdx], attacks: attacks[streamIdx],
          decaySustains: decaySustains[streamIdx], releases: releases[streamIdx],
          chordRanges: chordRanges[streamIdx], densities: densities[streamIdx], ties: ties[streamIdx],
        }
        if (Object.values(lanes).some(lane => lane == null)) return
        lanes.chords![stepIdx] = absNotes.length ? absNotes.map(n => Math.round(n)) : null
        lanes.notes![stepIdx] = absNotes[0] ?? null
        lanes.vels![stepIdx] = vec[1]
        lanes.brightnesses![stepIdx] = vec[2]
        lanes.noises![stepIdx] = vec[3]
        lanes.harmonicities![stepIdx] = vec[4]
        lanes.attacks![stepIdx] = vec[5]
        lanes.decaySustains![stepIdx] = vec[6]
        lanes.releases![stepIdx] = vec[7]
        lanes.chordRanges![stepIdx] = vec[8]
        lanes.densities![stepIdx] = vec[9]
        lanes.ties![stepIdx] = vec[10]
      }
    })
  })

  return {
    streamIds, stableStreamIds, chords, notes, vels, brightnesses, noises,
    harmonicities, attacks, decaySustains, releases, chordRanges, densities, ties
  }
}

const renderPolyphonicAudio = (timeSeries: any[][], bpmArg?: any, streamIds?: number[][]) => {
  progress.value.status = 'rendering'

  const normalizeRenderPayload = (ts: any[][], ids?: number[][]) => {
    const out: any[] = []
    const outStreamIds: number[][] = []

    const normAbs = (arr: any): number[] => {
      if (!Array.isArray(arr)) return []
      return arr.map(n => Number(n)).filter(n => Number.isFinite(n)).map(n => Math.round(n))
    }

    for (let stepIdx = 0; stepIdx < ts.length; stepIdx++) {
      const step = ts[stepIdx] ?? []
      const stepOut: any[] = []
      const stepIdsOut: number[] = []
      const sourceIds: number[] = Array.isArray(ids?.[stepIdx]) ? (ids?.[stepIdx] ?? []) : []

      for (let streamIdx = 0; streamIdx < step.length; streamIdx++) {
        const vec = step[streamIdx]
        if (!vec) continue

        if (Array.isArray(vec[0]) && vec.length === 11) {
          const absNotes = normAbs(vec[0])
          const vol = vec[1]
          stepOut.push([
            absNotes,
            vol,
            Number(vec[2]),
            Number(vec[3]),
            Number(vec[4]),
            Number(vec[5]),
            Number(vec[6]),
            Number(vec[7]),
            Number(vec[8]),
            Number(vec[9]),
            Number(vec[10])
          ])
          const parsedId = Number(sourceIds[streamIdx])
          stepIdsOut.push(Number.isInteger(parsedId) ? parsedId : streamIdx + 1)
        }
      }

      out.push(stepOut)
      outStreamIds.push(stepIdsOut)
    }

    return { out, streamIds: outStreamIds }
  }

  const { out, streamIds: normalizedStreamIds } = normalizeRenderPayload(timeSeries, streamIds)
  const bpmSeries = resolveGenerationBpmSeries(bpmArg, out.length)
  const bpm = bpmSeries[0] ?? DEFAULT_BPM
  axios.post('/api/web/supercolliders/render_polyphonic', {
    time_series: out,
    stream_ids: normalizedStreamIds,
    bpm,
    future_bpm: bpmSeries,
    initial_context_bpm: bpmSeries.slice(0, Math.min(1, bpmSeries.length)),
    tail_pad_seconds: 0.05,
  })
    .then(response => {
      if (response?.data?.error) {
        console.error("Rendering error:", response.data.error)
        progress.value.status = 'idle'
        return
      }

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

const generateParams = computed<Record<string, any>>(() => {
  const payload = latestParamsPayload.value
  if (!payload || typeof payload !== 'object') return {}
  return (payload as any).generate_polyphonic ?? payload
})

const initialStepCount = computed(() => {
  const resultInitial = (lastResultJson.value as any)?.initialContextBpm
  if (Array.isArray(resultInitial)) return resultInitial.length
  const context = generateParams.value.initial_context
  return Array.isArray(context) ? context.length : 0
})

const parameterFutureStepCount = computed(() => {
  const ignored = new Set(['initial_context', 'initial_context_bpm'])
  const configured = Object.entries(generateParams.value).reduce((max, [key, value]) => {
    if (ignored.has(key) || !Array.isArray(value)) return max
    return Math.max(max, value.length)
  }, 0)
  return Math.max(configured, stepCount.value - initialStepCount.value, 0)
})

const resolveParamValue = (keys: string[]) => {
  const gp = generateParams.value
  for (const key of keys) {
    if (gp[key] != null) return gp[key]
  }
  return null
}

const buildParamSeries = (keys: string[]): (number | null)[] => {
  const values = normalizeParamArray(resolveParamValue(keys))
  const futureLength = parameterFutureStepCount.value
  if (values.length === 0) return Array(initialStepCount.value + futureLength).fill(null)
  const last = values[values.length - 1]
  const future = Array.from({ length: futureLength }, (_, index) => values[index] ?? last)
  return Array(initialStepCount.value).fill(null).concat(future)
}

type ParameterSection = {
  key: string
  title: string
  streams: (number | null)[][]
  labels: string[]
  min: number
  max: number
  resolution: number
}

const makeParameterSection = (
  key: string,
  title: string,
  rows: Array<{ label: string; keys: string[] }>,
  min = 0,
  max = 1,
  resolution = 0.01
): ParameterSection => ({
  key,
  title,
  streams: rows.map(row => buildParamSeries(row.keys)),
  labels: rows.map(row => row.label),
  min,
  max,
  resolution,
})

const complexityRows = (prefix: string) => [
  { label: 'global', keys: [`${prefix}_global_complexity_target`, `${prefix}_global`] },
  { label: 'center', keys: [`${prefix}_stream_complexity_center`, `${prefix}_center`] },
  { label: 'span', keys: [`${prefix}_stream_complexity_span`, `${prefix}_spread`] },
  { label: 'concordance', keys: [`${prefix}_concordance`, `${prefix}_conc`] },
]

const valueRows = (prefix: string) => [
  { label: 'target', keys: [`${prefix}_value_target`, `${prefix}_target`] },
  { label: 'radius', keys: [`${prefix}_value_radius`, `${prefix}_target_spread`] },
]

const parameterSections = computed<ParameterSection[]>(() => {
  const sections: ParameterSection[] = [
    makeParameterSection('stream-count', 'STREAM COUNT Params', [
      { label: 'count', keys: ['stream_counts'] },
    ], 1, 16, 1),
    makeParameterSection('bpm', 'BPM Params', [
      { label: 'future BPM', keys: ['future_bpm', 'bpm_series', 'bpm'] },
    ], 1, 960, 1),
    makeParameterSection('tie', 'TIE Params', [
      ...complexityRows('tie'),
      { label: 'rate', keys: ['tie_rate_target'] },
    ], -1, 1, 0.01),
    makeParameterSection('generation-controls', 'GENERATION Params', [
      { label: 'recency center', keys: ['recency_center'] },
      { label: 'recency spread', keys: ['recency_spread'] },
      { label: 'strength target', keys: ['stream_strength_target'] },
      { label: 'strength spread', keys: ['stream_strength_spread'] },
      { label: 'register freedom', keys: ['note_register_freedom'] },
      { label: 'dissonance', keys: ['dissonance_target'] },
    ]),
    makeParameterSection('weights', 'SCORING WEIGHT Params', [
      { label: 'global distance', keys: ['global_dist_weight'] },
      { label: 'global quantity', keys: ['global_qty_weight'] },
      { label: 'global complexity', keys: ['global_comp_weight'] },
      { label: 'stream distance', keys: ['stream_dist_weight'] },
      { label: 'stream quantity', keys: ['stream_qty_weight'] },
      { label: 'stream complexity', keys: ['stream_comp_weight'] },
    ], 0, 5, 0.01),
    makeParameterSection('area-complexity', 'AREA Complexity Params', [
      { label: 'global', keys: ['area_global'] },
      { label: 'center', keys: ['area_center'] },
      { label: 'span', keys: ['area_spread'] },
      { label: 'concordance', keys: ['area_conc'] },
    ], -1, 1, 0.01),
  ]

  const dimensions = [
    { key: 'chord_range', title: 'CHORD_RANGE', max: 12, resolution: 1 },
    { key: 'density', title: 'DENSITY', max: 1, resolution: 0.1 },
    { key: 'vol', title: 'VOL', max: 1, resolution: 0.1 },
    { key: 'brightness', title: 'BRI', max: 1, resolution: 0.1 },
    { key: 'noise', title: 'NOI', max: 1, resolution: 0.1 },
    { key: 'harmonicity', title: 'HAR', max: 1, resolution: 0.1 },
    { key: 'attack', title: 'ATK', max: 1, resolution: 0.1 },
    { key: 'decay_sustain', title: 'DEC', max: 1, resolution: 0.1 },
    { key: 'release', title: 'S/R', max: 1, resolution: 0.1 },
  ]
  dimensions.forEach(dim => {
    sections.push(makeParameterSection(
      `${dim.key}-complexity`, `${dim.title} Complexity Params`,
      complexityRows(dim.key), -1, 1, 0.01
    ))
    sections.push(makeParameterSection(
      `${dim.key}-value`, `${dim.title} Value Params`,
      valueRows(dim.key), 0, dim.max, dim.resolution
    ))
  })
  return sections
})

const complexityMaxSteps = computed(() => initialStepCount.value + parameterFutureStepCount.value)

const globalScrollTrackWidth = computed(() => {
  const activeSteps = analysedViewMode.value === 'Cluster'
    ? Math.max(1, stepCount.value)
    : Math.max(1, stepCount.value, complexityMaxSteps.value)
  return Math.max(containerWidth.value, activeSteps * computedStepWidth.value)
})

// ===== pitch streams (chord) =====
const chordPitchStreams = computed(() => {
  return generate.value.chords
})

const pianoResultStreamLabels = computed(() =>
  generate.value.stableStreamIds.map(id => `S${id}`)
)

const volResultStreamLabels = computed(() => {
  return generate.value.stableStreamIds.map(id => `VOL-S${id}`)
})
const chordRangeResultStreamLabels = computed(() =>
  generate.value.stableStreamIds.map(id => `CR-S${id}`)
)
const densityResultStreamLabels = computed(() =>
  generate.value.stableStreamIds.map(id => `DEN-S${id}`)
)

const timbreDimensions = computed(() => [
  { label: 'BRI', values: generate.value.brightness },
  { label: 'NOI', values: generate.value.noise },
  { label: 'HAR', values: generate.value.harmonicity },
  { label: 'ATK', values: generate.value.attack },
  { label: 'DEC', values: generate.value.decay_sustain },
  { label: 'S/R', values: generate.value.release },
  { label: 'TIE', values: generate.value.tie },
])

const timbreResultStreams = computed(() =>
  timbreDimensions.value.flatMap(dimension => dimension.values)
)

const timbreResultStreamLabels = computed(() =>
  timbreDimensions.value.flatMap(dimension =>
    generate.value.stableStreamIds.map(id => `${dimension.label}-S${id}`)
  )
)

const volResultStreams = computed(() =>
  generate.value.velocities.map((stream: (number | null)[]) =>
    Array.isArray(stream)
      ? stream.map((value: number | null) => {
          if (value == null) return null
          const num = Number(value)
          return Number.isFinite(num) ? Math.max(0, Math.min(1, num)) : null
        })
      : []
  )
)

// Global cluster timelines returned by the latest response. All server dimensions
// are listed so Result/Analysed modes cannot silently omit NOTE or TIE.
const remapClusterTimeline = (clusters: ClusterData[], timelineSteps: number[]): ClusterData[] => {
  const grouped = new Map<string, ClusterData>()
  clusters.forEach(cluster => {
    cluster.indices.forEach(localStart => {
      const localEnd = localStart + cluster.window_size - 1
      const actualStart = timelineSteps[localStart]
      const actualEnd = timelineSteps[localEnd]
      if (actualStart == null || actualEnd == null) return
      const actualWindow = actualEnd - actualStart + 1
      const key = `${cluster.cluster_id}:${actualWindow}`
      const existing = grouped.get(key)
      if (existing) existing.indices.push(actualStart)
      else grouped.set(key, {
        cluster_id: cluster.cluster_id,
        window_size: actualWindow,
        indices: [actualStart],
      })
    })
  })
  return Array.from(grouped.values())
}

const sameTieControls = (previous: any, current: any) => {
  if (!Array.isArray(previous) || !Array.isArray(current)) return false
  const previousNotes = Array.isArray(previous[0]) ? previous[0].map(Number) : []
  const currentNotes = Array.isArray(current[0]) ? current[0].map(Number) : []
  if (currentNotes.length === 0 || previousNotes.length !== currentNotes.length) return false
  if (!previousNotes.every((note: number, index: number) => note === currentNotes[index])) return false
  if (Number(previous[1]) <= 0.01 || Number(current[1]) <= 0.01) return false
  return [1, 2, 3, 4, 5, 6].every(index =>
    Math.abs(Number(previous[index]) - Number(current[index])) <= 1e-9
  )
}

const tieTimelineSteps = computed(() => {
  const byStream: Record<string, number[]> = {}
  const global: number[] = []
  let previousById = new Map<number, any>()
  generate.value.rawTimeSeries.forEach((step: any[], stepIndex: number) => {
    const currentById = new Map<number, any>()
    let hasEligible = false
    const ids = generate.value.streamIds[stepIndex] ?? []
    ;(Array.isArray(step) ? step : []).forEach((vec, slot) => {
      const id = ids[slot]
      if (id == null) return
      const previous = previousById.get(id)
      if (sameTieControls(previous, vec)) {
        ;(byStream[String(id)] ??= []).push(stepIndex)
        hasEligible = true
      }
      currentById.set(id, vec)
    })
    if (hasEligible) global.push(stepIndex)
    previousById = currentById
  })
  return { global, byStream }
})

const clustersForScope = (
  source: { global: ClusterData[]; streams: Record<string, ClusterData[]> },
  dimension: string
) => {
  if (clusterScope.value === 'global') {
    return dimension === 'tie'
      ? remapClusterTimeline(source.global, tieTimelineSteps.value.global)
      : source.global
  }
  const localClusters = source.streams[clusterScope.value] ?? []
  const timeline = dimension === 'tie'
    ? (tieTimelineSteps.value.byStream[clusterScope.value] ?? [])
    : generate.value.streamIds.flatMap((ids, stepIndex) =>
        ids.includes(Number(clusterScope.value)) ? [stepIndex] : []
      )
  return remapClusterTimeline(localClusters, timeline)
}

const clusterSections = computed(() => [
  { key: 'note', title: 'NOTE', clusters: clustersForScope(generate.value.clusters.note, 'note') },
  { key: 'area', title: 'AREA', clusters: clustersForScope(generate.value.clusters.area, 'area') },
  { key: 'chord-range', title: 'CHORD_RANGE', clusters: clustersForScope(generate.value.clusters.chord_range, 'chord_range') },
  { key: 'density', title: 'DENSITY', clusters: clustersForScope(generate.value.clusters.density, 'density') },
  { key: 'vol', title: 'VOL', clusters: clustersForScope(generate.value.clusters.vol, 'vol') },
  { key: 'brightness', title: 'BRI', clusters: clustersForScope(generate.value.clusters.brightness, 'brightness') },
  { key: 'noise', title: 'NOI', clusters: clustersForScope(generate.value.clusters.noise, 'noise') },
  { key: 'harmonicity', title: 'HAR', clusters: clustersForScope(generate.value.clusters.harmonicity, 'harmonicity') },
  { key: 'attack', title: 'ATK', clusters: clustersForScope(generate.value.clusters.attack, 'attack') },
  { key: 'decay-sustain', title: 'DEC', clusters: clustersForScope(generate.value.clusters.decay_sustain, 'decay_sustain') },
  { key: 'release', title: 'S/R', clusters: clustersForScope(generate.value.clusters.release, 'release') },
  { key: 'tie', title: 'TIE', clusters: clustersForScope(generate.value.clusters.tie, 'tie') },
])

watch(() => generate.value.stableStreamIds, (ids) => {
  if (clusterScope.value !== 'global' && !ids.includes(Number(clusterScope.value))) {
    clusterScope.value = 'global'
  }
})

// ===== highlight =====
const pianoHighlightedIndices = ref<number[]>([])
const pianoHighlightedWindowSize = ref(0)
const onHoverClusterLeftAndPiano = (payload: { indices: number[]; windowSize: number } | null) => {
  if (!payload) {
    pianoHighlightedIndices.value = []
    pianoHighlightedWindowSize.value = 0
  } else {
    pianoHighlightedIndices.value = payload.indices
    pianoHighlightedWindowSize.value = payload.windowSize
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
  setResultViewMode,
})
</script>
