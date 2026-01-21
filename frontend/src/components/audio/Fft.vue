<template>
  <div class="fft-canvas-wrapper" :style="{ width: width + 'px' }">
    <canvas ref="canvas" :width="width" :height="height" />
  </div>
</template>

<script setup>
import { onMounted, onBeforeUnmount, watch, ref } from 'vue'

// Props
const props = defineProps({
  audioEl: {
    type: Object,
    required: false, // audioElが後で生成されるケースに対応
  },
  width: {
    type: Number,
    default: 1920,
  },
  height: {
    type: Number,
    default: 400,
  },
  fftSize: {
    type: Number,
    default: 4096,
  },
  smoothingTimeConstant: {
    type: Number,
    default: 0.3,
  },
})

const canvas = ref(null)
let ctx = null
let audioCtx = null
let source = null
let analyser = null
let dataArray = null
let rafId = null
let isConnected = false

function setupAudio() {
  if (!props.audioEl) return

  if (!audioCtx) {
    audioCtx = new (window.AudioContext || window.webkitAudioContext)()
  }

  if (source) {
    try { source.disconnect() } catch (e) {}
    source = null
  }

  try {
    source = audioCtx.createMediaElementSource(props.audioEl)
  } catch (err) {
    console.error('Failed to create MediaElementSource: ', err)
    return
  }

  analyser = audioCtx.createAnalyser()
  analyser.fftSize = props.fftSize
  analyser.smoothingTimeConstant = props.smoothingTimeConstant

  const bufferLength = analyser.frequencyBinCount
  dataArray = new Uint8Array(bufferLength)

  source.connect(analyser)
  analyser.connect(audioCtx.destination)
  isConnected = true
}

function teardownAudio() {
  if (!isConnected) return
  try {
    source.disconnect()
    analyser.disconnect()
  } catch (e) {}
  source = null
  analyser = null
  dataArray = null
  isConnected = false
}

function draw() {
  if (!canvas.value) return
  const c = canvas.value
  ctx = c.getContext('2d')
  const w = props.width
  const h = props.height
  const marginLeft = 70
  const marginBottom = 70
  const marginTop = 10
  const plotW = w - marginLeft - 10
  const plotH = h - marginTop - marginBottom

  ctx.fillStyle = '#ffffff'
  ctx.fillRect(0, 0, w, h)

  ctx.fillRect(marginLeft, marginTop, plotW, plotH)

  // 軸
  ctx.strokeStyle = '#000000'
  ctx.lineWidth = 1
  ctx.beginPath()
  ctx.moveTo(marginLeft, marginTop)
  ctx.lineTo(marginLeft, marginTop + plotH)
  ctx.stroke()
  ctx.beginPath()
  ctx.moveTo(marginLeft, marginTop + plotH)
  ctx.lineTo(marginLeft + plotW, marginTop + plotH)
  ctx.stroke()

  // ラベル
  ctx.fillStyle = '#000000'
  ctx.font = '12px monospace'
  ctx.textAlign = 'center'
  ctx.fillText('Frequency (Hz)', marginLeft + plotW / 2, h - 20)
  ctx.save()
  ctx.translate(18, marginTop + plotH / 2)
  ctx.rotate(-Math.PI / 2)
  ctx.textAlign = 'center'
  ctx.fillText('Magnitude (%)', 0, 0)
  ctx.restore()

  if (!analyser || !dataArray) {
    ctx.font = '16px monospace'
    ctx.textAlign = 'center'
    ctx.fillText('No audio connected', marginLeft + plotW / 2, marginTop + plotH / 2)
    return
  }

  analyser.getByteFrequencyData(dataArray)

  const bins = dataArray.length
  const sampleRate = audioCtx?.sampleRate || 44100
  const nyquist = sampleRate / 2

  // 半音刻みで周波数リストを生成（例: 20Hz〜Nyquist）
  const semitoneFreqs = []
  let f = 20
  while (f < nyquist) {
    semitoneFreqs.push(f)
    f *= Math.pow(2, 1 / 12) // 半音ごとに周波数を増やす
  }

  // 周波数→x座標（logスケール）
  const logMin = Math.log10(20)
  const logMax = Math.log10(nyquist)
  function freqToX(freq) {
    return marginLeft + (Math.log10(freq) - logMin) / (logMax - logMin) * plotW
  }

  // 各半音の強度を計算してバー描画
  const barW = plotW / semitoneFreqs.length
  for (let i = 0; i < semitoneFreqs.length; i++) {
    const freq = semitoneFreqs[i]
    const binIndex = Math.round((freq / nyquist) * (bins - 1))
    const value = dataArray[binIndex]
    const magnitude = value / 255 // 0〜1 に正規化

    const barH = magnitude * plotH
    const x = freqToX(freq) - barW / 2
    const y = marginTop + (plotH - barH)
    const intensity = 255 - Math.floor(magnitude * 200)
    ctx.fillStyle = `rgb(${intensity}, ${intensity}, ${intensity})`
    ctx.fillRect(x, y, barW, barH)
  }

  // x軸 log目盛り
  ctx.fillStyle = '#000000'
  ctx.font = '12px monospace'
  ctx.textAlign = 'center'
  const freqs = [20, 50, 100, 200, 400, 800, 1600, 3200, 6400, 12800, nyquist]
  for (const f of freqs) {
    const x = freqToX(f)
    const y = marginTop + plotH + 16
    ctx.fillText(f + ' Hz', x, y)
    ctx.beginPath()
    ctx.moveTo(x, marginTop + plotH)
    ctx.lineTo(x, marginTop + plotH - 6)
    ctx.stroke()
  }

  // y軸目盛り (%)
  ctx.textAlign = 'right'
  const yTicks = [0, 0.25, 0.5, 0.75, 1.0]
  for (const t of yTicks) {
    const y = marginTop + plotH - t * plotH
    ctx.fillText(Math.round(t * 100) + '%', marginLeft - 8, y + 4)
    ctx.beginPath()
    ctx.moveTo(marginLeft, y)
    ctx.lineTo(marginLeft + 6, y)
    ctx.stroke()
  }

  rafId = requestAnimationFrame(draw)
}



function handlePlayEvent() {
  if (!audioCtx) return
  if (audioCtx.state === 'suspended') {
    audioCtx.resume().catch(err => console.warn('AudioContext resume failed:', err))
  }
  if (!rafId) {
    draw()
  }
}

onMounted(() => {
  if (canvas.value) ctx = canvas.value.getContext('2d')

  if (props.audioEl) {
    props.audioEl.addEventListener('play', handlePlayEvent)
    props.audioEl.addEventListener('pause', () => {
      if (rafId) {
        cancelAnimationFrame(rafId)
        rafId = null
      }
    })
    if (!props.audioEl.paused) handlePlayEvent()
  }
})

onBeforeUnmount(() => {
  if (props.audioEl) {
    props.audioEl.removeEventListener('play', handlePlayEvent)
  }
  if (rafId) cancelAnimationFrame(rafId)
  teardownAudio()
  if (audioCtx) {
    try { audioCtx.close() } catch (e) {}
    audioCtx = null
  }
})

watch(() => props.audioEl, (newEl, oldEl) => {
  if (oldEl) {
    oldEl.removeEventListener('play', handlePlayEvent)
  }
  teardownAudio()
  if (newEl) {
    setupAudio()
    newEl.addEventListener('play', handlePlayEvent)
    if (!newEl.paused) handlePlayEvent()
  }
})
</script>

<style scoped>
canvas {
  display: block;
}
</style>
