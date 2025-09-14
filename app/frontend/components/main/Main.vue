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
        <v-col class="v-col-auto" v-if="selectedMode === 'Clustering'">
          <v-btn @click="analyse.setDataDialog = true">analyse</v-btn>
          <v-dialog width="1000" v-model="analyse.setDataDialog" >
            <v-form v-model='analyse.valid' fast-fail ref="form">
              <v-card>
                <v-card-title>
                  <v-row>
                    <v-col cols="5">
                      <div class="text-h4 d-flex align-center fill-height">Clustering Analyse</div>
                    </v-col>
                    <v-col cols="7">
                      <v-file-input
                      label="upload json file"
                      accept=".json"
                      prepend-icon="mdi-upload"
                      v-model="selectedFileAnalyse"
                      @change="onFileSelected"
                    ></v-file-input>
                    </v-col>
                  </v-row>
                </v-card-title>
                <v-card-text>
                  <v-row>
                    <v-col cols="12">
                      <v-textarea
                      placeholder="please set timeseries (like 1,2,3,4,5)"
                      required
                      v-model='analyse.timeSeries'
                      label="timeseries"
                      rows="1"
                      :rules="analyse.timeSeriesRules"
                    ></v-textarea>
                    </v-col>
                  </v-row>
                  <v-row>
                    <v-col cols="6">
                      <v-card>
                        <v-card-title>
                          generate randoms
                        </v-card-title>
                        <v-card-text>
                          <v-row>
                            <v-col cols="3">
                              <v-text-field
                                label="min"
                                type="number"
                                v-model="analyse.random.min"
                                min="1"
                              ></v-text-field>
                            </v-col>
                            <v-col cols="3">
                              <v-text-field
                                label="max"
                                type="number"
                                v-model="analyse.random.max"
                                :min="analyse.random.min"
                                :max="timeseriesMax"
                              ></v-text-field>
                            </v-col>
                            <v-col cols="3">
                              <v-text-field
                                label="length"
                                type="number"
                                v-model="analyse.random.length"
                                min="3"
                                max="2000"
                              ></v-text-field>
                            </v-col>
                            <v-col cols="3">
                              <v-btn :disabled='!analyse.random.max || !analyse.random.min || !analyse.random.length' @click="setRandoms">set</v-btn>
                            </v-col>
                          </v-row>
                        </v-card-text>
                      </v-card>
                    </v-col>
                    <v-col>
                      <v-row>
                        <v-col cols="4">
                          <v-text-field
                            label="merge threshold ratio"
                            type="number"
                            v-model="analyse.mergeThresholdRatio"
                            min="0"
                            max="1"
                            step="0.01"
                          ></v-text-field>
                        </v-col>
                        <v-col cols="4">
                          <v-btn :disabled='!analyse.valid' @click="analyseTimeseries" :loading="analyse.loading">Submit</v-btn>
                          <span v-if="progress.status == 'start' || progress.status == 'progress'">{{progress.percent}}%</span>
                        </v-col>
                      </v-row>
                    </v-col>
                  </v-row>
                  <v-row>
                    <v-col cols="12">
                      <div class="text-h4 d-flex align-center fill-height">Timeseries to music-element</div>
                    </v-col>
                  </v-row>
                  <v-row>
                    <v-col cols="2">
                      <v-btn
                        @click="onClickAddTrack()"
                      >
                        Add Track
                      </v-btn>
                    </v-col>

                    <v-col cols="2">
                      <v-select
                        label="tracks"
                        :items="music.tracks.map(t => t.name)"
                        v-model="analyse.selectedTrackName"
                      ></v-select>
                    </v-col>
                    <v-col cols="3">
                      <v-select
                        label="music-elements"
                        :items="analyse.musicElements"
                        v-model="analyse.selectedMusicElement"
                      ></v-select>
                    </v-col>
                    <v-col cols="1">
                      <v-btn @click="setTimeSeriesToMusicElement">set</v-btn>
                    </v-col>
                    <v-col cols="4">
                      <v-btn @click="closeAnalyseAndOpenMusicGenerate">open music-generate dialog</v-btn>

                    </v-col>
                  </v-row>
                </v-card-text>
              </v-card>
            </v-form>
          </v-dialog>
          <v-btn @click="generate.setDataDialog = true">generate</v-btn>
          <v-dialog width="1000" v-model="generate.setDataDialog" >
            <v-form v-model='generate.valid' fast-fail ref="form">
              <v-card>
                <v-card-title>
                  <v-row>
                    <v-col cols="5">
                      <div class="text-h4 d-flex align-center fill-height">Clustering Generate</div>
                    </v-col>
                    <v-col cols="7">
                      <v-file-input
                      label="upload json file"
                      accept=".json"
                      prepend-icon="mdi-upload"
                      v-model="selectedFileGenerate"
                      @change="onFileSelected"
                    ></v-file-input>
                    </v-col>
                  </v-row>
                </v-card-title>
                <v-card-text>
                  <v-row>
                    <v-col cols="3">
                      <v-select
                        label="use musical-feature"
                        :items="generate.useMusicalFeatures"
                        v-model="generate.selectedUseMusicalFeature"
                      ></v-select>
                    </v-col>
                  </v-row>
                  <v-row>
                    <v-col>
                      <v-textarea
                        placeholder="please set the first elements of the time series. (like 0,1,2,3,4,5)"
                        required
                        v-model='generate.firstElements'
                        label="first elements"
                        rows="1"
                        :rules="generate.firstElementsRules"
                      ></v-textarea>
                    </v-col>
                  </v-row>
                  <template v-if="generate.selectedUseMusicalFeature === 'dissonancesOutline'">
                    <v-row>
                      <v-col cols="10">
                        <v-textarea
                          placeholder="please set the dissonance transition. (like 1,2,3,4,5)"
                          v-model='generate.dissonance.transition'
                          label="dissonance transition(optional)"
                          rows="1"
                          :rules="generate.dissonance.transitionRules"
                        ></v-textarea>
                      </v-col>
                      <v-col cols="2">
                        <v-text-field
                          label="dissonance range"
                          type="number"
                          v-model="generate.dissonance.range"
                          min="1"
                        ></v-text-field>
                      </v-col>
                    </v-row>
                    <v-row>
                      <v-col>
                        <v-textarea
                          placeholder="please set the duration transition. (like 1,1,2,1,1,2)"
                          v-model='generate.dissonance.durationTransition'
                          label="duration transition"
                          rows="1"
                          :rules="durationTransitionRules"
                        ></v-textarea>
                      </v-col>
                    </v-row>
                  </template>
                  <template v-if="generate.selectedUseMusicalFeature === 'durationsOutline'">
                    <v-row>
                      <v-col cols="10">
                        <v-textarea
                          placeholder="please set the duration outline-transition. (like 11,11,11,0,0,0,0,0)"
                          v-model='generate.duration.outlineTransition'
                          label="duration outline-transition(optional)"
                          rows="1"
                          :rules="generate.duration.outlineRules"
                        ></v-textarea>
                      </v-col>
                      <v-col cols="2">
                        <v-text-field
                          label="duration range"
                          type="number"
                          v-model="generate.duration.outlineRange"
                          min="1"
                        ></v-text-field>
                      </v-col>
                    </v-row>
                  </template>
                  <v-row>
                    <v-col>
                      <v-textarea
                        placeholder="please set the complexity-ranking transition. (like 1,2,3,4,5)"
                        required
                        v-model='generate.complexityTransition'
                        label="complexity transition"
                        rows="1"
                        :rules="complexityTransitionRules"
                      ></v-textarea>
                    </v-col>
                  </v-row>
                  <v-row>
                    <v-col cols="8">
                      <v-card>
                        <v-card-title>
                          generate linear integers
                        </v-card-title>
                        <v-card-text>
                          <v-row>
                            <v-col>
                              <v-text-field
                                label="min"
                                type="number"
                                v-model="generate.linear.start"
                                min="1"
                              ></v-text-field>
                            </v-col>
                            <v-col>
                              <v-text-field
                              label="max"
                              type="number"
                              v-model="generate.linear.end"
                              :max="timeseriesMax"
                            ></v-text-field>
                            </v-col>
                            <v-col>
                              <v-text-field
                                label="length"
                                type="number"
                                v-model="generate.linear.length"
                                min="3"
                                max="2000"
                              ></v-text-field>
                            </v-col>
                            <v-col>
                              <v-btn :disabled='!generate.linear.start || !generate.linear.end || !generate.linear.length' @click="setLinearIntegers('overwrite')">overwrite</v-btn>
                            </v-col>
                            <v-col>
                              <v-btn :disabled='!generate.linear.start || !generate.linear.end || !generate.linear.length' @click="setLinearIntegers('add')">add</v-btn>
                            </v-col>
                          </v-row>
                        </v-card-text>
                      </v-card>
                    </v-col>
                    <v-col cols="4">
                      <v-card>
                        <v-card-title>
                          available range
                        </v-card-title>
                        <v-card-text>
                          <v-row>
                            <v-col>
                              <v-text-field
                              label="min"
                              type="number"
                              v-model="generate.rangeMin"
                              min="1"
                            ></v-text-field>
                            </v-col>
                            <v-col>
                              <v-text-field
                              label="max"
                              type="number"
                              v-model="generate.rangeMax"
                              :min="generate.rangeMin"
                              :max="timeseriesMax"
                            ></v-text-field>
                            </v-col>
                          </v-row>
                        </v-card-text>
                      </v-card>
                    </v-col>
                    <v-col cols="4">
                      <v-row>
                        <v-col>
                          <v-text-field
                            label="merge threshold ratio"
                            type="number"
                            v-model="generate.mergeThresholdRatio"
                            min="0"
                            max="1"
                            step="0.01"
                          ></v-text-field>
                        </v-col>
                        <v-col>
                          <v-btn :disabled='!generate.valid' @click="generateTimeseries" :loading="generate.loading">Submit</v-btn>
                          <span v-if="progress.status == 'start' || progress.status == 'progress'">{{progress.percent}}%</span>
                        </v-col>
                      </v-row>
                    </v-col>
                  </v-row>
                </v-card-text>
              </v-card>
            </v-form>
          </v-dialog>
        </v-col>
        <v-col class="v-col-auto" v-if="selectedMode === 'Music'">
          <v-btn @click="music.setDataDialog = true">generate</v-btn>
          <v-dialog width="1900" v-model="music.setDataDialog" >
            <v-form v-model='music.valid' fast-fail ref="form">
              <v-card>
                <v-card-title>
                  <v-row>
                    <v-col cols="5">
                      <div class="text-h4 d-flex align-center fill-height">Music Generate</div>
                    </v-col>
                    <!-- <v-col cols="7">
                      <v-file-input
                        label="Set MIDI file"
                        accept=".midi,.mid"
                        prepend-icon="mdi-upload"
                        v-model="music.midi"
                        @change="onMidiSelected"
                      />
                    </v-col> -->
                  </v-row>
                </v-card-title>
                <v-card-text>
                  <v-row>
                    <v-col cols="2">
                      <v-btn
                        @click="onClickAddTrack()"
                      >
                        Add Track
                      </v-btn>
                    </v-col>
                    <v-col cols="2">
                      <v-text-field
                        label="bpm"
                        type="number"
                        v-model="music.bpm"
                        min="30"
                        max="180"
                      ></v-text-field>
                    </v-col>
                    <v-col cols="2">
                      <v-text-field
                        label="velocity"
                        type="number"
                        v-model="music.velocity"
                        min="0"
                        max="1"
                        step="0.01"
                      ></v-text-field>
                    </v-col>
                    <v-col cols="2">
                      <v-btn @click="generateMidi" :loading="music.loading">generate</v-btn>
                    </v-col>
                  </v-row>
                  <template v-for='track in music.tracks'>
                    <v-row>
                      <v-col cols="1">
                        <v-text-field
                        placeholder="name"
                        required
                        v-model='track.name'
                        label="name"
                        ></v-text-field>
                      </v-col>
                      <v-col cols="5">
                        <v-row>
                          <v-col cols="2">
                            <v-text-field
                              label="harmRichness"
                              type="number"
                              v-model="track.harmRichness"
                              min="0"
                              max="1"
                              step="0.01"
                            ></v-text-field>
                          </v-col>
                          <v-col cols="2">
                            <v-text-field
                              label="brightness"
                              type="number"
                              v-model="track.brightness"
                              min="0"
                              max="1"
                              step="0.01"
                            ></v-text-field>
                          </v-col>
                          <v-col cols="2">
                            <v-text-field
                              label="noiseContent"
                              type="number"
                              v-model="track.noiseContent"
                              min="0"
                              max="1"
                              step="0.01"
                            ></v-text-field>
                          </v-col>
                          <v-col cols="2">
                            <v-text-field
                              label="formantChar"
                              type="number"
                              v-model="track.formantChar"
                              min="0"
                              max="1"
                              step="0.01"
                            ></v-text-field>
                          </v-col>
                          <v-col cols="2">
                            <v-text-field
                              label="inharmonicity"
                              type="number"
                              v-model="track.inharmonicity"
                              min="0"
                              max="1"
                              step="0.01"
                            ></v-text-field>
                          </v-col>
                          <v-col cols="2">
                            <v-text-field
                              label="resonance"
                              type="number"
                              v-model="track.resonance"
                              min="0"
                              max="1"
                              step="0.01"
                            ></v-text-field>
                          </v-col>
                        </v-row>
                      </v-col>
                      <v-col cols="3">
                        <v-textarea
                        placeholder="please set durations (like 8,4,4)"
                        required
                        v-model='track.durations'
                        label="durations"
                        rows="1"
                        :rules="track.durationRules"
                      ></v-textarea>
                      </v-col>
                      <v-col cols="3">
                        <v-textarea
                        placeholder="please set midi note numbers (like 60,62,64)"
                        required
                        v-model='track.midiNoteNumbers'
                        label="midiNoteNumbers"
                        rows="1"
                        :rules="track.midiNoteNumbersRules"
                      ></v-textarea>
                      </v-col>
                    </v-row>
                  </template>
                </v-card-text>
              </v-card>
            </v-form>
          </v-dialog>
          <!-- <v-btn @click='playNotes'>
            <v-icon v-if='nowPlaying'>mdi-stop</v-icon>
            <v-icon v-else>mdi-music</v-icon>
          </v-btn> -->
          <v-btn @click='switchStartOrStopSound()'>
            <v-icon v-if='nowPlaying'>mdi-stop</v-icon>
            <v-icon v-else>mdi-music</v-icon>
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
      <div v-if="selectedMode === 'Clustering'">
        <v-row no-gutters v-if='showTimeseriesChart'>
          <v-col>
            <div class='text-h6 ml-3 mb-2'>
              <v-row>
                <v-col cols="3">
                  <span class="mr-2">Timeseries</span>
                  <small v-if="analyse.processingTime !== null">Processing Time: {{ analyse.processingTime }} sec. </small>
                </v-col>
                <v-col cols="2">
                  <v-btn @click="saveToFile" class="d-flex align-center fill-height">
                    <v-icon>mdi-download</v-icon>
                    <span>Download</span>
                  </v-btn>
                </v-col>
              </v-row>
            </div>
            <div id='timeseries' style='height: 20vh;'></div>
          </v-col>
        </v-row>
        <v-row no-gutters>
          <v-col>
            <template v-if='showTimeseriesComplexityChart'>
              <div class='text-h6 ml-3 mb-2'>Complexity</div>
              <div id='timeseries-complexity' style='height: 20vh;'></div>
            </template>
          </v-col>
        </v-row>
        <v-row no-gutters >
          <v-col>
            <template v-if='showTimeline'>
              <div class='text-h6 ml-3 mb-2'>Clusters</div>
              <div id='timeline' style='height: 70vh;'></div>
            </template>
          </v-col>
        </v-row>
      </div>
      <div v-if="selectedMode === 'Music'">
        <v-row no-gutters>
          <v-col>
            <Music ref="musicComponent" :midiData='music.midiData' :secondsPerTick="music.secondsPerTick"></Music>
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

import { onMounted, computed, nextTick, ref, watch, useTemplateRef } from 'vue'
import * as Tone from 'tone'
import axios from 'axios'
import { v4 as uuidv4 } from 'uuid'
import { ScoreEntry } from '../../types/types';
import { MidiNote } from '../../types/types';
import { useJobChannel } from '../../composables/useJobChannel'
import Music from '../../components/music/Music.vue';
import Fft from '../../components/audio/Fft.vue';
import { Midi } from '@tonejs/midi'
import Decimal from 'decimal.js'
const timeseriesMax = ref(100)
const modes = ref(['Clustering', 'Music'])
const selectedMode = ref('Clustering')
type Cluster = {
  si: number[]; // subsequence indexes
  cc: { [childId: string]: Cluster }; // child clusters
};
type Clusters = {
  [clusterId: string]: Cluster;
};

import type { ComponentPublicInstance } from 'vue'
const musicComponent = ref<ComponentPublicInstance<{ start: () => void; stop: () => void }> | null>(null)
const analyse = ref<{
  timeSeries: string;
  clusteredSubsequences: [string, string, number, number][];
  timeSeriesChart: (number | null | string)[][];
  setDataDialog: boolean;
  loading: boolean;
  timeSeriesRules: ((v: any) => true | string)[];
  valid: boolean;
  random: {
    min: number | null;
    max: number | null;
    length: number | null;
  };
  mergeThresholdRatio: number;
  clusters: Clusters;
  musicElements: string[];
  selectedMusicElement: string;
  selectedTrackName: string | null;
  processingTime: null | number;
}>({
  timeSeries: '',
  clusteredSubsequences: [],
  timeSeriesChart: [],
  setDataDialog: false,
  loading: false,
  timeSeriesRules: [
    v => !!v || 'required',
    v => (v && String(v).split(',').every(n => !isNaN(Number(n)) && n !== "")) || 'must be comma separated numbers',
    v => (v && String(v).split(',').filter(n => n !== "").length >= 2) || 'must have at least 2 numbers',
    v => (v && String(v).split(',').length <= 2000) || 'must have no more than 2000 numbers',
    v => (v && String(v).split(',').every(n => Number.isInteger(Number(n)) && n.trim() !== "")) || 'must be integers',
    v => (v && String(v).split(',').every(n => Number(n) <= 100)) || 'numbers must be 100 or less'
  ],
  valid: false,
  random: {
    min: null,
    max: null,
    length: null
  },
  mergeThresholdRatio: 0.02,
  clusters: {},
  musicElements: ['durations', 'midiNoteNumbers'],
  selectedMusicElement: 'durations',
  selectedTrackName: null,
  processingTime: null
})
const complexityTransitionRules = computed(() => [
    v => !!v || 'required',
    v => (v && String(v).split(',').every(n => !isNaN(Number(n)) && n !== "")) || 'must be comma separated numbers',
    v => (v && String(v).split(',').filter(n => n !== "").length >= 1) || 'must have at least 1 numbers',
    v => (v && String(v).split(',').length <= 2000) || 'must have no more than 2000 numbers',
    v => (v && String(v).split(',').every(n => Number.isInteger(Number(n)) && n.trim() !== "")) || 'must be integers',
    v => (v && String(v).split(',').every(n => Number(n) <= generate.value.rangeMax)) || 'numbers must be availange-range-max or less'
  ]);
const durationTransitionRules = computed(() =>  [
    v => (v && String(v).split(',').every(n => !isNaN(Number(n)) && n !== "")) || 'must be comma separated numbers',
    v => (v && String(v).split(',').filter(n => n !== "").length >= 1) || 'must have at least 1 numbers',
    v => (v && String(v).split(',').length <= 2000) || 'must have no more than 2000 numbers',
    v => (v && String(v).split(',').length == generate.value.complexityTransition.split(',').length + generate.value.firstElements.split(',').length) || 'must have same length as complexity transition + first elements',
    v => (v && String(v).split(',').every(n => Number.isInteger(Number(n)) && n.trim() !== "")) || 'must be integers',
    v => (v && String(v).split(',').every(n => Number(n) >= 1)) || 'numbers must be 1 or more',
    v => (v && String(v).split(',').every(n => Number(n) <= 32)) || 'numbers must be 32 or less',
]);
const generate = ref({
  setDataDialog: false,
  rangeMin: 0,
  rangeMax: 11,
  complexityTransition: '',
  firstElements: '',
  firstElementsRules: [
    v => !!v || 'required',
    v => (v && String(v).split(',').every(n => !isNaN(Number(n)) && n !== "")) || 'must be comma separated numbers',
    v => (v && String(v).split(',').filter(n => n !== "").length >= 1) || 'must have at least 1 numbers',
    v => (v && String(v).split(',').length >= 3) || 'must have at least 3 numbers',
    v => (v && String(v).split(',').every(n => Number.isInteger(Number(n)) && n.trim() !== "")) || 'must be integers',
    v => (v && String(v).split(',').every(n => Number(n) <= 100)) || 'numbers must be 100 or less'
  ],
  useMusicalFeatures: ['', 'durationsOutline', 'dissonancesOutline'],
  selectedUseMusicalFeature: '',
  dissonance: {
    transition: '',
    transitionRules: [
      v => (v && String(v).split(',').every(n => !isNaN(Number(n)) && n !== "")) || 'must be comma separated numbers',
      v => (v && String(v).split(',').length >= 3) || 'must have at least 3 numbers',
      v => (v && String(v).split(',').every(n => Number.isInteger(Number(n)) && n.trim() !== "")) || 'must be integers',
      v => (v && String(v).split(',').every(n => Number(n) <= 100)) || 'numbers must be 100 or less'
    ],
    range: 2,
    durationTransition: '',
  },
  duration: {
    outlineTransition: '',
    outlineRange: 2,
    outlineRules: [
      v => (v && String(v).split(',').every(n => !isNaN(Number(n)) && n !== "")) || 'must be comma separated numbers',
      v => (v && String(v).split(',').length >= 3) || 'must have at least 3 numbers',
      v => (v && String(v).split(',').every(n => Number.isInteger(Number(n)) && n.trim() !== "")) || 'must be integers',
      v => (v && String(v).split(',').every(n => Number(n) <= 100)) || 'numbers must be 100 or less'
    ],
  },
  loading: false,
  valid: false,
  mergeThresholdRatio: 0.02,
  complexityTransitionChart: null,
  linear: {
    start: null,
    end: null,
    length: null
  },
  clusters: {}
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
let pitchMap = ref({
  12:'C0',13:'C#0',14:'D0',15:'D#0',16:'E0',17:'F0',18:'F#0',19:'G0',20:'G#0',21:'A0',22:'A#0',23:'B0',
  24:'C1',25:'C#1',26:'D1',27:'D#1',28:'E1',29:'F1',30:'F#1',31:'G1',32:'G#1',33:'A1',34:'A#1',35:'B1',
  36:'C2',37:'C#2',38:'D2',39:'D#2',40:'E2',41:'F2',42:'F#2',43:'G2',44:'G#2',45:'A2',46:'A#2',47:'B2',
  48:'C3',49:'C#3',50:'D3',51:'D#3',52:'E3',53:'F3',54:'F#3',55:'G3',56:'G#3',57:'A3',58:'A#3',59:'B3',
  60:'C4',61:'C#4',62:'D4',63:'D#4',64:'E4',65:'F4',66:'F#4',67:'G4',68:'G#4',69:'A4',70:'A#4',71:'B4',
  72:'C5',73:'C#5',74:'D5',75:'D#5',76:'E5',77:'F5',78:'F#5',79:'G5',80:'G#5',81:'A5',82:'A#5',83:'B5',
  84:'C6',85:'C#6',86:'D6',87:'D#6',88:'E6',89:'F6',90:'F#6',91:'G6',92:'G#6',93:'A6',94:'A#6',95:'B6',
  96:'C7',97:'C#7',98:'D7',99:'D#7',100:'E7',101:'F7',102:'F#7',103:'G7',104:'G#7',105:'A7',106:'A#7',107:'B7',
})
let nowPlaying = ref(false)
const progress = ref({
  percent: 0,
  status: 'beforeStart'
})
const jobId = ref('')

let methodType = ref<"analyse" | "generate" | null>(null)
let selectedFileAnalyse = ref<File | null>(null)
let selectedFileGenerate = ref<File | null>(null)

// life cycle hook------------------------------------------------------------------------------

onMounted(() => {
  google.charts.load("current", {packages:["timeline", "corechart"]})
})

watch(selectedMode, async (newVal) => {
  if (newVal === 'Clustering') {
    await nextTick()
    if(showTimeseriesChart.value){
      drawTimeSeries('timeseries', analyse.value.timeSeriesChart)
    }
    if(showTimeline.value){
      drawTimeline()
    }
    if(showTimeseriesComplexityChart.value){
      drawTimeSeriesComplexity('timeseries-complexity', generate.value.complexityTransitionChart)
    }
  }
})

// life cycle hook------------------------------------------------------------------------------
const setRandoms = () => {
  const { min, max, length } = analyse.value.random;

  if (min !== null && max !== null && length !== null) {
    const minParsed = parseInt(String(min));
    const maxParsed = parseInt(String(max));
    const len = parseInt(String(length));

    analyse.value.timeSeries = [...Array(len)]
      .map(() => Math.floor(Math.random() * (maxParsed - minParsed + 1)) + minParsed)
      .join(',');
  }
}

const setLinearIntegers = (setType) => {
  const linearIntegerArray = createLinearIntegerArray(
    generate.value.linear.start,
    generate.value.linear.end,
    generate.value.linear.length
  ).join(',')
  if(setType === 'overwrite'){
    generate.value.complexityTransition = linearIntegerArray
  }else if(setType === 'add'){
    if(generate.value.complexityTransition === ''){
      generate.value.complexityTransition = linearIntegerArray
    }else{
      generate.value.complexityTransition += (',' + linearIntegerArray)
    }
  }
}
const createLinearIntegerArray = (start, end, count) => {
  const result: number[] = []
  const step = (end - start) / (count - 1) // ステップを計算

  for (let i = 0; i < count; i++) {
      const value = parseInt(start) + step * i
      // start < end の場合は Math.ceil、start > end の場合は Math.floor を使う
      if (start < end) {
          result.push(Math.ceil(value)) // 小数点を切り上げ
      } else {
          result.push(Math.floor(value)) // 小数点を切り捨て
      }
  }
  return result
}

const subscribeToProgress = () =>{
  jobId.value = uuidv4()

  progress.value.percent = 0

  const { unsubscribe } = useJobChannel(jobId.value, (data) => {
    progress.value.status = data.status
    progress.value.percent = data.progress

    if (data.status === 'done') {
      unsubscribe()
    }
  })
}

const analyseTimeseries = () => {
  methodType.value = 'analyse'
  subscribeToProgress()
  analyse.value.loading = true
  let data = {
    analyse: {
      time_series: analyse.value.timeSeries,
      merge_threshold_ratio: analyse.value.mergeThresholdRatio,
      job_id: jobId.value
    }
  }
  axios.post('/api/web/time_series/analyse', data)
  .then(response => {
      console.log(response)
      analyse.value.clusteredSubsequences = response.data.clusteredSubsequences
      analyse.value.timeSeriesChart = response.data.timeSeriesChart
      analyse.value.clusters = response.data.clusters
      analyse.value.loading = false
      analyse.value.setDataDialog = false
      showTimeseriesComplexityChart.value = false
      analyse.value.processingTime = response.data.processingTime
      drawTimeline()
      drawTimeSeries('timeseries', analyse.value.timeSeriesChart)
  })
  .catch(error => {
      console.log(error)
  })
}
const generateTimeseries = () => {
  methodType.value = 'generate'
  subscribeToProgress()
  generate.value.loading = true
  let data = { generate:
    {
      complexity_transition: generate.value.complexityTransition,
      range_min: generate.value.rangeMin,
      range_max: generate.value.rangeMax,
      first_elements: generate.value.firstElements,
      merge_threshold_ratio: generate.value.mergeThresholdRatio,
      job_id: jobId.value,
      dissonance: {
        transition: generate.value.dissonance.transition,
        duration_transition: generate.value.dissonance.durationTransition,
        range: generate.value.dissonance.range,
      },
      duration: {
        outline_transition: generate.value.duration.outlineTransition,
        outline_range: generate.value.duration.outlineRange,
      },
      selected_use_musical_feature: generate.value.selectedUseMusicalFeature,
    }
  }
  axios.post('/api/web/time_series/generate', data)
  .then(response => {
      console.log(response)
      analyse.value.clusteredSubsequences = response.data.clusteredSubsequences
      analyse.value.timeSeries = String(response.data.timeSeries)
      analyse.value.timeSeriesChart = response.data.timeSeriesChart
      generate.value.complexityTransitionChart = response.data.timeSeriesComplexityChart
      generate.value.clusters = response.data.clusters
      analyse.value.processingTime = response.data.processingTime
      drawTimeline()
      drawTimeSeries('timeseries', analyse.value.timeSeriesChart)
      drawTimeSeriesComplexity('timeseries-complexity', generate.value.complexityTransitionChart)
      generate.value.loading = false
      generate.value.setDataDialog = false
  })
  .catch(error => {
      console.log(error)
  })
}

const drawTimeSeries = (elementId, drawData) => {
  showTimeseriesChart.value = true
  nextTick(() => {
    drawScatterChart(elementId, drawData, 200)
  })
}
const drawTimeSeriesComplexity = (elementId, drawData) => {
  showTimeseriesComplexityChart.value = true
  nextTick(() => {
    drawScatterChart(elementId, drawData, 100)
  })
}

const drawScatterChart = (elementId, drawData, height) => {
  const onlyData = drawData.map(data => data[1]).slice(1, drawData.length)
  const dataMin = Math.min(...onlyData)
  const dataMax = Math.max(...onlyData)
  const options = {
    pointSize: 20,
    'height': height,
    'width': window.innerWidth,
    isStacked: false,
    legend: 'none' as 'none' | google.visualization.ChartLegend,
    series: [
      {pointShape: 'square'},
      {pointShape: 'square'},
      {pointShape: 'square'},
    ],
    interpolateNulls:false,
    chartArea:{
      left:30,
      top:0,
      width:'100%',
      height:'100%',
      backgroundColor:{
        fill: 'white',
        fillOpacity: 100,
        strokeWidth: 10
      }
    },
    vAxis: {
      viewWindow: {
        min: dataMin,
        max: dataMax
      },
      ticks: [...Array(dataMax + 1)].map((_, i) => i + dataMin)
    }
  }
  const dataTable = new google.visualization.DataTable()
  dataTable.addColumn('string', 'index')
  dataTable.addColumn('number', 'value')
  dataTable.addColumn('number', 'selectedValue')
  dataTable.addColumn('number', 'playingValue')
  dataTable.addRows(drawData)
  const chart = new google.visualization.ScatterChart(document.getElementById(elementId) as HTMLElement)
  chart.draw(dataTable, options)
}

const drawTimeline = () => {
  if(analyse.value.clusteredSubsequences.length === 0){
    showTimeline.value = false
    return
  }
  showTimeline.value = true
  nextTick(() => {
    const container = document.getElementById('timeline')as HTMLElement;
    const chart = new google.visualization.Timeline(container)
    const dataTable = new google.visualization.DataTable()
    const options = {'height': 470, 'width': window.innerWidth, 'title': 'clustering'}
    dataTable.addColumn({ type: 'string', id: 'WindowSize' })
    dataTable.addColumn({ type: 'string', id: 'Cluster' })
    dataTable.addColumn({ type: 'number', id: 'Start' })
    dataTable.addColumn({ type: 'number', id: 'End' })
    dataTable.addRows(analyse.value.clusteredSubsequences)

    chart.draw(dataTable, options)
    google.visualization.events.addListener(chart, 'onmouseover', (e) => {
      onMouseoverCluster(e)
    })
  })
}

const onMouseoverCluster = (selected) => {
  let subsequencesIndexes: number[][] = []

  analyse.value.clusteredSubsequences.filter(subsequence =>
    subsequence[0] === analyse.value.clusteredSubsequences[selected['row']][0] && subsequence[1] === analyse.value.clusteredSubsequences[selected['row']][1]
  ).forEach(subsequence => {
    const startIndex = subsequence[2] / 1000
    const endIndex = subsequence[3] / 1000
    const len = endIndex - startIndex
    const indexes: number[] = new Array(len)
        .fill(null)
        .map((_, i) => i + startIndex)
    subsequencesIndexes.push(indexes)
  })
  let flattenSubsequencesIndexes: number[] = subsequencesIndexes.flat()
  let subsequencesInSameCluster: (number | null | string)[] = []
  analyse.value.timeSeriesChart.forEach((elm, index) => {
    subsequencesInSameCluster.push(flattenSubsequencesIndexes.includes(index) ? elm[1] : null)
  })
  analyse.value.timeSeriesChart.forEach((elm, index) => {
    if(elm.length === 4){
      elm[2] = subsequencesInSameCluster[index]
    }else if (elm.length === 3){
      elm[2] = subsequencesInSameCluster[index]
    }else if (elm.length === 2){
      elm.push(subsequencesInSameCluster[index])
    }

  })
  drawTimeSeries('timeseries', analyse.value.timeSeriesChart)
}

const onClickAddTrack = () => {
  music.value.tracks.push({
    name: getTrackId(),
    durations: '',
    durationRules: music.value.durationsRules,
    midiNoteNumbers: '',
    midiNoteNumbersRules: music.value.midiNoteNumbersRules,
    color: getRandomHexColor(),
    harmRichness: 0.0,
    brightness: 0.0,
    noiseContent: 0.0,
    formantChar: 0.0,
    inharmonicity: 0.0,
    resonance: 0.0
  })
}

const setTimeSeriesToMusicElement = () => {
  const track = music.value.tracks.find(t => t.name === analyse.value.selectedTrackName)
  if (!track) return

  if (analyse.value.selectedMusicElement === 'midiNoteNumbers') {
    track.midiNoteNumbers = analyse.value.timeSeries
  }else if(analyse.value.selectedMusicElement === 'durations'){
    track.durations = analyse.value.timeSeries
  }
}

const getRandomHexColor = () =>{
  return '#' + Math.floor(Math.random() * 16777215).toString(16).padStart(6, '0');
}

const getTrackId = () => {

  return (music.value.trackIdCounter += 1).toString()
}

const closeAnalyseAndOpenMusicGenerate = () => {
  analyse.value.setDataDialog = false
  selectedMode.value = 'Music'
  music.value.setDataDialog = true


}
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
        drawTimeline()
        drawTimeSeries('timeseries', analyse.value.timeSeriesChart)
      }else if(json.methodType === 'generate'){
        analyse.value = json.analyse
        generate.value = json.generate
        drawTimeline()
        drawTimeSeries('timeseries', analyse.value.timeSeriesChart)
        drawTimeSeriesComplexity('timeseries-complexity', generate.value.complexityTransitionChart)
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
  musicComponent.value?.stop()
  audio.value?.pause()
  audio.value.currentTime = 0;
}

const startPlayingSound = () => {
  nowPlaying.value = true
  audio.value?.play();
  if (musicComponent.value?.start) {
    musicComponent.value.start()
  }
}

const generateMidi = () => {
  music.value.loading = true
  const midi = new Midi()

  // テンポを指定
  midi.header.setTempo(music.value.bpm)

  // トラックを追加
  music.value.tracks.forEach(track => {
    const midiTrack = midi.addTrack()
    music.value.ticksPerBeat = music.value.ticksPerBeatDefault
    music.value.secondsPerTick = (60 / music.value.bpm) / music.value.ticksPerBeat
    const ticksPer16th = music.value.ticksPerBeat / 8 // 32分音符 = 60 ticks
    let currentTick = 0
    const durations = track.durations.split(',')
    const midiNoteNumbers = track.midiNoteNumbers.split(',')
    // ノートの数だけループ
    for (let i = 0; i < durations.length; i++) {
      const lengthIn16ths = parseInt(durations[i])         // 1〜32 の整数
      const noteNumber = parseInt(midiNoteNumbers[i])      // MIDI ノート番号

      const durationTicks = lengthIn16ths * ticksPer16th     // 実際のティック長さ

      midiTrack.addNote({
        midi: noteNumber,
        time: currentTick / music.value.ticksPerBeat,  // 秒ではなく「拍」で指定（Tone.js互換）
        duration: durationTicks / music.value.ticksPerBeat, // 同上
        velocity: 0.8 // 任意の音量（0〜1）
      })
      midiTrack['color'] = track.color // トラックの色を設定

      currentTick += durationTicks
    }
  })

  let data = {
    tracks: music.value.tracks
  }
  axios.post("/api/web/supercolliders/generate", data)
  .then(response => {
    const { sound_file_path, scd_file_path, audio_data } = response.data;

    // Base64データをデコードしてArrayBufferに変換
    console.log(audio_data)
    const binary = atob(audio_data);
    music.value.soundFilePath = sound_file_path
    music.value.scdFilePath = scd_file_path
    const len = binary.length;
    const bytes = new Uint8Array(len);
    for (let i = 0; i < len; i++) {
      bytes[i] = binary.charCodeAt(i);
    }

    const audioBlob = new Blob([bytes.buffer], { type: "audio/wav" });
    const url = URL.createObjectURL(audioBlob);

    audio.value = new Audio(url);
    music.value.midiData = midi
    music.value.loading = false
    music.value.setDataDialog = false
    cleanup()
  })
  .catch(error => console.error("音声生成エラー", error));
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

// deprecated------------------------------------------------------------------------------
// tone.js
const onMidiSelected = async () => {
  if (!music.value.midi) return

  const file = music.value.midi
  const arrayBuffer = await file.arrayBuffer()
  music.value.midiData = new Midi(arrayBuffer)

  music.value.ticksPerBeat = music.value.midiData.header.tempos?.[0]?.ppq ?? music.value.ticksPerBeatDefault
  music.value.bpm = music.value.midiData.header.tempos?.[0]?.bpm || music.value.bpmDefault
  music.value.secondsPerTick = (60 / music.value.bpm) / music.value.ticksPerBeat

  await nextTick()
  music.value.setDataDialog = false
}

const playNotes = () =>{
  nowPlaying.value ? stopPlayingNotes() : startPlayingNotes()
}
const stopPlayingNotes = () => {
  nowPlaying.value = false
  musicComponent.value?.stop()
  Tone.Transport.stop()
  Tone.Transport.cancel()
}

const startPlayingNotes = () => {
  nowPlaying.value = true
  const score: ScoreEntry[] = []

  // 各トラックごとに音符列を追加する
  for (const track of music.value.tracks) {
    const durations = track.durations.split(',').map(Number)
    const midiNoteNumbers = track.midiNoteNumbers.split(',').map(Number)
    let currentTimeInBeats = 0

    for (let i = 0; i < midiNoteNumbers.length; i++) {
      const midiNoteNumber = midiNoteNumbers[i]
      const pitch = pitchMap.value[midiNoteNumber]

      let setPitch: string
      let setVelocity: number
      if (pitch === undefined) {
        setPitch = 'C1'
        setVelocity = 0
      } else {
        setPitch = pitch
        setVelocity = music.value.velocity ?? 0.8 // トラックごとにvelocityを持たせたければここで分ける
      }

      const dur = durations[i] || 1
      const durationInBeats = Decimal.div(dur, 8)
      score.push({
        time: `${currentTimeInBeats}`,
        note: `${setPitch}`,
        duration: `${durationInBeats.toNumber()}`,
        velocity: setVelocity
      })

      currentTimeInBeats = Decimal.add(currentTimeInBeats, durationInBeats).toNumber()
    }
  }

  // Sampler は1つでよい（全トラック分鳴らす）
  const sampler = new Tone.Sampler({
    urls: {
      A0: "A0.mp3", C1: "C1.mp3", "D#1": "Ds1.mp3", "F#1": "Fs1.mp3",
      A1: "A1.mp3", C2: "C2.mp3", "D#2": "Ds2.mp3", "F#2": "Fs2.mp3",
      A2: "A2.mp3", C3: "C3.mp3", "D#3": "Ds3.mp3", "F#3": "Fs3.mp3",
      A3: "A3.mp3", C4: "C4.mp3", "D#4": "Ds4.mp3", "F#4": "Fs4.mp3",
      A4: "A4.mp3", C5: "C5.mp3", "D#5": "Ds5.mp3", "F#5": "Fs5.mp3",
      A5: "A5.mp3", C6: "C6.mp3", "D#6": "Ds6.mp3", "F#6": "Fs6.mp3",
      A6: "A6.mp3", C7: "C7.mp3", "D#7": "Ds7.mp3", "F#7": "Fs7.mp3",
      A7: "A7.mp3", C8: "C8.mp3"
    },
    baseUrl: "https://tonejs.github.io/audio/salamander/",
    onload: () => {
      const part = new Tone.Part((time, note) => {
        sampler.triggerAttackRelease(note.note, note.duration, time, note.velocity)
        if (musicComponent.value?.start) {
          musicComponent.value.start()
        }
      }, score)
      part.start(0)
      Tone.Transport.start()
    }
  }).toDestination()
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
</style>
