<template>
  <v-app>
    <v-app-bar app>
      <v-row class="align-center ">
        <v-col class="v-col-auto ml-3">
          <v-toolbar-title>Time series subsequence-clustering</v-toolbar-title>
        </v-col>
        <v-col class="v-col-auto">
          <v-select
            label="mode"
            :items="modes"
            v-model="selectedMode"
            class="hide-details"
          ></v-select>
        </v-col>
        <v-col class="v-col-auto">
          <v-btn color="primary" class="mr-2" :disabled="!hasOpenParams" @click="openParamsFromHeader">SET PARAMS</v-btn>
        </v-col>

        <!-- Music Mode (New Polyphonic) -->
        <v-col class="v-col-auto" v-if="selectedMode === 'MusicGenerate'">


          <!-- Sound Player Control -->
          <v-btn @click='switchStartOrStopSound()' class="ml-2" :disabled="!canPlay" :color="isNowPlaying ? 'error' : 'primary'">
            <v-icon v-if='isNowPlaying'>mdi-stop</v-icon>
            <v-icon v-else>mdi-play</v-icon>
            <span class="ml-1">{{ isNowPlaying ? 'STOP' : 'PLAY' }}</span>
          </v-btn>

        </v-col>
        <v-col class="v-col-auto">
          <v-btn @click="infoDialog = true">
            <v-icon icon="$info"></v-icon>
            Info
          </v-btn>
          <InfoDialog v-model="infoDialog" />
        </v-col>
      </v-row>
    </v-app-bar>
    <v-main>
    <component :is="selectedComponent" :job-id="jobId" ref="activeFeatureRef" />


      <div v-if="selectedMode === 'Music'">
        <v-row no-gutters>
          <v-col>
            <Music
              ref="musicComponent"
              :midiData="music.midiData"
              :secondsPerTick="music.secondsPerTick"
            ></Music>
          </v-col>
        </v-row>
        <v-row no-gutters class="mt-5">
          <v-col>
            <Fft ref="FftComponent" :audioEl='audio'></Fft>
          </v-col>
        </v-row>

      </div>
    </v-main>
  </v-app>
</template>

<script setup lang="ts">
import { onMounted, ref, watch, nextTick, computed } from 'vue'
import axios from 'axios'
import { v4 as uuidv4 } from 'uuid'
import { ScoreEntry } from '../../types/types';
import { MidiNote } from '../../types/types';
import { useJobChannel } from '../../composables/useJobChannel'
import Music from '../../components/music/Music.vue';
import Fft from '../../components/audio/Fft.vue';
import { Midi } from '@tonejs/midi'
import Decimal from 'decimal.js'
import ClusteringAnalyseDialog from '../../components/dialog/ClusteringAnalyseDialog.vue';
import GridContainer from '../../components/grid/GridContainer.vue';
import VisualizerContainer from '../../components/visualizer/VisualizerContainer.vue';
import ClusteringAnalyse from '../../components/features/ClusteringAnalyse.vue'
import ClusteringGenerate from '../../components/features/ClusteringGenerate.vue'
import MusicGenerate from '../../components/features/MusicGenerate.vue'
import InfoDialog from './InfoDialog.vue'
const infoDialog = ref(false)
const modes = ref(['ClusteringAnalyse', 'ClusteringGenerate', 'MusicGenerate'])
const selectedMode = ref('ClusteringAnalyse')
type Cluster = {
  si: number[]; // subsequence indexes
  cc: { [childId: string]: Cluster }; // child clusters
};
type Clusters = {
  [clusterId: string]: Cluster;
};

import type { ComponentPublicInstance } from 'vue'
const musicComponent = ref<ComponentPublicInstance<{ start: () => void; stop: () => void }> | null>(null)
const activeFeatureRef = ref<ComponentPublicInstance | null>(null)

const canPlay = computed(() => {
  const inst = activeFeatureRef.value as any
  return !!inst?.soundFilePath   // soundFilePath があれば再生可能とみなす
})
const isNowPlaying = computed(() => {
  const inst = activeFeatureRef.value as any
  return !!inst?.nowPlaying      // expose していれば
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



const switchStartOrStopSound = () =>{
  isNowPlaying.value ? stopPlayingSound() : startPlayingSound()
}

const stopPlayingSound = () => {
  (activeFeatureRef.value as any)?.stopPlayingSound?.()

}
const startPlayingSound = () => {
  (activeFeatureRef.value as any)?.startPlayingSound?.()

}



const subscribeToProgress = () => {
  jobId.value = uuidv4()
  progress.value = { percent: 0, status: 'start' }
  const { unsubscribe } = useJobChannel(jobId.value, (data) => {
    progress.value.status = data.status
    progress.value.percent = data.progress
    if (data.status === 'done') unsubscribe()
  })
}


const renderPolyphonicAudio = (timeSeries) => {
  progress.value.status = 'rendering'
  const stepDuration = 60.0 / music.value.bpm / 4.0
  axios.post('/api/web/supercolliders/render_polyphonic', {
    time_series: timeSeries, step_duration: stepDuration
  }).then(response => {
    const { sound_file_path, scd_file_path, audio_data } = response.data
    music.value.soundFilePath = sound_file_path
    music.value.scdFilePath = scd_file_path
    const binary = atob(audio_data)
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

</script>

<style scoped>
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
