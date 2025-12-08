<template>
  <v-dialog height="98%" width="98%" v-model="open" scrollable>
    <v-card>
      <!-- ===== ヘッダ（タイトル / 進捗 / 実行ボタン） ===== -->
      <v-card-title class="text-h5 grey lighten-2 d-flex align-center justify-space-between py-2">
        <span>Polyphonic Stream Generation Parameters</span>
        <div class="d-flex align-center">
          <div
            class="mr-4 text-caption"
            v-if="progressState.status === 'progress' || progressState.status === 'rendering'"
          >
            <span v-if="progressState.status === 'progress'">
              Generating: {{ progressState.percent }}%
            </span>
            <span v-if="progressState.status === 'rendering'">
              Rendering Audio...
            </span>
          </div>

          <v-btn
            color="success"
            class="mr-2"
            :loading="music.loading || isProcessing"
            :disabled="isProcessing"
            @click="handleGeneratePolyphonic"
          >
            GENERATE &amp; RENDER
          </v-btn>

          <v-btn icon @click="open = false">
            <v-icon>mdi-close</v-icon>
          </v-btn>
        </div>
      </v-card-title>

      <v-card-text class="pa-4" style="height: 80vh;">
        <!-- ===== 1. Initial Context (Past Context) ===== -->
        <v-card variant="outlined" class="mb-4 grid-card">
          <GridContainer
            title="1. Initial Context (Past Context)"
            v-model:rows="contextRows"
            v-model:steps="contextSteps"
            v-model:streamCount="contextStreamCount"
            :showStreamCount="true"
            :showRowsLength="false"
            :showColsLength="true"
          />
        </v-card>

        <!-- ===== 2. Generation Parameters (Future Targets) ===== -->
        <v-card variant="outlined" class="grid-card">
          <GridContainer
            title="2. Generation Parameters (Future Targets)"
            v-model:rows="genRows"
            v-model:steps="genSteps"
            :showRowsLength="false"
            :showColsLength="true"
          />
        </v-card>
      </v-card-text>
    </v-card>
  </v-dialog>
</template>

<script setup lang="ts">
import { computed, onUnmounted, ref, watch } from 'vue'
import axios from 'axios'
import { v4 as uuidv4 } from 'uuid'
import { useJobChannel } from '../../composables/useJobChannel'
import GridContainer from '../grid/GridContainer.vue'

/** ========== props / emit / dialog開閉 ========== */
const props = defineProps({
  modelValue: Boolean,
  progress: { type: Object, required: false }
})
const emit = defineEmits(['update:modelValue', 'generated-polyphonic', 'progress-update'])

const open = computed({
  get: () => props.modelValue,
  set: (v: boolean) => emit('update:modelValue', v)
})

/** ========== 進捗管理 ========== */
const progressState = ref<{ percent: number; status: string }>(
  props.progress || { percent: 0, status: 'idle' }
)
watch(
  () => props.progress,
  (val) => { if (val) progressState.value = val }
)

const updateProgress = (data: { percent: number; status: string }) => {
  progressState.value = data
  emit('progress-update', data)
}

let unsubscribeProgress: (() => void) | null = null

const cleanupProgress = () => {
  if (unsubscribeProgress) {
    unsubscribeProgress()
    unsubscribeProgress = null
  }
}

const startProgressTracking = (jobId: string) => {
  cleanupProgress()
  updateProgress({ percent: 0, status: 'start' })
  const { unsubscribe } = useJobChannel(jobId, (data: any) => {
    updateProgress({
      percent: data.progress ?? progressState.value.percent,
      status: data.status
    })
    if (data.status === 'done') cleanupProgress()
  })
  unsubscribeProgress = unsubscribe
}

const isProcessing = computed(
  () => ['start', 'progress', 'rendering'].includes(progressState.value.status)
)

/** ========== 音源側ステート(必要最低限) ========== */
const music = ref({ loading: false, setDataDialog: false, tracks: [] as any[], midiData: null })

/** 共通型 */
type GridRowData = {
  name: string;
  data: number[];
  config: {
    min: number;
    max: number;
    step?: number;
    isInt?: boolean;
  }
}

/** ========== 1. Initial Context 用の定義 ========== */

// 次元(6D): [oct, note, vol, bri, hrd, tex]
const dimensions = [
  { key: 'octave', label: 'OCTAVE' },
  { key: 'note', label: 'NOTE' },
  { key: 'vol', label: 'VOLUME' },
  { key: 'bri', label: 'BRIGHTNESS' },
  { key: 'hrd', label: 'HARDNESS' },
  { key: 'tex', label: 'TEXTURE' }
]

// 各次元のデフォルト値 (1ストリーム分) [oct, note, vol, bri, hrd, tex]
const defaultContextBase = [4, 0, 0.8, 0.2, 0.2, 0.0]

const contextSteps = ref(3)
const contextStreamCount = ref(2)
const contextRows = ref<GridRowData[]>([])

const makeContextConfig = (dimKey: string) => {
  if (dimKey === 'octave') {
    return { min: 0, max: 10, isInt: true, step: 1 }
  } else if (dimKey === 'note') {
    return { min: 0, max: 11, isInt: true, step: 1 }
  } else {
    return { min: 0, max: 1, isInt: false, step: 0.01 }
  }
}

const makeContextRow = (streamIdx: number, dimIdx: number): GridRowData => {
  const dim = dimensions[dimIdx]
  const base = defaultContextBase[dimIdx] ?? 0
  return {
    name: `S${streamIdx + 1} ${dim.label}`,
    data: Array(contextSteps.value).fill(base),
    config: makeContextConfig(dim.key)
  }
}

// 初期化
const initContextRows = () => {
  const rows: GridRowData[] = []
  for (let s = 0; s < contextStreamCount.value; s++) {
    for (let d = 0; d < dimensions.length; d++) {
      rows.push(makeContextRow(s, d))
    }
  }
  contextRows.value = rows
}
initContextRows()

// Steps が増減したとき: 行データを合わせる
watch(contextSteps, (len) => {
  contextRows.value = contextRows.value.map((row) => {
    const data = [...row.data]
    while (data.length < len) {
      data.push(data.length > 0 ? data[data.length - 1] : 0)
    }
    if (data.length > len) data.splice(len)
    return { ...row, data }
  })
})

// Streams が増減したとき: 6行単位で追加/削除
watch(
  contextStreamCount,
  (newVal, oldVal) => {
    if (oldVal == null) return
    const prev = oldVal as number
    const curr = newVal as number
    const rowsPerStream = dimensions.length

    if (curr > prev) {
      for (let s = prev; s < curr; s++) {
        for (let d = 0; d < dimensions.length; d++) {
          contextRows.value.push(makeContextRow(s, d))
        }
      }
    } else if (curr < prev) {
      const removeCount = (prev - curr) * rowsPerStream
      contextRows.value.splice(contextRows.value.length - removeCount, removeCount)
    }
  }
)

/** 初期コンテキストを [step][stream][dim] に再構成 */
const buildInitialContext = () => {
  const steps = contextSteps.value
  const streams = contextStreamCount.value
  const dimsLen = dimensions.length

  const initial: number[][][] = []

  for (let step = 0; step < steps; step++) {
    const stepArr: number[][] = []
    for (let s = 0; s < streams; s++) {
      const dimVals: number[] = []
      for (let d = 0; d < dimsLen; d++) {
        const rowIndex = s * dimsLen + d
        const row = contextRows.value[rowIndex]
        let v = row?.data[step] ?? 0
        const cfg = row?.config
        if (cfg) {
          if (cfg.isInt) v = Math.round(v)
          if (v < cfg.min) v = cfg.min
          if (v > cfg.max) v = cfg.max
        }
        dimVals.push(v)
      }
      stepArr.push(dimVals)
    }
    initial.push(stepArr)
  }

  return initial
}

/** ========== 2. Generation Parameters 用定義 ========== */

type GenRowMeta = {
  name: string;
  key: string;
  min: number;
  max: number;
  step?: number;
  isInt?: boolean;
  defaultFactory: (len: number) => number[];
}

const stepsDefault = 10

const fill = (start: number, mid: number, end: number, len: number = stepsDefault) => {
  const arr: number[] = []
  const pivot = Math.floor(len / 2)
  for (let i = 0; i < len; i++) {
    if (i < pivot) {
      arr.push(Number((start + (mid - start) * (i / Math.max(pivot, 1))).toFixed(2)))
    } else {
      const denom = Math.max(len - pivot - 1, 1)
      arr.push(Number((mid + (end - mid) * ((i - pivot) / denom)).toFixed(2)))
    }
  }
  return arr
}
const constant = (val: number, len: number = stepsDefault) => Array(len).fill(val)

const genSteps = ref<number>(stepsDefault)

const genRowMetas: GenRowMeta[] = [
  { // stream count
    name: 'STREAM COUNT',
    key: 'stream_counts',
    min: 1,
    max: 16,
    step: 1,
    isInt: true,
    defaultFactory: (len) => Array(len).fill(2)
  },
  // octave
  { name: 'OCT Global', key: 'octave_global', min: 0, max: 1, step: 0.01,
    defaultFactory: (len) => fill(0.0, 0.1, 1.0, len) },
  { name: 'OCT Ratio', key: 'octave_ratio', min: 0, max: 1, step: 0.01,
    defaultFactory: (len) => fill(0.0, 0.5, 1.0, len) },
  { name: 'OCT Tight', key: 'octave_tightness', min: 0, max: 1, step: 0.01,
    defaultFactory: (len) => constant(1.0, len) },
  { name: 'OCT Conc', key: 'octave_conc', min: -1, max: 1, step: 0.01,
    defaultFactory: (len) => fill(0.8, 0.5, 0.0, len) },

  // note
  { name: 'NOTE Global', key: 'note_global', min: 0, max: 1, step: 0.01,
    defaultFactory: (len) => fill(0.2, 0.5, 0.8, len) },
  { name: 'NOTE Ratio', key: 'note_ratio', min: 0, max: 1, step: 0.01,
    defaultFactory: (len) => fill(0.0, 0.5, 1.0, len) },
  { name: 'NOTE Tight', key: 'note_tightness', min: 0, max: 1, step: 0.01,
    defaultFactory: (len) => constant(0.5, len) },
  { name: 'NOTE Conc', key: 'note_conc', min: -1, max: 1, step: 0.01,
    defaultFactory: (len) => fill(0.8, 0.8, 0.2, len) },

  // volume
  { name: 'VOL Global', key: 'vol_global', min: 0, max: 1, step: 0.01,
    defaultFactory: (len) => constant(0.1, len) },
  { name: 'VOL Ratio', key: 'vol_ratio', min: 0, max: 1, step: 0.01,
    defaultFactory: (len) => constant(0.0, len) },
  { name: 'VOL Tight', key: 'vol_tightness', min: 0, max: 1, step: 0.01,
    defaultFactory: (len) => constant(0.0, len) },
  { name: 'VOL Conc', key: 'vol_conc', min: -1, max: 1, step: 0.01,
    defaultFactory: (len) => constant(1.0, len) },

  // brightness
  { name: 'BRI Global', key: 'bri_global', min: 0, max: 1, step: 0.01,
    defaultFactory: (len) => fill(0.1, 0.5, 1.0, len) },
  { name: 'BRI Ratio', key: 'bri_ratio', min: 0, max: 1, step: 0.01,
    defaultFactory: (len) => fill(0.0, 1.0, 1.0, len) },
  { name: 'BRI Tight', key: 'bri_tightness', min: 0, max: 1, step: 0.01,
    defaultFactory: (len) => constant(0.5, len) },
  { name: 'BRI Conc', key: 'bri_conc', min: -1, max: 1, step: 0.01,
    defaultFactory: (len) => constant(0.5, len) },

  // hardness
  { name: 'HRD Global', key: 'hrd_global', min: 0, max: 1, step: 0.01,
    defaultFactory: (len) => fill(0.0, 0.2, 0.9, len) },
  { name: 'HRD Ratio', key: 'hrd_ratio', min: 0, max: 1, step: 0.01,
    defaultFactory: (len) => fill(0.0, 0.0, 1.0, len) },
  { name: 'HRD Tight', key: 'hrd_tightness', min: 0, max: 1, step: 0.01,
    defaultFactory: (len) => constant(1.0, len) },
  { name: 'HRD Conc', key: 'hrd_conc', min: -1, max: 1, step: 0.01,
    defaultFactory: (len) => constant(0.5, len) },

  // texture
  { name: 'TEX Global', key: 'tex_global', min: 0, max: 1, step: 0.01,
    defaultFactory: (len) => fill(0.0, 0.0, 1.0, len) },
  { name: 'TEX Ratio', key: 'tex_ratio', min: 0, max: 1, step: 0.01,
    defaultFactory: (len) => fill(0.0, 0.0, 1.0, len) },
  { name: 'TEX Tight', key: 'tex_tightness', min: 0, max: 1, step: 0.01,
    defaultFactory: (len) => constant(1.0, len) },
  { name: 'TEX Conc', key: 'tex_conc', min: -1, max: 1, step: 0.01,
    defaultFactory: (len) => constant(0.0, len) }
]

// rows 実体
const genRows = ref<GridRowData[]>(
  genRowMetas.map((meta) => ({
    name: meta.name,
    data: meta.defaultFactory(genSteps.value),
    config: {
      min: meta.min,
      max: meta.max,
      step: meta.step,
      isInt: meta.isInt
    }
  }))
)

// steps 変更時に row.data を合わせる
watch(genSteps, (len) => {
  genRows.value = genRows.value.map((row, idx) => {
    const meta = genRowMetas[idx]
    const data = [...row.data]
    while (data.length < len) {
      data.push(meta.isInt ? meta.min : 0)
    }
    if (data.length > len) data.splice(len)
    return { ...row, data }
  })
})

// meta を key で引くマップ
const genMetaByKey: Record<string, GenRowMeta> = {}
genRowMetas.forEach((m) => { genMetaByKey[m.key] = m })

// rows からサーバ送信用パラメータ構築
const buildGenParamsFromRows = () => {
  const len = genSteps.value

  const ensureLen = (arr: number[] | undefined, meta: GenRowMeta) => {
    const out: number[] = []
    for (let i = 0; i < len; i++) {
      let v = (arr && i < arr.length && arr[i] != null)
        ? Number(arr[i])
        : (meta.isInt ? meta.min : 0)

      if (meta.isInt) v = Math.round(v)
      else v = Number(v.toFixed(2))

      if (v < meta.min) v = meta.min
      if (v > meta.max) v = meta.max

      out.push(v)
    }
    return out
  }

  const get = (key: string): number[] => {
    const meta = genMetaByKey[key]
    const idx = genRowMetas.indexOf(meta)
    const row = genRows.value[idx]
    return ensureLen(row?.data, meta)
  }

  const result: any = {}

  result.stream_counts = get('stream_counts')

  result.octave_global    = get('octave_global')
  result.octave_ratio     = get('octave_ratio')
  result.octave_tightness = get('octave_tightness')
  result.octave_conc      = get('octave_conc')

  result.note_global      = get('note_global')
  result.note_ratio       = get('note_ratio')
  result.note_tightness   = get('note_tightness')
  result.note_conc        = get('note_conc')

  result.vol_global       = get('vol_global')
  result.vol_ratio        = get('vol_ratio')
  result.vol_tightness    = get('vol_tightness')
  result.vol_conc         = get('vol_conc')

  result.bri_global       = get('bri_global')
  result.bri_ratio        = get('bri_ratio')
  result.bri_tightness    = get('bri_tightness')
  result.bri_conc         = get('bri_conc')

  result.hrd_global       = get('hrd_global')
  result.hrd_ratio        = get('hrd_ratio')
  result.hrd_tightness    = get('hrd_tightness')
  result.hrd_conc         = get('hrd_conc')

  result.tex_global       = get('tex_global')
  result.tex_ratio        = get('tex_ratio')
  result.tex_tightness    = get('tex_tightness')
  result.tex_conc         = get('tex_conc')

  return result
}

/** ========== サーバ呼び出し ========== */
const handleGeneratePolyphonic = async () => {
  try {
    const jobId = uuidv4()
    startProgressTracking(jobId)

    const genParams = buildGenParamsFromRows()
    const initialContext = buildInitialContext()

    const payload: any = {
      generate_polyphonic: {
        job_id: jobId,
        stream_counts: genParams.stream_counts,
        initial_context: initialContext
      }
    }

    ;['octave', 'note', 'vol', 'bri', 'hrd', 'tex'].forEach((k) => {
      payload[`${k}_global`]    = genParams[`${k}_global`]
      payload[`${k}_ratio`]     = genParams[`${k}_ratio`]
      payload[`${k}_tightness`] = genParams[`${k}_tightness`]
      payload[`${k}_conc`]      = genParams[`${k}_conc`]
    })

    const resp = await axios.post('/api/web/time_series/generate_polyphonic', payload)
    emit('generated-polyphonic', resp.data)

    open.value = false
  } catch (err) {
    console.error('Generate request failed', err)
  } finally {
    if (!['rendering', 'done'].includes(progressState.value.status)) {
      updateProgress({ percent: 0, status: 'idle' })
    }
    cleanupProgress()
  }
}

onUnmounted(() => cleanupProgress())

/** 親から open を操作したい場合用 */
import { defineExpose } from 'vue'
defineExpose({ open })
</script>

<style scoped>
.grid-card {
  overflow-x: auto;
  overflow-y: hidden;
  margin-bottom: 16px;
}
.step-input {
  width: 60px;
  border: 1px solid #ccc;
  padding: 2px 5px;
  border-radius: 4px;
  background: white;
}
</style>
