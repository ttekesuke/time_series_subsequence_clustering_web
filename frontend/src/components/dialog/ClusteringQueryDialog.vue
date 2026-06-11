<template>
  <v-dialog width="1000" v-model="open">
    <v-form>
      <v-card>
        <v-card-title>
          <div class="text-h4">Clustering Query</div>
        </v-card-title>
        <v-card-text>
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

          <div style="height:240px; overflow:auto;" class="mb-4">
            <GridContainer
              v-model:rows="queryRows"
              v-model:steps="querySteps"
              :showRowsLength="false"
              :showColsLength="true"
            />
          </div>

                  <!-- DB preview removed: DB is provided by server-side InfluxDB -->

          <v-row class="mt-4">
            <v-col cols="3">
              <v-text-field label="range min" type="number" v-model.number="rangeMin"></v-text-field>
            </v-col>
            <v-col cols="3">
              <v-text-field label="range max" type="number" v-model.number="rangeMax"></v-text-field>
            </v-col>
            <v-col cols="3">
              <v-text-field
                label="merge threshold"
                type="number"
                v-model.number="mergeThreshold"
                min="0" step="0.01"
              ></v-text-field>
            </v-col>
            <v-col cols="3">
              <v-text-field
                label="min match window"
                type="number"
                v-model.number="minMatchWindow"
                min="2" step="1"
              ></v-text-field>
            </v-col>
            <v-col cols="3">
              <v-btn color="success" :loading="loading" @click="handleQuery">Query</v-btn>
            </v-col>
          </v-row>
        </v-card-text>
      </v-card>
    </v-form>
  </v-dialog>
</template>

<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import GridContainer from '../grid/GridContainer.vue'
import axios from 'axios'

const props = defineProps({ modelValue: Boolean })
const emit = defineEmits(['update:modelValue', 'queried'])
const open = computed({ get: () => props.modelValue, set: (v: boolean) => emit('update:modelValue', v) })

// query rows
type GridRowData = {
  name: string; shortName: string; data: number[]; config: { min:number; max:number; step?:number; isInt?:boolean }
}
const querySteps = ref(8)
const queryRows = ref<GridRowData[]>([
  { name: 'querySeries', shortName: 'Query', data: Array(querySteps.value).fill(0), config: { min:0, max:11, isInt:true, step:1 } }
])

const rangeMin = ref(0)
const rangeMax = ref(127)
const mergeThreshold = ref(0.02)
const minMatchWindow = ref(3)
const loading = ref(false)

type ChordNoteMode = 'highest' | 'lowest'
type MidiEvent = {
  tick: number;
  channel: number;
  note: number;
  velocity: number;
  on: boolean;
}
type ParsedMidiTrack = {
  index: number;
  name: string;
  events: MidiEvent[];
}
type ParsedMidi = {
  format: number;
  division: number;
  ticksPerQuarter: number;
  tracks: ParsedMidiTrack[];
}
type MidiSeries = {
  pitch: number[];
  velocity: number[];
  activeSteps: number;
  restSteps: number;
}

const parsedMidi = ref<ParsedMidi | null>(null)
const selectedTrackIndex = ref<number | null>(null)
const selectedChannel = ref<number | 'all'>('all')
const chordNoteMode = ref<ChordNoteMode>('highest')
const midiSummary = ref('')
const midiError = ref('')

const chordNoteOptions = [
  { title: 'Highest note', value: 'highest' },
  { title: 'Lowest note', value: 'lowest' }
]

const midiTrackOptions = computed(() => {
  if (!parsedMidi.value) return []
  return parsedMidi.value.tracks
    .filter(t => t.events.length > 0)
    .map(t => {
      const channels = Array.from(new Set(t.events.map(e => e.channel))).sort((a, b) => a - b)
      const titleName = t.name ? `: ${t.name}` : ''
      return {
        title: `Track ${t.index + 1}${titleName} (${t.events.length} events / ch ${channels.join(',')})`,
        value: t.index
      }
    })
})

const midiChannelOptions = computed(() => {
  if (!parsedMidi.value || selectedTrackIndex.value == null) return []
  const track = parsedMidi.value.tracks[selectedTrackIndex.value]
  if (!track) return []
  const channels = Array.from(new Set(track.events.map(e => e.channel))).sort((a, b) => a - b)
  return [
    { title: 'All', value: 'all' as const },
    ...channels.map(ch => ({ title: `Ch ${ch}`, value: ch }))
  ]
})

const canExtractMidi = computed(() =>
  !!parsedMidi.value &&
  selectedTrackIndex.value != null &&
  midiTrackOptions.value.length > 0
)

watch(selectedTrackIndex, () => {
  selectedChannel.value = 'all'
})

// Keep query row length in sync when steps change
watch(() => querySteps.value, (len) => {
  const v = Math.max(1, Number(len) || 1)
  queryRows.value = queryRows.value.map((row) => {
    const newData = Array.from(row.data || [])
    if (newData.length < v) {
      while (newData.length < v) newData.push(0)
    } else if (newData.length > v) {
      newData.splice(v)
    }
    return { ...row, data: newData }
  })
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
    const b = bytes[state.pos++]
    value = (value << 7) | (b & 0x7f)
    count += 1
    if ((b & 0x80) === 0) break
    if (count > 4) break
  }
  return value
}

const parseMidi = (bytes: Uint8Array): ParsedMidi => {
  let pos = 0
  const readChunk = () => {
    if (pos + 8 > bytes.length) throw new Error('Invalid MIDI chunk header')
    const id = readAscii(bytes, pos, 4); pos += 4
    const length = readU32BE(bytes, pos); pos += 4
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
  for (let ti = 0; ti < numTracks && pos < bytes.length; ti++) {
    const chunk = readChunk()
    if (chunk.id !== 'MTrk') continue

    const events: MidiEvent[] = []
    let name = ''
    let tick = 0
    let i = chunk.start
    let runningStatus = -1

    while (i < chunk.end) {
      const state = { pos: i }
      const delta = readVarLen(bytes, state)
      i = state.pos
      tick += delta
      if (i >= chunk.end) break

      let status = bytes[i]
      if (status < 0x80) {
        if (runningStatus < 0) break
        status = runningStatus
      } else {
        i += 1
        if (status < 0xf0) runningStatus = status
        else runningStatus = -1
      }

      if (status === 0xff) {
        if (i >= chunk.end) break
        const metaType = bytes[i++]
        const lenState = { pos: i }
        const metaLen = readVarLen(bytes, lenState)
        i = lenState.pos
        if (metaType === 0x03) name = readAscii(bytes, i, Math.min(metaLen, chunk.end - i))
        i += metaLen
        continue
      }

      if (status === 0xf0 || status === 0xf7) {
        const lenState = { pos: i }
        const syxLen = readVarLen(bytes, lenState)
        i = lenState.pos + syxLen
        continue
      }

      const kind = status & 0xf0
      const channel = (status & 0x0f) + 1

      if (kind === 0x80 || kind === 0x90) {
        if (i + 1 >= chunk.end) break
        const note = bytes[i++]
        const velocity = bytes[i++]
        const on = kind === 0x90 && velocity > 0
        events.push({ tick, channel, note, velocity, on })
      } else if (kind === 0xa0 || kind === 0xb0 || kind === 0xe0) {
        i += 2
      } else if (kind === 0xc0 || kind === 0xd0) {
        i += 1
      } else {
        break
      }
    }

    tracks.push({ index: ti, name, events })
  }

  return { format, division: divisionRaw, ticksPerQuarter, tracks }
}

const extractMidiSeries = (
  midi: ParsedMidi,
  trackIndex: number,
  channel: number | 'all',
  noteMode: ChordNoteMode
): MidiSeries => {
  const track = midi.tracks[trackIndex]
  if (!track) return { pitch: [], velocity: [], activeSteps: 0, restSteps: 0 }

  const events = track.events
    .filter(e => channel === 'all' || e.channel === channel)
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
  let eidx = 0
  let lastPitch = 0
  let hasSounded = false
  let activeSteps = 0

  for (let s = 0; s < totalSteps; s++) {
    const stepTick = s * ticksPerStep
    while (eidx < events.length && events[eidx].tick <= stepTick) {
      const ev = events[eidx]
      const cur = active.get(ev.note)
      if (ev.on) {
        active.set(ev.note, { count: (cur?.count ?? 0) + 1, velocity: ev.velocity })
      } else if (!cur || cur.count <= 1) {
        active.delete(ev.note)
      } else {
        active.set(ev.note, { count: cur.count - 1, velocity: cur.velocity })
      }
      eidx += 1
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

  return { pitch, velocity, activeSteps, restSteps: velocity.filter(v => v === 0).length }
}

const onMidiFilePicked = async (val: File | File[] | null) => {
  midiError.value = ''
  midiSummary.value = ''
  parsedMidi.value = null
  selectedTrackIndex.value = null
  selectedChannel.value = 'all'

  const file = Array.isArray(val) ? val[0] : val
  if (!file) return

  try {
    const buf = await file.arrayBuffer()
    const parsed = parseMidi(new Uint8Array(buf))
    parsedMidi.value = parsed
    if (midiTrackOptions.value.length > 0) selectedTrackIndex.value = Number(midiTrackOptions.value[0].value)
    midiSummary.value = `MIDI loaded: format=${parsed.format}, tracks=${parsed.tracks.length}, PPQ=${parsed.ticksPerQuarter}`
  } catch (err: any) {
    midiError.value = `Failed to parse MIDI: ${err?.message ?? String(err)}`
  }
}

const applyMidiToGrid = () => {
  if (!parsedMidi.value || selectedTrackIndex.value == null) return
  const series = extractMidiSeries(
    parsedMidi.value,
    selectedTrackIndex.value,
    selectedChannel.value,
    chordNoteMode.value
  )

  const rows: GridRowData[] = [
    { name: 'midiPitch', shortName: 'Pitch', data: series.pitch, config: { min: 0, max: 127, isInt: true, step: 1 } },
    { name: 'midiVol', shortName: 'Vol', data: series.velocity, config: { min: 0, max: 1, isInt: true, step: 1 } }
  ]

  const nextRows = rows.length > 0 ? rows : [
    { name: 'querySeries', shortName: 'Query', data: [0], config: { min: 0, max: 127, isInt: true, step: 1 } }
  ]
  queryRows.value = nextRows
  querySteps.value = Math.max(1, nextRows[0].data.length)
  rangeMin.value = 0
  rangeMax.value = 127
  midiSummary.value = `Extracted steps=${nextRows[0].data.length}, note-steps=${series.activeSteps}, rests=${series.restSteps} (${chordNoteMode.value} note, vol=1 for sounding / 0 for rests)`
}

const buildQueryPoints = () => {
  const pitch = queryRows.value.find(row => row.name === 'midiPitch')?.data || []
  const velocity = queryRows.value.find(row => row.name === 'midiVol')?.data || []
  const len = Math.min(pitch.length, velocity.length)
  const out: number[][] = []
  for (let i = 0; i < len; i++) {
    const p = Math.max(0, Math.min(127, Math.round(Number(pitch[i]) || 0)))
    const v = Number(velocity[i]) > 0 ? 1 : 0
    out.push([p, v])
  }
  return out
}

// naive incremental matching algorithm
const handleQuery = async () => {
  loading.value = true
  try {
    const queryPoints = buildQueryPoints()
    const queryVectors = queryRows.value.map(row => Array.isArray(row.data) ? row.data : [])
    const payload = {
      query: {
        query_series: queryPoints.map(pt => pt[0]),
        query_points: queryPoints,
        query_vectors: queryVectors,
        query_axes: queryRows.value.map(row => row.name),
        query_mode: 'midi_note_vol',
        measurement: 'timeseries',
        batch_size: 500,
        merge_threshold_ratio: mergeThreshold.value,
        range_min: rangeMin.value,
        range_max: rangeMax.value,
        min_match_window: minMatchWindow.value
      }
    }

    const resp = await axios.post('/api/web/time_series/query_db', payload)
    // pass through response
    const data = resp.data
    emit('queried', { ...data, rangeMin: rangeMin.value, rangeMax: rangeMax.value })
    open.value = false
  } catch (err) {
    console.error('Query request failed', err)
  } finally {
    loading.value = false
  }
}
</script>

<style scoped>
</style>
