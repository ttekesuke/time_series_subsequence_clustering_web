<template>
  <div>
    <v-row class="pa-3 align-center">
      <v-col />
      <v-col class="v-col-auto">
        <!-- header buttons moved to Main.vue -->
      </v-col>
    </v-row>

    <div class="viz-container" ref="containerRef">
      <div class="viz-row" style="height:50%">
        <StreamsRoll
          ref="streamsRollRef"
          :streamValues="[generate.timeseries]"
          :minValue="minValue"
          :maxValue="maxValue"
          :highlightIndices="highlightedIndices"
          :highlightWindowSize="highlightedWindowSize"
          :stepWidth="computedStepWidth"
          @scroll="onScroll"
        />
      </div>
      <div class="viz-row" style="height:50%">
        <ClustersRoll
          ref="clustersRollRef"
          :clustersData="generate.clusteredSubsequences"
          :stepWidth="computedStepWidth"
          :maxSteps="maxSteps"
          @scroll="onScroll"
          @hover-cluster="onHoverCluster"
        />
      </div>
    </div>

    <ClusteringGenerateDialog
      v-model="openDialog"
      :on-file-selected="onFileSelected"
      :progress="progress"
      :job-id="props.jobId"
      @generated="handleGenerated"
    />
  </div>
</template>

<script setup lang="ts">
import StreamsRoll from '../visualizer/StreamsRoll.vue'
import ClustersRoll from '../visualizer/ClustersRoll.vue'
import { useScrollSync } from '../../composables/useScrollSync'

import { ref, nextTick, computed, watch, onMounted, onUnmounted } from 'vue'
import ClusteringGenerateDialog from '../dialog/ClusteringGenerateDialog.vue'
import axios from 'axios'

const props = defineProps({ jobId: { type: String, required: false } })

const openDialog = ref(false)
const progress = ref({ percent: 0, status: 'idle' })

const generate = ref({
  timeseries: [],
  clusteredSubsequences: [],
  timeSeriesChart: [],
  loading: false,
  mergeThresholdRatio: 0.02,
  clusters: {},
  processingTime: null
})

let showTimeseriesComplexityChart = ref(false)
let showTimeline = ref(false)

const onFileSelected = (file) => {
  const reader = new FileReader()
  reader.onload = (e) => {
    if (!e.target) return
    const text = e.target.result
      if (typeof text === 'string') {
      const json = JSON.parse(text)
      if (json.methodType === 'generate') {
        generate.value = json.generate || {}
      }
      showTimeseriesComplexityChart.value = true
      showTimeline.value = true
    }
  }
  reader.readAsText(file.target.files[0])
}

const handleGenerated = (data) => {

  console.log('generated', data)
  // reactive updates
  if (!generate.value.clusteredSubsequences) generate.value.clusteredSubsequences = []
  generate.value.clusteredSubsequences.splice(0, generate.value.clusteredSubsequences.length, ...(data.clusteredSubsequences || []))

  if (!generate.value.timeseries) generate.value.timeseries = []
  generate.value.timeseries.splice(0, generate.value.timeseries.length, ...(data.timeSeries || []))

  generate.value.clusters = data.clusters ? { ...data.clusters } : {}
  generate.value.processingTime = data.processingTime

  showTimeseriesComplexityChart.value = false
  showTimeline.value = false
  nextTick(() => {
    showTimeseriesComplexityChart.value = true
    showTimeline.value = true
  })
}

const saveToFile = () => {
  const data = { methodType: 'generate', generate: generate.value, downloadDatetime: new Date().toISOString() }
  const jsonStr = JSON.stringify(data, null, 2)
  const blob = new Blob([jsonStr], { type: 'application/json' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = `time-series-generate-${data.downloadDatetime}.json`
  a.click()
  URL.revokeObjectURL(url)
}

// expose methods for header
const openParams = () => { openDialog.value = true }
const save = () => { saveToFile() }
import { defineExpose } from 'vue'
defineExpose({ openParams, saveToFile: save })

const containerRef = ref<HTMLElement | null>(null)
const streamsRollRef = ref(null)
const clustersRollRef = ref(null)
const containerWidth = ref(containerRef.value ? containerRef.value.clientWidth : 0)
let resizeObserver: ResizeObserver | null = null
// スクロール同期
const { syncScroll } = useScrollSync([streamsRollRef, clustersRollRef])
const onScroll = (e) => syncScroll(e)

// ハイライト状態
const highlightedIndices = ref<number[]>([])
const highlightedWindowSize = ref(0)

const onHoverCluster = (clusterInfo) => {
  if (clusterInfo) {
    highlightedIndices.value = clusterInfo.indices
    highlightedWindowSize.value = clusterInfo.windowSize
  } else {
    highlightedIndices.value = []
    highlightedWindowSize.value = 0
  }
}

// 最大ステップ数の計算
const maxSteps = computed(() => {
  if (!generate.value.timeseries) return 100
  return generate.value.timeseries.length
})

const minValue = computed(() => Math.min(...(generate.value.timeseries || [0])))
const maxValue = computed(() => Math.max(...(generate.value.timeseries || [1])))

// 画面幅に合わせてステップ幅を計算
const computedStepWidth = computed(() => {
  const widthPerStep = containerWidth.value / maxSteps.value
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
</script>

<style scoped>
.viz-container { display: flex; flex-direction: column; height: calc(100vh - 120px); width: 100%; }
.viz-row { height: 50%; width: 100%; overflow-y: auto; }
</style>
