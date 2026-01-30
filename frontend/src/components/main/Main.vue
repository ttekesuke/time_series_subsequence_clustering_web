<template>
  <v-app>
    <v-app-bar app>
      <v-row class="align-center header-row" no-gutters>
        <v-col class="v-col-auto ml-3">
          <v-toolbar-title>Time series subsequence-clustering</v-toolbar-title>
        </v-col>
        <v-col class="v-col-auto">
          <v-select
            label="mode"
            :items="modes"
            :model-value="selectedMode"
            @update:modelValue="onModeSelect"
            class="hide-details"
          ></v-select>
        </v-col>
        <v-col class="v-col-auto">
          <div class="header-actions d-flex align-center">
            <v-btn
              color="primary"
              :disabled="!hasOpenParams"
              @click="openParamsFromHeader"
            >SET PARAMS</v-btn>
            <v-btn
              v-if="selectedMode === 'MusicGenerate'"
              color="primary"
              @click="transferDialog = true"
            >
              {{ transferButtonLabel }}
            </v-btn>
          </div>
        </v-col>
        <!-- Music Mode (New Polyphonic) -->
        <v-col
          class="v-col-auto"
          v-if="selectedMode === 'MusicGenerate' && runOnGithubActions"
        >
          <v-row class="align-center" no-gutters>
            <template v-if="musicDispatchInfo && musicDispatchInfo.workflow_page_url">
              <v-col class="v-col-auto">
                <v-btn
                  size="small"
                  variant="text"
                  :href="musicDispatchInfo.workflow_page_url"
                  target="_blank"
                  rel="noopener"
                >
                  Workflow
                </v-btn>
              </v-col>
              <v-col class="v-col-auto" v-if="musicDispatchInfo.run_html_url">
                <v-btn
                  size="small"
                  variant="text"
                  :href="musicDispatchInfo.run_html_url"
                  target="_blank"
                  rel="noopener"
                >
                  Run
                </v-btn>
              </v-col>
              <v-col class="v-col-auto" v-if="musicDispatchInfo.request_id">
                <span class="text-caption">
                  request_id: {{ musicDispatchInfo.request_id }}
                </span>
              </v-col>
            </template>
          </v-row>
        </v-col>

        <v-col class="v-col-auto" v-if="selectedMode === 'MusicGenerate'">
          <div class="d-flex align-center">
            <!-- Sound Player Control -->
            <v-btn @click='switchStartOrStopSound()' :disabled="!canPlay" :color="isNowPlaying ? 'error' : 'primary'">
              <v-icon v-if='isNowPlaying'>mdi-stop</v-icon>
              <v-icon v-else>mdi-play</v-icon>
              <span>{{ isNowPlaying ? 'STOP' : 'PLAY' }}</span>
            </v-btn>
            <v-select
              label="AnalysedViewMode"
              :items="analysedViewModes"
              :model-value="analysedViewMode"
              @update:modelValue="onAnalysedViewModeChange"
              class="hide-details"
            />
          </div>
        </v-col>
        <v-col class="v-col-auto">
          <v-btn @click="infoDialog = true">
            <v-icon icon="$info"></v-icon>
            Info
          </v-btn>
          <InfoDialog v-model="infoDialog" />
        </v-col>
      </v-row>
      <TransferDialog
        v-if="selectedMode === 'MusicGenerate'"
        v-model="transferDialog"
        :run-on-github-actions="runOnGithubActions"
        @upload-result-json="onPickResultJson"
        @upload-wav="onPickWav"
        @upload-params-json="onPickParamsJson"
        @download-result-json="downloadResultJson"
        @download-result-wav="downloadResultWav"
        @download-params-json="downloadParamsJson"
      />
    </v-app-bar>
    <v-main>
      <component :is="selectedComponent" :job-id="jobId" ref="activeFeatureRef" />
    </v-main>
  </v-app>
</template>

<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
import axios from 'axios'
import { v4 as uuidv4 } from 'uuid'
import ClusteringAnalyse from '../../components/features/ClusteringAnalyse.vue'
import ClusteringGenerate from '../../components/features/ClusteringGenerate.vue'
import MusicGenerate from '../../components/features/MusicGenerate.vue'
import InfoDialog from './InfoDialog.vue'
import TransferDialog from './TransferDialog.vue'
const infoDialog = ref(false)
const modes = ref(['ClusteringAnalyse', 'ClusteringGenerate', 'MusicGenerate'])
const selectedMode = ref('ClusteringAnalyse')
const analysedViewModes = ref(['Cluster', 'Complexity'])
const analysedViewMode = ref('Cluster')
const transferDialog = ref(false)

const runOnGithubActions = computed(() => {
  const raw = (import.meta as any).env?.VITE_RUN_GENERATE_POLYPHONIC_ON_GITHUB_ACTIONS ?? 'true'
  return String(raw).toLowerCase() === 'true'
})
const transferButtonLabel = computed(() =>
  runOnGithubActions.value ? 'UPLOAD' : 'UPLOAD / DOWNLOAD'
)

import type { ComponentPublicInstance } from 'vue'
const activeFeatureRef = ref<ComponentPublicInstance | null>(null)

const musicDispatchInfo = computed(() => {
  if (selectedMode.value !== 'MusicGenerate') return null
  const inst = activeFeatureRef.value as any
  if (!inst) return null
  const di = inst.dispatchInfo
  return (di && typeof di === 'object' && 'value' in di) ? di.value : di
})

const unwrapMaybeRef = <T>(v: any): T => {
  return (v && typeof v === 'object' && 'value' in v) ? v.value : v
}

const onPickResultJson = async (file: File) => {
  const inst = activeFeatureRef.value as any
  if (file) await inst?.loadResultJsonFile?.(file)
}

const onPickWav = async (file: File) => {
  const inst = activeFeatureRef.value as any
  if (file) await inst?.loadWavFile?.(file)
}

const onPickParamsJson = async (file: File) => {
  const inst = activeFeatureRef.value as any
  if (file) await inst?.loadParamsJsonFile?.(file)
}


const canPlay = computed(() => {
  const inst = activeFeatureRef.value as any
  const val = inst?.soundFilePath
  return !!unwrapMaybeRef<string>(val)
})
const isNowPlaying = computed(() => {
  const inst = activeFeatureRef.value as any
  const val = inst?.nowPlaying
  return !!unwrapMaybeRef<boolean>(val)
})

const selectedComponent = computed(() => {
  if (selectedMode.value === 'ClusteringAnalyse') return ClusteringAnalyse
  if (selectedMode.value === 'ClusteringGenerate') return ClusteringGenerate
  if (selectedMode.value === 'MusicGenerate') return MusicGenerate
  return ClusteringAnalyse
})


const audio = ref<HTMLAudioElement | null>(null)

const progress = ref({
  percent: 0,
  status: 'idle'
})
const jobId = ref(uuidv4())

// Header -> call methods exposed by active feature component
const hasOpenParams = computed(() => !!(activeFeatureRef.value && (activeFeatureRef.value as any).openParams))
const openParamsFromHeader = () => {
  if (!activeFeatureRef.value) return
  ;(activeFeatureRef.value as any).openParams?.()
}

const downloadResultJson = () => {
  (activeFeatureRef.value as any)?.downloadResultJson?.()
}

const downloadResultWav = () => {
  (activeFeatureRef.value as any)?.downloadResultWav?.()
}

const downloadParamsJson = () => {
  (activeFeatureRef.value as any)?.downloadParamsJson?.()
}

const onAnalysedViewModeChange = (val: string) => {
  analysedViewMode.value = val
  const inst = activeFeatureRef.value as any
  inst?.setAnalysedViewMode?.(val)
}



const switchStartOrStopSound = () =>{
  isNowPlaying.value ? stopPlayingSound() : startPlayingSound()
}

const stopPlayingSound = () => {
  (activeFeatureRef.value as any)?.stopPlayingSound?.()

}
const startPlayingSound = () => {
  (activeFeatureRef.value as any)?.startPlayingSound?.()

}

const renderPolyphonicAudio = (timeSeries) => {
  progress.value.status = 'rendering'
  const stepDuration = 60.0 / music.value.bpm / 4.0
  axios.post('/api/web/supercolliders/render_polyphonic', {
    time_series: timeSeries, step_duration: stepDuration
  }).then(response => {
    const { sound_file_path, scd_file_path, audio_data } = response.data
    music.value.soundFilePath = sound_file_path
    const base64 = audio_data.includes(',') ? audio_data.split(',')[1] : audio_data
    const binary = atob(base64)
    const len = binary.length
    const bytes = new Uint8Array(len)
    for (let i = 0; i < len; i++) bytes[i] = binary.charCodeAt(i)
    const blob = new Blob([bytes.buffer], { type: "audio/wav" })
    const url = URL.createObjectURL(blob)
    audio.value = new Audio(url)
    // audio.value.addEventListener('ended', () => nowPlaying.value = false)
    music.value.loading = false
    music.value.setDataDialog = false
    cleanup()
  })
  .catch(error => { console.error("Rendering error:", error); music.value.loading = false })
}

const confirmLeaveMessage = '移動または再読み込みしてよいですか？'
const confirmLeave = () => window.confirm(confirmLeaveMessage)

const onModeSelect = (nextMode: string) => {
  if (nextMode === selectedMode.value) return
  if (!confirmLeave()) return
  selectedMode.value = nextMode
  transferDialog.value = false
}

let lastUrl = ''

const handleBeforeUnload = (event: BeforeUnloadEvent) => {
  event.preventDefault()
  event.returnValue = confirmLeaveMessage
  return confirmLeaveMessage
}

const handlePopState = () => {
  if (!confirmLeave()) {
    history.pushState(null, '', lastUrl)
    return
  }
  lastUrl = window.location.href
}

onMounted(() => {
  lastUrl = window.location.href
  window.addEventListener('beforeunload', handleBeforeUnload)
  window.addEventListener('popstate', handlePopState)
})

onUnmounted(() => {
  window.removeEventListener('beforeunload', handleBeforeUnload)
  window.removeEventListener('popstate', handlePopState)
})

watch(activeFeatureRef, () => {
  if (selectedMode.value !== 'MusicGenerate') return
  const inst = activeFeatureRef.value as any
  inst?.setAnalysedViewMode?.(analysedViewMode.value)
})

</script>

<style scoped>

.header-row {
  column-gap: 0;
  row-gap: 0;
}
.header-row > .v-col {
  padding: 0;
}
  h3 + h3,
  h5 + h5 {
    margin-top: 1.5rem;
  }

  ::v-deep(.v-textarea textarea) {
    white-space: pre !important;
    overflow-x: auto !important;
    height: 68px;
  }
  ::v-deep(.v-select .v-input__details) {
    display: none !important;
  }
.grid-card {
  /* show horizontal scrollbar when content overflows, prevent vertical scroll */
  overflow-x: auto;
  overflow-y: hidden;
  margin-bottom: 16px;
}
.grid-container {
  display: block;
  width: 100%;
  overflow-x: auto; /* ensure inner scrolling when table is wider than container */
}
.param-grid {
  border-collapse: separate;
  border-spacing: 0;
  table-layout: fixed;
  font-size: 0.8rem;
  width: max-content; /* allow table to grow with fixed cell widths */
}
.param-grid th, .param-grid td {
  border: 1px solid #e0e0e0;
  padding: 2px;
  text-align: center;
  min-width: 3.5rem; /* prevent compression */
  width: 3.5rem;     /* fixed width */
  box-sizing: border-box;
  height: 1.5rem;
  white-space: nowrap; /* avoid internal wrapping */
}
.sticky-col { position: sticky; z-index: 2; background-color: white; }
.head-col { left: 0; z-index: 3; width: 100px !important; min-width: 100px !important; font-weight: bold; }
.sub-col { left: 100px; z-index: 3; width: 60px !important; min-width: 60px !important; }
thead th { position: sticky; top: 0; background-color: #f5f5f5; z-index: 2; height: 40px; }
thead th.head-col, thead th.sub-col { z-index: 4; }
.dim-start-row td { border-top: 3px solid #999 !important; }
.row-label { text-align: left; padding-left: 8px; vertical-align: middle; background-color: white; }
.border-none { border-top: none !important; }
.grid-input { width: 100%; height: 100%; border: none; text-align: center; background: transparent; outline: none; font-size: 0.9rem; }
.grid-input:focus { background-color: #e8f5e9; font-weight: bold; }
.step-input { width: 60px; border: 1px solid #ccc; padding: 2px 5px; border-radius: 4px; background: white; }
.label-count { color: #D81B60; font-weight: bold; }
.label-target { color: #6A1B9A; font-weight: bold; }
.label-global { color: #1976D2; font-weight: bold; }
.label-stream { color: #FB8C00; }
.label-conc { color: #43A047; }
.label-dim { color: #607D8B; font-weight: bold; }
.font-monospace textarea { font-family: monospace; font-size: 0.85rem; }
</style>
