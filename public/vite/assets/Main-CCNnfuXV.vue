<!-- const { reactive, toRefs } = Vue;
{
  setup(){
    const state = reactive({
      timeseriesMax: 100,
      analyse: {
        timeSeries: null,
        clusteredSubsequences: null,
        timeSeriesChart: null,
        setDataDialog: false,
        loading: false,
        timeSeriesRules: [
          v => !!v || 'required',
          v => (v && String(v).split(',').every(n => !isNaN(n) && n !== "")) || 'must be comma separated numbers',
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
        mergeThresholdRatio: 0.1,
      },
      generate: {
        setDataDialog: false,
        rangeMin: 0,
        rangeMax: 11,
        complexityTransition: null,
        firstElements: null,
        loading: false,
        complexityTransitionRules: [
          v => !!v || 'required',
          v => (v && String(v).split(',').every(n => !isNaN(n) && n !== "")) || 'must be comma separated numbers',
          v => (v && String(v).split(',').filter(n => n !== "").length >= 1) || 'must have at least 1 numbers',
          v => (v && String(v).split(',').length <= 2000) || 'must have no more than 2000 numbers',
          v => (v && String(v).split(',').every(n => Number.isInteger(Number(n)) && n.trim() !== "")) || 'must be integers',
          v => (v && String(v).split(',').every(n => Number(n) <= 100)) || 'numbers must be 100 or less'
        ],
        firstElementsRules: [
          v => !!v || 'required',
          v => (v && String(v).split(',').every(n => !isNaN(n) && n !== "")) || 'must be comma separated numbers',
          v => (v && String(v).split(',').filter(n => n !== "").length >= 1) || 'must have at least 1 numbers',
          v => (v && String(v).split(',').length >= 3) || 'must have at least 3 numbers',
          v => (v && String(v).split(',').every(n => Number.isInteger(Number(n)) && n.trim() !== "")) || 'must be integers',
          v => (v && String(v).split(',').every(n => Number(n) <= 100)) || 'numbers must be 100 or less'
        ],
        valid: false,
        mergeThresholdRatio: 0.1,
        complexityTransitionChart: null,
        linear: {
          start: null,
          end: null,
          length: null
        }
      },
      showTimeseriesChart: false,
      showTimeseriesComplexityChart: false,
      showTimeline: false,
      infoDialog: false,
      pitchMap: [
        'C1',
        'C#1',
        'D1',
        'D#1',
        'E1',
        'F1',
        'F#1',
        'G1',
        'G#1',
        'A1',
        'A#1',
        'B1',
        'C2',
        'C#2',
        'D2',
        'D#2',
        'E2',
        'F2',
        'F#2',
        'G2',
        'G#2',
        'A2',
        'A#2',
        'B2',
        'C3',
        'C#3',
        'D3',
        'D#3',
        'E3',
        'F3',
        'F#3',
        'G3',
        'G#3',
        'A3',
        'A#3',
        'B3',
        'C4',
        'C#4',
        'D4',
        'D#4',
        'E4',
        'F4',
        'F#4',
        'G4',
        'G#4',
        'A4',
        'A#4',
        'B4',
        'C5',
        'C#5',
        'D5',
        'D#5',
        'E5',
        'F5',
        'F#5',
        'G5',
        'G#5',
        'A5',
        'A#5',
        'B5',
        'C6',
        'C#6',
        'D6',
        'D#6',
        'E6',
        'F6',
        'F#6',
        'G6',
        'G#6',
        'A6',
        'A#6',
        'B6',
        'C7',
        'C#7',
        'D7',
        'D#7',
        'E7',
        'F7',
        'F#7',
        'G7',
        'G#7',
        'A7',
        'A#7',
        'B7',
      ],
      nowPlaying: false,
      tempo: 60,
      velocity: 1,
      sequenceCounter: 0,
    })

    return { ...toRefs(state) }
  },
  mounted() {
    google.charts.load("current", {packages:["timeline", "corechart"]})
  },
  methods: {
    playNotes(){
      this.nowPlaying ? this.stopPlayingNotes() : this.startPlayingNotes()
    },
    startPlayingNotes() {
      this.nowPlaying = true
      this.sequenceCounter = 0
      const timeSeriesArray = this.analyse.timeSeries.split(',').map(Number)
      let score = []
      const groupedTimeSeries = this.groupArray(timeSeriesArray, [4,4])
      groupedTimeSeries.forEach((measure, measureIndex) => {
        measure.forEach((quater, quaterIndex) => {
          quater.forEach((sixteenth, sixteenthIndex) => {
            let pitch = null
            const outOfRange = this.pitchMap[sixteenth] === undefined
            let velocity = null
            if(outOfRange){
              pitch = 'C1'
              velocity = 0
            }else{
              pitch = this.pitchMap[sixteenth]
              velocity = this.velocity
            }
            score.push({
              "time": `${measureIndex}:${quaterIndex}:${sixteenthIndex}`,
              "note": `${pitch}`,
              "duration": "16n",
              "velocity": velocity
            })
          })
        })
      })
      Tone.Transport.bpm.value = this.tempo

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
          const part = new Tone.Part(((time, note) => {
            sampler.triggerAttackRelease(note.note, note.duration, time, note.velocity)
            if(this.sequenceCounter === timeSeriesArray.length){
              this.stopPlayingNotes()
            }else{
              const noteLengthInSeconds = Tone.Time(note.duration).toSeconds()
              setTimeout( () => {
              }, noteLengthInSeconds * 1000)
              this.drawSequence(this.sequenceCounter, false)
              this.sequenceCounter += 1
            }
          }), score).start()
          Tone.Transport.start()
        }
      }).toDestination()
    },
    stopPlayingNotes() {
      this.nowPlaying = false
      this.drawSequence(null, true)
      Tone.Transport.stop()
      Tone.Transport.cancel()
    },
    createLinearIntegerArray(start, end, count) {
      const result = [];
      const step = (end - start) / (count - 1); // ステップを計算

      for (let i = 0; i < count; i++) {
          const value = parseInt(start) + step * i;
          // start < end の場合は Math.ceil、start > end の場合は Math.floor を使う
          if (start < end) {
              result.push(Math.ceil(value)); // 小数点を切り上げ
          } else {
              result.push(Math.floor(value)); // 小数点を切り捨て
          }
      }
      return result
    },
    drawTimeline() {
      this.showTimeline = true
      this.$nextTick(() => {
        const container = document.getElementById('timeline')
        const chart = new google.visualization.Timeline(container)
        const dataTable = new google.visualization.DataTable()
        const options = {'height': 470, 'width': window.innerWidth, 'title': 'clustering'}
        dataTable.addColumn({ type: 'string', id: 'WindowSize' })
        dataTable.addColumn({ type: 'string', id: 'Cluster' })
        dataTable.addColumn({ type: 'number', id: 'Start' })
        dataTable.addColumn({ type: 'number', id: 'End' })
        dataTable.addRows(this.clusteredSubsequences)

        chart.draw(dataTable, options)
        google.visualization.events.addListener(chart, 'onmouseover', (e) => {
          this.onSelectedSubsequence(e)
        })
      })
    },
    onSelectedSubsequence(selected) {
      let subsequencesIndexes = []

      this.clusteredSubsequences.filter(subsequence =>
        subsequence[0] === this.clusteredSubsequences[selected['row']][0] && subsequence[1] === this.clusteredSubsequences[selected['row']][1]
      ).forEach(subsequence => {
        const startIndex = subsequence[2] / 1000
        const endIndex = subsequence[3] / 1000
        const len = endIndex - startIndex
        const indexes = new Array(len)
            .fill(null)
            .map((_, i) => i + startIndex)
        subsequencesIndexes.push(indexes)
      })
      subsequencesIndexes = subsequencesIndexes.flat()
      let subsequencesInSameCluster = []
      this.timeSeriesChart.forEach((elm, index) => {
        subsequencesInSameCluster.push(subsequencesIndexes.includes(index) ? elm[1] : null)
      })
      this.timeSeriesChart.forEach((elm, index) => {
        if(elm.length === 4){
          elm[2] = subsequencesInSameCluster[index]
        }else if (elm.length === 3){
          elm[2] = subsequencesInSameCluster[index]
        }else if (elm.length === 2){
          elm.push(subsequencesInSameCluster[index])
        }

      })
      this.drawTimeSeries('timeseries', this.timeSeriesChart)
    },
    drawSequence(index, finish){
      let displaySeries = new Array(this.timeSeriesChart.length).fill(null)
      if(!finish){
        displaySeries[index] = this.timeSeriesMaxValue
      }
      this.timeSeriesChart.forEach((elm, index) => {
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
      this.drawTimeSeries('timeseries', this.timeSeriesChart)

    },
    drawTimeSeries(elementId, drawData){
      this.showTimeseriesChart = true
      this.$nextTick(() => {
        this.drawSteppedAreaChart(elementId, drawData, 200)
      })
    },
    drawTimeSeriesComplexity(elementId, drawData){
      this.showTimeseriesComplexityChart = true
      this.$nextTick(() => {
        this.drawSteppedAreaChart(elementId, drawData, 100)
      })
    },
    drawSteppedAreaChart(elementId, drawData, height){
      const onlyData = drawData.map(data => data[1]).slice(1, drawData.length)
      const dataMin = Math.min(...onlyData)
      const dataMax = Math.max(...onlyData)
      const options = {
        'height': height,
        'width': window.innerWidth,
        isStacked: false,
        legend: 'none',
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
      const chart = new google.visualization.SteppedAreaChart(document.getElementById(elementId))
      chart.draw(dataTable, options)
    },
    setLinearIntegers(setType){
      const linearIntegerArray = this.createLinearIntegerArray(
        this.generate.linear.start,
        this.generate.linear.end,
        this.generate.linear.length
      ).join(',')
      if(setType === 'overwrite'){
        this.generate.complexityTransition = linearIntegerArray
      }else if(setType === 'add'){
        if(this.generate.complexityTransition === null || this.generate.complexityTransition === ''){
          this.generate.complexityTransition = linearIntegerArray
        }else{
          this.generate.complexityTransition += (',' + linearIntegerArray)
        }
      }
    },
    setRandoms(){
      this.analyse.timeSeries = [...Array(parseInt(this.analyse.random.length))].map(() => Math.floor(Math.random() * (parseInt(this.analyse.random.max) - parseInt(this.analyse.random.min)+ 1)) + parseInt(this.analyse.random.min)).join(',')
    },
    analyseTimeseries() {
      this.analyse.loading = true
      let data = {
        analyse: {
          time_series: this.analyse.timeSeries,
          merge_threshold_ratio: this.analyse.mergeThresholdRatio,
        }
      }
      axios.post('/api/web/time_series/analyse', data)
      .then(response => {
         console.log(response)
         this.clusteredSubsequences = response.data.clusteredSubsequences
         this.timeSeriesChart = response.data.timeSeriesChart
         this.analyse.loading = false
         this.analyse.setDataDialog = false
         this.showTimeseriesComplexityChart = false
         this.drawTimeline()
         this.drawTimeSeries('timeseries', this.timeSeriesChart)
      })
      .catch(error => {
         console.log(error)
      })
    },
    generateTimeseries() {
      this.generate.loading = true
      let data = { generate:
        {
          complexity_transition: this.generate.complexityTransition,
          range_min: this.generate.rangeMin,
          range_max: this.generate.rangeMax,
          first_elements: this.generate.firstElements,
          merge_threshold_ratio: this.generate.mergeThresholdRatio,
        }
      }
      axios.post('/api/web/time_series/generate', data)
      .then(response => {
         console.log(response)
         this.clusteredSubsequences = response.data.clusteredSubsequences
         this.analyse.timeSeries = String(response.data.timeSeries)
         this.timeSeriesChart = response.data.timeSeriesChart
         this.generate.complexityTransitionChart = response.data.timeSeriesComplexityChart
         this.drawTimeline()
         this.drawTimeSeries('timeseries', this.timeSeriesChart)
         this.drawTimeSeriesComplexity('timeseries-complexity', this.generate.complexityTransitionChart)
         this.generate.loading = false
         this.generate.setDataDialog = false

      })
      .catch(error => {
         console.log(error)
      })
    },
    groupArray(arr, sizes) {
      // sizes配列に従って階層的にグループ化する再帰関数
      function group(arr, size) {
        const grouped = [];
        for (let i = 0; i < arr.length; i += size) {
          grouped.push(arr.slice(i, i + size));
        }
        return grouped;
      }

      // sizes配列に従って順次グループ化
      let result = arr;
      for (let size of sizes) {
        result = group(result, size);
      }

      return result;
    }
  },
  computed: {
    timeSeriesMaxValue(){
      return Math.max(...this.timeSeriesChart.map(elm => elm[1]))
    }
  }
} -->
<template>
  <p>{{ state.message }}</p>
</template>

<script lang="ts">
import { defineComponent } from 'vue'

export default defineComponent({
  name: 'App',
  setup() {
      return {
          state: {
              message: "Ruby on Rails + vite + Vue3!"
          }
      }
  }
})
</script>

<style scoped>
p {
  font-size: 2em;
  text-align: center;
}
</style>
