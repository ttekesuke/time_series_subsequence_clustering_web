<template>
  <div class="music-generate-root">
    <div class="viz-container" ref="containerRef">
      <div class="quadrant top-left">
        <StreamsRoll
          v-if="resultViewMode === 'pianoRoll'"
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
          title="Timbre Roll (BRI/NOI/HAR/ATK/DEC/SR)"
          @scroll="onScroll"
        />
        <StreamsRoll
          v-else
          ref="volRollRef"
          :streamValues="volResultStreams"
          :streamLabels="volResultStreamLabels"
          :stepWidth="computedStepWidth"
          :minValue="0"
          :maxValue="1"
          :valueResolution="1"
          :playheadStep="playheadStepForRoll"
          title="VOL Roll"
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
              ref="attackClustersRef"
              :clustersData="attackClustersForView"
              :stepWidth="computedStepWidth"
              :maxSteps="stepCount"
              title="ATK Clusters"
              :highlightedIndices="leftHighlightedIndices"
              :highlightedWindowSize="leftHighlightedWindowSize"
              @hover-cluster="onHoverClusterLeft"
              @scroll="onScroll"
            />
            <StreamsRoll
              v-else
              ref="attackClustersRef"
              :streamValues="complexityStreams.attack"
              :streamLabels="complexityParamStreamLabels"
              :stepWidth="computedStepWidth"
              :minValue="0"
              :maxValue="1"
              :valueResolution="0.01"
              :playheadStep="playheadStepForRoll"
              title="ATK Params"
              @scroll="onScroll"
            />
          </div>

          <div class="row-in-quadrant">
            <ClustersRoll
              v-if="analysedViewMode === 'Cluster'"
              ref="brightnessClustersRef"
              :clustersData="brightnessClustersForView"
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
              ref="brightnessClustersRef"
              :streamValues="complexityStreams.brightness"
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
              ref="noiseClustersRef"
              :clustersData="noiseClustersForView"
              :stepWidth="computedStepWidth"
              :maxSteps="stepCount"
              title="NOI Clusters"
              :highlightedIndices="rightHighlightedIndices"
              :highlightedWindowSize="rightHighlightedWindowSize"
              @hover-cluster="onHoverClusterRight"
              @scroll="onScroll"
            />
            <StreamsRoll
              v-else
              ref="noiseClustersRef"
              :streamValues="complexityStreams.noise"
              :streamLabels="complexityParamStreamLabels"
              :stepWidth="computedStepWidth"
              :minValue="0"
              :maxValue="1"
              :valueResolution="0.01"
              :playheadStep="playheadStepForRoll"
              title="NOI Params"
              @scroll="onScroll"
            />
          </div>

          <div class="row-in-quadrant">
            <ClustersRoll
              v-if="analysedViewMode === 'Cluster'"
              ref="harmonicityClustersRef"
              :clustersData="harmonicityClustersForView"
              :stepWidth="computedStepWidth"
              :maxSteps="stepCount"
              title="HAR Clusters"
              :highlightedIndices="rightHighlightedIndices"
              :highlightedWindowSize="rightHighlightedWindowSize"
              @hover-cluster="onHoverClusterRight"
              @scroll="onScroll"
            />
            <StreamsRoll
              v-else
              ref="harmonicityClustersRef"
              :streamValues="complexityStreams.harmonicity"
              :streamLabels="complexityParamStreamLabels"
              :stepWidth="computedStepWidth"
              :minValue="0"
              :maxValue="1"
              :valueResolution="0.01"
              :playheadStep="playheadStepForRoll"
              title="HAR Params"
              @scroll="onScroll"
            />
          </div>

          <div class="row-in-quadrant">
            <ClustersRoll
              v-if="analysedViewMode === 'Cluster'"
              ref="decaySustainClustersRef"
              :clustersData="decaySustainClustersForView"
              :stepWidth="computedStepWidth"
              :maxSteps="stepCount"
              title="DEC Clusters"
              :highlightedIndices="rightHighlightedIndices"
              :highlightedWindowSize="rightHighlightedWindowSize"
              @hover-cluster="onHoverClusterRight"
              @scroll="onScroll"
            />
            <StreamsRoll
              v-else
              ref="decaySustainClustersRef"
              :streamValues="complexityStreams.decaySustain"
              :streamLabels="complexityParamStreamLabels"
              :stepWidth="computedStepWidth"
              :minValue="0"
              :maxValue="1"
              :valueResolution="0.01"
              :playheadStep="playheadStepForRoll"
              title="DEC Params"
              @scroll="onScroll"
            />
          </div>

          <div class="row-in-quadrant">
            <ClustersRoll
              v-if="analysedViewMode === 'Cluster'"
              ref="releaseClustersRef"
              :clustersData="releaseClustersForView"
              :stepWidth="computedStepWidth"
              :maxSteps="stepCount"
              title="SR Clusters"
              :highlightedIndices="rightHighlightedIndices"
              :highlightedWindowSize="rightHighlightedWindowSize"
              @hover-cluster="onHoverClusterRight"
              @scroll="onScroll"
            />
            <StreamsRoll
              v-else
              ref="releaseClustersRef"
              :streamValues="complexityStreams.release"
              :streamLabels="complexityParamStreamLabels"
              :stepWidth="computedStepWidth"
              :minValue="0"
              :maxValue="1"
              :valueResolution="0.01"
              :playheadStep="playheadStepForRoll"
              title="SR Params"
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
const timbreRollRef = ref<any>(null)
const volRollRef = ref<any>(null)
const dissonanceRollRef = ref<any>(null)
const velClustersRef = ref<any>(null)
const chordRangeClustersRef = ref<any>(null)
const areaClustersRef = ref<any>(null)
const densityClustersRef = ref<any>(null)
const attackClustersRef = ref<any>(null)
const brightnessClustersRef = ref<any>(null)
const noiseClustersRef = ref<any>(null)
const harmonicityClustersRef = ref<any>(null)
const decaySustainClustersRef = ref<any>(null)
const releaseClustersRef = ref<any>(null)
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
const resultViewMode = ref<'pianoRoll' | 'timbreRoll' | 'volRoll'>('pianoRoll')

const containerWidth = ref(0)
let resizeObserver: ResizeObserver | null = null

const progress = ref({ percent: 0, status: 'idle' })
const setDataDialog = ref(false)
const complexityParamStreamLabels = ['global', 'conc', 'spread', 'center']
const singleValueStreamLabel = ['value']
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
const setResultViewMode = (mode: 'pianoRoll' | 'timbreRoll' | 'volRoll') => {
  resultViewMode.value = mode === 'timbreRoll' || mode === 'volRoll' ? mode : 'pianoRoll'
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
  dissonanceRollRef,
  velClustersRef,
  chordRangeClustersRef,
  areaClustersRef,
  densityClustersRef,
  attackClustersRef,
  brightnessClustersRef,
  noiseClustersRef,
  harmonicityClustersRef,
  decaySustainClustersRef,
  releaseClustersRef,
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
// strict server: [abs_notes(Int[]), vol, brightness, noise, harmonicity, attack, decay_sustain, release, chord_range(Int), density]
type StepVecStrict = [number[], number, number, number, number, number, number, number, number?, number?]
type StepVec = StepVecStrict
type PolyphonicResponse = {
  timeSeries: StepVec[][];
  clusters: Record<string, { global: ClusterData[]; streams: Record<string, ClusterData[]> }>;
  timbreSeries?: {
    brightness?: number[][]
    noise?: number[][]
    harmonicity?: number[][]
    attack?: number[][]
    decay_sustain?: number[][]
    release?: number[][]
  }
  processingTime: number;
}

// ===== state =====
const generate = ref({
  rawTimeSeries: [] as any[],
  notes: [] as (number | null)[][],
  velocities: [] as (number | null)[][],
  brightness: [] as (number | null)[][],
  noise: [] as (number | null)[][],
  harmonicity: [] as (number | null)[][],
  attack: [] as (number | null)[][],
  decay_sustain: [] as (number | null)[][],
  release: [] as (number | null)[][],

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
  },
})

const convertStepMajorTimbreToStreamMajor = (stepMajor: any): (number | null)[][] => {
  if (!Array.isArray(stepMajor)) return []
  const steps = stepMajor.length
  const maxStreams = Math.max(0, ...stepMajor.map((step: any) => (Array.isArray(step) ? step.length : 0)))
  const out = Array.from({ length: maxStreams }, () => Array(steps).fill(null) as (number | null)[])

  for (let stepIdx = 0; stepIdx < steps; stepIdx++) {
    const step = stepMajor[stepIdx]
    if (!Array.isArray(step)) continue
    for (let streamIdx = 0; streamIdx < step.length; streamIdx++) {
      const raw = step[streamIdx]
      if (raw == null) continue
      const v = Number(raw)
      if (!Number.isFinite(v)) continue
      out[streamIdx][stepIdx] = Math.max(0, Math.min(1, v))
    }
  }

  return out
}

// ===== handle response =====
const applyPolyphonicResponse = (data: PolyphonicResponse) => {
  lastResultJson.value = data
  const ts = (data as any).timeSeries as any[]
  const { notes, vels, brightnesses, noises, harmonicities, attacks, decaySustains, releases } = expandTimeSeries(ts)
  const timbreSeries = (data as any).timbreSeries ?? {}
  const resBrightness = convertStepMajorTimbreToStreamMajor(timbreSeries.brightness)
  const resNoise = convertStepMajorTimbreToStreamMajor(timbreSeries.noise)
  const resHarmonicity = convertStepMajorTimbreToStreamMajor(timbreSeries.harmonicity)
  const resAttack = convertStepMajorTimbreToStreamMajor(timbreSeries.attack)
  const resDecaySustain = convertStepMajorTimbreToStreamMajor(timbreSeries.decay_sustain)
  const resRelease = convertStepMajorTimbreToStreamMajor(timbreSeries.release)

  generate.value.rawTimeSeries = ts as any
  generate.value.notes        = notes      // root（abs_notes[0] or pcs[0]）互換用途
  generate.value.velocities   = vels
  generate.value.brightness   = resBrightness.length > 0 ? resBrightness : brightnesses
  generate.value.noise        = resNoise.length > 0 ? resNoise : noises
  generate.value.harmonicity  = resHarmonicity.length > 0 ? resHarmonicity : harmonicities
  generate.value.attack       = resAttack.length > 0 ? resAttack : attacks
  generate.value.decay_sustain = resDecaySustain.length > 0 ? resDecaySustain : decaySustains
  generate.value.release      = resRelease.length > 0 ? resRelease : releases

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
}

const handleGenerated = (data: PolyphonicResponse) => {
  applyPolyphonicResponse(data)
  const ts = data.timeSeries
  const responseBpmSeries = (data as any)?.bpmSeries ?? (data as any)?.futureBpm ?? (data as any)?.bpm
  renderPolyphonicAudio(ts, responseBpmSeries)
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
  const brightnesses = make2D()
  const noises = make2D()
  const harmonicities = make2D()
  const attacks = make2D()
  const decaySustains = make2D()
  const releases = make2D()

  ts.forEach((stepStreams, stepIdx) => {
    stepStreams.forEach((vec, streamIdx) => {
      if (!vec) return

      // Strict: [abs_notes, vol, brightness, noise, harmonicity, attack, decay_sustain, release, chord_range, density]
      if (Array.isArray(vec[0])) {
        const absNotes = (vec[0] as any[]).map(n => Number(n)).filter(n => Number.isFinite(n))
        notes[streamIdx][stepIdx] = absNotes.length ? absNotes[0] : null
        vels[streamIdx][stepIdx]  = vec[1]
        brightnesses[streamIdx][stepIdx] = vec[2]
        noises[streamIdx][stepIdx] = vec[3]
        harmonicities[streamIdx][stepIdx] = vec[4]
        attacks[streamIdx][stepIdx] = vec[5]
        decaySustains[streamIdx][stepIdx] = vec[6]
        releases[streamIdx][stepIdx] = vec[7]
      }
    })
  })

  return { notes, vels, brightnesses, noises, harmonicities, attacks, decaySustains, releases, maxStreams }
}

const renderPolyphonicAudio = (timeSeries: any[][], bpmArg?: any) => {
  progress.value.status = 'rendering'

  const normalizeRenderPayload = (ts: any[][]) => {
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

        if (Array.isArray(vec[0])) {
          const absNotes = normAbs(vec[0])
          const vol = vec[1]
          stepOut.push([
            absNotes,
            vol,
            Number(vec[2] ?? 0.5),
            Number(vec[3] ?? 0.2),
            Number(vec[4] ?? 0.8),
            Number(vec[5] ?? 0.5),
            Number(vec[6] ?? 0.5),
            Number(vec[7] ?? 0.3)
          ])

          const pcs = absNotes
            .map(n => ((n % 12) + 12) % 12)
            .sort((a, b) => a - b)
          stepChords.push(pcs)
        }
      }

      out.push(stepOut)
      chords.push(stepChords)
    }

    return { out, chords }
  }

  const { out, chords } = normalizeRenderPayload(timeSeries)
  const bpmSeries = resolveGenerationBpmSeries(bpmArg, out.length)
  const bpm = bpmSeries[0] ?? DEFAULT_BPM
  axios.post('/api/web/supercolliders/render_polyphonic', {
    time_series: out,
    bpm,
    bpm_series: bpmSeries,
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
  brightness: buildComplexityStreams('brightness'),
  noise: buildComplexityStreams('noise'),
  harmonicity: buildComplexityStreams('harmonicity'),
  attack: buildComplexityStreams('attack'),
  decaySustain: buildComplexityStreams('decay_sustain'),
  release: buildComplexityStreams('release'),
  density: buildComplexityStreams('density'),
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

      return null
    })
  )
})

const timbreResultStreamLabels = ['BRI', 'NOI', 'HAR', 'ATK', 'DEC', 'SR']

const volResultStreamLabels = computed(() => {
  const labels: string[] = []
  for (let idx = 0; idx < generate.value.velocities.length; idx++) {
    labels.push(`VOL-S${idx + 1}`)
  }
  return labels
})

const buildTimbreLane = (matrix: (number | null)[][]) => {
  const seriesLen = Math.max(stepCount.value, ...matrix.map(stream => (Array.isArray(stream) ? stream.length : 0)))
  return Array.from({ length: seriesLen }, (_, stepIdx) => {
    const values = matrix.flatMap((stream) => {
      const raw = stream?.[stepIdx]
      if (raw == null) return []
      const v = Number(raw)
      return Number.isFinite(v) ? [Math.max(0, Math.min(1, v))] : []
    })

    return values.length > 0 ? values : null
  })
}

const timbreResultStreams = computed(() => ([
  buildTimbreLane(generate.value.brightness),
  buildTimbreLane(generate.value.noise),
  buildTimbreLane(generate.value.harmonicity),
  buildTimbreLane(generate.value.attack),
  buildTimbreLane(generate.value.decay_sustain),
  buildTimbreLane(generate.value.release),
]))

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

const attackMode = ref<'global' | 'stream'>('global')
const attackStreamId = ref<number>(0)
const attackClustersForView = computed<ClusterData[]>(() => {
  const src = (generate.value.clusters as any).attack
  if (!src) return []
  if (attackMode.value === 'global') return src.global
  return src.streams[String(attackStreamId.value)] || []
})

const brightnessMode = ref<'global' | 'stream'>('global')
const brightnessStreamId = ref<number>(0)
const brightnessClustersForView = computed<ClusterData[]>(() => {
  const src = generate.value.clusters.brightness
  if (!src) return []
  if (brightnessMode.value === 'global') return src.global
  return src.streams[String(brightnessStreamId.value)] || []
})

const noiseMode = ref<'global' | 'stream'>('global')
const noiseStreamId = ref<number>(0)
const noiseClustersForView = computed<ClusterData[]>(() => {
  const src = generate.value.clusters.noise
  if (!src) return []
  if (noiseMode.value === 'global') return src.global
  return src.streams[String(noiseStreamId.value)] || []
})

const harmonicityMode = ref<'global' | 'stream'>('global')
const harmonicityStreamId = ref<number>(0)
const harmonicityClustersForView = computed<ClusterData[]>(() => {
  const src = generate.value.clusters.harmonicity
  if (!src) return []
  if (harmonicityMode.value === 'global') return src.global
  return src.streams[String(harmonicityStreamId.value)] || []
})

const decaySustainMode = ref<'global' | 'stream'>('global')
const decaySustainStreamId = ref<number>(0)
const decaySustainClustersForView = computed<ClusterData[]>(() => {
  const src = generate.value.clusters.decay_sustain
  if (!src) return []
  if (decaySustainMode.value === 'global') return src.global
  return src.streams[String(decaySustainStreamId.value)] || []
})

const releaseMode = ref<'global' | 'stream'>('global')
const releaseStreamId = ref<number>(0)
const releaseClustersForView = computed<ClusterData[]>(() => {
  const src = generate.value.clusters.release
  if (!src) return []
  if (releaseMode.value === 'global') return src.global
  return src.streams[String(releaseStreamId.value)] || []
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
  setResultViewMode,
})
</script>
