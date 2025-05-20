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
const ticksPerBeatDefault = 480
const ticksPerBeat = ref(ticksPerBeatDefault)
const bpmDefault = 120
const bpm = ref(bpmDefault)
const secondsPerTick = ref(0)


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
  await analyseMidi()
  drawPianoRoll(0)
}

const analyseMidi = async () => {
  if (!midiData.value) return

  ticksPerBeat.value = midiData.value.header.tempos?.[0]?.ppq ?? ticksPerBeatDefault
  bpm.value = midiData.value.header.tempos?.[0]?.bpm || bpmDefault
  secondsPerTick.value = (60 / bpm.value) / ticksPerBeat.value

  await nextTick()
}

const drawPianoRoll = (scrollTime) => {
  const ctx = canvas.value.getContext('2d')
  ctx.clearRect(0, 0, canvas.value.width, canvas.value.height)

  const visibleOffsetX = scrollTime * pixelsPerSecond

  midiData.value.tracks.forEach((track, trackIndex) => {
    const color = ['#f44336', '#2196f3', '#4caf50', '#ff9800'][trackIndex % 4]


    track.notes.forEach(note => {
      const startTime = note.ticks * secondsPerTick.value
      const duration = note.durationTicks * secondsPerTick.value

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

      const duration = note.durationTicks * secondsPerTick.value

      synth.triggerAttackRelease(
        note.name,      // 例: 'C4'
        duration,       // 秒に変換した長さ
        now + note.ticks * secondsPerTick.value // 開始時間
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
  const allNotes = midiData.value.tracks.flatMap(track => track.notes)
  const maxTick = Math.max(...allNotes.map(note => note.ticks + note.durationTicks))
  const midiDurationSec = maxTick * secondsPerTick.value

  if (elapsedSec < midiDurationSec) {
    animationFrameId = requestAnimationFrame(animate)
  } else {
    isPlaying.value = false
    cancelAnimationFrame(animationFrameId)
  }
}

// 例: 手動でMIDIを作る
const createMidi = () => {
  const midi = new Midi()

  // テンポを指定（例: 120BPM）
  midi.header.setTempo(120)

  // トラックを追加
  const track = midi.addTrack()

  // ノートを追加（MIDIノート番号、開始時間 [秒]、長さ [秒]）
  track.addNote({
    midi: 60,          // C4
    time: 0,           // 秒
    duration: 0.5,     // 秒
    velocity: 0.8,
  })

  track.addNote({
    midi: 64,          // E4
    time: 1,           // 秒
    duration: 0.3,
    velocity: 0.8,
  })

  track.addNote({
    midi: 67,          // G4
    time: 1.5,
    duration: 0.7,
    velocity: 0.8,
  })

  return midi
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
