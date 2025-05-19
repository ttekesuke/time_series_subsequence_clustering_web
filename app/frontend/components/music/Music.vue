<script setup>
import { ref, onMounted, nextTick } from 'vue'
import { Midi } from '@tonejs/midi'
import * as Tone from 'tone'

const midi = ref(null)
const canvas = ref(null)
const midiData = ref(null)
const isPlaying = ref(false)
const startTime = ref(0)
const scrollOffset = ref(0)

const canvasWidth = 3000  // 長めに確保
const canvasHeight = 600
const noteHeight = 6
const pixelsPerSecond = 100
const barOffsetX = 0  // 再生バーのX位置（スクロール固定）

let animationFrameId = null

const onMidiSelected = async () => {
  if (!midi.value) return

  const file = midi.value
  const arrayBuffer = await file.arrayBuffer()
  midiData.value = new Midi(arrayBuffer)

  await nextTick()
  drawPianoRoll(0)
}

const drawPianoRoll = (scrollTime) => {
  const ctx = canvas.value.getContext('2d')
  ctx.clearRect(0, 0, canvas.value.width, canvas.value.height)

  const visibleOffsetX = scrollTime * pixelsPerSecond

  midiData.value.tracks.forEach((track, trackIndex) => {
    const color = ['#f44336', '#2196f3', '#4caf50', '#ff9800'][trackIndex % 4]

    const ticksPerBeat = midiData.value.ppq ?? 480 // ここ修正
    const bpm = midiData.value.header.tempos?.[0]?.bpm || 120
    const secondsPerTick = (60 / bpm) / ticksPerBeat

    track.notes.forEach(note => {
      const startTime = note.ticks * secondsPerTick
      const duration = note.durationTicks * secondsPerTick

      const x = startTime * pixelsPerSecond - visibleOffsetX + barOffsetX
      const y = (127 - note.midi) * noteHeight
      const width = duration * pixelsPerSecond
      const height = noteHeight

      if (x + width >= 0 && x <= canvasWidth) {
        ctx.fillStyle = color
        ctx.fillRect(x, y, width, height)
      }
    })

  })

  // 再生バー
  ctx.strokeStyle = 'black'
  ctx.beginPath()
  ctx.moveTo(barOffsetX, 0)
  ctx.lineTo(barOffsetX, canvasHeight)
  ctx.stroke()
}

const playMidi = async () => {
  if (!midiData.value) return

  await Tone.start()
  const now = Tone.now() + 0.5

  // 再生用シンセ
  const synth = new Tone.PolySynth().toDestination()

  midiData.value.tracks.forEach(track => {
    track.notes.forEach(note => {
      const ticksPerBeat = midiData.value.ppq ?? 480
      const bpm = midiData.value.header.tempos?.[0]?.bpm ?? 120
      const secondsPerTick = (60 / bpm) / ticksPerBeat

      const duration = note.durationTicks * secondsPerTick

      synth.triggerAttackRelease(
        note.name,      // 例: 'C4'
        duration,       // 秒に変換した長さ
        now + note.ticks * secondsPerTick // 開始時間
      )

    })
  })

  isPlaying.value = true
  startTime.value = performance.now()
  animate()
}

const animate = () => {
  const elapsedMs = performance.now() - startTime.value
  const elapsedSec = elapsedMs / 1000

  drawPianoRoll(elapsedSec)

  // duration を計算
  const ticksPerBeat = midiData.value.header.tempos?.[0]?.ppq ?? 480
  const bpm = midiData.value.header.tempos?.[0]?.bpm ?? 120
  const secondsPerTick = (60 / bpm) / ticksPerBeat

  const allNotes = midiData.value.tracks.flatMap(track => track.notes)
  const maxTick = Math.max(...allNotes.map(note => note.ticks + note.durationTicks))
  const midiDurationSec = maxTick * secondsPerTick

  if (elapsedSec < midiDurationSec) {
    animationFrameId = requestAnimationFrame(animate)
  } else {
    isPlaying.value = false
    cancelAnimationFrame(animationFrameId)
  }
}

</script>

<template>
  <v-container>
    <v-row>
      <v-col cols="5">
        <v-file-input
          label="Set MIDI file"
          accept=".midi,.mid"
          prepend-icon="mdi-upload"
          v-model="midi"
          @change="onMidiSelected"
        />
      </v-col>
      <v-col cols="2">
        <v-btn color="primary" @click="playMidi" :disabled="!midiData || isPlaying">
          ▶️ Play
        </v-btn>
      </v-col>
    </v-row>


    <div style="overflow-x: hidden; border: 1px solid #ccc; margin-top: 20px;">
      <canvas
        ref="canvas"
        :width="canvasWidth"
        :height="canvasHeight"
        style="display: block;"
      ></canvas>
    </div>
  </v-container>
</template>


<style scoped>
canvas {
  width: 100%;
  height: 600px;
  background-color: #fafafa;
}
</style>

<!--
必要な依存:
- tonejs/midi: `yarn add @tonejs/midi`
- Vuetify 3 (既に導入済みと仮定)
-->
