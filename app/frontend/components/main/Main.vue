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
          <v-btn color="secondary" :disabled="!hasSaveToFile" @click="saveToFileFromHeader">Download</v-btn>
        </v-col>

        <!-- Music Mode (New Polyphonic) -->
        <v-col class="v-col-auto" v-if="selectedMode === 'Music'">
          <v-btn @click="music.setDataDialog = true" color="primary">Polyphonic Generate</v-btn>

          <v-dialog height="98%" width="98%" v-model="music.setDataDialog" scrollable>
            <v-card>
              <v-card-title class="text-h5 grey lighten-2 d-flex align-center justify-space-between py-2">
                <span>Polyphonic Stream Generation Parameters</span>
                <div class="d-flex align-center">
                  <!-- Progress Status -->
                  <div class="mr-4 text-caption" v-if="progress.status === 'progress' || progress.status === 'rendering'">
                    <span v-if="progress.status === 'progress'">Generating: {{progress.percent}}%</span>
                    <span v-if="progress.status === 'rendering'">Rendering Audio...</span>
                  </div>
                  <v-btn
                    color="secondary"
                    class="mr-2 open-param-gen-btn"
                    :disabled="!focusedCell.type"
                    @mousedown="setSuppressBlur"
                    @click="openParamGenDialog"
                  >
                    GENERATE PARAMETERS
                  </v-btn>
                  <!-- GENERATE & RENDER Button -->
                  <v-btn
                    color="success"
                    class="mr-2"
                    :loading="music.loading"
                    @click="generatePolyphonic"
                  >
                    GENERATE & RENDER
                  </v-btn>

                  <v-btn icon @click="music.setDataDialog = false"><v-icon>mdi-close</v-icon></v-btn>
                </div>
              </v-card-title>

              <v-card-text class="pa-4" style="height: 80vh;">

                <!-- 上段: Initial Context (初期値) -->
                <v-card variant="outlined" class="mb-4 grid-card">
                  <v-toolbar density="compact" color="grey-lighten-4" class="px-2">
                    <v-toolbar-title class="text-subtitle-1 font-weight-bold">1. Initial Context (Past Context)</v-toolbar-title>
                    <v-spacer></v-spacer>
                    <!-- Context Controllers -->
                    <div class="d-flex align-center mr-4" style="font-size: 0.9rem;">
                      <span class="mr-2">Streams:</span>
                      <input
                        type="number"
                        v-model.number="contextStreamCount"
                        min="1" max="16"
                        class="step-input mr-1"
                        @change="updateContextStreams"
                      >
                    </div>
                    <div class="d-flex align-center mr-2" style="font-size: 0.9rem;">
                      <span class="mr-2">Steps:</span>
                      <input
                        type="number"
                        v-model.number="contextStepCount"
                        min="1" max="100"
                        class="step-input mr-1"
                        @change="updateContextSteps"
                      >
                    </div>
                  </v-toolbar>

                  <div class="grid-container">
                    <table class="param-grid">
                      <thead>
                        <tr>
                          <th class="sticky-col head-col" style="width: 100px;">Stream</th>
                          <th class="sticky-col sub-col" style="width: 100px!important;">Param</th>
                          <!-- Context Steps -->
                          <th v-for="i in contextStepCount" :key="`ctx-h-${i}`" class="data-col">
                            {{ i }}
                          </th>
                        </tr>
                      </thead>
                      <tbody>
                        <template v-for="s in contextStreamCount" :key="`s-${s}`">
                          <!-- Stream Header / First Dim -->
                          <tr class="dim-start-row">
                            <td class="sticky-col head-col row-label" rowspan="6">Stream {{ s }}</td>
                            <td class="sticky-col sub-col label-dim">{{ dimensions[0].label }}</td>
                            <td v-for="(step, i) in polyParams.initial_context" :key="`ctx-${s}-${dimensions[0].key}-${i}`">
                              <input
                                type="number"
                                v-if="step[s-1]"
                                v-model.number="step[s-1][0]"
                                class="grid-input"
                                min="0" max="10"
                                @paste="onContextPaste($event, s-1, 0, i)"
                                @focus="onContextFocus(s-1, 0, i, { min: 0, max: 10, isInt: true })" @blur="onContextBlur"
                              >
                            </td>
                          </tr>
                          <!-- Remaining Dims -->
                          <tr v-for="(dim, dIdx) in dimensions.slice(1)" :key="`dim-${dim.key}-${s}`">
                            <td class="sticky-col sub-col label-dim">{{ dim.label }}</td>
                            <td v-for="(step, i) in polyParams.initial_context" :key="`ctx-${s}-${dim.key}-${i}`">
                              <input
                                type="number"
                                v-if="step[s-1]"
                                v-model.number="step[s-1][dIdx + 1]"
                                class="grid-input"
                                :step="dim.key === 'note' ? 1 : 0.1"
                                @paste="onContextPaste($event, s-1, dIdx + 1, i)"
                                @focus="onContextFocus(s-1, dIdx + 1, i, { min: dim.key === 'note' ? 0 : 0, max: dim.key === 'note' ? 11 : 1, isInt: dim.key === 'note' })" @blur="onContextBlur"
                              >
                            </td>
                          </tr>
                        </template>
                      </tbody>
                    </table>
                  </div>
                </v-card>

                <!-- 下段: Generation Parameters (生成パラメータ) -->
                <v-card variant="outlined" class="fill-height grid-card">
                  <v-toolbar density="compact" color="grey-lighten-4" class="px-2">
                    <v-toolbar-title class="text-subtitle-1 font-weight-bold">2. Generation Parameters (Future Targets)</v-toolbar-title>
                    <v-spacer></v-spacer>
                    <div class="d-flex align-center mr-2" style="font-size: 0.9rem;">
                      <span class="mr-2">Gen Steps:</span>
                      <input
                        type="number"
                        v-model.number="newStepCount"
                        min="1" max="100"
                        class="step-input mr-1"
                        @change="updateStepCount"
                      >
                    </div>
                  </v-toolbar>

                  <div class="grid-container">
                    <table class="param-grid">
                      <thead>
                        <tr>
                          <th class="sticky-col head-col" style="width: 100px;"></th>
                          <th class="sticky-col sub-col" style="width: 60px;">Param</th>
                          <th v-for="(count, i) in polyParams.stream_counts" :key="i" class="data-col">
                            {{ i + 1 }}
                          </th>
                        </tr>
                      </thead>
                      <tbody>
                        <!-- Stream Counts Row -->
                        <tr class="dim-start-row">
                          <td class="sticky-col head-col row-label" rowspan="1">STREAM</td>
                          <td class="sticky-col sub-col label-count">Count</td>
                          <td v-for="(val, i) in polyParams.stream_counts" :key="`count-${i}`" class="data-col">
                            <input
                              type="number"
                              v-model.number="polyParams.stream_counts[i]"
                              min="1"
                              class="grid-input"
                              @paste="onGenParamPaste($event, polyParams.stream_counts, i, true)"
                              @focus="onGridFocus(polyParams.stream_counts, i, { min: 1, max: 16, isInt: true })" @blur="onGridBlur"
                            >
                          </td>
                        </tr>

                        <template v-for="dim in dimensions" :key="dim.key">
                          <!-- Global -->
                          <tr class="dim-start-row">
                            <td class="sticky-col head-col row-label" rowspan="4">{{ dim.label }}</td>
                            <td class="sticky-col sub-col label-global">Global</td>
                            <td v-for="(val, i) in polyParams.stream_counts" :key="`g-${dim.key}-${i}`" class="data-col">
                              <input
                                type="number"
                                v-model.number="polyParams[`${dim.key}_global`][i]"
                                step="0.01" min="0" max="1"
                                class="grid-input"
                                @paste="onGenParamPaste($event, polyParams[`${dim.key}_global`], i)"
                                @focus="onGridFocus(polyParams[`${dim.key}_global`], i, { min: 0, max: 1 })" @blur="onGridBlur"
                              >
                            </td>
                          </tr>
                          <!-- Ratio -->
                          <tr>
                            <td class="sticky-col sub-col label-stream">Ratio</td>
                            <td v-for="(val, i) in polyParams.stream_counts" :key="`r-${dim.key}-${i}`" class="data-col">
                              <input
                                type="number"
                                v-model.number="polyParams[`${dim.key}_ratio`][i]"
                                step="0.01" min="0" max="1"
                                class="grid-input"
                                @paste="onGenParamPaste($event, polyParams[`${dim.key}_ratio`], i)"
                                @focus="onGridFocus(polyParams[`${dim.key}_ratio`], i, { min: 0, max: 1 })" @blur="onGridBlur"
                              >
                            </td>
                          </tr>
                          <!-- Tightness -->
                          <tr>
                            <td class="sticky-col sub-col label-stream">Tight</td>
                            <td v-for="(val, i) in polyParams.stream_counts" :key="`t-${dim.key}-${i}`" class="data-col">
                              <input
                                type="number"
                                v-model.number="polyParams[`${dim.key}_tightness`][i]"
                                step="0.01" min="0" max="1"
                                class="grid-input"
                                @paste="onGenParamPaste($event, polyParams[`${dim.key}_tightness`], i)"
                                @focus="onGridFocus(polyParams[`${dim.key}_tightness`], i, { min: 0, max: 1 })" @blur="onGridBlur"
                              >
                            </td>
                          </tr>
                          <!-- Concordance -->
                          <tr>
                            <td class="sticky-col sub-col label-conc">Conc</td>
                            <td v-for="(val, i) in polyParams.stream_counts" :key="`c-${dim.key}-${i}`" class="data-col">
                              <input
                                type="number"
                                v-model.number="polyParams[`${dim.key}_conc`][i]"
                                step="0.01" min="-1" max="1"
                                class="grid-input"
                                @paste="onGenParamPaste($event, polyParams[`${dim.key}_conc`], i)"
                                @focus="onGridFocus(polyParams[`${dim.key}_conc`], i, { min: -1, max: 1 })" @blur="onGridBlur"
                              >
                            </td>
                          </tr>
                        </template>
                      </tbody>
                    </table>
                  </div>
                </v-card>
              </v-card-text>
            </v-card>
          </v-dialog>

          <!-- ★追加: パラメータ生成用ダイアログ -->
          <v-dialog v-model="paramGenDialog" width="500">
            <v-card>
              <v-card-title class="text-h6 bg-grey-lighten-3">Generate Parameters</v-card-title>
              <v-card-text class="pt-4">
                <v-row>
                  <v-col cols="12">
                    <v-text-field
                      label="Steps to Generate"
                      type="number"
                      v-model.number="paramGen.steps"
                      min="1"
                      hint="Number of cells to fill from cursor"
                      persistent-hint
                    ></v-text-field>
                  </v-col>

                  <v-col cols="12">
                    <v-tabs v-model="paramGen.mode" density="compact" color="primary">
                      <v-tab value="transition">Transition</v-tab>
                      <v-tab value="random">Random</v-tab>
                    </v-tabs>

                    <v-window v-model="paramGen.mode" class="mt-4">
                      <!-- Transition Mode -->
                      <v-window-item value="transition">
                        <v-row>
                          <v-col cols="6">
                            <v-text-field label="Start Value" type="number" v-model.number="paramGen.start" step="0.1"></v-text-field>
                          </v-col>
                          <v-col cols="6">
                            <v-text-field label="End Value" type="number" v-model.number="paramGen.end" step="0.1"></v-text-field>
                          </v-col>
                          <v-col cols="12">
                            <v-select
                              label="Curve Type"
                              :items="easingFunctions"
                              item-title="title"
                              item-value="value"
                              v-model="paramGen.curve"
                            ></v-select>
                          </v-col>
                        </v-row>
                      </v-window-item>

                      <!-- Random Mode -->
                      <v-window-item value="random">
                        <v-row>
                          <v-col cols="6">
                            <v-text-field label="Min Value" type="number" v-model.number="paramGen.randMin" step="0.1"></v-text-field>
                          </v-col>
                          <v-col cols="6">
                            <v-text-field label="Max Value" type="number" v-model.number="paramGen.randMax" step="0.1"></v-text-field>
                          </v-col>
                        </v-row>
                      </v-window-item>
                    </v-window>
                  </v-col>
                </v-row>
              </v-card-text>
              <v-card-actions>
                <v-spacer></v-spacer>
                <v-btn color="grey" text @click="paramGenDialog = false">Cancel</v-btn>
                <v-btn color="primary" @click="applyGeneratedParams">Generate & Paste</v-btn>
              </v-card-actions>
            </v-card>
          </v-dialog>

          <!-- Sound Player Control -->
          <v-btn @click='switchStartOrStopSound()' class="ml-2" :disabled="!music.soundFilePath" :color="nowPlaying ? 'error' : 'primary'">
            <v-icon v-if='nowPlaying'>mdi-stop</v-icon>
            <v-icon v-else>mdi-play</v-icon>
            <span class="ml-1">{{ nowPlaying ? 'STOP' : 'PLAY' }}</span>
          </v-btn>

        </v-col>
        <v-col class="v-col-auto">
          <v-btn @click="infoDialog = true">
            <v-icon icon="$info"></v-icon>
            Info
          </v-btn>
          <v-dialog width="1000" v-model="infoDialog" >
            <v-card>
              <v-card-text>
                <h3>What is this site?</h3>
                <div>The site can cluster and display substrings of various lengths that are similar to each other in the time series data entered by the user.</div>
                <h3>How to use</h3>
                <h5>Analye</h5>
                <ul class="custom-list">
                  <li>Click "ANALYSE".</li>
                  <li>Enter your time series data into the large input field. For example, 1,3,5,1,3,5.</li>
                  <li>If you find it bothersome to input data, you can also set random numbers by entering values into the three input fields under "generate randoms" and pressing "SET RANDOMS".</li>
                  <li>Click "SUBMIT" to display the results.</li>
                </ul>
                <h5>Generate</h5>
                <ul class="custom-list">
                  <a href="https://youtu.be/vAQeHWESkEk" target="_blank">movie</a>
                </ul>
                <h3>Attention</h3>
                <ul class="custom-list">
                  <li>All of them are free of charge.</li>
                  <li>Input values and results are not saved.</li>
                  <li>The system may change without notice.</li>
                  <li>We do not guarantee the correctness of the results.</li>
                  <li>Due to the circumstances of being operated for free, it may take about 50 seconds to re-access the site if there is no access for a while. Please wait.</li>
                </ul>
                <h3>Developer</h3>
                <div>
                  <a href='https://tekesuke1986.tumblr.com' target='_blank'>Takuya SHIMIZU</a>
                </div>
              </v-card-text>
            </v-card>
          </v-dialog>
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


const selectedComponent = computed(() => {
  if (selectedMode.value === 'ClusteringAnalyse') return ClusteringAnalyse
  if (selectedMode.value === 'ClusteringGenerate') return ClusteringGenerate
  if (selectedMode.value === 'MusicGenerate') return MusicGenerate
  return ClusteringAnalyse
})
type Track = {
  name: string;
  durations: string;
  durationRules: ((v: any) => true | string)[];
  midiNoteNumbers: string;
  midiNoteNumbersRules: ((v: any) => true | string)[];
  color: string;
  harmRichness: number;
  brightness: number;
  noiseContent: number;
  formantChar: number;
  inharmonicity: number;
  resonance: number;
};

const music = ref<{
  notes: (MidiNote | null)[];
  tracks: Track[];
  trackIdCounter: number;
  durations: string;
  durationsRules: ((v: any) => true | string)[];
  midiNoteNumbers: string;
  midiNoteNumbersRules: ((v: any) => true | string)[];
  setDataDialog: boolean;
  valid: boolean;
  midi: File[] | null;
  midiData: any;
  ticksPerBeat: number;
  ticksPerBeatDefault: number;
  bpmDefault: number;
  bpm: number;
  secondsPerTick: number;
  velocity: number;
  loading: boolean;
  soundFilePath: string | null;
  scdFilePath: string | null;
}>({
  notes: [],
  tracks: [],
  trackIdCounter: -1,
  midiNoteNumbers: '',
  midiNoteNumbersRules: [
    v => !!v || 'required',
    v => (v && String(v).split(',').every(n => !isNaN(Number(n)) && n !== "")) || 'must be comma separated numbers',
    v => (v && String(v).split(',').filter(n => n !== "").length >= 1) || 'must have at least 1 numbers',
    v => (v && String(v).split(',').length <= 2000) || 'must have no more than 2000 numbers',
    v => (v && String(v).split(',').every(n => Number.isInteger(Number(n)) && n.trim() !== "")) || 'must be integers',
    v => (v && String(v).split(',').every(n => Number(n) >= 12)) || 'numbers must be 12 or more',
    v => (v && String(v).split(',').every(n => Number(n) <= 127)) || 'numbers must be 127 or less',
  ],
  durations: '',
  durationsRules: [
    v => !!v || 'required',
    v => (v && String(v).split(',').every(n => !isNaN(Number(n)) && n !== "")) || 'must be comma separated numbers',
    v => (v && String(v).split(',').filter(n => n !== "").length >= 1) || 'must have at least 1 numbers',
    v => (v && String(v).split(',').length <= 2000) || 'must have no more than 2000 numbers',
    v => (v && String(v).split(',').every(n => Number.isInteger(Number(n)) && n.trim() !== "")) || 'must be integers',
    v => (v && String(v).split(',').every(n => Number(n) >= 1)) || 'numbers must be 1 or more',
    v => (v && String(v).split(',').every(n => Number(n) <= 100)) || 'numbers must be 100 or less'
  ],
  setDataDialog: false,
  valid: false,
  midi: null,
  midiData: null,
  ticksPerBeat: 480,
  ticksPerBeatDefault: 480,
  bpmDefault: 60,
  bpm: 60,
  secondsPerTick: 0,
  velocity: 1,
  loading: false,
  soundFilePath: null,
  scdFilePath: null
})

const audio = ref<HTMLAudioElement | null>(null)
let showTimeseriesChart = ref(false)
let showTimeseriesComplexityChart = ref(false)
let showTimeline = ref(false)
let infoDialog = ref(false)
const nowPlaying = ref(false)
const progress = ref({
  percent: 0,
  status: 'idle'
})
const jobId = ref(uuidv4())

let methodType = ref<"analyse" | "generate" | null>(null)
let selectedFileAnalyse = ref<File | null>(null)
let selectedFileGenerate = ref<File | null>(null)

const dimensions = [
  { key: 'octave', label: 'OCTAVE' },
  { key: 'note',   label: 'NOTE' },
  { key: 'vol',    label: 'VOLUME' },
  { key: 'bri',    label: 'BRIGHTNESS' },
  { key: 'hrd',    label: 'HARDNESS' },
  { key: 'tex',    label: 'TEXTURE' }
]

const steps = 10
const fill = (start, mid, end, len=steps) => {
  const arr = [];
  const pivot = Math.floor(len / 2);
  for (let i = 0; i < len; i++) {
    if (i < pivot) arr.push(Number((start + (mid - start) * (i / pivot)).toFixed(2)));
    else arr.push(Number((mid + (end - mid) * ((i - pivot) / (len - pivot - 1))).toFixed(2)));
  }
  return arr;
};
const constant = (val, len=steps) => Array(len).fill(val);

const polyParams = ref<any>({
  stream_counts: constant(2),
  initial_context: [
    [[4,0,0.8,0.2,0.2,0.0], [4,7,0.8,0.2,0.2,0.0]],
    [[4,0,0.8,0.2,0.2,0.0], [4,7,0.8,0.2,0.2,0.0]],
    [[4,0,0.8,0.2,0.2,0.0], [4,7,0.8,0.2,0.2,0.0]]
  ],

  octave_global:    fill(0.0, 0.1, 1.0),
  octave_ratio:     fill(0.0, 0.5, 1.0),
  octave_tightness: constant(1.0),
  octave_conc:      fill(0.8, 0.5, 0.0),

  note_global:      fill(0.2, 0.5, 0.8),
  note_ratio:       fill(0.0, 0.5, 1.0),
  note_tightness:   constant(0.5),
  note_conc:        fill(0.8, 0.8, 0.2),
  vol_global:       constant(0.1),
  vol_ratio:        constant(0.0),
  vol_tightness:    constant(0.0),
  vol_conc:         constant(1.0),

  bri_global:       fill(0.1, 0.5, 1.0),
  bri_ratio:        fill(0.0, 1.0, 1.0),
  bri_tightness:    constant(0.5),
  bri_conc:         constant(0.5),

  hrd_global:       fill(0.0, 0.2, 0.9),
  hrd_ratio:        fill(0.0, 0.0, 1.0),
  hrd_tightness:    constant(1.0),
  hrd_conc:         constant(0.5),

  tex_global:       fill(0.0, 0.0, 1.0),
  tex_ratio:        fill(0.0, 0.0, 1.0),
  tex_tightness:    constant(1.0),
  tex_conc:         constant(0.0),
})

const newStepCount = ref(steps)
const contextStepCount = ref(3)
const contextStreamCount = ref(2)

// ★追加: パラメータ生成用ステート
const paramGenDialog = ref(false)
const focusedCell = ref<any>({ type: null, targetArray: null, index: null, constraints: null })
// snapshot of the focus target captured when opening the param-gen dialog
const paramGenTarget = ref<any>(null)
const _suppressBlurClear = ref(false)

const setSuppressBlur = () => {
  _suppressBlurClear.value = true
  // clear after short timeout to avoid permanently suppressing
  setTimeout(() => { _suppressBlurClear.value = false }, 300)
}
const paramGen = ref({
  steps: 10,
  mode: 'transition', // 'transition' | 'random'
  start: 0, end: 1, curve: 'linear',
  randMin: 0, randMax: 1
})

const easingFunctions = [
  { title: 'Linear', value: 'linear' },
  { title: 'Ease In (Quad)', value: 'easeInQuad' },
  { title: 'Ease Out (Quad)', value: 'easeOutQuad' },
  { title: 'Ease In Out (Quad)', value: 'easeInOutQuad' },
]





const saveToFile = () => {
  const data = {
    methodType: methodType.value,
    downloadDatetime: new Date().toISOString()
  }
  if(methodType.value === 'analyse'){
    data['analyse'] = analyse.value
  }else if(methodType.value === 'generate'){
    data['analyse'] = analyse.value
    data['generate'] = generate.value
  }
  const jsonStr = JSON.stringify(data, null, 2)
  const blob = new Blob([jsonStr], { type: "application/json" })
  const url = URL.createObjectURL(blob)

  const a = document.createElement("a")
  a.href = url
  a.download = `time-series-data-${methodType.value}-${data.downloadDatetime}.json`
  a.click()

  URL.revokeObjectURL(url)
}

// Header -> call methods exposed by active feature component
const hasOpenParams = computed(() => !!(activeFeatureRef.value && (activeFeatureRef.value as any).openParams))
const hasSaveToFile = computed(() => !!(activeFeatureRef.value && (activeFeatureRef.value as any).saveToFile))
const openParamsFromHeader = () => {
  if (!activeFeatureRef.value) return
  ;(activeFeatureRef.value as any).openParams?.()
}
const saveToFileFromHeader = () => {
  if (!activeFeatureRef.value) return
  ;(activeFeatureRef.value as any).saveToFile?.()
}

const onFileSelected = (file) => {
  const reader = new FileReader()

  reader.onload = (e) => {
    if (!e.target) {
      console.error("FileReader event target is null.");
      return;
    }
    const text = e.target.result;
    if (typeof text === 'string') {
      const json = JSON.parse(text);
      if(json.methodType === 'analyse'){
        analyse.value = json.analyse
        // drawTimeline()
        // drawTimeSeries('timeseries', analyse.value.timeSeriesChart)
      }else if(json.methodType === 'generate'){
        analyse.value = json.analyse
        generate.value = json.generate
        // drawTimeline()
        // drawTimeSeries('timeseries', analyse.value.timeSeriesChart)
        // drawTimeSeriesComplexity('timeseries-complexity', generate.value.complexityTransitionChart)
        showTimeseriesComplexityChart.value = true

      }
      showTimeseriesChart.value = true
      showTimeline.value = true
    } else {
      console.error("FileReader result is not a string.");
    }
  };

  reader.readAsText(file.target.files[0]);
}

const switchStartOrStopSound = () =>{
  nowPlaying.value ? stopPlayingSound() : startPlayingSound()
}

const stopPlayingSound = () => {
  nowPlaying.value = false
  audio.value?.pause()
  if(audio.value) audio.value.currentTime = 0
  musicComponent.value?.stop()
}
const startPlayingSound = () => {
  if(!audio.value) return
  nowPlaying.value = true
  audio.value.play()
  musicComponent.value?.start()
}
const cleanup = () => {
  let data = {
    cleanup: {
      sound_file_path: music.value.soundFilePath,
      scd_file_path: music.value.scdFilePath
    }
  }
  axios.delete("/api/web/supercolliders/cleanup", { data })
  .then(response => {
    console.log('deleted temporary files')
  })
  .catch(error => console.error("音声削除エラー", error));
}


const updateContextSteps = () => {
  const targetLen = contextStepCount.value
  const current = polyParams.value.initial_context
  while (current.length < targetLen) {
    const lastStep = current[current.length - 1]
    current.push(JSON.parse(JSON.stringify(lastStep)))
  }
  if (current.length > targetLen) current.splice(targetLen)
}

const updateContextStreams = () => {
  const targetCount = contextStreamCount.value
  polyParams.value.initial_context.forEach(step => {
    while (step.length < targetCount) {
      step.push([4, 0, 0.8, 0.2, 0.2, 0.0])
    }
    if (step.length > targetCount) {
      step.splice(targetCount)
    }
  })
}

const updateStepCount = () => {
  const targetLen = newStepCount.value
  updateArrayLength(polyParams.value.stream_counts, targetLen, 2)
  dimensions.forEach(dim => {
    updateArrayLength(polyParams.value[`${dim.key}_global`], targetLen, 0.0)
    updateArrayLength(polyParams.value[`${dim.key}_ratio`], targetLen, 0.0)
    updateArrayLength(polyParams.value[`${dim.key}_tightness`], targetLen, 1.0)
    updateArrayLength(polyParams.value[`${dim.key}_conc`], targetLen, 0.0)
  })
}

const updateArrayLength = (arr, targetLen, defaultVal) => {
  while (arr.length < targetLen) arr.push(arr.length > 0 ? arr[arr.length - 1] : defaultVal)
  if (arr.length > targetLen) arr.splice(targetLen)
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

// ★ Paste Handler for Generation Parameters (Simple Array)
const onGenParamPaste = (e, targetArr, startIndex, isInt = false) => {
  e.preventDefault();
  const text = e.clipboardData.getData('text');
  if (!text) return;

  // タブまたは空白で区切って配列化
  const values = text.split(/\s+/).filter(v => v !== '').map(Number);
  if (values.some(isNaN)) return;

  const requiredLen = startIndex + values.length;

  // ステップ数が足りない場合は拡張
  if (requiredLen > polyParams.value.stream_counts.length) {
    newStepCount.value = requiredLen;
    updateStepCount(); // 既存メソッドを再利用して全配列を拡張
  }

  // 拡張後の配列に対して値をセット (Vueのリアクティブ性を考慮)
  values.forEach((val, k) => {
    // targetArrは参照渡しされている配列
    if (targetArr[startIndex + k] !== undefined) {
      targetArr[startIndex + k] = isInt ? Math.round(val) : val;
    }
  });
}

// ★ Paste Handler for Initial Context (Nested Array)
const onContextPaste = (e, streamIdx, dimIdx, stepIdx) => {
  e.preventDefault();
  const text = e.clipboardData.getData('text');
  if (!text) return;

  const values = text.split(/\s+/).filter(v => v !== '').map(Number);
  if (values.some(isNaN)) return;

  const requiredLen = stepIdx + values.length;

  // ステップ拡張
  if (requiredLen > polyParams.value.initial_context.length) {
    contextStepCount.value = requiredLen;
    updateContextSteps(); // 既存メソッドで拡張
  }

  // 値の書き込み
  values.forEach((val, k) => {
    const targetStep = polyParams.value.initial_context[stepIdx + k];
    if (targetStep && targetStep[streamIdx]) {
      const isInt = (dimIdx === 0 || dimIdx === 1); // Octave, Note are ints
      targetStep[streamIdx][dimIdx] = isInt ? Math.round(val) : val;
    }
  });
}

// ★追加: グリッドフォーカス検知
const onGridFocus = (targetArr, idx, constraints) => {
  // try to detect which polyParams key this array belongs to so we can reference it later
  const findKey = (arr) => {
    for (const k of Object.keys(polyParams.value)) {
      try {
        if (polyParams.value[k] === arr) return k
      } catch (e) {
        // ignore
      }
    }
    return null
  }
  const keyName = findKey(targetArr)
  focusedCell.value = {
    type: 'simple',
    targetArray: targetArr,
    index: idx,
    constraints: constraints,
    keyName: keyName
  }
}

// Clear simple-grid focus when input loses focus (unless focus moved inside the grid/dialog)
const onGridBlur = () => {
  // defer to allow click handlers (e.g. the button) to run first
  setTimeout(() => {
    if (_suppressBlurClear.value) return
    const active = document.activeElement as HTMLElement | null
    if (active && (active.closest('.param-grid') || active.closest('.grid-container') || active.closest('.grid-card'))) {
      return
    }
    focusedCell.value = { type: null, targetArray: null, index: null, constraints: null }
  }, 0)
}

// ★追加: Context用フォーカス検知
const onContextFocus = (streamIdx, dimIdx, stepIdx, constraints) => {
  focusedCell.value = {
    type: 'context',
    streamIdx, dimIdx, stepIdx,
    constraints: constraints
  }
}

// Clear context focus on blur (unless focus moved back into grid/dialog)
const onContextBlur = () => {
  setTimeout(() => {
    if (_suppressBlurClear.value) return
    const active = document.activeElement as HTMLElement | null
    if (active && (active.closest('.param-grid') || active.closest('.grid-container') || active.closest('.grid-card'))) {
      return
    }
    focusedCell.value = { type: null, targetArray: null, index: null, constraints: null }
  }, 0)
}

// Document-level click handler to clear focus when clicking outside the grid
let _docMouseDownHandler: ((e: MouseEvent) => void) | null = null
const addDocumentClickHandler = () => {
  if (_docMouseDownHandler) return
  _docMouseDownHandler = (e: MouseEvent) => {
    const t = e.target as HTMLElement | null
    if (!t) return
    if (t.closest('.param-grid') || t.closest('.grid-container') || t.closest('.grid-card') || t.closest('.open-param-gen-btn')) return
    focusedCell.value = { type: null, targetArray: null, index: null, constraints: null }
  }
  document.addEventListener('mousedown', _docMouseDownHandler)
}
const removeDocumentClickHandler = () => {
  if (!_docMouseDownHandler) return
  document.removeEventListener('mousedown', _docMouseDownHandler)
  _docMouseDownHandler = null
}

// attach/remove listener while the polyphonic dialog is open
watch(() => music.value.setDataDialog, (open) => {
  if (open) addDocumentClickHandler()
  else removeDocumentClickHandler()
})

import { onBeforeUnmount } from 'vue'
onBeforeUnmount(() => {
  removeDocumentClickHandler()
})

// ★追加: 生成ダイアログオープン
const openParamGenDialog = () => {
  const { type, targetArray, index, stepIdx, constraints } = focusedCell.value || {}
  if (!type) return

  let currentVal = 0
  if (type === 'simple') {
    currentVal = targetArray && targetArray[index] !== undefined ? targetArray[index] : 0
    // デフォルトステップ数: 残り全部
    paramGen.value.steps = Math.max(1, (targetArray ? targetArray.length : 1) - index)
  } else if (type === 'context') {
    // Contextの場合は3次元配列から値を取得
    const ctx = polyParams.value.initial_context
    if (ctx[stepIdx] && ctx[stepIdx][focusedCell.streamIdx]) {
       currentVal = ctx[stepIdx][focusedCell.streamIdx][focusedCell.dimIdx]
    }
    paramGen.value.steps = Math.max(1, ctx.length - stepIdx)
  }

  // capture minimal snapshot (identifiers, not deep-copy of array) so applyGeneratedParams
  // can resolve the real target array later even if focus is lost
  paramGenTarget.value = {
    type: focusedCell.value.type,
    keyName: focusedCell.value.keyName || null,
    index: focusedCell.value.index,
    streamIdx: focusedCell.value.streamIdx,
    dimIdx: focusedCell.value.dimIdx,
    stepIdx: focusedCell.value.stepIdx,
    constraints: focusedCell.value.constraints || null
  }

  // 初期値設定
  paramGen.value.start = currentVal
  paramGen.value.end = constraints.max
  paramGen.value.randMin = constraints.min
  paramGen.value.randMax = constraints.max

  paramGenDialog.value = true
}

// ★追加: パラメータ生成実行
const applyGeneratedParams = () => {
  // prefer live focusedCell, but fall back to the snapshot captured when opening dialog
  const live = focusedCell.value || {}
  const snap = paramGenTarget.value || {}
  const use = (live && live.type) ? live : snap
  const type = use.type
  if (!type) return

  const { steps, mode, start, end, curve, randMin, randMax } = paramGen.value

  // resolve indices/constraints
  const index = use.index
  const streamIdx = use.streamIdx
  const dimIdx = use.dimIdx
  const stepIdx = use.stepIdx
  const constraints = use.constraints || {}

  // safe constraints defaults
  const safeConstraints = {
    min: Number.NEGATIVE_INFINITY,
    max: Number.POSITIVE_INFINITY,
    isInt: false,
    ...(constraints || {})
  }

  // resolve targetArray: prefer live reference, otherwise resolve by saved keyName
  let targetArray = (live && live.targetArray) ? live.targetArray : null
  if (!targetArray && snap && snap.keyName) {
    targetArray = polyParams.value[snap.keyName] || null
  }

  // 配列拡張判定
  if (type === 'simple') {
    const requiredLen = (index || 0) + steps
    if (requiredLen > polyParams.value.stream_counts.length) {
      newStepCount.value = requiredLen
      updateStepCount()
    }
  } else if (type === 'context') {
    const requiredLen = (stepIdx || 0) + steps
    if (requiredLen > polyParams.value.initial_context.length) {
      contextStepCount.value = requiredLen
      updateContextSteps()
    }
  }

  // 値の生成と適用
  for (let i = 0; i < steps; i++) {
    let val = 0
    if (mode === 'transition') {
      const t = steps > 1 ? i / (steps - 1) : 1
      let easedT = t
      if (curve === 'easeInQuad') easedT = t * t
      if (curve === 'easeOutQuad') easedT = t * (2 - t)
      if (curve === 'easeInOutQuad') easedT = t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t

      val = start + (end - start) * easedT
    } else {
      val = randMin + Math.random() * (randMax - randMin)
    }

    // 丸め & クランプ (use safeConstraints)
    if (safeConstraints.isInt) {
      val = Math.round(val)
    } else {
      val = Number(val.toFixed(2))
    }
    if (val < safeConstraints.min) val = safeConstraints.min
    if (val > safeConstraints.max) val = safeConstraints.max

    // 値セット
    if (type === 'simple') {
      if (targetArray && typeof index === 'number' && targetArray[index + i] !== undefined) {
        targetArray[index + i] = val
      }
    } else if (type === 'context') {
      const targetStep = polyParams.value.initial_context[(stepIdx || 0) + i]
      if (targetStep && typeof streamIdx === 'number') {
        targetStep[streamIdx][dimIdx] = val
      }
    }
  }

  // clear snapshot after applying
  paramGenTarget.value = null

  if (type === 'context') {
    polyParams.value.initial_context_json = JSON.stringify(polyParams.value.initial_context, null, 2)
  }

  paramGenDialog.value = false
}

const generatePolyphonic = () => {
  subscribeToProgress()
  music.value.loading = true

  const parseArr = (str) => Array.isArray(str) ? str : str.split(',').map(Number)

  const payload = {
    job_id: jobId.value,
    stream_counts: parseArr(polyParams.value.stream_counts),
    initial_context: polyParams.value.initial_context,
  }

  dimensions.forEach(dim => {
    payload[`${dim.key}_global`] = parseArr(polyParams.value[`${dim.key}_global`])
    payload[`${dim.key}_ratio`] = parseArr(polyParams.value[`${dim.key}_ratio`])
    payload[`${dim.key}_tightness`] = parseArr(polyParams.value[`${dim.key}_tightness`])
    payload[`${dim.key}_conc`] = parseArr(polyParams.value[`${dim.key}_conc`])
  })

  axios.post('/api/web/time_series/generate_polyphonic', { generate_polyphonic: payload })
    .then(response => {
      console.log('Generated:', response.data)
      const rawTimeSeries = response.data.timeSeries
      convertResponseToTracks(rawTimeSeries)
      renderPolyphonicAudio(rawTimeSeries)

    })
    .catch(error => {
      console.error(error)
      music.value.loading = false
    })
}

const convertResponseToTracks = (timeSeries) => {
  console.log("Converting Response:", timeSeries);
  if (!timeSeries || timeSeries.length === 0) { console.warn("TimeSeries is empty"); return; }

  const maxStreams = Math.max(...timeSeries.map(step => step.length))
  const newTracksForUi = []
  const newTracksForMidi = []
  const TICKS_PER_STEP = 120

  music.value.ticksPerBeat = 480
  music.value.bpm = 120
  music.value.secondsPerTick = 60 / music.value.bpm / music.value.ticksPerBeat

  for (let s = 0; s < maxStreams; s++) {
    const midiNotesStr = []
    const durationsStr = []
    const velocitiesStr = []
    const notesForDrawing = []
    const color = getStreamColor(s)
    let currentTick = 0

    timeSeries.forEach(step => {
      const voice = step[s]
      if (voice) {
        const [oct, note, vol, bri, hrd, tex] = voice
        const midiNoteNum = (oct + 1) * 12 + note

        midiNotesStr.push(midiNoteNum)
        durationsStr.push(4)
        velocitiesStr.push(vol)

        if (vol > 0.01) {
          notesForDrawing.push({ midi: midiNoteNum, ticks: currentTick, durationTicks: TICKS_PER_STEP, velocity: vol })
        }
      } else {
        midiNotesStr.push(0); durationsStr.push(4); velocitiesStr.push(0);
      }
      currentTick += TICKS_PER_STEP
    })

    newTracksForUi.push({
      name: `Stream ${s + 1}`,
      midiNoteNumbers: midiNotesStr.join(','),
      durations: durationsStr.join(','),
      velocities: velocitiesStr.join(','),
      color: color,
      brightness: timeSeries[timeSeries.length-1][s]?.[3] || 0.5,
      hardness:   timeSeries[timeSeries.length-1][s]?.[4] || 0.5,
      texture:    timeSeries[timeSeries.length-1][s]?.[5] || 0.0,
      resonance:  0.2
    })
    newTracksForMidi.push({ color: color, notes: notesForDrawing })
  }
  music.value.tracks = newTracksForUi
  music.value.midiData = { tracks: newTracksForMidi }
}

const getStreamColor = (index) => {
  const hue = Math.floor((index * 137.508) % 360);
  return `hsl(${hue}, 75%, 45%)`;
}

const renderPolyphonicAudio = (timeSeries) => {
  progress.value.status = 'rendering'
  const stepDuration = 60.0 / music.value.bpm / 4.0
  axios.post('/api/web/supercolliders/render_polyphonic', {
    time_series: timeSeries, step_duration: stepDuration
  }).then(response => {
    const { sound_file_path, audio_data } = response.data
    music.value.soundFilePath = sound_file_path
    const binary = atob(audio_data)
    const len = binary.length
    const bytes = new Uint8Array(len)
    for (let i = 0; i < len; i++) bytes[i] = binary.charCodeAt(i)
    const blob = new Blob([bytes.buffer], { type: "audio/wav" })
    const url = URL.createObjectURL(blob)
    audio.value = new Audio(url)
    audio.value.addEventListener('ended', () => nowPlaying.value = false)
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
