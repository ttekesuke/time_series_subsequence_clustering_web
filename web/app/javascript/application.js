const clusteredSubsequences = gon.clusteredSubsequences
const timeSeries = gon.timeSeries

google.charts.load("current", {packages:["timeline", "corechart"]})
google.charts.setOnLoadCallback(drawTimeline)
google.charts.setOnLoadCallback(drawTimeSeries(timeSeries))

function drawTimeline() {
  const container = document.getElementById('timeline')
  const chart = new google.visualization.Timeline(container)
  const dataTable = new google.visualization.DataTable()
  const options = {'height': 500, 'width': 1850}
  dataTable.addColumn({ type: 'string', id: 'WindowSize' })
  dataTable.addColumn({ type: 'string', id: 'Cluster' })
  dataTable.addColumn({ type: 'number', id: 'Start' })
  dataTable.addColumn({ type: 'number', id: 'End' })
  dataTable.addRows(clusteredSubsequences)

  chart.draw(dataTable, options)
  google.visualization.events.addListener(chart, 'onmouseover', (e) => {
    onSelectedSubsequence(e)
  })
}

function onSelectedSubsequence(selected) {
  let subsequencesIndexes = []

  clusteredSubsequences.filter(subsequence => 
    subsequence[0] === clusteredSubsequences[selected['row']][0] && subsequence[1] === clusteredSubsequences[selected['row']][1]
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
  const timeSeriesWithoutHeader = timeSeries.slice(1,timeSeries.length)
  timeSeriesWithoutHeader.forEach((elm, index) => {
    subsequencesInSameCluster.push(subsequencesIndexes.includes(index) ? elm[1] : null)
  })
  timeSeries.forEach((elm, index) => {
    if(elm.length > 2){
      elm.pop()
    }
    elm.push(subsequencesInSameCluster[index])
  })
  drawTimeSeries(timeSeries)()

}
function drawTimeSeries(timeSeries){
  return function(){
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
      timeSeries,
    )
    const chart = new google.visualization.SteppedAreaChart(document.getElementById('timeseries'));
    chart.draw(data , options)
  }
}