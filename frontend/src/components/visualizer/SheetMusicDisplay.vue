<template>
  <div>
    <div v-if="loading" class="loading">Loading MusicXML...</div>
    <div v-if="error" class="error">{{ error }}</div>

    <div ref="scoreContainer" class="score-container"></div>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted, onUnmounted, watch } from 'vue'
import axios from 'axios'
import { OpenSheetMusicDisplay } from 'opensheetmusicdisplay'

const props = defineProps<{
  composer: string
  title: string
  folder: string
  xmlScore: string
  seriesId?: string // DBのseries_id
  part?: string     // パート情報
  staff?: string    // スタッフ情報
  voice?: string    // ボイス情報
  phraseIndex?: number // フレーズインデックス
  match?: any // query result match range
}>()

const loading = ref(false)
const error = ref('')
const osmdInstances = ref<any[]>([])
const scoreContainer = ref<HTMLElement | null>(null)
let renderRequestId = 0
let renderTimer: number | null = null

// APIからMusicXMLを取得
async function fetchMusicXmlEntries(): Promise<Array<{ xml: string }>> {
  if (!props.match) return []
  const res = await axios.post('/api/web/time_series/get_xml', {
    composer: props.composer,
    folder: props.folder,
    xml_score: props.xmlScore,
    series_id: props.seriesId || "",
    part: props.part || "P1",
    staff: props.staff || "1",
    voice: props.voice || "1",
    phrase_index: props.phraseIndex || 1,
    match: props.match || null
  })
  const response = res.data

  if (response.error) {
    throw new Error(response.error)
  }
  if (!response.phrase_bounds) {
    throw new Error('Phrase range was not found for this score result')
  }

  if (Array.isArray(response.xmls)) return response.xmls
  return response.xml ? [{ xml: response.xml }] : []
}

// 楽譜をロードして表示
async function loadAndRenderScore() {
  if (!scoreContainer.value) return

  const requestId = ++renderRequestId
  loading.value = true
  error.value = ''

  try {
    for (const instance of osmdInstances.value) instance.clear?.()
    osmdInstances.value = []
    scoreContainer.value.innerHTML = ''

    const entries = await fetchMusicXmlEntries()
    if (requestId !== renderRequestId || !scoreContainer.value) return
    if (entries.length === 0) return

    for (const entry of entries) {
      if (requestId !== renderRequestId || !scoreContainer.value) return
      const host = document.createElement('div')
      host.className = 'score-entry'
      scoreContainer.value.appendChild(host)

      const instance = new OpenSheetMusicDisplay(host, {
        autoResize: false,
        backend: 'svg',
        disableCursor: true,
        drawTitle: false,
        drawSubtitle: false,
        drawComposer: false,
        drawCredits: false,
      })
      await instance.load(entry.xml)
      if (requestId !== renderRequestId || !scoreContainer.value) {
        instance.clear?.()
        return
      }
      await instance.render()
      osmdInstances.value.push(instance)
    }

  } catch (err: any) {
    console.error('Failed to load/render score:', err)
    error.value = err.message || 'Failed to load score'
  } finally {
    if (requestId === renderRequestId) loading.value = false
  }
}

const scheduleLoadAndRenderScore = () => {
  if (renderTimer !== null) window.clearTimeout(renderTimer)
  renderTimer = window.setTimeout(() => {
    renderTimer = null
    loadAndRenderScore()
  }, 120)
}

watch(() => [props.composer, props.folder, props.xmlScore, props.seriesId, props.part, props.staff, props.voice, props.phraseIndex, props.match], () => {
  scheduleLoadAndRenderScore()
})

onMounted(() => {
  scheduleLoadAndRenderScore()
})

onUnmounted(() => {
  if (renderTimer !== null) window.clearTimeout(renderTimer)
  renderTimer = null
  renderRequestId += 1
  for (const instance of osmdInstances.value) instance.clear?.()
  osmdInstances.value = []
})
</script>

<style scoped>
.score-container {
  width: 100%;
  min-height: 200px;
  background-color: #fff;
}
:deep(.score-entry) {
  margin-bottom: 12px;
}
.loading, .error {
  padding: 20px;
  text-align: center;
}
.error {
  color: red;
}
</style>
