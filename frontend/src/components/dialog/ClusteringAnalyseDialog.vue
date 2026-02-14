<template>
  <v-dialog width="1000" v-model="open">
    <v-form fast-fail>
      <v-card>
        <v-card-title>
          <v-row>
            <v-col cols="5">
              <div class="text-h4 d-flex align-center fill-height">Clustering Analyse</div>
            </v-col>
          </v-row>
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
                MIDI -> Grid
              </v-btn>
            </v-col>
          </v-row>

          <v-row v-if="midiSummary || midiError" class="mb-2">
            <v-col>
              <div class="text-caption text-error" v-if="midiError">{{ midiError }}</div>
              <div class="text-caption" v-else>{{ midiSummary }}</div>
            </v-col>
          </v-row>

          <GridContainer
            v-model:rows="rows"
            v-model:steps="steps"
            :showRowsLength="false"
          />

          <v-row>
            <v-col>
              <v-row>
                <v-col cols="4">
                  <v-text-field
                    label="merge threshold ratio"
                    type="number"
                    v-model="mergeThreshold"
                    min="0"
                    max="1"
                    step="0.01"
                  ></v-text-field>
                </v-col>
                <v-col cols="4">
                  <v-btn @click="handleAnalyseTimeseries" :loading="loading" color="success">Submit</v-btn>
                  <span v-if="props.progress.status == 'start' || props.progress.status == 'progress'">{{ props.progress.percent }}%</span>
                </v-col>
              </v-row>
            </v-col>
          </v-row>
        </v-card-text>
      </v-card>
    </v-form>
  </v-dialog>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue'
const props = defineProps({
  modelValue: Boolean,
  progress: { type: Object, required: false },
  onFileSelected: { type: Function, required: false },
  jobId: { type: String, required: false }
})
const emit = defineEmits(['update:modelValue', 'analysed'])

const open = computed({
  get: () => props.modelValue,
  set: (v: boolean) => emit('update:modelValue', v)
})

import GridContainer from '../grid/GridContainer.vue'
import axios from 'axios'

type GridRowData = {
  name: string;
  shortName: string;
  data: Array<number | null>;
  config: {
    min: number;
    max?: number;
    isInt?: boolean;
    step?: number;
  };
}

type MidiEvent = {
  tick: number;
  channel: number; // 1..16
  note: number;
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

const rows = ref<GridRowData[]>([
  {
    name: 'analysingValues',
    shortName: 'Analysing Values',
    data: [0, 0, 0],
    config: {
      min: -1,
      max: 127,
      isInt: true,
      step: 1
    }
  },
])
const steps = ref(3)
const mergeThreshold = ref(0.02)
const loading = ref(false)
const parsedMidi = ref<ParsedMidi | null>(null)
const selectedTrackIndex = ref<number | null>(null)
const selectedChannel = ref<number | 'all'>('all')
const midiSummary = ref('')
const midiError = ref('')

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
        if (metaType === 0x03) {
          name = readAscii(bytes, i, Math.min(metaLen, chunk.end - i))
        }
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
        const vel = bytes[i++]
        const on = kind === 0x90 && vel > 0
        events.push({ tick, channel, note, on })
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

  return {
    format,
    division: divisionRaw,
    ticksPerQuarter,
    tracks
  }
}

const extractHighestMidiSeries = (
  midi: ParsedMidi,
  trackIndex: number,
  channel: number | 'all'
): Array<number | null> => {
  const track = midi.tracks[trackIndex]
  if (!track) return []

  const events = track.events
    .filter(e => channel === 'all' || e.channel === channel)
    .slice()
    .sort((a, b) => {
      if (a.tick !== b.tick) return a.tick - b.tick
      if (a.on === b.on) return 0
      return a.on ? 1 : -1 // off first
    })

  if (events.length === 0) return []

  const ticksPerStep = Math.max(1, Math.round(midi.ticksPerQuarter / 4)) // 16th-note grid
  const maxTick = events[events.length - 1].tick
  const totalSteps = Math.max(1, Math.floor(maxTick / ticksPerStep) + 1)

  const active = new Map<number, number>()
  const out: Array<number | null> = []
  let eidx = 0

  for (let s = 0; s < totalSteps; s++) {
    const stepTick = s * ticksPerStep
    while (eidx < events.length && events[eidx].tick <= stepTick) {
      const ev = events[eidx]
      const cur = active.get(ev.note) ?? 0
      if (ev.on) {
        active.set(ev.note, cur + 1)
      } else if (cur <= 1) {
        active.delete(ev.note)
      } else {
        active.set(ev.note, cur - 1)
      }
      eidx += 1
    }

    const highest = active.size > 0 ? Math.max(...Array.from(active.keys())) : null
    out.push(highest)
  }

  while (out.length > 0 && out[out.length - 1] == null) out.pop()
  return out
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

    if (midiTrackOptions.value.length > 0) {
      selectedTrackIndex.value = Number(midiTrackOptions.value[0].value)
    }

    midiSummary.value = `MIDI loaded: format=${parsed.format}, tracks=${parsed.tracks.length}, PPQ=${parsed.ticksPerQuarter}`
  } catch (err: any) {
    midiError.value = `Failed to parse MIDI: ${err?.message ?? String(err)}`
  }
}

const applyMidiToGrid = () => {
  if (!parsedMidi.value || selectedTrackIndex.value == null) return

  const seq = extractHighestMidiSeries(
    parsedMidi.value,
    selectedTrackIndex.value,
    selectedChannel.value
  )

  const data = seq.length > 0 ? seq : [null]
  rows.value = [{
    ...rows.value[0],
    data
  }]
  steps.value = Math.max(1, data.length)

  const nPitch = seq.filter(v => v != null).length
  const nRest = seq.length - nPitch
  midiSummary.value = `Extracted steps=${seq.length}, note-steps=${nPitch}, rests=${nRest} (highest note in chord)`
}

const handleAnalyseTimeseries = async () => {
  loading.value = true
  try {
    const raw = (rows.value && rows.value[0] && rows.value[0].data) ? rows.value[0].data : []
    const time_series = raw.map(v => {
      if (v == null) return null
      const n = Number(v)
      return Number.isFinite(n) ? Math.round(n) : null
    })
    const data = {
      analyse: {
        time_series,
        skip_empty: true,
        merge_threshold_ratio: mergeThreshold.value,
        job_id: props.jobId
      }
    }
    const resp = await axios.post('/api/web/time_series/analyse', data)
    // emit full response data to parent; do not mutate parent props here
    emit('analysed', resp.data)
    // close dialog
    open.value = false
  } catch (err) {
    console.error('Analyse request failed', err)
  } finally {
    loading.value = false
  }
}
</script>

<style scoped>
/* keep styling minimal; using existing app styles */
</style>
