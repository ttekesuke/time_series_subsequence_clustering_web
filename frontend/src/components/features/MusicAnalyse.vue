<template>
  <div class="music-analyse-root" ref="containerRef">
    <div v-if="errorMessage" class="error-banner">{{ errorMessage }}</div>

    <div v-if="result" class="viz-container" :style="topRollHeight == null ? undefined : { gridTemplateRows: `${topRollHeight}px minmax(0, 1fr)` }">
      <div class="top-roll">
        <div class="piano-stream-toolbar" aria-label="MusicXML Piano Roll streams">
          <span class="piano-stream-toolbar-label">Streams</span>
          <button
            type="button"
            class="piano-stream-all-button"
            :disabled="hiddenPianoStreamIndices.length === 0"
            @click="showAllPianoStreams"
          >
            ALL
          </button>
          <label
            v-for="stream in pianoStreamMetas"
            :key="stream.id"
            class="piano-stream-item"
            :title="stream.label"
          >
            <input
              type="checkbox"
              :checked="!hiddenPianoStreamIndices.includes(stream.index)"
              @change="togglePianoStream(stream.index)"
            >
            <i class="piano-stream-swatch" :style="{ backgroundColor: stream.color }"></i>
            <span>{{ stream.label }}</span>
          </label>
        </div>
        <div class="piano-roll-body">
          <StreamsRoll
            ref="pianoRollRef"
            :streamValues="pianoStreams"
            :streamVelocities="pianoVelocities"
            :streamLabels="pianoLabels"
            :hiddenStreamIndices="hiddenPianoStreamIndices"
            :stepWidth="computedStepWidth"
            :minValue="0"
            :maxValue="127"
            :valueResolution="1"
            :highlightIndices="highlightIndices"
            :highlightWindowSize="highlightWindowSize"
            resizable
            title="MusicXML Piano Roll"
            @resize-height="resizeTopRoll"
            @scroll="onScroll"
          />
        </div>
      </div>

      <div class="analysis-area">
        <div class="analysis-toolbar">
          <label for="music-analysis-scope">Scope</label>
          <select id="music-analysis-scope" v-model="analysisScope">
            <option value="global">Global</option>
            <option v-for="stream in result.streams" :key="stream.id" :value="String(stream.id)">
              {{ stream.label }}
            </option>
            <option v-if="analysedViewMode === 'Complexity' && hasConcordance" value="concordance">
              Concordance
            </option>
          </select>
          <span class="timing-info">
            exact grid: {{ result.timing.quarterUnit }} quarter / {{ result.timing.stepCount }} steps
          </span>
          <span v-if="result.metadata?.pitchClusterMode" class="timing-info">
            pitch cluster: {{ result.metadata.pitchClusterMode === 'interval' ? 'interval / transposition-invariant' : 'absolute' }}
          </span>
          <div v-if="analysedViewMode === 'Complexity'" class="metric-legend">
            <span v-for="(label, index) in visibleMetricLabels" :key="label">
              <i :style="{ backgroundColor: metricColor(index) }"></i>{{ label }}
            </span>
          </div>
        </div>

        <div class="analysis-scroll">
          <div
            v-for="(section, index) in sections"
            :key="section.key"
            class="analysis-row"
            :style="{ height: `${analysisRowHeights[section.key] ?? (analysedViewMode === 'Complexity' ? 184 : 92)}px` }"
          >
            <ClustersRoll
              v-if="analysedViewMode === 'Cluster'"
              :ref="el => setAnalysisRollRef(el, index)"
              :compressedData="compressedForSection(section)"
              :stepWidth="computedStepWidth"
              :maxSteps="stepCount"
              :title="section.title + ' Clusters'"
              resizable
              @resize-height="height => analysisRowHeights[section.key] = height"
              @hover-cluster="onHoverCluster"
              @scroll="onScroll"
            />
            <StreamsRoll
              v-else
              :ref="el => setAnalysisRollRef(el, index)"
              :streamValues="complexityStreams(section)"
              :streamLabels="complexityLabels(section)"
              :stepWidth="computedStepWidth"
              :minValue="0"
              :maxValue="maxValueForSection(section)"
              :valueResolution="analysisScope !== 'concordance' && (section.key === 'stream_count' || section.key === 'chord_range' || section.key === 'area') ? 1 : 0.01"
              :title="section.title + (analysisScope === 'concordance' ? ' Concordance' : isDirectValueDimension(section.key) ? ' Value' : ' Complexity')"
              resizable
              @resize-height="height => analysisRowHeights[section.key] = height"
              @scroll="onScroll"
            />
          </div>
        </div>
      </div>
    </div>

    <div v-else class="empty-state">
      SET MusicXMLからMusicXMLを選択して解析してください。
    </div>

    <div class="bottom-scrollbar" ref="bottomScrollRef" @scroll="onScroll">
      <div class="bottom-scrollbar-track" :style="{ width: globalScrollTrackWidth + 'px' }"></div>
    </div>

    <v-dialog v-model="dialogOpen" max-width="760" scrollable>
      <v-card>
        <v-card-title class="d-flex align-center justify-space-between">
          <span>SET MusicXML</span>
          <v-btn icon :disabled="submitting" @click="dialogOpen = false"><v-icon>mdi-close</v-icon></v-btn>
        </v-card-title>
        <v-card-text>
          <v-radio-group v-model="sourceType" inline>
            <v-radio label="Upload MusicXML" value="upload" />
            <v-radio label="ASAP dataset" value="asap" />
          </v-radio-group>

          <div v-if="sourceType === 'upload'" class="upload-panel">
            <input
              type="file"
              accept=".xml,.musicxml,text/xml,application/xml"
              @change="onFileChange"
            >
            <div v-if="selectedFile" class="text-caption mt-2">
              {{ selectedFile.name }} ({{ Math.round(selectedFile.size / 1024) }} KB)
            </div>
          </div>

          <div v-else>
            <v-autocomplete
              v-model="selectedAsap"
              :items="asapSources"
              :loading="loadingAsap"
              item-title="label"
              return-object
              label="ASAP MusicXML"
              clearable
            />
          </div>

          <v-text-field
            v-model.number="mergeThresholdRatio"
            type="number"
            min="0"
            max="1"
            step="0.001"
            label="Merge threshold ratio"
          />

          <v-radio-group
            v-model="pitchClusterMode"
            label="Pitch clustering"
            inline
            hide-details
            class="mt-1"
          >
            <v-radio label="Absolute pitch" value="absolute" />
            <v-radio label="Interval contour (transposition-invariant)" value="interval" />
          </v-radio-group>
          <div class="text-caption text-medium-emphasis mb-2">
            Interval mode clusters adjacent pitch differences, so the same phrase transposed by a fifth,
            octave, or another constant interval can match.
          </div>

          <v-alert v-if="analysisProgressMessage" type="info" variant="tonal" class="mt-3">
            <div>{{ analysisProgressMessage }}</div>
            <v-progress-linear
              v-if="submitting"
              class="mt-2"
              :model-value="analysisProgressPercent"
              :indeterminate="analysisProgressPercent <= 0"
            />
          </v-alert>

          <v-alert v-if="dialogError" type="error" variant="tonal" class="mt-3">
            {{ dialogError }}
          </v-alert>
        </v-card-text>
        <v-card-actions class="justify-end">
          <v-btn
            variant="text"
            :disabled="submitting && cancellationRequested"
            @click="submitting ? cancelAnalysisJob() : (dialogOpen = false)"
          >
            {{ submitting ? (cancellationRequested ? 'STOPPING…' : 'STOP') : 'CANCEL' }}
          </v-btn>
          <v-btn color="primary" :loading="submitting" :disabled="submitting" @click="submitMusicXml">SUBMIT</v-btn>
        </v-card-actions>
      </v-card>
    </v-dialog>
  </div>
</template>

<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue'
import axios from 'axios'
import StreamsRoll from '../visualizer/StreamsRoll.vue'
import ClustersRoll from '../visualizer/ClustersRoll.vue'
import { useScrollSync } from '../../composables/useScrollSync'
import { buildVisualizerBenchmarkFixture } from '../../composables/visualizerBenchmarkFixture'

type CompressedSpan = {
  window_min: number; window_max: number; cluster_ids: number[]
  indices: number[]; fit_limits: number[]; parent_index: number | null
}
type AxisBundle = {
  prediction?: Array<number | null>
  diversity?: Array<number | null>
  shape?: Array<number | null>
  mass?: Array<number | null>
}
type DimensionResult = {
  values: {
    global: Array<number | null>
    streams: Record<string, Array<number | null>>
    concordance: Array<number | null>
  }
  analysis?: {
    global: { axes: AxisBundle; raw: any }
    streams: Record<string, { axes: AxisBundle; raw: any }>
  }
  compressedClusters?: {
    global: CompressedSpan[]
    streams: Record<string, CompressedSpan[]>
  }
}
type MusicAnalysisResult = {
  metadata: any
  timing: { exact: boolean; gridDenominator: number; quarterUnit: string; stepCount: number }
  streams: Array<{ id: number; label: string; partId: string; staff: string; voice: string; lane: string; sourceVoices: string[] }>
  pianoRoll: {
    streams: Array<Array<number[] | null>>
    velocities: Array<Array<number | null>>
    streamIds: number[]
    streamLabels: string[]
  }
  dimensionOrder: string[]
  dimensions: Record<string, DimensionResult>
}

const result = ref<MusicAnalysisResult | null>(null)
const lastResultJson = ref<any | null>(null)
const errorMessage = ref('')
const dialogError = ref('')
const dialogOpen = ref(false)
const sourceType = ref<'upload' | 'asap'>('upload')
const selectedFile = ref<File | null>(null)
const selectedAsap = ref<any | null>(null)
const asapSourcesRaw = ref<any[]>([])
const loadingAsap = ref(false)
const submitting = ref(false)
const analysisJobId = ref('')
const analysisProgressMessage = ref('')
const analysisProgressPercent = ref(0)
const cancellationRequested = ref(false)
let analysisPollToken = 0
const mergeThresholdRatio = ref(0.02)
const pitchClusterMode = ref<'absolute' | 'interval'>('absolute')
const analysedViewMode = ref<'Cluster' | 'Complexity'>('Complexity')
const analysisScope = ref('global')
const topRollHeight = ref<number | null>(null)
const analysisRowHeights = ref<Record<string, number>>({})
const hiddenPianoStreamIndices = ref<number[]>([])

const visualizerBenchmarkEnabled = () =>
  new URLSearchParams(window.location.search).get('visualizerBenchmark') === '1'

const containerRef = ref<HTMLElement | null>(null)
const pianoRollRef = ref<any>(null)
// Template function refs run during rendering; this list is only read by scroll event handlers.
const analysisRollRefs: { value: any[] } = { value: [] }
const bottomScrollRef = ref<HTMLElement | null>(null)
const containerWidth = ref(0)
let resizeObserver: ResizeObserver | null = null

const resizeTopRoll = (height: number) => {
  const availableHeight = (containerRef.value?.clientHeight ?? height) - 160
  topRollHeight.value = Math.min(height, Math.max(92, availableHeight))
}

const setAnalysisRollRef = (el: any, index: number) => {
  analysisRollRefs.value[index] = el ?? null
}

const { syncScroll } = useScrollSync([pianoRollRef, analysisRollRefs, bottomScrollRef])
const onScroll = (e: Event) => syncScroll(e)

const stepCount = computed(() => result.value?.timing?.stepCount ?? 0)
const plotAreaWidth = computed(() => Math.max(1, containerWidth.value - 80))
const computedStepWidth = computed(() => {
  const count = Math.max(stepCount.value, 1)
  return Math.max(1, Math.min(8, plotAreaWidth.value / count, 30000 / count))
})
const globalScrollTrackWidth = computed(() =>
  Math.max(containerWidth.value, Math.max(stepCount.value, 1) * computedStepWidth.value)
)

const pianoStreams = computed(() => result.value?.pianoRoll?.streams ?? [])
const pianoVelocities = computed(() => result.value?.pianoRoll?.velocities ?? [])
const pianoStreamColor = (index: number) => `hsl(${(index * 137.5) % 360}, 70%, 45%)`
const pianoStreamMetas = computed(() => {
  const data = result.value
  if (!data) return []
  const streamById = new Map(data.streams.map(stream => [String(stream.id), stream]))
  return data.pianoRoll.streamIds.map((id, index) => {
    const stream = streamById.get(String(id))
    const voices = Array.isArray(stream?.sourceVoices) && stream.sourceVoices.length > 0
      ? stream.sourceVoices
      : stream?.voice ? [stream.voice] : []
    const fallbackLabel = [
      stream?.partId || `stream ${id}`,
      stream?.staff ? `staff ${stream.staff}` : '',
      stream?.lane ? `lane ${stream.lane}` : '',
    ].filter(Boolean).join(' / ') + (voices.length > 0 ? ` (voices ${voices.join(', ')})` : '')
    return {
      id,
      index,
      label: stream?.label?.trim() || data.pianoRoll.streamLabels[index] || fallbackLabel,
      color: pianoStreamColor(index),
    }
  })
})
const pianoLabels = computed(() => pianoStreamMetas.value.map(stream => stream.label))
const togglePianoStream = (index: number) => {
  if (hiddenPianoStreamIndices.value.includes(index)) {
    hiddenPianoStreamIndices.value = hiddenPianoStreamIndices.value.filter(value => value !== index)
  } else {
    hiddenPianoStreamIndices.value = [...hiddenPianoStreamIndices.value, index].sort((a, b) => a - b)
  }
}
const showAllPianoStreams = () => {
  hiddenPianoStreamIndices.value = []
}

watch(
  () => result.value?.pianoRoll?.streamIds?.map(id => String(id)).join('|') ?? '',
  () => {
    hiddenPianoStreamIndices.value = []
  },
)

const titleMap: Record<string, string> = {
  note: 'NOTE / PITCH',
  area: 'AREA / REGISTER',
  chord_range: 'CHORD RANGE',
  density: 'CHORD DENSITY',
  vol: 'VOLUME',
  tie: 'TIE',
  dissonance: 'DISSONANCE',
  stream_count: 'STREAM COUNT',
}
const isDirectValueDimension = (key: string) =>
  ['area', 'vol', 'chord_range', 'density', 'tie', 'dissonance', 'stream_count'].includes(key)

const sections = computed(() => {
  const data = result.value
  if (!data) return []
  return data.dimensionOrder
    .filter(key => !!data.dimensions[key])
    .filter(key => analysedViewMode.value !== 'Cluster' || !isDirectValueDimension(key))
    .filter(key => key !== 'stream_count' || analysisScope.value === 'global')
    .filter(key => analysisScope.value !== 'concordance' ||
      data.dimensions[key]!.values.concordance.some(value => value != null))
    .map(key => ({ key, title: titleMap[key] ?? key, dimension: data.dimensions[key]! }))
})

const metricKeys = ['prediction', 'diversity', 'shape', 'mass'] as const
const metricLabels = ['Prediction', 'Diversity', 'Shape', 'Mass']
const hasConcordance = computed(() => sections.value.some(section =>
  section.dimension.values.concordance.some(value => value != null)
))
const visibleMetricLabels = computed(() => analysisScope.value === 'concordance' ? ['Concordance'] : metricLabels)
const metricColor = (index: number) => 'hsl(' + ((index * 137.5) % 360) + ', 70%, 45%)'

const axisBundleFor = (section: any): AxisBundle => {
  const dim = section.dimension as DimensionResult
  if (analysisScope.value === 'global') return dim.analysis?.global?.axes ?? {}
  return dim.analysis?.streams?.[analysisScope.value]?.axes ?? dim.analysis?.global?.axes ?? {}
}

const complexityStreams = (section: any) => {
  if (analysisScope.value === 'concordance') return [section.dimension.values.concordance]
  if (isDirectValueDimension(section.key)) {
    const values = section.dimension.values as DimensionResult['values']
    return [analysisScope.value === 'global' ? values.global : values.streams[analysisScope.value] ?? []]
  }
  const axes = axisBundleFor(section)
  return metricKeys.map(key =>
    Array.isArray(axes[key]) ? (axes[key] as Array<number | null>) : Array(stepCount.value).fill(null)
  )
}

const complexityLabels = (section: { key: string }) =>
  analysisScope.value !== 'concordance' && isDirectValueDimension(section.key)
    ? [titleMap[section.key] ?? section.key]
    : visibleMetricLabels.value

const maxValueForSection = (section: { key: string; dimension: DimensionResult }) => {
  if (section.key === 'stream_count') return Math.max(result.value?.streams.length ?? 0, 1)
  if (section.key === 'area' && analysisScope.value !== 'concordance') return 127
  if (section.key !== 'chord_range' || analysisScope.value === 'concordance') return 1
  const values = analysisScope.value === 'global'
    ? section.dimension.values.global
    : section.dimension.values.streams[analysisScope.value] ?? []
  return values.reduce<number>((max, value) => typeof value === 'number' && Number.isFinite(value)
    ? Math.max(max, value) : max, 1)
}

const compressedForSection = (section: any): CompressedSpan[] => {
  const dim = section.dimension as DimensionResult
  if (analysisScope.value === 'global') return dim.compressedClusters?.global ?? []
  return dim.compressedClusters?.streams?.[analysisScope.value] ?? []
}

const highlightIndices = ref<number[]>([])
const highlightWindowSize = ref(0)
const onHoverCluster = (payload: { indices: number[]; windowSize: number } | null) => {
  if (!payload) {
    highlightIndices.value = []
    highlightWindowSize.value = 0
    return
  }
  highlightIndices.value = payload.indices
  highlightWindowSize.value = payload.windowSize
}

const asapSources = computed(() =>
  asapSourcesRaw.value.map(item => ({
    ...item,
    label: [item.composer, item.title, item.folder, item.xml_score].filter(Boolean).join(' / ')
  }))
)

const loadAsapSources = async () => {
  if (asapSourcesRaw.value.length > 0 || loadingAsap.value) return
  loadingAsap.value = true
  try {
    const { data } = await axios.post('/api/web/time_series/asap_musicxml_sources', {})
    asapSourcesRaw.value = Array.isArray(data?.sources) ? data.sources : []
  } catch (error: any) {
    const status = error?.response?.status
    const data = error?.response?.data
    const backendMessage = typeof data?.message === 'string' ? data.message : ''
    const backendCode = typeof data?.code === 'string' ? data.code : ''
    if (backendMessage) {
      dialogError.value = backendCode
        ? backendMessage + ' (' + backendCode + ')'
        : backendMessage
    } else if (status === 404) {
      dialogError.value = 'ASAP API endpoint was not found (HTTP 404). Restart or redeploy the backend so the new route is loaded.'
    } else if (status) {
      dialogError.value = 'ASAP dataset list could not be loaded (HTTP ' + status + ').'
    } else {
      dialogError.value = 'ASAP dataset list could not be loaded. The backend may not be reachable.'
    }
  } finally {
    loadingAsap.value = false
  }
}

const openMusicXmlDialog = () => {
  dialogError.value = ''
  dialogOpen.value = true
  if (sourceType.value === 'asap') void loadAsapSources()
}

const onFileChange = (event: Event) => {
  const input = event.target as HTMLInputElement
  selectedFile.value = input.files?.[0] ?? null
  dialogError.value = ''
}

const sleep = (milliseconds: number) =>
  new Promise(resolve => window.setTimeout(resolve, milliseconds))

const updateAnalysisJobProgress = (status: any) => {
  const phase = String(status?.phase ?? status?.status ?? '')
  const label = String(status?.label ?? '')
  const processed = Number(status?.processed ?? 0)
  const total = Number(status?.total ?? 0)
  const percent = Number(status?.percent ?? 0)
  analysisProgressPercent.value = Number.isFinite(percent) ? Math.max(0, Math.min(100, percent)) : 0
  const count = total > 0 ? ` ${processed}/${total}` : ''
  const labelText = label ? ` — ${label}` : ''
  analysisProgressMessage.value = `${phase || 'running'}${labelText}${count}`
}

const cancelAnalysisJob = async () => {
  if (!analysisJobId.value || cancellationRequested.value) return
  cancellationRequested.value = true
  analysisProgressMessage.value = 'cancelling…'
  try {
    const { data } = await axios.post('/api/web/time_series/analyse_music_job_cancel', {
      job_id: analysisJobId.value,
    })
    updateAnalysisJobProgress(data)
  } catch (error: any) {
    cancellationRequested.value = false
    dialogError.value = error?.response?.data?.message ?? error?.message ?? 'Cancellation failed.'
  }
}

const submitMusicXml = async () => {
  if (submitting.value) return
  dialogError.value = ''
  errorMessage.value = ''
  analysisProgressMessage.value = ''
  analysisProgressPercent.value = 0
  cancellationRequested.value = false
  submitting.value = true
  const pollToken = ++analysisPollToken
  try {
    const payload: any = {
      source_type: sourceType.value,
      merge_threshold_ratio: Number(mergeThresholdRatio.value),
      pitch_cluster_mode: pitchClusterMode.value,
    }

    if (sourceType.value === 'upload') {
      const file = selectedFile.value
      if (!file) throw new Error('MusicXML file is required.')
      const lower = file.name.toLowerCase()
      if (!(lower.endsWith('.xml') || lower.endsWith('.musicxml'))) {
        throw new Error('Only .xml and .musicxml are supported. .mxl is not supported.')
      }
      payload.filename = file.name
      payload.musicxml_text = await file.text()
    } else {
      const selected = selectedAsap.value
      if (!selected) throw new Error('Select a score from the ASAP dataset.')
      payload.composer = selected.composer
      payload.title = selected.title
      payload.folder = selected.folder
      payload.xml_score = selected.xml_score
    }

    const startResponse = await axios.post('/api/web/time_series/analyse_music_job_start', {
      analyse_music: { ...payload, compact_cluster_view: true },
    })
    const jobId = String(startResponse.data?.jobId ?? '')
    if (!jobId) throw new Error('MusicAnalyse job ID was not returned.')
    analysisJobId.value = jobId
    updateAnalysisJobProgress(startResponse.data)

    while (pollToken === analysisPollToken) {
      const { data: status } = await axios.post('/api/web/time_series/analyse_music_job_status', {
        job_id: jobId,
      })
      updateAnalysisJobProgress(status)
      const state = String(status?.status ?? '')

      if (state === 'completed') {
        const { data } = await axios.post('/api/web/time_series/analyse_music_job_result', {
          job_id: jobId,
        })
        result.value = data as MusicAnalysisResult
        lastResultJson.value = data
        analysisScope.value = 'global'
        analysisRowHeights.value = {}
        highlightIndices.value = []
        highlightWindowSize.value = 0
        errorMessage.value = ''
        dialogOpen.value = false
        await nextTick()
        return
      }

      if (state === 'failed' || state === 'cancelled' || state === 'interrupted') {
        const backendMessage = String(status?.errorMessage ?? '')
        throw new Error(backendMessage || `MusicXML analysis ${state}.`)
      }

      await sleep(600)
    }
  } catch (error: any) {
    const message = error?.response?.data?.message ?? error?.message ?? 'MusicXML analysis failed.'
    dialogError.value = message
    errorMessage.value = message
  } finally {
    if (pollToken === analysisPollToken) {
      submitting.value = false
      analysisJobId.value = ''
      cancellationRequested.value = false
    }
  }
}

const downloadAnalysisJson = () => {
  if (!lastResultJson.value) return
  const blob = new Blob([JSON.stringify(lastResultJson.value, null, 2)], { type: 'application/json' })
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = 'music-analysis.json'
  document.body.appendChild(anchor)
  anchor.click()
  document.body.removeChild(anchor)
  URL.revokeObjectURL(url)
}

const setAnalysedViewMode = (mode: string) => {
  analysedViewMode.value = mode === 'Cluster' ? 'Cluster' : 'Complexity'
  if (analysedViewMode.value === 'Cluster' && analysisScope.value === 'concordance') analysisScope.value = 'global'
  analysisRollRefs.value = []
}

const loadVisualizerBenchmarkFixture = async (
  steps = 2352,
  streams = 6,
  mode: 'Cluster' | 'Complexity' = 'Complexity',
) => {
  const fixture = buildVisualizerBenchmarkFixture(steps, streams)
  result.value = fixture as MusicAnalysisResult
  lastResultJson.value = fixture
  analysisScope.value = 'global'
  analysisRowHeights.value = {}
  highlightIndices.value = []
  highlightWindowSize.value = 0
  errorMessage.value = ''
  setAnalysedViewMode(mode)
  await nextTick()
  return {
    steps: result.value.timing.stepCount,
    streams: result.value.streams.length,
    mode: analysedViewMode.value,
  }
}

watch(sourceType, value => {
  if (value === 'asap') void loadAsapSources()
})

watch(() => result.value?.streams, streams => {
  if (analysisScope.value === 'global') return
  const ids = (streams ?? []).map(stream => String(stream.id))
  if (!ids.includes(analysisScope.value)) analysisScope.value = 'global'
})

onMounted(() => {
  if (containerRef.value) {
    containerWidth.value = containerRef.value.clientWidth
    resizeObserver = new ResizeObserver(entries => {
      const width = entries[0]?.contentRect?.width
      if (width && width > 0) containerWidth.value = width
    })
    resizeObserver.observe(containerRef.value)
  }
  if (visualizerBenchmarkEnabled()) {
    ;(window as any).loadMusicAnalyseBenchmarkFixture = loadVisualizerBenchmarkFixture
    ;(window as any).getMusicAnalyseBenchmarkState = () => ({
      steps: stepCount.value,
      mode: analysedViewMode.value,
      highlightIndices: [...highlightIndices.value],
      highlightWindowSize: highlightWindowSize.value,
      scrollLefts: [
        pianoRollRef.value?.scrollWrapper?.scrollLeft ?? null,
        ...analysisRollRefs.value.map(roll => roll?.scrollWrapper?.scrollLeft ?? null),
        bottomScrollRef.value?.scrollLeft ?? null,
      ],
    })
    console.info(
      '[visualizer-benchmark] fixture loader enabled: '
      + 'loadMusicAnalyseBenchmarkFixture(2352, 6, "Complexity")',
    )
  }
})

onUnmounted(() => {
  analysisPollToken += 1
  resizeObserver?.disconnect()
  resizeObserver = null
  if ((window as any).loadMusicAnalyseBenchmarkFixture === loadVisualizerBenchmarkFixture) {
    delete (window as any).loadMusicAnalyseBenchmarkFixture
  }
  delete (window as any).getMusicAnalyseBenchmarkState
})

defineExpose({
  openMusicXmlDialog,
  downloadAnalysisJson,
  setAnalysedViewMode,
  loadVisualizerBenchmarkFixture,
})
</script>

<style scoped>
.music-analyse-root {
  height: calc(100vh - 80px);
  display: flex;
  flex-direction: column;
  min-height: 0;
}
.viz-container {
  flex: 1 1 auto;
  min-height: 0;
  display: grid;
  grid-template-rows: 0.38fr 0.62fr;
}
.top-roll,
.analysis-area {
  min-height: 0;
  overflow: hidden;
}
.top-roll {
  display: flex;
  flex-direction: column;
}
.piano-stream-toolbar {
  flex: 0 0 auto;
  min-height: 32px;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 4px 8px;
  overflow-x: auto;
  border-bottom: 1px solid #ddd;
  background: #fafafa;
  font-size: 11px;
  white-space: nowrap;
}
.piano-stream-toolbar-label {
  color: #666;
  font-weight: 600;
}
.piano-stream-all-button {
  border: 1px solid #bbb;
  border-radius: 3px;
  padding: 1px 6px;
  background: #fff;
  color: #444;
  font-size: 10px;
  cursor: pointer;
}
.piano-stream-all-button:disabled {
  cursor: default;
  opacity: 0.45;
}
.piano-stream-item {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  cursor: pointer;
  max-width: 320px;
}
.piano-stream-item input {
  margin: 0;
}
.piano-stream-item span {
  overflow: hidden;
  text-overflow: ellipsis;
}
.piano-stream-swatch {
  width: 10px;
  height: 10px;
  flex: 0 0 10px;
  display: inline-block;
  border-radius: 2px;
}
.piano-roll-body {
  flex: 1 1 auto;
  min-height: 0;
}
.analysis-area {
  display: flex;
  flex-direction: column;
}
.analysis-toolbar {
  flex: 0 0 auto;
  min-height: 38px;
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 4px 8px;
  border-top: 1px solid #ddd;
  border-bottom: 1px solid #ddd;
  background: #fafafa;
  font-size: 12px;
}
.analysis-toolbar select {
  min-width: 180px;
}
.timing-info {
  color: #666;
  white-space: nowrap;
}
.metric-legend {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  margin-left: auto;
}
.metric-legend span {
  display: inline-flex;
  align-items: center;
  gap: 3px;
  white-space: nowrap;
}
.metric-legend i {
  width: 9px;
  height: 9px;
  display: inline-block;
  border-radius: 50%;
}
.analysis-scroll {
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  overflow-y: auto;
}
.analysis-row {
  min-height: 92px;
  flex: 0 0 auto;
}
.empty-state {
  flex: 1 1 auto;
  display: flex;
  align-items: center;
  justify-content: center;
  color: #777;
}
.error-banner {
  flex: 0 0 auto;
  padding: 6px 10px;
  color: #b00020;
  background: #ffebee;
  border-bottom: 1px solid #ffcdd2;
}
.bottom-scrollbar {
  overflow-x: auto;
  overflow-y: hidden;
  width: 100%;
  min-height: 14px;
  max-height: 14px;
  border-top: 1px solid #ccc;
}
.bottom-scrollbar-track {
  height: 1px;
}
.upload-panel {
  padding: 12px 0 20px;
}
</style>
