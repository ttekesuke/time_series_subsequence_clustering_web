<template>
  <div>
    <div class="viz-container" ref="containerRef">
      <div class="viz-row" style="height:30%">
        <StreamsRoll
          ref="queryStreamsRollRef"
          :streamValues="queryDisplaySeries"
          :minValue="0"
          :maxValue="queryMaxValue"
          :stepWidth="computedQueryStepWidth"
          :highlightIndices="highlightQIndices"
          :highlightWindowSize="highlightWindowSize"
          title="Query TimeSeries"
        />
      </div>
      <div class="viz-row" style="height:55%; overflow:auto; padding:8px">
        <v-alert
          v-if="queryStatus"
          class="mb-3"
          :type="queryStatus.type"
          density="compact"
          variant="tonal"
        >
          {{ queryStatus.message }}
        </v-alert>
        <div v-if="Object.keys(results.bySeries || {}).length === 0">{{ emptyResultsMessage }}</div>
        <div v-else>
          <div v-for="(info, idx) in seriesSummaries" :key="idx" style="margin-bottom:12px">
            <div style="display:flex; align-items:center; gap:12px;">
              <div><strong>DB series {{info.seriesLabel}}</strong> — matches: {{info.matches.length}} / score: {{info.matchScore}}</div>
              <v-btn small @click="showSeries(info.seriesIndex)">View</v-btn>
            </div>
            <div v-if="visibleSeries === info.seriesIndex" style="margin-top:6px">
              <StreamsRoll
                :ref="(el) => setDbStreamsRollRef(el, info.seriesIndex)"
                :streamValues="displaySeries(results.dbSeries[info.seriesIndex])"
                :minValue="0"
                :maxValue="queryMaxValue"
                :stepWidth="dbStepWidth(info.seriesIndex)"
                :highlightIndices="highlightDBIndices"
                :highlightWindowSize="highlightWindowSize"
                title="DB Series"
              ></StreamsRoll>
              <div style="margin-top:6px">
                <div class="matches-row">
                  <v-card
                    v-for="(m,mi) in info.matches"
                    :key="mi"
                    class="match-card"
                    outlined
                    @mouseenter="handleMatchHover(m, info.seriesIndex)"
                    @mouseleave="hoveredMatch = null"
                    style="cursor:default"
                  >
                    <v-card-text style="font-size:12px; line-height:1.2">
                      <div><strong>q_start:</strong> {{m.q_start}}</div>
                      <div>
                        <strong>db_start:</strong>
                        <span v-if="m.db_starts && m.db_starts.length > 0">
                          {{ m.db_starts.slice(0,5).join(', ') }}<span v-if="m.db_starts.length > 5"> …(+{{ m.db_starts.length - 5 }})</span>
                        </span>
                        <span v-else>—</span>
                      </div>
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

const STREAMS_ROLL_LABEL_WIDTH = 80
type StreamsRollExpose = {
  scrollToStep?: (step: number, windowSize?: number) => void
}

const openDialog = ref(false)
const query = ref({ timeseries: [], vectors: [] as any[], axes: [] as any[], mode: 'single' })
const results = ref({ dbSeries: [], bySeries: {} as Record<number, any[]> })
const dbStatus = ref<string | null>(null)
const dbDiagnostics = ref<Record<string, any> | null>(null)
const dbError = ref<string | null>(null)
const visibleSeries = ref<number | null>(null)

const containerRef = ref<HTMLElement | null>(null)
const queryStreamsRollRef = ref<StreamsRollExpose | null>(null)
const dbStreamsRollRefs = ref<Record<number, StreamsRollExpose | null>>({})
const containerWidth = ref(0)
let resizeObserver: ResizeObserver | null = null

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

const availableRollWidth = computed(() => {
  const width = containerWidth.value || 800
  return Math.max(1, width - STREAMS_ROLL_LABEL_WIDTH)
})

const queryLength = computed(() => {
  const vectors = query.value.vectors || []
  if (Array.isArray(vectors) && vectors.length > 0 && Array.isArray(vectors[0])) return vectors[0].length
  return query.value.timeseries.length || 100
})
const sharedStepWidth = computed(() => Math.max(4, availableRollWidth.value / Math.max(1, queryLength.value)))
const computedQueryStepWidth = sharedStepWidth
const queryDisplaySeries = computed(() => {
  const vectors = query.value.vectors || []
  if (Array.isArray(vectors) && vectors.length > 0) return vectors
  return [query.value.timeseries]
})
const queryMaxValue = computed(() => {
  const series = queryDisplaySeries.value.flat ? queryDisplaySeries.value.flat() : []
  const max = Math.max(11, ...series.map(v => Number(v) || 0))
  return Math.min(127, max)
})

const displaySeries = (series: any) => {
  if (!Array.isArray(series)) return [[]]
  if (series.length > 0 && Array.isArray(series[0])) {
    const notes = series.map((pt: any) => Array.isArray(pt) ? Number(pt[0] || 0) : Number(pt || 0))
    const vols = series.map((pt: any) => Array.isArray(pt) ? Number(pt[1] || 0) : 0)
    return [notes, vols]
  }
  return [series]
}

const seriesLength = (series: any) => {
  if (!Array.isArray(series)) return 1
  return series.length
}

const dbStepWidth = (seriesIndex: number) => {
  const len = seriesLength(results.value.dbSeries?.[seriesIndex])
  return Math.max(4, availableRollWidth.value / Math.max(1, len))
}

const handleQueried = (payload) => {
  query.value.timeseries = payload.query || []
  query.value.vectors = payload.queryVectors || []
  query.value.axes = payload.queryAxes || []
  query.value.mode = payload.queryModeInput || 'single'
  results.value.dbSeries = payload.dbSeries || []
  results.value.bySeries = payload.clustersPerSeries || {}
  dbStatus.value = payload.dbStatus || null
  dbDiagnostics.value = payload.dbDiagnostics || null
  dbError.value = payload.influxError || null
  if (payload.dbStatus && payload.dbStatus !== 'ok') {
    console.warn('Query DB status', {
      status: payload.dbStatus,
      diagnostics: payload.dbDiagnostics,
      influxError: payload.influxError,
      influxErrors: payload.influxErrors,
    })
  }
}

const queryStatus = computed(() => {
  if (!dbStatus.value) return null
  if (dbStatus.value === 'ok') return null
  const diag = dbDiagnostics.value || {}
  const suffix = `series=${diag.seriesStatsCount ?? 0}, fetched=${diag.fetchedSeriesCount ?? 0}, points=${diag.fetchedPointCount ?? 0}`
  if (dbStatus.value === 'influx_error') {
    return { type: 'error', message: `InfluxDB query failed. ${dbError.value || 'Check Render logs for [query_db][influx].'} (${suffix})` }
  }
  if (dbStatus.value === 'db_empty') {
    return { type: 'warning', message: `InfluxDB returned no series for this measurement/field. (${suffix})` }
  }
  if (dbStatus.value === 'no_match') {
    return { type: 'info', message: `InfluxDB data was scanned, but no subsequence matched. (${suffix})` }
  }
  return { type: 'info', message: `Query status: ${dbStatus.value}. (${suffix})` }
})

const emptyResultsMessage = computed(() => {
  if (!dbStatus.value) return 'No results yet. Open Query dialog and run a query.'
  if (dbStatus.value === 'no_match') return 'No matching DB series for the current query.'
  if (dbStatus.value === 'db_empty') return 'No DB series were available from InfluxDB.'
  if (dbStatus.value === 'influx_error') return 'InfluxDB query failed.'
  return 'No matching DB series.'
})

const seriesSummaries = computed(() => {
  const out: Array<any> = []
  const by = results.value.bySeries || {}
  for (const k of Object.keys(by)) {
    const idx = Number(k)
    const entry = by[idx]
    let matches = []
    if (Array.isArray(entry)) matches = entry
    else if (entry && entry.matches) matches = entry.matches

    // group by q_start + windowSize
    const groups = new Map()
    for (const m of matches) {
      const q = typeof m.q_start !== 'undefined' ? Number(m.q_start) : (typeof m.qStart !== 'undefined' ? Number(m.qStart) : 0)
      const ws = typeof m.windowSize !== 'undefined' ? Number(m.windowSize) : (typeof m.len !== 'undefined' ? Number(m.len) : 0)
      const db = typeof m.start !== 'undefined' ? Number(m.start) : (typeof m.db_start !== 'undefined' ? Number(m.db_start) : 0)
      const key = `${q}:${ws}`
      if (!groups.has(key)) groups.set(key, { q_start: q, windowSize: ws, db_starts: new Set() })
      groups.get(key).db_starts.add(db)
    }

    const grouped = Array.from(groups.values()).map(g => ({ q_start: g.q_start, windowSize: g.windowSize, db_starts: Array.from(g.db_starts).sort((a,b)=>a-b) }))
    const sourceLabel = entry && entry.series_id !== undefined
      ? `#${entry.series_id}`
      : (entry && entry.source_index !== undefined ? `#${entry.source_index}` : `#${idx}`)
    const matchScore = entry && entry.match_score !== undefined
      ? Number(entry.match_score)
      : grouped.reduce((sum, m) => sum + Number(m.windowSize || 0) * (m.db_starts?.length || 0), 0)
    out.push({ seriesIndex: idx, seriesLabel: sourceLabel, matchScore, matches: grouped })
  }
  return out.sort((a,b) => b.matchScore - a.matchScore)
})

const showSeries = (i: number) => {
  visibleSeries.value = visibleSeries.value === i ? null : i
}

const setDbStreamsRollRef = (el: unknown, seriesIndex: number) => {
  dbStreamsRollRefs.value[seriesIndex] = el as StreamsRollExpose | null
}

const hoveredMatch = ref<any | null>(null)
const highlightQIndices = computed(() => hoveredMatch.value ? [hoveredMatch.value.q_start] : [])
const highlightDBIndices = computed(() => hoveredMatch.value ? (hoveredMatch.value.db_starts || []) : [])
const highlightWindowSize = computed(() => hoveredMatch.value ? (hoveredMatch.value.windowSize || 0) : 0)

const handleMatchHover = async (match: any, seriesIndex: number) => {
  hoveredMatch.value = match
  await nextTick()
  const windowSize = Number(match?.windowSize || 1)
  queryStreamsRollRef.value?.scrollToStep?.(Number(match?.q_start || 0), windowSize)
  const dbStart = Array.isArray(match?.db_starts) && match.db_starts.length > 0 ? Number(match.db_starts[0]) : 0
  dbStreamsRollRefs.value[seriesIndex]?.scrollToStep?.(dbStart, windowSize)
}

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
