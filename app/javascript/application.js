const { createApp, reactive, toRefs } = Vue;
const { createVuetify } = Vuetify;

const vuetify = createVuetify()
const app = createApp({
  setup(){
    const state = reactive({
      timeSeries: null,
      clusteredSubsequences: null,
      timeSeriesChart: null,
      dialog: false,
      infoDialog: false,
      loading: false,
      random: {
        min: null,
        max: null,
        length: null
      },
      valid: false,      
      timeSeriesRules: [
        v => !!v || 'timeseries is required',
        v => (v && v.split(',').every(n => !isNaN(n))) || 'timeseries must be comma separated numbers',
        v => (v && v.split(',').length >= 2) || 'timeseries must have at least 2 numbers',
        v => (v && v.split(',').length <= 200) || 'timeseries must have no more than 200 numbers'
      ],      
      toleranceDiffDistance: 1
    })

    return { ...toRefs(state) };
  },
  mounted() {
    google.charts.load("current", {packages:["timeline", "corechart"]})
  },
  methods: {
    submit () {
      this.loading = true
      let data = { time_series_analysis: {time_series: this.timeSeries, tolerance_diff_distance: this.toleranceDiffDistance }}
      axios.post('/api/web/time_series_analysis', data)
      .then(response => {
         console.log(response)
         this.clusteredSubsequences = response.data.clusteredSubsequences
         this.timeSeriesChart = response.data.timeSeries
         this.loading = false
         this.dialog = false
         this.drawTimeline()
         this.drawTimeSeries()
      })
      .catch(error => {
         console.log(error)
      })
    },
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
      this.timeSeries = [...Array(parseInt(this.random.length))].map(() => Math.floor(Math.random() * (parseInt(this.random.max) - parseInt(this.random.min)+ 1)) + parseInt(this.random.min)).join(',')
    }
  }
  
})
app.use(vuetify)
app.mount('#app')

