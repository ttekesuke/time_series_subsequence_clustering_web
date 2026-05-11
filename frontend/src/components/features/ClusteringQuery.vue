<template>
  <div>
    <div class="viz-container" ref="containerRef">
      <div class="viz-row" style="height:30%">
        <StreamsRoll
          ref="queryStreamsRollRef"
          :streamValues="[query.timeseries]"
          :minValue="0"
          :maxValue="11"
          :stepWidth="computedQueryStepWidth"
          :highlightIndices="highlightQIndices"
          :highlightWindowSize="highlightWindowSize"
          title="Query TimeSeries"
        />
      </div>
      <div class="viz-row" style="height:55%; overflow:auto; padding:8px">
        <div v-if="Object.keys(results.bySeries || {}).length === 0">No results yet. Open Query dialog and run a query.</div>
        <div v-else>
          <div v-for="(info, idx) in seriesSummaries" :key="idx" style="margin-bottom:12px">
            <div style="display:flex; align-items:center; gap:12px;">
              <div><strong>DB series #{{info.seriesIndex}}</strong> — matches: {{info.matches.length}}</div>
              <v-btn small @click="showSeries(info.seriesIndex)">View</v-btn>
            </div>
            <div v-if="visibleSeries === info.seriesIndex" style="margin-top:6px">
              <StreamsRoll :streamValues="[results.dbSeries[info.seriesIndex]]" :minValue="0" :maxValue="11" :stepWidth="computedDbStepWidth" :highlightIndices="highlightDBIndices" :highlightWindowSize="highlightWindowSize" title="DB Series"></StreamsRoll>
              <div style="margin-top:6px">
                <div class="matches-row">
                  <v-card
                    v-for="(m,mi) in info.matches"
                    :key="mi"
                    class="match-card"
                    outlined
                    @mouseenter="hoveredMatch = m"
                    @mouseleave="hoveredMatch = null"
                    style="cursor:default"
                  >
                    <v-card-text style="font-size:12px; line-height:1.2">
                      <div><strong>q_start:</strong> {{m.q_start}}</div>
                      <div><strong>db_start:</strong> {{m.start}}</div>
                      <div><strong>len:</strong> {{m.windowSize}}</div>
                    </v-card-text>
                  </v-card>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <ClusteringQueryDialog v-model="openDialog" @queried="handleQueried" />
  </div>
</template>

<script setup lang="ts">
import { ref, computed, nextTick, onMounted, onUnmounted } from 'vue'
import StreamsRoll from '../visualizer/StreamsRoll.vue'
import ClusteringQueryDialog from '../dialog/ClusteringQueryDialog.vue'
import { useScrollSync } from '../../composables/useScrollSync'

const openDialog = ref(false)
const query = ref({ timeseries: [] })
const results = ref({ dbSeries: [], bySeries: {} as Record<number, any[]> })
const visibleSeries = ref<number | null>(null)

const containerRef = ref<HTMLElement | null>(null)
const queryStreamsRollRef = ref(null)
const containerWidth = ref(0)
let resizeObserver: ResizeObserver | null = null
const { syncScroll } = useScrollSync([queryStreamsRollRef])
const onScroll = (e) => syncScroll(e)

onMounted(() => {
  nextTick(() => { if (containerRef.value) containerWidth.value = containerRef.value.clientWidth })
  if (containerRef.value) {
    resizeObserver = new ResizeObserver((entries) => {
      for (const entry of entries) if (entry.contentRect.width > 0) containerWidth.value = entry.contentRect.width
    })
    resizeObserver.observe(containerRef.value)
  }
})
onUnmounted(() => { if (resizeObserver) resizeObserver.disconnect() })

const computedQueryStepWidth = computed(() => Math.max(4, (containerWidth.value || 800) / Math.max(1, (query.value.timeseries.length || 100))))

const computedDbStepWidth = computed(() => {
  const len = (visibleSeries.value !== null && results.value.dbSeries[visibleSeries.value]) ? results.value.dbSeries[visibleSeries.value].length : (query.value.timeseries.length || 100)
  return Math.max(4, (containerWidth.value || 800) / Math.max(1, len))
})

const handleQueried = (payload) => {
  query.value.timeseries = payload.query || []
  results.value.dbSeries = payload.dbSeries || []
  results.value.bySeries = payload.clustersPerSeries || {}
}

const seriesSummaries = computed(() => {
  const out: Array<any> = []
  const by = results.value.bySeries || {}
  for (const k of Object.keys(by)) {
    const idx = Number(k)
    const entry = by[idx]
    let matches = []
    if (Array.isArray(entry)) matches = entry
    else if (entry && entry.matches) matches = entry.matches
    out.push({ seriesIndex: idx, matches })
  }
  return out.sort((a,b) => b.matches.length - a.matches.length)
})

const showSeries = (i: number) => {
  visibleSeries.value = visibleSeries.value === i ? null : i
}

const hoveredMatch = ref<any | null>(null)
const highlightQIndices = computed(() => hoveredMatch.value ? [hoveredMatch.value.q_start] : [])
const highlightDBIndices = computed(() => hoveredMatch.value ? [hoveredMatch.value.start] : [])
const highlightWindowSize = computed(() => hoveredMatch.value ? (hoveredMatch.value.windowSize || 0) : 0)

// expose open dialog from header
import { defineExpose } from 'vue'
const openParams = () => { openDialog.value = true }
defineExpose({ openParams })
</script>

<style scoped>
.viz-container { display:flex; flex-direction:column; height: calc(100vh - 80px); width:100% }
.viz-row { width:100% }
 .matches-row { display:flex; gap:8px; flex-wrap:wrap; align-items:flex-start }
 .match-card { width:180px; min-width:140px }
</style>
