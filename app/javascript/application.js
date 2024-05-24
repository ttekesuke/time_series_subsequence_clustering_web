const { createApp, reactive, toRefs } = Vue;
const { createVuetify } = Vuetify;

const vuetify = createVuetify()
const app = createApp({
  setup(){
    const state = reactive({
      analyse: {
        timeSeries: null,
        clusteredSubsequences: null,
        timeSeriesChart: null,
        setDataDialog: false,
        loading: false,
        timeSeriesRules: [
          v => !!v || 'required',
          v => (v && v.split(',').every(n => !isNaN(n) && n !== "")) || 'must be comma separated numbers',
          v => (v && v.split(',').filter(n => n !== "").length >= 2) || 'must have at least 2 numbers',
          v => (v && v.split(',').length <= 2000) || 'must have no more than 2000 numbers'
        ],      
        valid: false, 
        random: {
          min: null,
          max: null,
          length: null
        },      
        toleranceDiffDistance: 1   
      },
      generate: {
        setDataDialog: false,
        rangeMin: null,
        rangeMax: null,
        distanceTransitionsBetweenClusters: null,
        loading: false,
        distanceTransitionsBetweenClustersRules: [
          v => !!v || 'required',
          v => (v && v.split(',').every(n => !isNaN(n) && n !== "")) || 'must be comma separated numbers',
          v => (v && v.split(',').filter(n => n !== "").length >= 1) || 'must have at least 1 numbers',
          v => (v && v.split(',').length <= 2000) || 'must have no more than 2000 numbers'
        ],
        similarityTransitions: null,
        similarityTransitionsRules: [
          v => !!v || 'required',
          v => (v && v.split(',').every(n => !isNaN(n) && n !== "")) || 'must be comma separated numbers',
          v => (v && v.split(',').filter(n => n !== "").length >= 1) || 'must have at least 1 numbers',
          v => (v && v.split(',').length <= 2000) || 'must have no more than 2000 numbers'
        ],      
        valid: false, 
      },      
      infoDialog: false,
    })

    return { ...toRefs(state) };
  },
  mounted() {
    google.charts.load("current", {packages:["timeline", "corechart"]})
  },
  methods: {
    drawTimeline() {
      const container = document.getElementById('timeline')
      const chart = new google.visualization.Timeline(container)
      const dataTable = new google.visualization.DataTable()
      const options = {'height': 500, 'width': window.innerWidth}
      dataTable.addColumn({ type: 'string', id: 'WindowSize' })
      dataTable.addColumn({ type: 'string', id: 'Cluster' })
      dataTable.addColumn({ type: 'number', id: 'Start' })
      dataTable.addColumn({ type: 'number', id: 'End' })
      dataTable.addRows(this.clusteredSubsequences)
    
      chart.draw(dataTable, options)
      google.visualization.events.addListener(chart, 'onmouseover', (e) => {
        this.onSelectedSubsequence(e)
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
      let subsequencesInSameCluster = ['selectedValue']
      const timeSeriesWithoutHeader = this.timeSeriesChart.slice(1,this.timeSeriesChart.length)
      timeSeriesWithoutHeader.forEach((elm, index) => {
        subsequencesInSameCluster.push(subsequencesIndexes.includes(index) ? elm[1] : null)
      })
      this.timeSeriesChart.forEach((elm, index) => {
        if(elm.length > 2){
          elm.pop()
        }
        elm.push(subsequencesInSameCluster[index])
      })
      this.drawTimeSeries()
    },
    drawTimeSeries(){
      const options = {
        'height': 350, 
        'width': window.innerWidth, 
        isStacked: false, 
        legend: 'none', 
        series: [
          {areaOpacity : 0},
          {areaOpacity : 0},
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
        }
      }
      const data = google.visualization.arrayToDataTable(
        this.timeSeriesChart,
      )
      const chart = new google.visualization.SteppedAreaChart(document.getElementById('timeseries'));
      chart.draw(data , options)
    },
    setRandoms(){
      this.analyse.timeSeries = [...Array(parseInt(this.analyse.random.length))].map(() => Math.floor(Math.random() * (parseInt(this.analyse.random.max) - parseInt(this.analyse.random.min)+ 1)) + parseInt(this.analyse.random.min)).join(',')
    },
    analyseTimeseries() {
      this.analyse.loading = true
      let data = { analyse: {time_series: this.analyse.timeSeries, tolerance_diff_distance: this.analyse.toleranceDiffDistance }}
      axios.post('/api/web/time_series/analyse', data)
      .then(response => {
         console.log(response)
         this.clusteredSubsequences = response.data.clusteredSubsequences
         this.timeSeriesChart = response.data.timeSeries
         this.analyse.loading = false
         this.analyse.setDataDialog = false
         this.drawTimeline()
         this.drawTimeSeries()
      })
      .catch(error => {
         console.log(error)
      })
    },
    generateTimeseries() {
      this.generate.loading = true
      let data = { generate: 
        {
          distance_tansitions_between_clusters: this.generate.distanceTransitionsBetweenClusters,
          range_min: this.generate.rangeMin,
          range_max: this.generate.rangeMax,
          similarity_transitions: this.generate.similarityTransitions
        }
      }
      axios.post('/api/web/time_series/generate', data)
      .then(response => {
         console.log(response)
      })
      .catch(error => {
         console.log(error)
      })
    },    
  }
  
})
app.use(vuetify)
app.mount('#app')

