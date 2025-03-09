<template>
  <v-app>
    <v-app-bar app>
      <v-toolbar-title>Time series subsequence-clustering</v-toolbar-title>
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
            <h5>Generate(experimental)</h5>
            <ul class="custom-list">
              <li>under construction.</li>
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
      <v-btn @click="analyse.setDataDialog = true">analyse</v-btn>
      <v-dialog width="1000" v-model="analyse.setDataDialog" >
        <v-form v-model='analyse.valid' fast-fail ref="form">
          <v-card>
            <v-card-text>
              <v-row>
                <v-col cols="9">
                  <v-textarea
                  placeholder="please set timeseries (like 1,2,3,4,5)"
                  required
                  v-model='analyse.timeSeries'
                  label="timeseries"
                  rows="1"
                  :rules="analyse.timeSeriesRules"
                ></v-textarea>
                </v-col>
                <v-col cols="3">
                  <v-row>
                    <v-col>
                      <v-card>
                        <v-card-title>
                          generate randoms
                        </v-card-title>
                        <v-card-text>
                          <v-row>
                            <v-col>
                              <v-text-field
                                label="min"
                                type="number"
                                v-model="analyse.random.min"
                                min="1"
                              ></v-text-field>
                            </v-col>
                          </v-row>
                          <v-row>
                            <v-col>
                              <v-text-field
                                label="max"
                                type="number"
                                v-model="analyse.random.max"
                                :min="analyse.random.min"
                                :max="timeseriesMax"
                              ></v-text-field>
                            </v-col>
                          </v-row>
                          <v-row>
                            <v-col>
                              <v-text-field
                                label="length"
                                type="number"
                                v-model="analyse.random.length"
                                min="3"
                                max="2000"
                              ></v-text-field>
                            </v-col>
                          </v-row>
                          <v-row>
                            <v-col>
                              <v-btn :disabled='!analyse.random.max || !analyse.random.min || !analyse.random.length' @click="setRandoms">set randoms</v-btn>
                            </v-col>
                          </v-row>
                        </v-card-text>
                      </v-card>
                    </v-col>
                  </v-row>
                  <v-row>
                    <v-col>
                      <v-text-field
                        label="merge threshold ratio"
                        type="number"
                        v-model="analyse.mergeThresholdRatio"
                        min="0"
                        max="1"
                        step="0.01"
                      ></v-text-field>
                    </v-col>
                  </v-row>
                  <v-row>
                    <v-col>
                      <v-checkbox
                        label="Show single cluster"
                        v-model="generate.showSingleCluster"
                      ></v-checkbox>
                    </v-col>
                  </v-row>
                  <v-row>
                    <v-col>
                      <v-btn :disabled='!analyse.valid' @click="analyseTimeseries" :loading="analyse.loading">Submit</v-btn>
                    </v-col>
                  </v-row>
                </v-col>
              </v-row>
            </v-card-text>
          </v-card>
        </v-form>
      </v-dialog>
      <v-btn @click="generate.setDataDialog = true">generate(experimental)</v-btn>
      <v-dialog width="1000" v-model="generate.setDataDialog" >
        <v-form v-model='generate.valid' fast-fail ref="form">
          <v-card>
            <v-card-text>
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
              <v-row>
                <v-col>
                  <v-textarea
                    placeholder="please set the complexity transition. (like 1,2,3,4,5)"
                    required
                    v-model='generate.complexityTransition'
                    label="complexity transition"
                    rows="1"
                    :rules="generate.complexityTransitionRules"
                  ></v-textarea>
                </v-col>
              </v-row>
              <v-row>
                <v-col cols="4">
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
                      </v-row>
                      <v-row>
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
                  <v-text-field
                    label="merge threshold ratio"
                    type="number"
                    v-model="generate.mergeThresholdRatio"
                    min="0"
                    max="1"
                    step="0.01"
                  ></v-text-field>
                  <v-btn :disabled='!generate.valid' @click="generateTimeseries" :loading="generate.loading">Submit</v-btn>
                </v-col>
              </v-row>
            </v-card-text>
          </v-card>
        </v-form>
      </v-dialog>
    </v-app-bar>
    <v-main>
      <v-row no-gutters v-if='showTimeseriesChart'>
        <v-col>
          <div class='text-h6 ml-3 mb-2'>
            <v-row>
              <v-col cols="1">
                <span>timeseries</span>
              </v-col>
              <v-col cols="3">
                <v-card>
                  <v-card-text class='py-1'>
                    <v-row>
                      <v-col cols="3" class='text-h6 '>
                        <span class="d-flex align-center fill-height">playback</span>
                      </v-col>
                      <v-col cols="3">
                        <v-text-field
                          label="tempo"
                          type="number"
                          v-model="tempo"
                          min="30"
                          max="180"
                          hide-details="auto"
                        ></v-text-field>
                      </v-col>
                      <v-col cols="3">
                        <v-text-field
                          label="velocity"
                          type="number"
                          v-model="velocity"
                          min="0"
                          max="1"
                          step="0.01"
                          hide-details="auto"
                        ></v-text-field>
                      </v-col>
                      <v-col cols="3">
                        <v-btn @click='playNotes' class="d-flex align-center fill-height">
                          <v-icon v-if='nowPlaying'>mdi-stop</v-icon>
                          <v-icon v-else>mdi-music</v-icon>
                        </v-btn>
                      </v-col>
                    </v-row>
                  </v-card-text>
                </v-card>
              </v-col>
            </v-row>
          </div>
          <div id='timeseries' styls='height: 20vh;'></div>
        </v-col>
      </v-row>
      <v-row no-gutters>
        <v-col>
          <template v-if='showTimeseriesComplexityChart'>
            <div class='text-h6 ml-3 mb-2'>timeseries-complexity</div>
            <div id='timeseries-complexity' styls='height: 20vh;'></div>
          </template>
        </v-col>
      </v-row>
      <v-row no-gutters >
        <v-col>
          <template v-if='showTimeline'>
            <div class='text-h6 ml-3 mb-2'>clusters</div>
            <div id='timeline' styls='height: 70vh;'></div>
          </template>
          <template v-else>
            <span>no similar clusters</span>
          </template>
        </v-col>
      </v-row>
    </v-main>
  </v-app>
</template>

<script setup lang="ts">

import { onMounted, computed, nextTick, ref } from 'vue'
import * as Tone from 'tone'
import axios from 'axios'
import { ScoreEntry } from '../../types/types';

const timeseriesMax = ref(100)
const analyse = ref({
  timeSeries: '',
  clusteredSubsequences: null,
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
  mergeThresholdRatio: 0.05,
})
const generate = ref({
  setDataDialog: false,
  rangeMin: 0,
  rangeMax: 11,
  complexityTransition: '',
  firstElements: '',
  loading: false,
  complexityTransitionRules: [
    v => !!v || 'required',
    v => (v && String(v).split(',').every(n => !isNaN(Number(n)) && n !== "")) || 'must be comma separated numbers',
    v => (v && String(v).split(',').filter(n => n !== "").length >= 1) || 'must have at least 1 numbers',
    v => (v && String(v).split(',').length <= 2000) || 'must have no more than 2000 numbers',
    v => (v && String(v).split(',').every(n => Number.isInteger(Number(n)) && n.trim() !== "")) || 'must be integers',
    v => (v && String(v).split(',').every(n => Number(n) <= 100)) || 'numbers must be 100 or less'
  ],
  firstElementsRules: [
    v => !!v || 'required',
    v => (v && String(v).split(',').every(n => !isNaN(Number(n)) && n !== "")) || 'must be comma separated numbers',
    v => (v && String(v).split(',').filter(n => n !== "").length >= 1) || 'must have at least 1 numbers',
    v => (v && String(v).split(',').length >= 3) || 'must have at least 3 numbers',
    v => (v && String(v).split(',').every(n => Number.isInteger(Number(n)) && n.trim() !== "")) || 'must be integers',
    v => (v && String(v).split(',').every(n => Number(n) <= 100)) || 'numbers must be 100 or less'
  ],
  valid: false,
  mergeThresholdRatio: 0.05,
  complexityTransitionChart: null,
  linear: {
    start: null,
    end: null,
    length: null
  },
  showSingleCluster: false
})
let showTimeseriesChart = ref(false)
let showTimeseriesComplexityChart = ref(false)
let showTimeline = ref(false)
let infoDialog = ref(false)
let pitchMap = ref([
  'C1','C#1','D1','D#1','E1','F1','F#1','G1','G#1','A1','A#1','B1',
  'C2','C#2','D2','D#2','E2','F2','F#2','G2','G#2','A2','A#2','B2',
  'C3','C#3','D3','D#3','E3','F3','F#3','G3','G#3','A3','A#3','B3',
  'C4','C#4','D4','D#4','E4','F4','F#4','G4','G#4','A4','A#4','B4',
  'C5','C#5','D5','D#5','E5','F5','F#5','G5','G#5','A5','A#5','B5',
  'C6','C#6','D6','D#6','E6','F6','F#6','G6','G#6','A6','A#6','B6',
  'C7','C#7','D7','D#7','E7','F7','F#7','G7','G#7','A7','A#7','B7',
])
let nowPlaying = ref(false)
let tempo = ref(60)
let velocity = ref(1)
let sequenceCounter = ref(0)
onMounted(() => {
  google.charts.load("current", {packages:["timeline", "corechart"]})
})

const playNotes = () =>{
  nowPlaying.value ? stopPlayingNotes() : startPlayingNotes()
}
const startPlayingNotes = () => {
  nowPlaying.value = true
  sequenceCounter.value = 0
  const timeSeriesArray = analyse.value.timeSeries.split(',').map(Number)
  const score : ScoreEntry[] = []
  const groupedTimeSeries = groupArray(timeSeriesArray, [4,4])
  groupedTimeSeries.forEach((measure, measureIndex) => {
    measure.forEach((quater, quaterIndex) => {
      quater.forEach((sixteenth, sixteenthIndex) => {
        let setPitch: string
        let setVelocity: number
        const outOfRange = pitchMap.value[sixteenth] === undefined

        if(outOfRange){
          setPitch = 'C1'
          setVelocity = 0
        }else{
          setPitch = pitchMap.value[sixteenth]
          setVelocity = velocity.value
        }
        score.push({
          "time": `${measureIndex}:${quaterIndex}:${sixteenthIndex}`,
          "note": `${setPitch}`,
          "duration": "16n",
          "velocity": setVelocity
        })
      })
    })
  })

  const sampler = new Tone.Sampler({
    urls: {
      A0: "A0.mp3",
      C1: "C1.mp3",
      "D#1": "Ds1.mp3",
      "F#1": "Fs1.mp3",
      A1: "A1.mp3",
      C2: "C2.mp3",
      "D#2": "Ds2.mp3",
      "F#2": "Fs2.mp3",
      A2: "A2.mp3",
      C3: "C3.mp3",
      "D#3": "Ds3.mp3",
      "F#3": "Fs3.mp3",
      A3: "A3.mp3",
      C4: "C4.mp3",
      "D#4": "Ds4.mp3",
      "F#4": "Fs4.mp3",
      A4: "A4.mp3",
      C5: "C5.mp3",
      "D#5": "Ds5.mp3",
      "F#5": "Fs5.mp3",
      A5: "A5.mp3",
      C6: "C6.mp3",
      "D#6": "Ds6.mp3",
      "F#6": "Fs6.mp3",
      A6: "A6.mp3",
      C7: "C7.mp3",
      "D#7": "Ds7.mp3",
      "F#7": "Fs7.mp3",
      A7: "A7.mp3",
      C8: "C8.mp3",
    },
    baseUrl: "https://tonejs.github.io/audio/salamander/",
    onload: () => {
      const part = new Tone.Part((time, note) => {
        sampler.triggerAttackRelease(note.note, note.duration, time, note.velocity)
        if(sequenceCounter.value === timeSeriesArray.length){
          stopPlayingNotes()
        }else{
          const noteLengthInSeconds = Tone.Time(note.duration).toSeconds()
          setTimeout( () => {
          }, noteLengthInSeconds * 1000)
          drawSequence(sequenceCounter.value, false)
          sequenceCounter.value += 1
        }
      }, score).start(0)
      Tone.Transport.start()
    }
  }).toDestination()
}
const stopPlayingNotes = () => {
  nowPlaying.value = false
  drawSequence(null, true)
  Tone.Transport.stop()
  Tone.Transport.cancel()
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
const drawTimeline = () => {
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
      onSelectedSubsequence(e)
    })
  })
}
const onSelectedSubsequence = (selected) => {
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
  let subsequencesInSameCluster: number[] = []
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
const drawSequence = (index, finish) => {
  let displaySeries = new Array(analyse.value.timeSeriesChart.length).fill(null)
  if(!finish){
    displaySeries[index] = timeSeriesMaxValue.value
  }
  analyse.value.timeSeriesChart.forEach((elm, index) => {
    if(elm.length === 4){
      elm[3] = displaySeries[index]
    }else if (elm.length === 3){
      elm.push(displaySeries[index])
    }else if (elm.length === 2){
      if(index === 0){
        elm.push(displaySeries[index])
      }else{
        elm.push(null)
        elm.push(displaySeries[index])
      }
    }
  })
  drawTimeSeries('timeseries', analyse.value.timeSeriesChart)

}
const drawTimeSeries = (elementId, drawData) => {
  showTimeseriesChart.value = true
  nextTick(() => {
    drawSteppedAreaChart(elementId, drawData, 200)
  })
}
const drawTimeSeriesComplexity = (elementId, drawData) => {
  showTimeseriesComplexityChart.value = true
  nextTick(() => {
    drawSteppedAreaChart(elementId, drawData, 100)
  })
}
const drawSteppedAreaChart = (elementId, drawData, height) => {
  const onlyData = drawData.map(data => data[1]).slice(1, drawData.length)
  const dataMin = Math.min(...onlyData)
  const dataMax = Math.max(...onlyData)
  const options = {
    'height': height,
    'width': window.innerWidth,
    isStacked: false,
    legend: 'none' as 'none' | google.visualization.ChartLegend,
    series: [
      {areaOpacity : 0},
      {areaOpacity : 0},
      {areaOpacity : 0.5},
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
  dataTable.addColumn('number', 'allValue')
  dataTable.addColumn('number', 'selectedValue')
  dataTable.addColumn('number', 'sequenceValue')
  dataTable.addRows(drawData)
  const chart = new google.visualization.SteppedAreaChart(document.getElementById(elementId) as HTMLElement)
  chart.draw(dataTable, options)
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
const setRandoms = () => {
  analyse.value.timeSeries = [...Array(parseInt(analyse.value.random.length))].map(() => Math.floor(Math.random() * (parseInt(analyse.value.random.max) - parseInt(analyse.value.random.min)+ 1)) + parseInt(analyse.value.random.min)).join(',')
}
const analyseTimeseries = () => {
  analyse.value.loading = true
  let data = {
    analyse: {
      time_series: analyse.value.timeSeries,
      merge_threshold_ratio: analyse.value.mergeThresholdRatio,
      show_single_cluster: generate.value.showSingleCluster
    }
  }
  axios.post('/api/web/time_series/analyse', data)
  .then(response => {
      console.log(response)
      analyse.value.clusteredSubsequences = response.data.clusteredSubsequences
      analyse.value.timeSeriesChart = response.data.timeSeriesChart
      analyse.value.loading = false
      analyse.value.setDataDialog = false
      showTimeseriesComplexityChart.value = false
      drawTimeline()
      drawTimeSeries('timeseries', analyse.value.timeSeriesChart)
  })
  .catch(error => {
      console.log(error)
  })
}
const generateTimeseries = () => {
  generate.value.loading = true
  let data = { generate:
    {
      complexity_transition: generate.value.complexityTransition,
      range_min: generate.value.rangeMin,
      range_max: generate.value.rangeMax,
      first_elements: generate.value.firstElements,
      merge_threshold_ratio: generate.value.mergeThresholdRatio,
    }
  }
  axios.post('/api/web/time_series/generate', data)
  .then(response => {
      console.log(response)
      analyse.value.clusteredSubsequences = response.data.clusteredSubsequences
      analyse.value.timeSeries = String(response.data.timeSeries)
      analyse.value.timeSeriesChart = response.data.timeSeriesChart
      generate.value.complexityTransitionChart = response.data.timeSeriesComplexityChart
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
const groupArray = <T>(arr: T[], sizes: number[]): T[] | T[][] => {
  // 再帰的にグループ化する関数
  function group(array: T[], size: number): T[][] {
    const grouped: T[][] = [];
    for (let i = 0; i < array.length; i += size) {
      grouped.push(array.slice(i, i + size));
    }
    return grouped;
  }

  // sizes配列に従って順次グループ化
  let result: T[] | T[][] = arr;
  for (let size of sizes) {
    result = group(result as T[], size);
  }

  return result;
};

const timeSeriesMaxValue = computed(() => {
  return analyse.value.timeSeriesChart ? Math.max(...analyse.value.timeSeriesChart.map(elm => elm[1])) : 0
})
</script>

<style scoped>
  [v-cloak] { display: none;}
  .custom-list {
    padding-left: 0;
    list-style-position: inside;
  }

  h3:not(:first-of-type) {
    margin-top: 1.5rem;
  }
  h5:not(:first-of-type) {
    margin-top: 1.5rem;
  }
  .v-textarea textarea {
    white-space: pre !important;
    overflow-x: auto !important;
    padding-top: 40px;
    height: 90px;
  }
</style>
