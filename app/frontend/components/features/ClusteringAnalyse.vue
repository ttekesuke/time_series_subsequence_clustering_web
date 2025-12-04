<template>
  <div>
    <div class="viz-container" ref="containerRef">
      <!-- 上段: Value Roll -->
      <div class="viz-row" style="height: 50%;">
        <StreamsRoll
          ref="StreamsRollRef"
          :streamValues="[analyse.timeseries]"
          :minValue="minValue"
          :maxValue="maxValue"
          :stepWidth="computedStepWidth"
          :highlightIndices="highlightedIndices"
          :highlightWindowSize="highlightedWindowSize"
          @scroll="onScroll"
        />
      </div>

      <!-- 下段: Clusters Roll -->
      <div class="viz-row" style="height: 50%;">
        <ClustersRoll
          ref="clustersRollRef"
          :clustersData="analyse.clusteredSubsequences"
          :stepWidth="computedStepWidth"
          :maxSteps="maxSteps"
          @scroll="onScroll"
          @hover-cluster="onHoverCluster"
        />
      </div>
    </div>

    <ClusteringAnalyseDialog
      v-model="openDialog"
      :on-file-selected="onFileSelected"
      :progress="progress"
      :job-id="props.jobId"
      @analysed="handleAnalysed"
    />
  </div>
</template>

<script setup lang="ts">
import StreamsRoll from '../visualizer/StreamsRoll.vue'
import ClustersRoll from '../visualizer/ClustersRoll.vue'
import { useScrollSync } from '../../composables/useScrollSync'

import { ref, nextTick, computed, watch, onMounted, onUnmounted } from 'vue'
import ClusteringAnalyseDialog from '../dialog/ClusteringAnalyseDialog.vue'
import axios from 'axios'

const props = defineProps({ jobId: { type: String, required: false } })
const jobId = props.jobId

const openDialog = ref(false)
const progress = ref({ percent: 0, status: 'idle' })

const analyse = ref({
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
      if (json.methodType === 'analyse') {
        analyse.value = json.analyse
      }
      showTimeseriesComplexityChart.value = true
      showTimeline.value = true
    }
  }
  reader.readAsText(file.target.files[0])
}

const handleAnalysed = (data) => {
  analyse.value.clusteredSubsequences = data.clusteredSubsequences
  analyse.value.timeseries = data.timeSeries
  analyse.value.clusters = data.clusters
  analyse.value.processingTime = data.processingTime
  // ensure charts show
  showTimeseriesComplexityChart.value = false
  showTimeline.value = false
  nextTick(() => {
    showTimeseriesComplexityChart.value = true
    showTimeline.value = true
  })
}

const saveToFile = () => {
  const data = { methodType: 'analyse', analyse: analyse.value, downloadDatetime: new Date().toISOString() }
  const jsonStr = JSON.stringify(data, null, 2)
  const blob = new Blob([jsonStr], { type: 'application/json' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = `time-series-analyse-${data.downloadDatetime}.json`
  a.click()
  URL.revokeObjectURL(url)
}

// expose methods for parent header buttons
const openParams = () => { openDialog.value = true }
const save = () => { saveToFile() }
import { defineExpose } from 'vue'
defineExpose({ openParams, saveToFile: save })

const containerRef = ref<HTMLElement | null>(null)
const StreamsRollRef = ref(null)
const clustersRollRef = ref(null)
const containerWidth = ref(containerRef.value ? containerRef.value.clientWidth : 0)
let resizeObserver: ResizeObserver | null = null
// スクロール同期
const { syncScroll } = useScrollSync([StreamsRollRef, clustersRollRef])
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
  if (!analyse.value.timeseries) return 100


  return analyse.value.timeseries.length
})

const minValue = computed(() => {
  return Math.min(...analyse.value.timeseries)
})
const maxValue = computed(() => {
  return Math.max(...analyse.value.timeseries)
})
// 画面幅に合わせてステップ幅を計算
const computedStepWidth = computed(() => {

  const widthPerStep = containerWidth.value / maxSteps.value

  // 最小幅(2px)を下回る場合はスクロールさせる
  return Math.max(4, widthPerStep)
})

// リサイズ監視
const updateWidth = () => {
  if (containerRef.value && containerRef.value.clientWidth > 0) {
    containerWidth.value = containerRef.value.clientWidth
  }
}

onMounted(() => {
  // nextTickでDOM更新を待つ
  nextTick(() => {
    updateWidth()
  })

  if (containerRef.value) {
    resizeObserver = new ResizeObserver((entries) => {
      for (const entry of entries) {
        // 幅が正しく取得できたタイミングで更新
        if (entry.contentRect.width > 0) {
          containerWidth.value = entry.contentRect.width
        }
      }
    })
    resizeObserver.observe(containerRef.value)
  }
})

onUnmounted(() => {
  if (resizeObserver) {
    resizeObserver.disconnect()
  }
})
</script>

<style scoped>
.viz-container {
  display: flex;
  flex-direction: column;
  height: calc(100vh - 80px); /* adjust so it fills main area under header */
  width: 100%;
}
.viz-row {
  height: 50%;
  width: 100%;
  overflow-y: auto;
}
</style>
