<template>
  <div class="music-analyse-root" ref="containerRef">
    <div v-if="errorMessage" class="error-banner">{{ errorMessage }}</div>

    <div v-if="result" class="viz-container">
      <div class="top-roll">
        <StreamsRoll
          ref="pianoRollRef"
          :streamValues="pianoStreams"
          :streamVelocities="pianoVelocities"
          :streamLabels="pianoLabels"
          :stepWidth="computedStepWidth"
          :minValue="0"
          :maxValue="127"
          :valueResolution="1"
          :highlightIndices="highlightIndices"
          :highlightWindowSize="highlightWindowSize"
          title="MusicXML Piano Roll"
          @scroll="onScroll"
        />
      </div>

      <div class="analysis-area">
        <div class="analysis-toolbar">
          <label for="music-analysis-scope">Scope</label>
          <select id="music-analysis-scope" v-model="analysisScope">
            <option value="global">Global</option>
            <option v-for="stream in result.streams" :key="stream.id" :value="String(stream.id)">
              {{ stream.label }}
            </option>
          </select>
          <span class="timing-info">
            exact grid: {{ result.timing.quarterUnit }} quarter / {{ result.timing.stepCount }} steps
          </span>
          <div v-if="analysedViewMode === 'Complexity'" class="metric-legend">
            <span v-for="(label, index) in metricLabelsWithConcordance" :key="label">
              <i :style="{ backgroundColor: metricColor(index) }"></i>{{ label }}
            </span>
          </div>
        </div>

        <div class="analysis-scroll">
          <div v-for="(section, index) in sections" :key="section.key" class="analysis-row">
            <ClustersRoll
              v-if="analysedViewMode === 'Cluster'"
              :ref="el => setAnalysisRollRef(el, index)"
              :clustersData="clustersForSection(section)"
              :stepWidth="computedStepWidth"
              :maxSteps="stepCount"
              :title="section.title + ' Clusters'"
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
              :maxValue="1"
              :valueResolution="0.01"
              :title="section.title + ' Complexity'"
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
          <v-btn icon @click="dialogOpen = false"><v-icon>mdi-close</v-icon></v-btn>
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

          <v-alert v-if="dialogError" type="error" variant="tonal" class="mt-3">
            {{ dialogError }}
          </v-alert>
        </v-card-text>
        <v-card-actions class="justify-end">
          <v-btn variant="text" @click="dialogOpen = false">CANCEL</v-btn>
          <v-btn color="primary" :loading="submitting" @click="submitMusicXml">SUBMIT</v-btn>
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

type ClusterData = { window_size: number; cluster_id: string; indices: number[] }
type AxisBundle = {
  prediction?: Array<number | null>
  diversity?: Array<number | null>
  shape?: Array<number | null>
  occurrence?: Array<number | null>
  mass?: Array<number | null>
  combined?: Array<number | null>
}
type DimensionResult = {
  values: {
    global: Array<number | null>
    streams: Record<string, Array<number | null>>
    concordance: Array<number | null>
  }
  analysis: {
    global: { axes: AxisBundle; raw: any }
    streams: Record<string, { axes: AxisBundle; raw: any }>
  }
  clusters: {
    global: ClusterData[]
    streams: Record<string, ClusterData[]>
  }
}
type MusicAnalysisResult = {
  metadata: any
  timing: { exact: boolean; gridDenominator: number; quarterUnit: string; stepCount: number }
  streams: Array<{ id: number; label: string; partId: string; staff: string; voice: string }>
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
const mergeThresholdRatio = ref(0.02)
const analysedViewMode = ref<'Cluster' | 'Complexity'>('Complexity')
const analysisScope = ref('global')

const containerRef = ref<HTMLElement | null>(null)
const pianoRollRef = ref<any>(null)
const analysisRollRefs = ref<any[]>([])
const bottomScrollRef = ref<HTMLElement | null>(null)
const containerWidth = ref(0)
let resizeObserver: ResizeObserver | null = null

const setAnalysisRollRef = (el: any, index: number) => {
  analysisRollRefs.value[index] = el ?? null
}

const { syncScroll } = useScrollSync([pianoRollRef, analysisRollRefs, bottomScrollRef])
const onScroll = (e: Event) => syncScroll(e)

const stepCount = computed(() => result.value?.timing?.stepCount ?? 0)
const plotAreaWidth = computed(() => Math.max(1, containerWidth.value - 80))
const computedStepWidth = computed(() => {
  const count = Math.max(stepCount.value, 1)
  return Math.max(0.25, Math.min(8, plotAreaWidth.value / count, 30000 / count))
})
const globalScrollTrackWidth = computed(() =>
  Math.max(containerWidth.value, Math.max(stepCount.value, 1) * computedStepWidth.value)
)

const pianoStreams = computed(() => result.value?.pianoRoll?.streams ?? [])
const pianoVelocities = computed(() => result.value?.pianoRoll?.velocities ?? [])
const pianoLabels = computed(() => result.value?.pianoRoll?.streamLabels ?? [])

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

const sections = computed(() => {
  const data = result.value
  if (!data) return []
  return data.dimensionOrder
    .filter(key => !!data.dimensions[key])
    .map(key => ({ key, title: titleMap[key] ?? key, dimension: data.dimensions[key] }))
})

const metricKeys = ['prediction', 'diversity', 'shape', 'occurrence', 'mass', 'combined'] as const
const metricLabels = ['Prediction', 'Diversity', 'Shape', 'Occurrence', 'Mass', 'Combined']
const metricLabelsWithConcordance = [...metricLabels, 'Concordance']
const metricColor = (index: number) => 'hsl(' + ((index * 137.5) % 360) + ', 70%, 45%)'

const axisBundleFor = (section: any): AxisBundle => {
  const dim = section.dimension as DimensionResult
  if (analysisScope.value === 'global') return dim.analysis.global?.axes ?? {}
  return dim.analysis.streams?.[analysisScope.value]?.axes ?? dim.analysis.global?.axes ?? {}
}

const complexityStreams = (section: any) => {
  const axes = axisBundleFor(section)
  const rows: Array<Array<number | null>> = metricKeys.map(key =>
    Array.isArray(axes[key]) ? (axes[key] as Array<number | null>) : Array(stepCount.value).fill(null)
  )
  const conc = section.dimension?.values?.concordance
  if (Array.isArray(conc) && conc.some((value: any) => value != null)) rows.push(conc)
  return rows
}

const complexityLabels = (section: any) => {
  const labels = [...metricLabels]
  const conc = section.dimension?.values?.concordance
  if (Array.isArray(conc) && conc.some((value: any) => value != null)) labels.push('Concordance')
  return labels
}

const clustersForSection = (section: any): ClusterData[] => {
  const dim = section.dimension as DimensionResult
  if (analysisScope.value === 'global') return dim.clusters?.global ?? []
  return dim.clusters?.streams?.[analysisScope.value] ?? []
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
    dialogError.value = error?.response?.data?.message ?? 'ASAP dataset list could not be loaded.'
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

const submitMusicXml = async () => {
  dialogError.value = ''
  submitting.value = true
  try {
    const payload: any = {
      source_type: sourceType.value,
      merge_threshold_ratio: Number(mergeThresholdRatio.value),
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

    const { data } = await axios.post('/api/web/time_series/analyse_music', { analyse_music: payload })
    result.value = data as MusicAnalysisResult
    lastResultJson.value = data
    analysisScope.value = 'global'
    highlightIndices.value = []
    highlightWindowSize.value = 0
    errorMessage.value = ''
    dialogOpen.value = false
    await nextTick()
  } catch (error: any) {
    const message = error?.response?.data?.message ?? error?.message ?? 'MusicXML analysis failed.'
    dialogError.value = message
    errorMessage.value = message
  } finally {
    submitting.value = false
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
  analysisRollRefs.value = []
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
})

onUnmounted(() => {
  resizeObserver?.disconnect()
  resizeObserver = null
})

defineExpose({
  openMusicXmlDialog,
  downloadAnalysisJson,
  setAnalysedViewMode,
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
  flex: 1 0 92px;
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
