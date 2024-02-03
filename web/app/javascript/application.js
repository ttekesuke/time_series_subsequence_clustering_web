const { createApp } = Vue;
const { createVuetify } = Vuetify;

const vuetify = createVuetify()
const app = createApp({
  setup(){
    return {
      timeSeries: null,
      clusteredSubsequences: null,
      timeSeriesChart: null
    }
  },
  mounted() {
    google.charts.load("current", {packages:["timeline", "corechart"]})
  },
  methods: {
    submit () {
      let data = { time_series: this.timeSeries }
      axios.post('/api/web/tops', data)
      .then(response => {
         console.log(response)
         this.clusteredSubsequences = response.data.clusteredSubsequences
         this.timeSeriesChart = response.data.timeSeries

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
      const options = {'height': 500, 'width': 1850}
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
        'width': 1850, 
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
    }
  }
  
})
app.use(vuetify)
app.mount('#app')

