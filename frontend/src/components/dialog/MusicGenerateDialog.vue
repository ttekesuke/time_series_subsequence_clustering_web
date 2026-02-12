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
            {{ runButtonLabel }}
          </v-btn>

          <v-btn icon @click="open = false">
            <v-icon>mdi-close</v-icon>
          </v-btn>
        </div>
      </v-card-title>

      <v-card-text class="pa-4 dialog-body">
        <!-- ===== 1. Initial Context (Past Context) ===== -->
        <v-card variant="outlined" class="grid-card context-card">
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
        <v-card variant="outlined" class="grid-card generation-card">
          <GridContainer
            title="2. Generation Parameters (Future Targets)"
            v-model:rows="genRows"
            v-model:steps="genSteps"
            :showRowsLength="false"
            :showColsLength="true"
          >
            <template #toolbar-extra>
              <div class="d-flex align-center mr-4" style="font-size: 0.9rem;">
                <span class="mr-2">MergeThresholdRatio:</span>
                <input
                  type="number"
                  :value="mergeThresholdRatio"
                  @input="onMergeThresholdInput"
                  min="0"
                  max="1"
                  step="0.001"
                  class="step-input mr-1"
                >
              </div>
            </template>
          </GridContainer>
        </v-card>
      </v-card-text>
      <v-card-footer></v-card-footer>
    </v-card>
  </v-dialog>
</template>

<script setup lang="ts">
import { computed, onUnmounted, ref, watch, nextTick } from 'vue'
import axios from 'axios'
import { v4 as uuidv4 } from 'uuid'
import GridContainer from '../grid/GridContainer.vue'

/** ========== props / emit / dialog開閉 ========== */
const props = defineProps({
  modelValue: Boolean,
  progress: { type: Object, required: false }
})
const emit = defineEmits([
  'update:modelValue',
  'generated-polyphonic',
  'dispatched-polyphonic',
  // alias for newer feature component
  'generated',
  'dispatched',
  'progress-update',
  'params-built',
  'params-updated'
])

const open = computed({
  get: () => props.modelValue,
  set: (v: boolean) => emit('update:modelValue', v)
})


/** ========== 実行先切り替え (GitHub Actions / Hosting Server) ========== */
const runOnGithubActions = computed(() => {
  const raw = (import.meta as any).env?.VITE_RUN_GENERATE_POLYPHONIC_ON_GITHUB_ACTIONS ?? 'true'
  return String(raw).toLowerCase() === 'true'
})
const runButtonLabel = computed(() =>
  runOnGithubActions.value ? 'RUN ON GITHUB ACTIONS' : 'RUN'
)


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
  // const { unsubscribe } = useJobChannel(jobId, (data: any) => {
  //   updateProgress({
  //     percent: data.progress ?? progressState.value.percent,
  //     status: data.status
  //   })
  //   if (data.status === 'done') cleanupProgress()
  // })
  // unsubscribeProgress = unsubscribe
}

const isProcessing = computed(
  () => ['start', 'progress', 'rendering'].includes(progressState.value.status)
)

/** ========== 音源側ステート(必要最低限) ========== */
const music = ref({ loading: false, setDataDialog: false, tracks: [] as any[], midiData: null })

/** 共通型 */
type GridRowData = {
  name: string;
  shortName: string;
  data: number[];
  config: {
    min: number;
    max: number;
    step?: number;
    isInt?: boolean;
  }
  help?: any;
}

/** ========== 1. Initial Context 用の定義 ========== */

// 次元(8D): [abs_note(midi), vol, bri, hrd, tex, chord_range(semitones), density, sustain]
const dimensions = [
  { key: 'abs_note', shortName: 'NOTE_ABS', name: 'NOTE (Abs MIDI)' },
  { key: 'vol', shortName: 'VOLUME', name: 'VOLUME' },
  { key: 'bri', shortName: 'BRIGHTNESS', name: 'BRIGHTNESS' },
  { key: 'hrd', shortName: 'HARDNESS', name: 'HARDNESS' },
  { key: 'tex', shortName: 'TEXTURE', name: 'TEXTURE' },
  { key: 'chord_range', shortName: 'CHORD_RANGE', name: 'CHORD RANGE (semitones)' },
  { key: 'density', shortName: 'DENSITY', name: 'DENSITY' },
  { key: 'sustain', shortName: 'SUSTAIN', name: 'SUSTAIN' }
]


// 各次元のデフォルト値 (1ストリーム分) [abs_note, vol, bri, hrd, tex, chord_range, density, sustain]
const defaultContextBase = [60, 1, 0, 0, 0, 0, 0, 0.5]

const contextSteps = ref(3)
const contextStreamCount = ref(1)
const contextRows = ref<GridRowData[]>([])
const suppressContextWatch = ref(false)

const makeContextConfig = (dimKey: string) => {
  if (dimKey === 'abs_note') {
    return { min: 0, max: 127, isInt: true, step: 1 }
  } else if (dimKey === 'chord_range') {
    return { min: 0, max: 127, isInt: true, step: 1 }
  } else if (dimKey === 'density') {
    return { min: 0, max: 1, isInt: false, step: 0.01 }
  } else if (dimKey === 'sustain') {
    return { min: 0, max: 1, isInt: false, step: 0.25 }
  } else {
    // vol/bri/hrd/tex
    return { min: 0, max: 1, isInt: false, step: 0.01 }
  }
}

const makeContextRow = (streamIdx: number, dimIdx: number): GridRowData => {
  const dim = dimensions[dimIdx]
  const base = defaultContextBase[dimIdx] ?? 0
  return {
    name: `S${streamIdx + 1} ${dim.name}`,
    shortName: `S${streamIdx + 1} ${dim.shortName}`,
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
  if (suppressContextWatch.value) return
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
    if (suppressContextWatch.value) return
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
/** 初期コンテキストを [step][stream][dim] に再構成（strict） */
const buildInitialContext = () => {
  const steps = contextSteps.value
  const streams = contextStreamCount.value
  const dimsLen = dimensions.length

  const initial: any[] = []

  for (let step = 0; step < steps; step++) {
    const stepArr: any[] = []
    for (let s = 0; s < streams; s++) {
      const vals: number[] = []
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
        vals.push(v)
      }

      // vals: [abs_note, vol, bri, hrd, tex, chord_range, density, sustain]
      const absNote = Math.round(vals[0] ?? 0)
      const vol = vals[1] ?? 0
      const bri = vals[2] ?? 0
      const hrd = vals[3] ?? 0
      const tex = vals[4] ?? 0
      const chordRange = Math.round(vals[5] ?? 0)
      const density = vals[6] ?? 0
      const sustain = vals[7] ?? 0.5

      // server strict: [abs_notes(Int[]), vol, bri, hrd, tex, chord_range(Int), density, sustain]
      stepArr.push([[absNote], vol, bri, hrd, tex, chordRange, density, sustain])
    }
    initial.push(stepArr)
  }

  return initial
}


/** ========== 2. Generation Parameters 用定義 ========== */
type RowHelp = {
  overview: string
  range: string
  atMin: string
  atMax: string
}

type GenRowMeta = {
  shortName: string
  name: string
  key: string
  min: number
  max: number
  step?: number
  isInt?: boolean
  defaultFactory: (len: number) => number[]
  help?: RowHelp
}

const makeRangeText = (m: Pick<GenRowMeta, "min" | "max" | "step" | "isInt">) => {
  const step = m.isInt ? 1 : (m.step ?? 1)
  return `${m.min}〜${m.max}（step ${step}）`
}

const H = (
  meta: Pick<GenRowMeta, "min" | "max" | "step" | "isInt">,
  overview: string,
  atMin: string,
  atMax: string
): RowHelp => ({
  overview,
  range: makeRangeText(meta),
  atMin,
  atMax
})

const stepsDefault = 3

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
const suppressGenWatch = ref(false)
const mergeThresholdRatio = ref(0.02)

const onMergeThresholdInput = (e: Event) => {
  const target = e.target as HTMLInputElement
  const raw = target.value
  if (raw === '') return
  const v = Number(raw)
  if (!Number.isFinite(v)) return
  mergeThresholdRatio.value = Math.min(1, Math.max(0, v))
}

const genRowMetas: GenRowMeta[] = [
  // =========================================================
  // stream count
  // =========================================================
  {
    shortName: "STREAM COUNT",
    name: "Stream Count (Number of Streams)",
    key: "stream_counts",
    min: 1,
    max: 16,
    step: 1,
    isInt: true,
    defaultFactory: (len) => Array(len).fill(1),
    help: H(
      { min: 1, max: 16, step: 1, isInt: true },
      "各stepで同時に扱うストリーム（声部）の本数を指定します。",
      "1：単一ストリーム（モノフォニック寄り）。",
      "16：最大16ストリーム。探索空間と評価の負荷が増える。"
    )
  },

  // =========================================================
  // stream strength control (vol side)
  // =========================================================
  {
    shortName: "STR Target",
    name: "Stream Strength Target",
    key: "stream_strength_target",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "vol次元のstream側評価で「どの程度ストリーム間の強弱（存在感の差）を作るか」の目標値です。",
      "0：ストリーム間の強弱差を作りにくい（均し寄り）。",
      "1：ストリーム間の強弱差を作りやすい（主役/従役が立ちやすい）。"
    )
  },
  {
    shortName: "STR Spread",
    name: "Stream Strength Spread",
    key: "stream_strength_spread",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "Stream Strength Target を中心に、ストリームごとの強度ターゲットをどのくらい広げるかです（中心±幅）。",
      "0：全ストリームがほぼ同じ強度ターゲット。",
      "1：強度ターゲットの幅が最大。"
    )
  },

  // =========================================================
  // dissonance target (0..1)
  // =========================================================
  {
    shortName: "DIS Target",
    name: "Dissonance Target",
    key: "dissonance_target",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0.3, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "最終段の和音詳細化で、roughness（不協和度）をどれくらいに寄せたいかの目標値です。",
      "0：協和寄り（濁りが少ない）。",
      "1：不協和寄り（濁りが強い）。"
    )
  },

  // =========================================================
  // AREA (macro pitch movement) : global / center / spread / conc
  // =========================================================
  {
    shortName: "AREA G",
    name: "AREA Global Complexity",
    key: "area_global",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "音高の大まかな動き（エリア遷移）の global 複雑度ターゲットです。",
      "0：同じエリアに留まりやすい。",
      "1：エリアがよく変わる。"
    )
  },
  {
    shortName: "AREA C",
    name: "AREA Center",
    key: "area_center",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
  },
  {
    shortName: "AREA S",
    name: "AREA Spread",
    key: "area_spread",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
  },
  {
    shortName: "AREA Conc",
    name: "AREA Conformity (Conc)",
    key: "area_conc",
    min: -1,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
  },

  // =========================================================
  // CHORD_RANGE : global / center / spread / conc
  // =========================================================
  {
    shortName: "CR G",
    name: "CHORD_RANGE Global Complexity",
    key: "chord_range_global",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "和音の幅（最低音〜最高音の半音幅）をどう動かすかの複雑度ターゲットです。",
      "0：幅が変わりにくい。",
      "1：幅がよく変わる。"
    )
  },
  {
    shortName: "CR C",
    name: "CHORD_RANGE Center",
    key: "chord_range_center",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
  },
  {
    shortName: "CR S",
    name: "CHORD_RANGE Spread",
    key: "chord_range_spread",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
  },
  {
    shortName: "CR Conc",
    name: "CHORD_RANGE Conformity (Conc)",
    key: "chord_range_conc",
    min: -1,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
  },
  {
    shortName: "CR Target",
    name: "CHORD_RANGE Target",
    key: "chord_range_target",
    min: 0,
    max: 12,
    step: 1,
    isInt: true,
    defaultFactory: (len) => constant(6, len),
    help: H(
      { min: 0, max: 12, step: 1, isInt: true },
      "CHORD_RANGE の探索中心値です。",
      "0：狭い幅を中心に探索。",
      "12：広い幅を中心に探索。"
    )
  },
  {
    shortName: "CR Spread",
    name: "CHORD_RANGE Spread (Target Window)",
    key: "chord_range_target_spread",
    min: 0,
    max: 12,
    step: 1,
    isInt: true,
    defaultFactory: (len) => constant(12, len),
    help: H(
      { min: 0, max: 12, step: 1, isInt: true },
      "CHORD_RANGE の探索許容幅（中心±幅）です。",
      "0：中心値のみ探索。",
      "12：ほぼ全域を探索。"
    )
  },

  // =========================================================
  // DENSITY : global / center / spread / conc
  // =========================================================
  {
    shortName: "DEN G",
    name: "DENSITY Global Complexity",
    key: "density_global",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "和音内にどれだけ音を詰めるか（密度）をどう動かすかの複雑度ターゲットです。",
      "0：密度が変わりにくい。",
      "1：密度がよく変わる。"
    )
  },
  {
    shortName: "DEN C",
    name: "DENSITY Center",
    key: "density_center",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
  },
  {
    shortName: "DEN S",
    name: "DENSITY Spread",
    key: "density_spread",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
  },
  {
    shortName: "DEN Conc",
    name: "DENSITY Conformity (Conc)",
    key: "density_conc",
    min: -1,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
  },
  {
    shortName: "DEN Target",
    name: "DENSITY Target",
    key: "density_target",
    min: 0,
    max: 1,
    step: 0.1,
    defaultFactory: (len) => constant(0.5, len),
    help: H(
      { min: 0, max: 1, step: 0.1 },
      "DENSITY の探索中心値です（0.1刻み）。",
      "0：低密度中心。",
      "1：高密度中心。"
    )
  },
  {
    shortName: "DEN Spread",
    name: "DENSITY Spread (Target Window)",
    key: "density_target_spread",
    min: 0,
    max: 1,
    step: 0.1,
    defaultFactory: (len) => constant(1, len),
    help: H(
      { min: 0, max: 1, step: 0.1 },
      "DENSITY の探索許容幅（中心±幅、0.1刻み）です。",
      "0：中心値のみ探索。",
      "1：ほぼ全域を探索。"
    )
  },

  // =========================================================
  // SUSTAIN : global / center / spread / conc (+ target window)
  // =========================================================
  {
    shortName: "SUS G",
    name: "SUSTAIN Global Complexity",
    key: "sustain_global",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "音を次の発音へどれだけ滑らかにつなぐか（サステイン感）の変化複雑度です。",
      "0：サステイン感が変わりにくい。",
      "1：サステイン感がよく変わる。"
    )
  },
  {
    shortName: "SUS C",
    name: "SUSTAIN Center",
    key: "sustain_center",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0.5, len),
  },
  {
    shortName: "SUS S",
    name: "SUSTAIN Spread",
    key: "sustain_spread",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
  },
  {
    shortName: "SUS Conc",
    name: "SUSTAIN Conformity (Conc)",
    key: "sustain_conc",
    min: -1,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
  },
  {
    shortName: "SUS Target",
    name: "SUSTAIN Target",
    key: "sustain_target",
    min: 0,
    max: 1,
    step: 0.25,
    defaultFactory: (len) => constant(0.5, len),
    help: H(
      { min: 0, max: 1, step: 0.25 },
      "SUSTAIN の探索中心値です（0.0/0.25/0.5/0.75/1.0）。",
      "0：切れやすい。",
      "1：つながりやすい。"
    )
  },
  {
    shortName: "SUS Spread",
    name: "SUSTAIN Spread (Target Window)",
    key: "sustain_target_spread",
    min: 0,
    max: 1,
    step: 0.25,
    defaultFactory: (len) => constant(1, len),
    help: H(
      { min: 0, max: 1, step: 0.25 },
      "SUSTAIN の探索許容幅（中心±幅）です。",
      "0：中心値のみ探索。",
      "1：5候補を広く探索。"
    )
  },

  // =========================================================
  // vol/bri/hrd/tex : global / center / spread / conc
  // =========================================================
  {
    shortName: "VOL G",
    name: "VOLUME Global Complexity",
    key: "vol_global",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
  },
  { shortName: "VOL C", name: "VOLUME Center", key: "vol_center", min: 0, max: 1, step: 0.01, defaultFactory: (len) => constant(0, len) },
  { shortName: "VOL S", name: "VOLUME Spread", key: "vol_spread", min: 0, max: 1, step: 0.01, defaultFactory: (len) => constant(0, len) },
  { shortName: "VOL Conc", name: "VOLUME Conformity (Conc)", key: "vol_conc", min: -1, max: 1, step: 0.01, defaultFactory: (len) => constant(0, len) },
  {
    shortName: "VOL Target",
    name: "VOLUME Target",
    key: "vol_target",
    min: 0,
    max: 1,
    step: 0.1,
    defaultFactory: (len) => constant(0.5, len),
    help: H(
      { min: 0, max: 1, step: 0.1 },
      "VOLUME の探索中心値です（0.1刻み）。",
      "0：小さめ音量中心。",
      "1：大きめ音量中心。"
    )
  },
  {
    shortName: "VOL Spread",
    name: "VOLUME Spread (Target Window)",
    key: "vol_target_spread",
    min: 0,
    max: 1,
    step: 0.1,
    defaultFactory: (len) => constant(1, len),
    help: H(
      { min: 0, max: 1, step: 0.1 },
      "VOLUME の探索許容幅（中心±幅、0.1刻み）です。",
      "0：中心値のみ探索。",
      "1：ほぼ全域を探索。"
    )
  },

  { shortName: "BRI G", name: "BRIGHTNESS Global Complexity", key: "bri_global", min: 0, max: 1, step: 0.01, defaultFactory: (len) => constant(0, len) },
  { shortName: "BRI C", name: "BRIGHTNESS Center", key: "bri_center", min: 0, max: 1, step: 0.01, defaultFactory: (len) => constant(0, len) },
  { shortName: "BRI S", name: "BRIGHTNESS Spread", key: "bri_spread", min: 0, max: 1, step: 0.01, defaultFactory: (len) => constant(0, len) },
  { shortName: "BRI Conc", name: "BRIGHTNESS Conformity (Conc)", key: "bri_conc", min: -1, max: 1, step: 0.01, defaultFactory: (len) => constant(0, len) },

  { shortName: "HRD G", name: "HARDNESS Global Complexity", key: "hrd_global", min: 0, max: 1, step: 0.01, defaultFactory: (len) => constant(0, len) },
  { shortName: "HRD C", name: "HARDNESS Center", key: "hrd_center", min: 0, max: 1, step: 0.01, defaultFactory: (len) => constant(0, len) },
  { shortName: "HRD S", name: "HARDNESS Spread", key: "hrd_spread", min: 0, max: 1, step: 0.01, defaultFactory: (len) => constant(0, len) },
  { shortName: "HRD Conc", name: "HARDNESS Conformity (Conc)", key: "hrd_conc", min: -1, max: 1, step: 0.01, defaultFactory: (len) => constant(0, len) },

  { shortName: "TEX G", name: "TEXTURE Global Complexity", key: "tex_global", min: 0, max: 1, step: 0.01, defaultFactory: (len) => constant(0, len) },
  { shortName: "TEX C", name: "TEXTURE Center", key: "tex_center", min: 0, max: 1, step: 0.01, defaultFactory: (len) => constant(0, len) },
  { shortName: "TEX S", name: "TEXTURE Spread", key: "tex_spread", min: 0, max: 1, step: 0.01, defaultFactory: (len) => constant(0, len) },
  { shortName: "TEX Conc", name: "TEXTURE Conformity (Conc)", key: "tex_conc", min: -1, max: 1, step: 0.01, defaultFactory: (len) => constant(0, len) },
]

// rows 実体
const genRows = ref<GridRowData[]>(
  genRowMetas.map((meta) => ({
    name: meta.name,
    shortName: meta.shortName,
    data: meta.defaultFactory(genSteps.value),
    config: {
      min: meta.min,
      max: meta.max,
      step: meta.step,
      isInt: meta.isInt
    },
    help: meta.help
  }))
)

// steps 変更時に row.data を合わせる
watch(genSteps, (len) => {
  if (suppressGenWatch.value) return
  genRows.value = genRows.value.map((row, idx) => {
    const meta = genRowMetas[idx]
    const data = [...row.data]
    while (data.length < len) {
      data.push(data.length > 0 ? data[data.length - 1] : (meta.isInt ? meta.min : 0))
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

  result.stream_strength_target = get('stream_strength_target')
  result.stream_strength_spread = get('stream_strength_spread')
  result.dissonance_target      = get('dissonance_target')

  // macro pitch movement
  result.area_global  = get('area_global')
  result.area_center  = get('area_center')
  result.area_spread  = get('area_spread')
  result.area_conc    = get('area_conc')

  // chord controls
  result.chord_range_global = get('chord_range_global')
  result.chord_range_center = get('chord_range_center')
  result.chord_range_spread = get('chord_range_spread')
  result.chord_range_conc   = get('chord_range_conc')
  result.chord_range_target = get('chord_range_target')
  result.chord_range_target_spread = get('chord_range_target_spread')

  result.density_global = get('density_global')
  result.density_center = get('density_center')
  result.density_spread = get('density_spread')
  result.density_conc   = get('density_conc')
  result.density_target = get('density_target')
  result.density_target_spread = get('density_target_spread')

  result.sustain_global = get('sustain_global')
  result.sustain_center = get('sustain_center')
  result.sustain_spread = get('sustain_spread')
  result.sustain_conc   = get('sustain_conc')
  result.sustain_target = get('sustain_target')
  result.sustain_target_spread = get('sustain_target_spread')

  // timbre-ish controls
  result.vol_global = get('vol_global')
  result.vol_center = get('vol_center')
  result.vol_spread = get('vol_spread')
  result.vol_conc   = get('vol_conc')
  result.vol_target = get('vol_target')
  result.vol_target_spread = get('vol_target_spread')

  result.bri_global = get('bri_global')
  result.bri_center = get('bri_center')
  result.bri_spread = get('bri_spread')
  result.bri_conc   = get('bri_conc')

  result.hrd_global = get('hrd_global')
  result.hrd_center = get('hrd_center')
  result.hrd_spread = get('hrd_spread')
  result.hrd_conc   = get('hrd_conc')

  result.tex_global = get('tex_global')
  result.tex_center = get('tex_center')
  result.tex_spread = get('tex_spread')
  result.tex_conc   = get('tex_conc')

  return result
}

const normalizeNumber = (val: any, fallback: number) => {
  const num = Number(val)
  return Number.isFinite(num) ? num : fallback
}

const normalizeArray = (val: any) => {
  if (Array.isArray(val)) return val
  if (val == null) return []
  return [val]
}

const applyInitialContextFromPayload = async (ctxRaw: any) => {
  if (!Array.isArray(ctxRaw)) return
  const steps = Math.max(1, ctxRaw.length)
  const streamCount = Math.max(
    1,
    ...ctxRaw.map((step: any) => (Array.isArray(step) ? step.length : 0))
  )

  suppressContextWatch.value = true
  contextSteps.value = steps
  contextStreamCount.value = streamCount

  const rows: GridRowData[] = []
  for (let s = 0; s < streamCount; s++) {
    for (let d = 0; d < dimensions.length; d++) {
      const row = makeContextRow(s, d)
      const base = defaultContextBase[d] ?? 0
      const data: number[] = []
      for (let step = 0; step < steps; step++) {
        const stepArr = ctxRaw[step]
        const streamArr = Array.isArray(stepArr) ? stepArr[s] : null
        let rawVal = Array.isArray(streamArr) ? streamArr[d] : null
        if (d === 0 && Array.isArray(rawVal)) rawVal = rawVal[0]
        let v = normalizeNumber(rawVal, base)
        const cfg = row.config
        if (cfg) {
          if (cfg.isInt) v = Math.round(v)
          if (v < cfg.min) v = cfg.min
          if (v > cfg.max) v = cfg.max
        }
        data.push(v)
      }
      row.data = data
      rows.push(row)
    }
  }

  contextRows.value = rows
  await nextTick()
  suppressContextWatch.value = false
}

const applyGenParamsFromPayload = async (payload: any) => {
  const candidate = payload?.generate_polyphonic ?? payload ?? {}
  if (candidate.merge_threshold_ratio != null) {
    const v = normalizeNumber(candidate.merge_threshold_ratio, mergeThresholdRatio.value)
    mergeThresholdRatio.value = Math.min(1, Math.max(0, Number(v)))
  }

  const lengths = genRowMetas.map((meta) => {
    const val = candidate[meta.key]
    return Array.isArray(val) ? val.length : (val != null ? 1 : 0)
  })
  const steps = Math.max(1, ...lengths)

  suppressGenWatch.value = true
  genSteps.value = steps

  genRows.value = genRowMetas.map((meta) => {
    const arr = normalizeArray(candidate[meta.key]).map((v: any) => normalizeNumber(v, meta.isInt ? meta.min : 0))
    const data: number[] = []
    for (let i = 0; i < steps; i++) {
      let v = arr[i]
      if (v == null) {
        v = meta.isInt ? meta.min : 0
      }
      if (meta.isInt) v = Math.round(v)
      else v = Number(Number(v).toFixed(2))
      if (v < meta.min) v = meta.min
      if (v > meta.max) v = meta.max
      data.push(v)
    }

    return {
      name: meta.name,
      shortName: meta.shortName,
      data,
      config: {
        min: meta.min,
        max: meta.max,
        step: meta.step,
        isInt: meta.isInt
      },
      help: meta.help
    } as GridRowData
  })

  await nextTick()
  suppressGenWatch.value = false
}

const buildParamsPayload = (jobIdOverride?: string) => {
  const genParams = buildGenParamsFromRows()
  const initialContext = buildInitialContext()
  const jobId = jobIdOverride || uuidv4()

  const payload: any = {
    generate_polyphonic: {
      job_id: jobId,
      stream_counts: genParams.stream_counts,
      initial_context: initialContext,
      merge_threshold_ratio: mergeThresholdRatio.value,
      stream_strength_target: genParams.stream_strength_target,
      stream_strength_spread: genParams.stream_strength_spread,
      dissonance_target: genParams.dissonance_target
    }
  }

  ;['area', 'chord_range', 'density', 'sustain', 'vol', 'bri', 'hrd', 'tex'].forEach((k) => {
    payload.generate_polyphonic[`${k}_global`] = genParams[`${k}_global`]
    payload.generate_polyphonic[`${k}_center`] = genParams[`${k}_center`]
    payload.generate_polyphonic[`${k}_spread`] = genParams[`${k}_spread`]
    payload.generate_polyphonic[`${k}_conc`] = genParams[`${k}_conc`]
  })
  ;['vol', 'chord_range', 'density', 'sustain'].forEach((k) => {
    payload.generate_polyphonic[`${k}_target`] = genParams[`${k}_target`]
    payload.generate_polyphonic[`${k}_target_spread`] = genParams[`${k}_target_spread`]
  })

  return payload
}

const applyParamsPayload = async (payload: any) => {
  if (!payload || typeof payload !== 'object') return
  const candidate = payload.generate_polyphonic ?? payload
  await applyInitialContextFromPayload(candidate.initial_context)
  await applyGenParamsFromPayload(candidate)
}

/** ========== サーバ呼び出し ========== */
const handleGeneratePolyphonic = async () => {
  try {
    const jobId = uuidv4()
    const payload = buildParamsPayload(jobId)
    emit('params-built', payload)

    const endpoint = runOnGithubActions.value
      ? '/api/web/time_series/dispatch_generate_polyphonic'
      : '/api/web/time_series/generate_polyphonic'

    const resp = await axios.post(endpoint, payload)

    if (runOnGithubActions.value) {
      emit('dispatched-polyphonic', resp.data)
      emit('dispatched', resp.data)
    } else {
      emit('generated-polyphonic', resp.data)
      emit('generated', resp.data)
    }

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
defineExpose({ open, applyParamsPayload, buildParamsPayload })

watch(open, (next, prev) => {
  if (prev && !next) {
    emit('params-updated', buildParamsPayload())
  }
})
</script>

<style scoped>
.dialog-body {
  max-height: 80vh;
  overflow-y: auto;
  overflow-x: hidden;
}
.grid-card {
  min-height: 0;
  overflow: hidden;
  margin-bottom: 16px;
}
.context-card {
  height: clamp(260px, 36vh, 420px);
}
.generation-card {
  height: clamp(420px, 78vh, 900px);
  margin-bottom: 0;
}
.step-input {
  width: 60px;
  border: 1px solid #ccc;
  padding: 2px 5px;
  border-radius: 4px;
  background: white;
}
</style>
