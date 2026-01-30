<template>
  <div class="music-generate-root">
    <div class="viz-container" ref="containerRef">
      <div class="quadrant top-left">
        <StreamsRoll
          ref="pianoRollRef"
          :streamValues="chordPitchStreams"
          :streamVelocities="generate.velocities"
          :minValue="minPitch"
          :maxValue="maxPitch"
          :valueResolution="1"
          :highlightIndices="leftHighlightedIndices"
          :highlightWindowSize="leftHighlightedWindowSize"
          :stepWidth="computedStepWidth"
          title="Piano Roll(octaves, notes, volumes)"
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
              title="Brightness"
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
              title="Hardness"
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
              title="Texture"
              @scroll="onScroll"
            />
          </div>
        </div>
      </div>

      <div class="quadrant bottom-left">
        <div class="in-quadrant" v-if="analysedViewMode === 'Cluster'">
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
        <div class="in-quadrant" v-else>
          <div class="row-in-quadrant">
            <StreamsRoll
              ref="velClustersRef"
              :streamValues="complexityStreams.vol"
              :minValue="-1"
              :maxValue="1"
              :valueResolution="0.01"
              :stepWidth="computedStepWidth"
              title="VOL (global/conc/spread/center)"
              @scroll="onScroll"
            />
          </div>
          <div class="row-in-quadrant">
            <StreamsRoll
              ref="octClustersRef"
              :streamValues="complexityStreams.oct"
              :minValue="-1"
              :maxValue="1"
              :valueResolution="0.01"
              :stepWidth="computedStepWidth"
              title="OCT (global/conc/spread/center)"
              @scroll="onScroll"
            />
          </div>
          <div class="row-in-quadrant">
            <StreamsRoll
              ref="noteClustersRef"
              :streamValues="complexityStreams.note"
              :minValue="-1"
              :maxValue="1"
              :valueResolution="0.01"
              :stepWidth="computedStepWidth"
              title="NOTE (global/conc/spread/center)"
              @scroll="onScroll"
            />
          </div>
        </div>
      </div>

      <div class="quadrant bottom-right">
        <div class="in-quadrant" v-if="analysedViewMode === 'Cluster'">
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
        <div class="in-quadrant" v-else>
          <div class="row-in-quadrant">
            <StreamsRoll
              ref="briClustersRef"
              :streamValues="complexityStreams.bri"
              :minValue="-1"
              :maxValue="1"
              :valueResolution="0.01"
              :stepWidth="computedStepWidth"
              title="BRI (global/conc/spread/center)"
              @scroll="onScroll"
            />
          </div>
          <div class="row-in-quadrant">
            <StreamsRoll
              ref="hrdClustersRef"
              :streamValues="complexityStreams.hrd"
              :minValue="-1"
              :maxValue="1"
              :valueResolution="0.01"
              :stepWidth="computedStepWidth"
              title="HRD (global/conc/spread/center)"
              @scroll="onScroll"
            />
          </div>
          <div class="row-in-quadrant">
            <StreamsRoll
              ref="texClustersRef"
              :streamValues="complexityStreams.tex"
              :minValue="-1"
              :maxValue="1"
              :valueResolution="0.01"
              :stepWidth="computedStepWidth"
              title="TEX (global/conc/spread/center)"
              @scroll="onScroll"
            />
          </div>
        </div>
      </div>
    </div>

    <MusicGenerateDialog
      ref="dialogRef"
      v-model="setDataDialog"
      :progress="progress"
      @generated-polyphonic="handleGenerated"
      @dispatched-polyphonic="handleDispatched"
      @params-built="handleParamsBuilt"
      @params-updated="handleParamsUpdated"
    />
  </div>
</template>

<style scoped>
.viz-container {
  display: grid;
  grid-template-columns: 1fr 1fr;
  grid-template-rows: 1fr 1fr;
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
.music-generate-root {
  display: flex;
  flex-direction: column;
  height: calc(100vh - 80px);
  width: 100%;
  min-height: 0;
}


</style>

<script setup lang="ts">
import { ref, nextTick, computed, onMounted, onUnmounted, watch } from 'vue'
import axios from 'axios'
import MusicGenerateDialog from '../dialog/MusicGenerateDialog.vue'
import StreamsRoll from '../visualizer/StreamsRoll.vue'
import ClustersRoll from '../visualizer/ClustersRoll.vue'
import { useScrollSync } from '../../composables/useScrollSync'

// ===== refs =====
const pianoRollRef = ref<any>(null)
const briRollRef = ref<any>(null)
const hrdRollRef = ref<any>(null)
const texRollRef = ref<any>(null)
const velClustersRef = ref<any>(null)
const octClustersRef = ref<any>(null)
const noteClustersRef = ref<any>(null)
const briClustersRef = ref<any>(null)
const hrdClustersRef = ref<any>(null)
const texClustersRef = ref<any>(null)
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

const openParams = () => { setDataDialog.value = true }
const setAnalysedViewMode = (mode: 'Cluster' | 'Complexity') => { analysedViewMode.value = mode }
const stopPlayingSound = () => {
  nowPlaying.value = false
  audio.value?.pause()
  if (audio.value) audio.value.currentTime = 0
}
const startPlayingSound = () => {
  if (!audio.value) return
  nowPlaying.value = true
  audio.value.play()
}

// Keep audio element in sync with the latest soundFilePath (generated or uploaded)
watch(soundFilePath, (url) => {
  // stop current
  nowPlaying.value = false
  try { audio.value?.pause() } catch {}
  audio.value = null

  if (!url) return
  const a = new Audio(url)
  a.addEventListener('ended', () => { nowPlaying.value = false })
  audio.value = a
})
import { defineExpose } from 'vue'

// ===== scroll sync =====
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
const onScroll = (e: Event) => syncScroll(e)

// ===== sizing =====
const stepCount = ref(0)
const maxSteps = computed(() => (stepCount.value > 0 ? stepCount.value : 100))

const computedStepWidth = computed(() => {
  const widthPerStep = containerWidth.value / 2 / maxSteps.value
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
  if (uploadedWavObjectUrl) URL.revokeObjectURL(uploadedWavObjectUrl)
  if (generatedAudioObjectUrl) URL.revokeObjectURL(generatedAudioObjectUrl)
})

// ===== types =====
type ClusterData = {
  window_size: number
  cluster_id: string
  indices: number[]
}
type StepVec = [number, number[] | number, number, number, number, number]
type PolyphonicResponse = {
  timeSeries: StepVec[][];   // [step][stream][6]
  chordSizes?: number[][];
  clusters: Record<string, { global: ClusterData[]; streams: Record<string, ClusterData[]> }>;
  processingTime: number;
}

// ===== state =====
const generate = ref({
  rawTimeSeries: [] as number[][][],
  octaves: [] as (number | null)[][],
  notes: [] as (number | null)[][],
  velocities: [] as (number | null)[][],
  brightness: [] as (number | null)[][],
  hardness: [] as (number | null)[][],
  texture: [] as (number | null)[][],

  chordSizes: [] as (number | null)[][],                 // [step][stream] を alignして入れる
  noteChordsPitchClasses: [] as (number[] | null)[][],    //  align済み: [step][stream] (pcs or null)

  clusters: {
    octave: { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    note:   { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    vol:    { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    bri:    { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    hrd:    { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
    tex:    { global: [] as ClusterData[], streams: {} as Record<string, ClusterData[]> },
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

// ===== helpers =====


/**
 * noteChordsPitchClasses / chordSizes は「生成step分だけ」返る想定が多いので
 * timeSeries の step数に合わせて「末尾寄せ」で align する
 */
const alignTailBySteps = <T>(fullSteps: number, partial: T[] | undefined | null): (T | null)[] => {
  const out: (T | null)[] = Array(fullSteps).fill(null)
  if (!partial || partial.length === 0) return out
  const offset = Math.max(0, fullSteps - partial.length)
  for (let i = 0; i < partial.length; i++) out[offset + i] = partial[i]
  return out
}

// ===== handle response =====
const applyPolyphonicResponse = (data: PolyphonicResponse) => {
  lastResultJson.value = data
  const ts = data.timeSeries
  const { octs, notes, vels, bris, hrds, texs } = expandTimeSeries(ts)

  generate.value.rawTimeSeries = ts
  generate.value.octaves      = octs
  generate.value.notes        = notes      // root（pcs[0]）だけ入れる互換用途
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

  generate.value.chordSizes = data.chordSizes ?? []
  generate.value.noteChordsPitchClasses = (data.noteChordsPitchClasses ?? []) as any
}

const handleGenerated = (data: PolyphonicResponse) => {
  applyPolyphonicResponse(data)
  const ts = data.timeSeries
  renderPolyphonicAudio(ts)
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

  const octs = make2D()
  const notes = make2D()
  const vels = make2D()
  const bris = make2D()
  const hrds = make2D()
  const texs = make2D()

  ts.forEach((stepStreams, stepIdx) => {
    stepStreams.forEach((vec, streamIdx) => {
      octs[streamIdx][stepIdx] = vec[0]
      const noteVal = vec[1]
      const pcs = Array.isArray(noteVal) ? noteVal : [noteVal]
      notes[streamIdx][stepIdx] = (pcs[0] ?? 0) // root互換
      vels[streamIdx][stepIdx] = vec[2]
      bris[streamIdx][stepIdx] = vec[3]
      hrds[streamIdx][stepIdx] = vec[4]
      texs[streamIdx][stepIdx] = vec[5]
    })
  })

  return { octs, notes, vels, bris, hrds, texs, maxStreams }
}

const renderPolyphonicAudio = (timeSeries: number[][][]) => {
  progress.value.status = 'rendering'
  const stepDuration = 1 / 4.0

  axios.post('/api/web/supercolliders/render_polyphonic', {
    time_series: timeSeries,
    step_duration: stepDuration,
    note_chords_pitch_classes: generate.value.noteChordsPitchClasses,
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
  if (uploadedParamsJsonFile.value) {
    triggerDownload(uploadedParamsJsonFile.value, 'params.json')
    return
  }
  if (latestParamsPayload.value) {
    const blob = new Blob([JSON.stringify(latestParamsPayload.value, null, 2)], { type: 'application/json' })
    triggerDownload(blob, 'params.json')
  }
}

// ===== cluster view switch =====
const velocityMode = ref<'global' | 'stream'>('global')
const velocityStreamId = ref<number>(0)
const velocityClustersForView = computed<ClusterData[]>(() => {
  const src = generate.value.clusters.vol
  if (!src) return []
  if (velocityMode.value === 'global') return src.global
  return src.streams[String(velocityStreamId.value)] || []
})

const octaveMode = ref<'global' | 'stream'>('global')
const octaveStreamId = ref<number>(0)
const octaveClustersForView = computed<ClusterData[]>(() => {
  const src = generate.value.clusters.octave
  if (!src) return []
  if (octaveMode.value === 'global') return src.global
  return src.streams[String(octaveStreamId.value)] || []
})

const noteMode = ref<'global' | 'stream'>('global')
const noteStreamId = ref<number>(0)
const noteClustersForView = computed<ClusterData[]>(() => {
  const src = generate.value.clusters.note
  if (!src) return []
  if (noteMode.value === 'global') return src.global
  return src.streams[String(noteStreamId.value)] || []
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

// ===== pitch streams (chord) =====
// StreamsRoll に渡す値: [stream][step] だが、step要素は number | number[] | null を許す
const chordPitchStreams = computed(() => {
  const ts = generate.value.rawTimeSeries as any[]
  if (!ts.length) return []

  const streamCount = Math.max(0, ...ts.map(step => step.length))
  const stepLen = ts.length

  return Array.from({ length: streamCount }, (_, sIdx) =>
    Array.from({ length: stepLen }, (_, stepIdx) => {
      const vec = ts[stepIdx]?.[sIdx]
      if (!vec) return null

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
  const gp = payload.generate_polyphonic ?? payload
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
  oct: buildComplexityStreams('octave'),
  note: buildComplexityStreams('note'),
  bri: buildComplexityStreams('bri'),
  hrd: buildComplexityStreams('hrd'),
  tex: buildComplexityStreams('tex'),
}))
// ====== PianoRoll 用の固定レンジ ======
// octave が 0..7 なら 8オクターブ = 96段
const OCTAVE_MIN = 0
const OCTAVE_MAX = 7
const OCTAVE_COUNT = (OCTAVE_MAX - OCTAVE_MIN + 1)

const minPitch = computed(() => OCTAVE_MIN * 12)
const maxPitch = computed(() => (OCTAVE_MIN + OCTAVE_COUNT) * 12 - 1) // 95

defineExpose({
  openParams,
  stopPlayingSound,
  startPlayingSound,
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
