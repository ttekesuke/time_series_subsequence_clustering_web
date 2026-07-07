<template>
  <v-row class="mb-2">
    <v-col cols="4">
      <v-file-input
        label="Upload MIDI File"
        accept=".mid,.midi,audio/midi"
        prepend-icon="mdi-music-note"
        @update:modelValue="onMidiFilePicked"
      />
    </v-col>
    <v-col cols="4">
      <v-select
        label="Track"
        :items="midiTrackOptions"
        v-model="selectedTrackIndex"
        item-title="title"
        item-value="value"
        :disabled="midiTrackOptions.length === 0"
      />
    </v-col>
    <v-col cols="2">
      <v-select
        label="Channel"
        :items="midiChannelOptions"
        v-model="selectedChannel"
        item-title="title"
        item-value="value"
        :disabled="midiChannelOptions.length === 0"
      />
    </v-col>
    <v-col cols="2" class="d-flex align-center">
      <v-btn color="primary" block :disabled="!canExtractMidi" @click="applyMidiToGrid">
        MIDI -> Query
      </v-btn>
    </v-col>
  </v-row>

  <v-row class="mb-2">
    <v-col cols="3">
      <v-select
        label="chord note"
        :items="chordNoteOptions"
        v-model="chordNoteMode"
        item-title="title"
        item-value="value"
      />
    </v-col>
    <v-col cols="9" class="d-flex align-center">
      <div class="text-caption text-error" v-if="midiError">{{ midiError }}</div>
      <div class="text-caption" v-else>{{ midiSummary }}</div>
    </v-col>
  </v-row>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue'

type GridRowData = {
  name: string
  shortName: string
  data: number[]
  config: { min: number; max: number; step?: number; isInt?: boolean }
}

type ChordNoteMode = 'highest' | 'lowest'

type MidiEvent = {
  tick: number
  channel: number
  note: number
  velocity: number
  on: boolean
}

type ParsedMidiTrack = {
  index: number
  name: string
  events: MidiEvent[]
}

type ParsedMidi = {
  format: number
  division: number
  ticksPerQuarter: number
  tracks: ParsedMidiTrack[]
}

type MidiSeries = {
  pitch: number[]
  velocity: number[]
  activeSteps: number
  restSteps: number
}

type MidiApplyPayload = {
  rows: GridRowData[]
  steps: number
  summary: string
}

const emit = defineEmits<{ (e: 'applied', payload: MidiApplyPayload): void }>()

const parsedMidi = ref<ParsedMidi | null>(null)
const selectedTrackIndex = ref<number | null>(null)
const selectedChannel = ref<number | 'all'>('all')
const chordNoteMode = ref<ChordNoteMode>('highest')
const midiSummary = ref('')
const midiError = ref('')

const chordNoteOptions = [
  { title: 'Highest note', value: 'highest' },
  { title: 'Lowest note', value: 'lowest' },
]

const midiTrackOptions = computed(() => {
  if (!parsedMidi.value) return []
  return parsedMidi.value.tracks
    .filter((track) => track.events.length > 0)
    .map((track) => {
      const channels = Array.from(new Set(track.events.map((event) => event.channel))).sort((a, b) => a - b)
      const titleName = track.name ? `: ${track.name}` : ''
      return {
        title: `Track ${track.index + 1}${titleName} (${track.events.length} events / ch ${channels.join(',')})`,
        value: track.index,
      }
    })
})

const midiChannelOptions = computed(() => {
  if (!parsedMidi.value || selectedTrackIndex.value == null) return []
  const track = parsedMidi.value.tracks[selectedTrackIndex.value]
  if (!track) return []
  const channels = Array.from(new Set(track.events.map((event) => event.channel))).sort((a, b) => a - b)
  return [
    { title: 'All', value: 'all' as const },
    ...channels.map((channel) => ({ title: `Ch ${channel}`, value: channel })),
  ]
})

const canExtractMidi = computed(() => {
  return !!parsedMidi.value && selectedTrackIndex.value != null && midiTrackOptions.value.length > 0
})

watch(selectedTrackIndex, () => {
  selectedChannel.value = 'all'
})

const readU32BE = (bytes: Uint8Array, offset: number) =>
  (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]

const readU16BE = (bytes: Uint8Array, offset: number) =>
  (bytes[offset] << 8) | bytes[offset + 1]

const readAscii = (bytes: Uint8Array, start: number, length: number) =>
  String.fromCharCode(...bytes.slice(start, start + length))

const readVarLen = (bytes: Uint8Array, state: { pos: number }) => {
  let value = 0
  let count = 0
  while (state.pos < bytes.length) {
    const byte = bytes[state.pos++]
    value = (value << 7) | (byte & 0x7f)
    count += 1
    if ((byte & 0x80) === 0) break
    if (count > 4) break
  }
  return value
}

const parseMidi = (bytes: Uint8Array): ParsedMidi => {
  let pos = 0
  const readChunk = () => {
    if (pos + 8 > bytes.length) throw new Error('Invalid MIDI chunk header')
    const id = readAscii(bytes, pos, 4)
    pos += 4
    const length = readU32BE(bytes, pos)
    pos += 4
    const start = pos
    const end = pos + length
    if (end > bytes.length) throw new Error('Invalid MIDI chunk length')
    pos = end
    return { id, start, end, length }
  }

  const header = readChunk()
  if (header.id !== 'MThd') throw new Error('Not a MIDI file')
  if (header.length < 6) throw new Error('Invalid MIDI header')

  const format = readU16BE(bytes, header.start)
  const numTracks = readU16BE(bytes, header.start + 2)
  const divisionRaw = readU16BE(bytes, header.start + 4)
  const ticksPerQuarter = (divisionRaw & 0x8000) === 0 ? divisionRaw : 480

  const tracks: ParsedMidiTrack[] = []
  for (let trackIndex = 0; trackIndex < numTracks && pos < bytes.length; trackIndex++) {
    const chunk = readChunk()
    if (chunk.id !== 'MTrk') continue

    const events: MidiEvent[] = []
    let name = ''
    let tick = 0
    let index = chunk.start
    let runningStatus = -1

    while (index < chunk.end) {
      const state = { pos: index }
      const delta = readVarLen(bytes, state)
      index = state.pos
      tick += delta
      if (index >= chunk.end) break

      let status = bytes[index]
      if (status < 0x80) {
        if (runningStatus < 0) break
        status = runningStatus
      } else {
        index += 1
        if (status < 0xf0) runningStatus = status
        else runningStatus = -1
      }

      if (status === 0xff) {
        if (index >= chunk.end) break
        const metaType = bytes[index++]
        const lenState = { pos: index }
        const metaLen = readVarLen(bytes, lenState)
        index = lenState.pos
        if (metaType === 0x03) name = readAscii(bytes, index, Math.min(metaLen, chunk.end - index))
        index += metaLen
        continue
      }

      if (status === 0xf0 || status === 0xf7) {
        const lenState = { pos: index }
        const syxLen = readVarLen(bytes, lenState)
        index = lenState.pos + syxLen
        continue
      }

      const kind = status & 0xf0
      const channel = (status & 0x0f) + 1

      if (kind === 0x80 || kind === 0x90) {
        if (index + 1 >= chunk.end) break
        const note = bytes[index++]
        const velocity = bytes[index++]
        const on = kind === 0x90 && velocity > 0
        events.push({ tick, channel, note, velocity, on })
      } else if (kind === 0xa0 || kind === 0xb0 || kind === 0xe0) {
        index += 2
      } else if (kind === 0xc0 || kind === 0xd0) {
        index += 1
      } else {
        break
      }
    }

    tracks.push({ index: trackIndex, name, events })
  }

  return { format, division: divisionRaw, ticksPerQuarter, tracks }
}

const extractMidiSeries = (
  midi: ParsedMidi,
  trackIndex: number,
  channel: number | 'all',
  noteMode: ChordNoteMode,
): MidiSeries => {
  const track = midi.tracks[trackIndex]
  if (!track) return { pitch: [], velocity: [], activeSteps: 0, restSteps: 0 }

  const events = track.events
    .filter((event) => channel === 'all' || event.channel === channel)
    .slice()
    .sort((a, b) => {
      if (a.tick !== b.tick) return a.tick - b.tick
      if (a.on === b.on) return 0
      return a.on ? 1 : -1
    })

  if (events.length === 0) return { pitch: [], velocity: [], activeSteps: 0, restSteps: 0 }

  const ticksPerStep = Math.max(1, Math.round(midi.ticksPerQuarter / 4))
  const maxTick = events[events.length - 1].tick
  const totalSteps = Math.max(1, Math.floor(maxTick / ticksPerStep) + 1)
  const active = new Map<number, { count: number; velocity: number }>()
  const pitch: number[] = []
  const velocity: number[] = []
  let eventIndex = 0
  let lastPitch = 0
  let hasSounded = false
  let activeSteps = 0

  for (let step = 0; step < totalSteps; step++) {
    const stepTick = step * ticksPerStep
    while (eventIndex < events.length && events[eventIndex].tick <= stepTick) {
      const event = events[eventIndex]
      const current = active.get(event.note)
      if (event.on) {
        active.set(event.note, { count: (current?.count ?? 0) + 1, velocity: event.velocity })
      } else if (!current || current.count <= 1) {
        active.delete(event.note)
      } else {
        active.set(event.note, { count: current.count - 1, velocity: current.velocity })
      }
      eventIndex += 1
    }

    if (active.size > 0) {
      const notes = Array.from(active.keys())
      const selected = noteMode === 'highest' ? Math.max(...notes) : Math.min(...notes)
      lastPitch = selected
      hasSounded = true
      activeSteps += 1
      pitch.push(selected)
      velocity.push(1)
    } else if (hasSounded) {
      pitch.push(lastPitch)
      velocity.push(0)
    }
  }

  while (velocity.length > 0 && velocity[velocity.length - 1] === 0) {
    velocity.pop()
    pitch.pop()
  }

  return { pitch, velocity, activeSteps, restSteps: velocity.filter((value) => value === 0).length }
}

const onMidiFilePicked = async (value: File | File[] | null) => {
  midiError.value = ''
  midiSummary.value = ''
  parsedMidi.value = null
  selectedTrackIndex.value = null
  selectedChannel.value = 'all'

  const file = Array.isArray(value) ? value[0] : value
  if (!file) return

  try {
    const buffer = await file.arrayBuffer()
    const parsed = parseMidi(new Uint8Array(buffer))
    parsedMidi.value = parsed
    if (midiTrackOptions.value.length > 0) {
      selectedTrackIndex.value = Number(midiTrackOptions.value[0].value)
    }
    midiSummary.value = `MIDI loaded: format=${parsed.format}, tracks=${parsed.tracks.length}, PPQ=${parsed.ticksPerQuarter}`
  } catch (error: any) {
    midiError.value = `Failed to parse MIDI: ${error?.message ?? String(error)}`
  }
}

const applyMidiToGrid = () => {
  if (!parsedMidi.value || selectedTrackIndex.value == null) return

  const series = extractMidiSeries(
    parsedMidi.value,
    selectedTrackIndex.value,
    selectedChannel.value,
    chordNoteMode.value,
  )

  const rows: GridRowData[] = [
    { name: 'midiPitch', shortName: 'Pitch', data: series.pitch, config: { min: 0, max: 127, isInt: true, step: 1 } },
    { name: 'midiVol', shortName: 'Vol', data: series.velocity, config: { min: 0, max: 1, isInt: true, step: 1 } },
  ]

  const nextRows = rows.length > 0 ? rows : [
    { name: 'querySeries', shortName: 'Query', data: [0], config: { min: 0, max: 127, isInt: true, step: 1 } },
  ]

  emit('applied', {
    rows: nextRows,
    steps: Math.max(1, nextRows[0].data.length),
    summary: `Extracted steps=${nextRows[0].data.length}, note-steps=${series.activeSteps}, rests=${series.restSteps} (${chordNoteMode.value} note, vol=1 for sounding / 0 for rests)`,
  })

  midiSummary.value = `Extracted steps=${nextRows[0].data.length}, note-steps=${series.activeSteps}, rests=${series.restSteps} (${chordNoteMode.value} note, vol=1 for sounding / 0 for rests)`
}
</script>
