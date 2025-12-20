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
import { computed, onUnmounted, ref, watch, nextTick } from 'vue'
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
  shortName: string;
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
  { key: 'octave', shortName: 'OCTAVE', name: 'OCTAVE' },
  { key: 'note', shortName: 'NOTE', name: 'NOTE' },
  { key: 'vol', shortName: 'VOLUME', name: 'VOLUME' },
  { key: 'bri', shortName: 'BRIGHTNESS', name: 'BRIGHTNESS' },
  { key: 'hrd', shortName: 'HARDNESS', name: 'HARDNESS' },
  { key: 'tex', shortName: 'TEXTURE', name: 'TEXTURE' }
]

// 各次元のデフォルト値 (1ストリーム分) [oct, note, vol, bri, hrd, tex]
const defaultContextBase = [4, 0, 1, 0, 0, 0]

const contextSteps = ref(3)
const contextStreamCount = ref(1)
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
      "各stepで同時に扱うストリーム（声部）の本数を指定します。以降の全パラメータは、この本数に応じて「同時発音の並び（和音/配置）」が決まります。",
      "1：単一ストリーム。配置・クラスタリングが単純で追跡しやすい（モノフォニック寄り）。",
      "16：最大16ストリーム。多層化しやすいが、探索空間と評価の負荷が増える（ただしアルゴリズムは決定論）。"
    )
  },

  // =========================================================
  // stream strength control
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
      "0：全ストリームがほぼ同じ強度ターゲットになる（差を作りにくい）。",
      "1：強度ターゲットの幅が最大（強い/弱いの役割が分かれやすい）。"
    )
  },

  // =========================================================
  // dissonance target (0..1)
  // =========================================================
  {
    shortName: "DISSON Target",
    name: "Dissonance Target (STM Roughness Target)",
    key: "dissonance_target",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "STM roughness（不協和度）で、12Ck候補の中から「そのstepで使う pitch-class 集合」を選ぶための目標です。今の実装では octave/volume/chord_size を仮置きして roughness を測り、targetに最も近い集合を選びます。",
      "0：より協和寄り（roughnessが低い候補を選びやすい）。",
      "1：より不協和寄り（roughnessが高い候補を選びやすい）。"
    )
  },

  // =========================================================
  // chord_size params (7th concept)
  // =========================================================
  {
    shortName: "CHORD Global",
    name: "Chord Size Global Target",
    key: "chord_size_global",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "各streamの chord_size（和音構成音数）の「同時刻パターン（全ストリームまとめた並び）」の時系列的な複雑度を、global側でどれくらい目標にするかです。",
      "0：和音数パターンが単純・反復しやすい（似た並びが続く）。",
      "1：和音数パターンが複雑・変化しやすい（並びが揺れやすい）。"
    )
  },
  {
    shortName: "CHORD Center",
    name: "Chord Size Stream Center",
    key: "chord_size_center",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "各streamの chord_size を stream側でどう分布させるかの中心位置です（stream_targets の中心）。",
      "0：stream_targets の中心が低め（全体的に小さめの chord_size を狙いやすい）。",
      "1：stream_targets の中心が高め（全体的に大きめの chord_size を狙いやすい）。"
    )
  },
  {
    shortName: "CHORD Spread",
    name: "Chord Size Stream Spread",
    key: "chord_size_spread",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "stream_targets の広がり（spread）の強さです。高いほどストリーム間のばらつきを抑え、低いほどばらけやすくします。",
      "0：ストリーム間で chord_size がばらけやすい（役割分担が出やすい）。",
      "1：ストリーム間で chord_size が揃いやすい（均質になりやすい）。"
    )
  },
  {
    shortName: "CHORD Conc",
    name: "Chord Size Concordance Weight",
    key: "chord_size_conc",
    min: -1,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: -1, max: 1, step: 0.01 },
      "同時刻の値（和音数）の“幅”を罰則にする重みです（discordance×weight）。負の場合は無視します。",
      "-1：同時刻の幅（最大-最小）を評価から外す（罰則なし）。",
      "1：同時刻の幅が大きいほど強く罰する（揃った chord_size を好む）。"
    )
  },

  // =========================================================
  // octave
  // =========================================================
  {
    shortName: "OCT Global",
    name: "Octave Global Target",
    key: "octave_global",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "octave（各streamのオクターブ）の同時刻パターンの時系列的複雑度を global 側でどれくらい目標にするかです。",
      "0：オクターブ配置の変化が単純・反復しやすい。",
      "1：オクターブ配置の変化が複雑・揺れやすい。"
    )
  },
  {
    shortName: "OCT Center",
    name: "Octave Stream Center",
    key: "octave_center",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "stream側での octave ターゲット分布の中心です（低域寄り/高域寄り）。",
      "0：低域寄りの octave を狙いやすい。",
      "1：高域寄りの octave を狙いやすい。"
    )
  },
  {
    shortName: "OCT Spread",
    name: "Octave Stream Spread",
    key: "octave_spread",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "octave の stream_targets のばらつき抑制です。",
      "0：ストリーム間で octave がばらけやすい（上下に広がりやすい）。",
      "1：ストリーム間で octave が揃いやすい（密集しやすい）。"
    )
  },
  {
    shortName: "OCT Conc",
    name: "Octave Concordance Weight",
    key: "octave_conc",
    min: -1,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: -1, max: 1, step: 0.01 },
      "同時刻の octave 幅（max-min）を罰則にする重みです。負なら無視。",
      "-1：同時刻の octave 幅を評価から外す（罰則なし）。",
      "1：同時刻の octave 幅を強く抑える（同じ帯域に集めやすい）。"
    )
  },

  // =========================================================
  // note
  // =========================================================
  {
    shortName: "NOTE Global",
    name: "Note Global Target (Root Notes Only)",
    key: "note_global",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "note（root note; 0..11）の同時刻パターンの時系列的複雑度を global 側でどれくらい目標にするかです。※実体の和音 pitch-class 集合は dissonance + chord_size で別決定し、ここは root の配置最適化（shift後の候補から選択）に使います。",
      "0：root配置が単純・反復しやすい（似たroot並びが続く）。",
      "1：root配置が複雑・変化しやすい（root並びが揺れやすい）。"
    )
  },
  {
    shortName: "NOTE Center",
    name: "Note Stream Center",
    key: "note_center",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "stream側での root note ターゲット分布の中心です（低いpitch-class寄り/高いpitch-class寄り）。",
      "0：低めの pitch-class を狙いやすい。",
      "1：高めの pitch-class を狙いやすい。"
    )
  },
  {
    shortName: "NOTE Spread",
    name: "Note Stream Spread",
    key: "note_spread",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "root note の stream_targets のばらつき抑制です。",
      "0：ストリーム間で root note がばらけやすい（分散しやすい）。",
      "1：ストリーム間で root note が揃いやすい（同じ/近い音に寄りやすい）。"
    )
  },
  {
    shortName: "NOTE Conc",
    name: "Note Concordance Weight",
    key: "note_conc",
    min: -1,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: -1, max: 1, step: 0.01 },
      "同時刻の root note 幅（max-min）を罰則にする重みです。負なら無視。",
      "-1：同時刻の root note 幅を評価から外す（罰則なし）。",
      "1：同時刻の root note 幅を強く抑える（同じ音付近に寄せやすい）。"
    )
  },

  // =========================================================
  // volume
  // =========================================================
  {
    shortName: "VOL Global",
    name: "Volume Global Target",
    key: "vol_global",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "vol（音量）の同時刻パターンの時系列的複雑度を global 側でどれくらい目標にするかです。",
      "0：音量パターンが単純・反復しやすい。",
      "1：音量パターンが複雑・変化しやすい。"
    )
  },
  {
    shortName: "VOL Center",
    name: "Volume Stream Center",
    key: "vol_center",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "stream側での vol ターゲット分布の中心です（全体的に小さめ/大きめ）。",
      "0：全体的に小さめの vol を狙いやすい。",
      "1：全体的に大きめの vol を狙いやすい。"
    )
  },
  {
    shortName: "VOL Spread",
    name: "Volume Stream Spread",
    key: "vol_spread",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "vol の stream_targets のばらつき抑制です。",
      "0：ストリーム間で vol がばらけやすい（強弱差が出やすい）。",
      "1：ストリーム間で vol が揃いやすい（均質になりやすい）。"
    )
  },
  {
    shortName: "VOL Conc",
    name: "Volume Concordance Weight",
    key: "vol_conc",
    min: -1,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: -1, max: 1, step: 0.01 },
      "同時刻の vol 幅（max-min）を罰則にする重みです。負なら無視。",
      "-1：同時刻の vol 幅を評価から外す（罰則なし）。",
      "1：同時刻の vol 幅を強く抑える（全ストリームの音量が揃いやすい）。"
    )
  },

  // =========================================================
  // brightness
  // =========================================================
  {
    shortName: "BRI Global",
    name: "Brightness Global Target",
    key: "bri_global",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "bri（明るさ）の同時刻パターンの時系列的複雑度を global 側でどれくらい目標にするかです。",
      "0：明るさパターンが単純・反復しやすい。",
      "1：明るさパターンが複雑・変化しやすい。"
    )
  },
  {
    shortName: "BRI Center",
    name: "Brightness Stream Center",
    key: "bri_center",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "stream側での bri ターゲット分布の中心です。",
      "0：暗め（bri低め）を狙いやすい。",
      "1：明るめ（bri高め）を狙いやすい。"
    )
  },
  {
    shortName: "BRI Spread",
    name: "Brightness Stream Spread",
    key: "bri_spread",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "bri の stream_targets のばらつき抑制です。",
      "0：ストリーム間で bri がばらけやすい（役割差が出やすい）。",
      "1：ストリーム間で bri が揃いやすい（均質になりやすい）。"
    )
  },
  {
    shortName: "BRI Conc",
    name: "Brightness Concordance Weight",
    key: "bri_conc",
    min: -1,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: -1, max: 1, step: 0.01 },
      "同時刻の bri 幅（max-min）を罰則にする重みです。負なら無視。",
      "-1：同時刻の bri 幅を評価から外す（罰則なし）。",
      "1：同時刻の bri 幅を強く抑える（同時に似た明るさに寄せやすい）。"
    )
  },

  // =========================================================
  // hardness
  // =========================================================
  {
    shortName: "HRD Global",
    name: "Hardness Global Target",
    key: "hrd_global",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "hrd（硬さ）の同時刻パターンの時系列的複雑度を global 側でどれくらい目標にするかです。",
      "0：硬さパターンが単純・反復しやすい。",
      "1：硬さパターンが複雑・変化しやすい。"
    )
  },
  {
    shortName: "HRD Center",
    name: "Hardness Stream Center",
    key: "hrd_center",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "stream側での hrd ターゲット分布の中心です。",
      "0：柔らかめ（hrd低め）を狙いやすい。",
      "1：硬め（hrd高め）を狙いやすい。"
    )
  },
  {
    shortName: "HRD Spread",
    name: "Hardness Stream Spread",
    key: "hrd_spread",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "hrd の stream_targets のばらつき抑制です。",
      "0：ストリーム間で hrd がばらけやすい。",
      "1：ストリーム間で hrd が揃いやすい。"
    )
  },
  {
    shortName: "HRD Conc",
    name: "Hardness Concordance Weight",
    key: "hrd_conc",
    min: -1,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: -1, max: 1, step: 0.01 },
      "同時刻の hrd 幅（max-min）を罰則にする重みです。負なら無視。",
      "-1：同時刻の hrd 幅を評価から外す。",
      "1：同時刻の hrd 幅を強く抑える（同時に似た硬さに寄せやすい）。"
    )
  },

  // =========================================================
  // texture
  // =========================================================
  {
    shortName: "TEX Global",
    name: "Texture Global Target",
    key: "tex_global",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "tex（テクスチャ/粗さ）の同時刻パターンの時系列的複雑度を global 側でどれくらい目標にするかです。",
      "0：テクスチャ変化が単純・反復しやすい。",
      "1：テクスチャ変化が複雑・変化しやすい。"
    )
  },
  {
    shortName: "TEX Center",
    name: "Texture Stream Center",
    key: "tex_center",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "stream側での tex ターゲット分布の中心です。",
      "0：tex低めを狙いやすい。",
      "1：tex高めを狙いやすい。"
    )
  },
  {
    shortName: "TEX Spread",
    name: "Texture Stream Spread",
    key: "tex_spread",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "tex の stream_targets のばらつき抑制です。",
      "0：ストリーム間で tex がばらけやすい。",
      "1：ストリーム間で tex が揃いやすい。"
    )
  },
  {
    shortName: "TEX Conc",
    name: "Texture Concordance Weight",
    key: "tex_conc",
    min: -1,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: -1, max: 1, step: 0.01 },
      "同時刻の tex 幅（max-min）を罰則にする重みです。負なら無視。",
      "-1：同時刻の tex 幅を評価から外す。",
      "1：同時刻の tex 幅を強く抑える（同時に似た質感に寄せやすい）。"
    )
  }
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

  // ★追加
  result.stream_strength_target = get('stream_strength_target')
  result.stream_strength_spread = get('stream_strength_spread')
  result.dissonance_target      = get('dissonance_target')

  // ★追加 (chord_size)
  result.chord_size_global      = get('chord_size_global')
  result.chord_size_center       = get('chord_size_center')
  result.chord_size_spread   = get('chord_size_spread')
  result.chord_size_conc        = get('chord_size_conc')

  // 既存6次元
  result.octave_global    = get('octave_global')
  result.octave_center     = get('octave_center')
  result.octave_spread = get('octave_spread')
  result.octave_conc      = get('octave_conc')

  result.note_global      = get('note_global')
  result.note_center       = get('note_center')
  result.note_spread   = get('note_spread')
  result.note_conc        = get('note_conc')

  result.vol_global       = get('vol_global')
  result.vol_center        = get('vol_center')
  result.vol_spread    = get('vol_spread')
  result.vol_conc         = get('vol_conc')

  result.bri_global       = get('bri_global')
  result.bri_center        = get('bri_center')
  result.bri_spread    = get('bri_spread')
  result.bri_conc         = get('bri_conc')

  result.hrd_global       = get('hrd_global')
  result.hrd_center        = get('hrd_center')
  result.hrd_spread    = get('hrd_spread')
  result.hrd_conc         = get('hrd_conc')

  result.tex_global       = get('tex_global')
  result.tex_center        = get('tex_center')
  result.tex_spread    = get('tex_spread')
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

    // ★重要: すべて generate_polyphonic 配下にネストする
    const payload: any = {
      generate_polyphonic: {
        job_id: jobId,
        stream_counts: genParams.stream_counts,
        initial_context: initialContext,

        stream_strength_target: genParams.stream_strength_target,
        stream_strength_spread: genParams.stream_strength_spread,
        dissonance_target:      genParams.dissonance_target,
      }
    }

    ;['octave', 'note', 'vol', 'bri', 'hrd', 'tex', 'chord_size'].forEach((k) => {
      payload.generate_polyphonic[`${k}_global`]    = genParams[`${k}_global`]
      payload.generate_polyphonic[`${k}_center`]     = genParams[`${k}_center`]
      payload.generate_polyphonic[`${k}_spread`] = genParams[`${k}_spread`]
      payload.generate_polyphonic[`${k}_conc`]      = genParams[`${k}_conc`]
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
