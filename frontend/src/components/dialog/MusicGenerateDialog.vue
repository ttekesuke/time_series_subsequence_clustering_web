<template>
  <v-dialog height="98%" width="98%" v-model="open" scrollable>
    <v-card>
      <!-- ===== ヘッダ（タイトル / 進捗 / 実行ボタン） ===== -->
      <v-card-title class="text-h5 grey lighten-2 d-flex align-center justify-space-between py-2">
        <span>Polyphonic Stream Generation</span>
        <div class="d-flex align-center justify-end flex-wrap header-controls">
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
            color="primary"
            variant="outlined"
            class="mr-2"
            :disabled="!canOpenSoundCheck"
            @click="openSoundCheckDialog"
          >
            Sound Check
          </v-btn>

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
            v-model:rows="contextRowsForGrid"
            v-model:steps="contextSteps"
            v-model:streamCount="contextStreamCount"
            @selected-columns-change="onContextSelectedColumnsChange"
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
            :rowLabelWidth="276"
            :rowPrefixWidth="110"
          >
            <template #row-prefix="{ rowIndex }">
              <div class="dimension-policy-row-slot">
                <template v-if="getDimensionPolicyDimForGenRow(rowIndex)">
                  <input
                    type="checkbox"
                    :checked="getDimensionPolicyValue(getDimensionPolicyDimForGenRow(rowIndex)).useFixedValue"
                    @change="onDimensionPolicyAcceptChange(resolveManagedDimKey(getDimensionPolicyDimForGenRow(rowIndex)), $event)"
                    class="dimension-policy-checkbox"
                    :title="`${getDimensionPolicyConfig(getDimensionPolicyDimForGenRow(rowIndex)).label} fixed value`"
                  >
                  <template v-if="getDimensionPolicyValue(getDimensionPolicyDimForGenRow(rowIndex)).useFixedValue">
                    <select
                      :value="getDimensionPolicyValue(getDimensionPolicyDimForGenRow(rowIndex)).fixedValueSource"
                      @change="onDimensionPolicyFixedValueSourceChange(resolveManagedDimKey(getDimensionPolicyDimForGenRow(rowIndex)), $event)"
                      class="step-input dim-policy-select"
                    >
                      <option value="initial_context_last_step">Last Step</option>
                      <option value="manual_input">Manual</option>
                    </select>
                    <input
                      v-if="getDimensionPolicyValue(getDimensionPolicyDimForGenRow(rowIndex)).fixedValueSource === 'manual_input'"
                      type="number"
                      :value="getDimensionPolicyValue(getDimensionPolicyDimForGenRow(rowIndex)).fixedValue"
                      @input="onDimensionPolicyFixedValueInput(resolveManagedDimKey(getDimensionPolicyDimForGenRow(rowIndex)), $event)"
                      :min="getDimensionPolicyConfig(getDimensionPolicyDimForGenRow(rowIndex)).min"
                      :max="getDimensionPolicyConfig(getDimensionPolicyDimForGenRow(rowIndex)).max"
                      :step="getDimensionPolicyConfig(getDimensionPolicyDimForGenRow(rowIndex)).step"
                      class="step-input dim-policy-input"
                    >
                  </template>
                </template>
              </div>
            </template>
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

  <v-dialog v-model="soundCheckDialog" max-width="1200" scrollable>
    <v-card>
      <v-card-title class="text-h6 d-flex align-center justify-space-between">
        <span>Sound Check</span>
        <v-btn icon @click="soundCheckDialog = false">
          <v-icon>mdi-close</v-icon>
        </v-btn>
      </v-card-title>
      <v-card-text>
        <div class="sound-check-layout">
          <v-card variant="outlined" class="sound-check-grid-card">
            <GridContainer
              title="Sound Check Grid"
              v-model:rows="soundCheckRows"
              :steps="1"
              :showRowsLength="false"
              :showColsLength="false"
              :showGenerateParametersButton="false"
            />
          </v-card>

          <div class="sound-check-controls">
            <v-select
              v-model="soundCheckStreamIndex"
              :items="soundCheckStreamItems"
              item-title="title"
              item-value="value"
              label="Target Stream"
              density="compact"
              hide-details
            />

            <div class="d-flex ga-2">
              <v-btn color="success" :loading="soundCheckPlaying" @click="playSoundCheckTone">
                Play
              </v-btn>
              <v-btn color="primary" variant="outlined" @click="saveSoundCheckToInitialContext">
                Save
              </v-btn>
            </div>
          </div>

          <v-card variant="outlined" class="sound-check-fft-card pa-2">
            <Fft :audioEl="soundCheckAudioEl" :width="980" :height="240" />
          </v-card>
        </div>
      </v-card-text>
    </v-card>
  </v-dialog>
</template>

<script setup lang="ts">
import { computed, defineExpose, nextTick, onUnmounted, ref, watch } from 'vue'
import axios from 'axios'
import { v4 as uuidv4 } from 'uuid'
import GridContainer from '../grid/GridContainer.vue'
import Fft from '../audio/Fft.vue'

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
const DEFAULT_BPM = 480

/** 共通型 */
type GridRowData = {
  name: string;
  shortName: string;
  data: Array<number | string>;
  config: {
    min: number;
    max: number;
    step?: number;
    isInt?: boolean;
    inputMode?: 'number' | 'note-array';
  }
  help?: any;
  disabled?: boolean;
}

type ManagedDimKey = 'area' | 'chord_range' | 'density' | 'vol' | 'brightness' | 'noise' | 'harmonicity' | 'attack' | 'decay_sustain' | 'release'

type DimensionPolicyConfig = {
  label: string
  min: number
  max: number
  step: number
  isInt?: boolean
  defaultUseFixedValue: boolean
  defaultFixedValue: number
}

type DimensionFixedValueSource = 'initial_context_last_step' | 'manual_input'

type DimensionPolicyValue = {
  useFixedValue: boolean
  fixedValue: number
  fixedValueSource: DimensionFixedValueSource
}

const managedDimPolicyConfigs: Record<ManagedDimKey, DimensionPolicyConfig> = {
  area: { label: 'AREA', min: 0, max: 1, step: 0.01, defaultUseFixedValue: false, defaultFixedValue: 0.5 },
  chord_range: { label: 'CR', min: 0, max: 24, step: 1, isInt: true, defaultUseFixedValue: false, defaultFixedValue: 0 },
  density: { label: 'DEN', min: 0, max: 1, step: 0.01, defaultUseFixedValue: false, defaultFixedValue: 0 },
  vol: { label: 'VOL', min: 0, max: 1, step: 0.01, defaultUseFixedValue: false, defaultFixedValue: 1 },
  brightness: { label: 'BRI', min: 0, max: 1, step: 0.01, defaultUseFixedValue: false, defaultFixedValue: 0.5 },
  noise: { label: 'NOI', min: 0, max: 1, step: 0.01, defaultUseFixedValue: false, defaultFixedValue: 0.2 },
  harmonicity: { label: 'HAR', min: 0, max: 1, step: 0.01, defaultUseFixedValue: false, defaultFixedValue: 0.5 },
  attack: { label: 'ATK', min: 0, max: 1, step: 0.01, defaultUseFixedValue: false, defaultFixedValue: 0.05 },
  decay_sustain: { label: 'DEC', min: 0, max: 1, step: 0.01, defaultUseFixedValue: false, defaultFixedValue: 0.20 },
  release: { label: 'S/R', min: 0, max: 1, step: 0.01, defaultUseFixedValue: false, defaultFixedValue: 0.75 }
}

const managedDimKeys = Object.keys(managedDimPolicyConfigs) as ManagedDimKey[]

const canonicalizeDimensionFixedValueSource = (raw: unknown): DimensionFixedValueSource => {
  const key = String(raw ?? '').trim().toLowerCase()
  if (
    key === 'initial_context_last_step' ||
    key === 'initial_context' ||
    key === 'context_last_step' ||
    key === 'last_step' ||
    key === 'last-step'
  ) {
    return 'initial_context_last_step'
  }
  return 'manual_input'
}

const createDefaultDimensionPolicy = (): Record<ManagedDimKey, DimensionPolicyValue> => ({
  area: { useFixedValue: managedDimPolicyConfigs.area.defaultUseFixedValue, fixedValue: managedDimPolicyConfigs.area.defaultFixedValue, fixedValueSource: 'manual_input' },
  chord_range: { useFixedValue: managedDimPolicyConfigs.chord_range.defaultUseFixedValue, fixedValue: managedDimPolicyConfigs.chord_range.defaultFixedValue, fixedValueSource: 'manual_input' },
  density: { useFixedValue: managedDimPolicyConfigs.density.defaultUseFixedValue, fixedValue: managedDimPolicyConfigs.density.defaultFixedValue, fixedValueSource: 'manual_input' },
  vol: { useFixedValue: managedDimPolicyConfigs.vol.defaultUseFixedValue, fixedValue: managedDimPolicyConfigs.vol.defaultFixedValue, fixedValueSource: 'manual_input' },
  brightness: { useFixedValue: managedDimPolicyConfigs.brightness.defaultUseFixedValue, fixedValue: managedDimPolicyConfigs.brightness.defaultFixedValue, fixedValueSource: 'manual_input' },
  noise: { useFixedValue: managedDimPolicyConfigs.noise.defaultUseFixedValue, fixedValue: managedDimPolicyConfigs.noise.defaultFixedValue, fixedValueSource: 'manual_input' },
  harmonicity: { useFixedValue: managedDimPolicyConfigs.harmonicity.defaultUseFixedValue, fixedValue: managedDimPolicyConfigs.harmonicity.defaultFixedValue, fixedValueSource: 'manual_input' },
  attack: { useFixedValue: managedDimPolicyConfigs.attack.defaultUseFixedValue, fixedValue: managedDimPolicyConfigs.attack.defaultFixedValue, fixedValueSource: 'manual_input' },
  decay_sustain: { useFixedValue: managedDimPolicyConfigs.decay_sustain.defaultUseFixedValue, fixedValue: managedDimPolicyConfigs.decay_sustain.defaultFixedValue, fixedValueSource: 'manual_input' },
  release: { useFixedValue: managedDimPolicyConfigs.release.defaultUseFixedValue, fixedValue: managedDimPolicyConfigs.release.defaultFixedValue, fixedValueSource: 'manual_input' }
})

const dimensionPolicy = ref<Record<ManagedDimKey, DimensionPolicyValue>>(createDefaultDimensionPolicy())

const coerceFiniteNumber = (val: unknown, fallback: number) => {
  const num = Number(val)
  return isFinite(num) ? num : fallback
}

const coerceBoolean = (val: unknown, fallback: boolean) => {
  if (typeof val === 'boolean') return val
  if (typeof val === 'number') return val !== 0
  if (typeof val === 'string') {
    const normalized = val.trim().toLowerCase()
    if (normalized === 'true') return true
    if (normalized === 'false') return false
    if (normalized === '1') return true
    if (normalized === '0') return false
  }
  return fallback
}

const clampDimensionFixedValue = (key: ManagedDimKey, raw: unknown) => {
  const config = managedDimPolicyConfigs[key]
  let value = coerceFiniteNumber(raw, config.defaultFixedValue)
  if (config.isInt) value = Math.round(value)
  if (value < config.min) value = config.min
  if (value > config.max) value = config.max
  return value
}

const onDimensionPolicyAcceptChange = (key: ManagedDimKey, e: Event) => {
  const target = e.target as HTMLInputElement
  dimensionPolicy.value = {
    ...dimensionPolicy.value,
    [key]: {
      ...dimensionPolicy.value[key],
      useFixedValue: target.checked
    }
  }
}

const onDimensionPolicyFixedValueInput = (key: ManagedDimKey, e: Event) => {
  const target = e.target as HTMLInputElement
  if (target.value === '') return
  dimensionPolicy.value = {
    ...dimensionPolicy.value,
    [key]: {
      ...dimensionPolicy.value[key],
      fixedValue: clampDimensionFixedValue(key, target.value)
    }
  }
}

const onDimensionPolicyFixedValueSourceChange = (key: ManagedDimKey, e: Event) => {
  const target = e.target as HTMLSelectElement
  dimensionPolicy.value = {
    ...dimensionPolicy.value,
    [key]: {
      ...dimensionPolicy.value[key],
      fixedValueSource: canonicalizeDimensionFixedValueSource(target.value)
    }
  }
}

const dimensionPolicyAliases: Record<string, ManagedDimKey> = {
  area: 'area',
  chord_range: 'chord_range',
  density: 'density',
  vol: 'vol',
  brightness: 'brightness',
  noise: 'noise',
  harmonicity: 'harmonicity',
  attack: 'attack',
  decay_sustain: 'decay_sustain',
  release: 'release'
}

const canonicalizeManagedDimKey = (raw: unknown): ManagedDimKey | null => {
  const key = String(raw ?? '').trim().toLowerCase()
  return dimensionPolicyAliases[key] ?? null
}

const resolveManagedDimKey = (raw: unknown): ManagedDimKey => (
  canonicalizeManagedDimKey(raw) ?? 'area'
)

const getDimensionPolicyConfig = (raw: unknown) => {
  const key = resolveManagedDimKey(raw)
  return managedDimPolicyConfigs[key]
}

const getDimensionPolicyValue = (raw: unknown) => {
  const key = resolveManagedDimKey(raw)
  return dimensionPolicy.value[key]
}

const getManagedDimKeyForGenRow = (metaKey: string): ManagedDimKey | null => {
  for (const key of managedDimKeys) {
    if (metaKey === key || metaKey.indexOf(`${key}_`) === 0) return key
  }
  return null
}

const getDimensionPolicyDimForGenRow = (rowIndex: number): ManagedDimKey | null => {
  const meta = genRowMetas[rowIndex]
  if (!meta) return null
  for (const key of managedDimKeys) {
    if (meta.key === `${key}_center`) return key
  }
  return null
}

const isGenRowDisabled = (metaKey: string) => {
  const dimKey = getManagedDimKeyForGenRow(metaKey)
  return dimKey ? dimensionPolicy.value[dimKey].useFixedValue : false
}

const buildDimensionPolicyPayload = () => {
  const result: Record<string, { accept_params: boolean; fixed_value: number; fixed_value_source: DimensionFixedValueSource }> = {}
  for (const key of managedDimKeys) {
    result[key] = {
      // Server contract is accept_params=true => generate from params.
      accept_params: !dimensionPolicy.value[key].useFixedValue,
      fixed_value: getResolvedDimensionPolicyFixedValue(key),
      fixed_value_source: dimensionPolicy.value[key].fixedValueSource
    }
  }
  return result
}

const applyDimensionPolicyFromPayload = (rawPolicy: any) => {
  const next = createDefaultDimensionPolicy()

  if (rawPolicy && typeof rawPolicy === 'object') {
    for (const rawKey in rawPolicy) {
      const rawVal = rawPolicy[rawKey]
      const key = canonicalizeManagedDimKey(rawKey)
      if (!key) continue

      if (rawVal != null && typeof rawVal === 'object' && !Array.isArray(rawVal)) {
        const policy = rawVal as Record<string, any>
        const acceptSource = policy.accept_params ?? policy.receive_params ?? policy.enabled ?? policy.use_user_params
        const fixedModeSource = policy.use_fixed_value ?? policy.fixed_mode
        const fixedSource = policy.fixed_value ?? policy.fallback_value ?? policy.value
        const fixedValueSource = policy.fixed_value_source ?? policy.fixed_source ?? policy.value_source

        if (acceptSource != null) {
          next[key].useFixedValue = !coerceBoolean(acceptSource, !next[key].useFixedValue)
        }
        if (fixedModeSource != null) {
          next[key].useFixedValue = coerceBoolean(fixedModeSource, next[key].useFixedValue)
        }
        if (fixedSource != null) {
          next[key].fixedValue = clampDimensionFixedValue(key, fixedSource)
        }
        if (fixedValueSource != null) {
          next[key].fixedValueSource = canonicalizeDimensionFixedValueSource(fixedValueSource)
        }
      } else if (typeof rawVal === 'boolean') {
        next[key].useFixedValue = !rawVal
      } else if (rawVal != null) {
        next[key].fixedValue = clampDimensionFixedValue(key, rawVal)
      }
    }
  }

  dimensionPolicy.value = next
}

/** ========== 1. Initial Context 用の定義 ========== */

// Initial Context input dimensions: chord_range/density are derived from abs notes.
const contextInputDimensions = [
  { key: 'abs_note', shortName: 'NOTE_ABS', name: 'NOTE (Abs MIDI)' },
  { key: 'vol', shortName: 'VOLUME', name: 'VOLUME' },
  { key: 'brightness', shortName: 'BRIGHTNESS', name: 'BRIGHTNESS' },
  { key: 'noise', shortName: 'NOISE', name: 'NOISE' },
  { key: 'harmonicity', shortName: 'HARMONICITY', name: 'HARMONICITY' },
  { key: 'attack', shortName: 'ATTACK', name: 'ATTACK' },
  { key: 'decay_sustain', shortName: 'DECAY', name: 'DECAY' },
  { key: 'release', shortName: 'SUSTAIN_RELEASE', name: 'SUSTAIN/RELEASE' },
  { key: 'legato', shortName: 'LEGATO', name: 'LEGATO' }
]


// Strict server shape remains derived: [abs_note, vol, brightness, noise, harmonicity, attack, decay_sustain, release, chord_range, density, sustain, legato]
// Input rows omit chord_range/density because they are derived per-step from abs notes.
// Default values still keep strict indices for payload assembly.
const defaultContextInputBase = [60, 1, 0.5, 0.2, 0.8, 0.05, 0.20, 0.75, 0]
const defaultContextBase = [60, 1, 0.5, 0.2, 0.8, 0.05, 0.20, 0.75, 0, 0, 0.5, 0]
const areaBandSize = 4
const areaBandLowMin = 24
const areaBandLowMax = 120

const contextManagedDimensionIndex: Record<Exclude<ManagedDimKey, 'area'>, number> = {
  vol: 1,
  brightness: 2,
  noise: 3,
  harmonicity: 4,
  attack: 5,
  decay_sustain: 6,
  release: 7,
  chord_range: -1,
  density: -1
}

const strictContextIndexByKey = {
  abs_note: 0,
  vol: 1,
  brightness: 2,
  noise: 3,
  harmonicity: 4,
  attack: 5,
  decay_sustain: 6,
  release: 7,
  chord_range: 8,
  density: 9,
  sustain: 10,
  legato: 11
} as const

const contextInputIndexByKey = {
  abs_note: 0,
  vol: 1,
  brightness: 2,
  noise: 3,
  harmonicity: 4,
  attack: 5,
  decay_sustain: 6,
  release: 7,
  legato: 8
} as const

const contextSteps = ref(3)
const contextStreamCount = ref(1)
const contextRows = ref<GridRowData[]>([])
const suppressContextWatch = ref(false)
const selectedContextColumns = ref<number[]>([])
const selectedContextColumnForSoundCheck = ref<number | null>(null)

const canOpenSoundCheck = computed(() => {
  const col = selectedContextColumnForSoundCheck.value
  return col != null && col >= 0 && col < contextSteps.value
})

const makeBpmGridRow = (data: number[]): GridRowData => ({
  name: 'Initial Context BPM',
  shortName: 'BPM',
  data,
  config: {
    min: 1,
    max: 960,
    step: 1,
    isInt: true
  }
})

const initialContextBpm = ref<number[]>(Array(contextSteps.value).fill(DEFAULT_BPM))

const contextRowsForGrid = computed<GridRowData[]>({
  get: () => [
    makeBpmGridRow(initialContextBpm.value),
    ...contextRows.value
  ],
  set: (rows: GridRowData[]) => {
    const nextRows = Array.isArray(rows) ? [...rows] : []
    const bpmRow = nextRows.shift()
    initialContextBpm.value = normalizeBpmSeries(bpmRow?.data, contextSteps.value)
    contextRows.value = nextRows
  }
})

const onContextSelectedColumnsChange = (raw: unknown) => {
  if (!Array.isArray(raw)) {
    selectedContextColumns.value = []
    return
  }

  selectedContextColumns.value = raw
    .map((v) => Number(v))
    .filter((v) => Number.isInteger(v) && v >= 0 && v < contextSteps.value)

  if (selectedContextColumns.value.length === 1) {
    selectedContextColumnForSoundCheck.value = selectedContextColumns.value[0]
  } else if (selectedContextColumns.value.length > 1) {
    selectedContextColumnForSoundCheck.value = null
  }
}

const soundCheckDialog = ref(false)
const soundCheckRows = ref<GridRowData[]>([])
const soundCheckPlaying = ref(false)
const soundCheckStreamIndex = ref(0)
const soundCheckAudioEl = ref<HTMLAudioElement | null>(null)
let soundCheckAudioUrl = ''

const soundCheckStreamItems = computed(() => {
  const items: Array<{ title: string; value: number }> = []
  for (let i = 0; i < contextStreamCount.value; i++) {
    items.push({ title: `Stream ${i + 1}`, value: i })
  }
  return items
})

const cloneRowSingleColumn = (row: GridRowData, colIndex: number): GridRowData => {
  const fallback = row.config.inputMode === 'note-array' ? '' : 0
  return {
    ...row,
    config: { ...row.config },
    data: [row.data[colIndex] ?? fallback]
  }
}

const openSoundCheckDialog = () => {
  if (!canOpenSoundCheck.value) return

  const colIndex = selectedContextColumnForSoundCheck.value as number
  soundCheckRows.value = contextRowsForGrid.value.map((row) => cloneRowSingleColumn(row, colIndex))
  soundCheckStreamIndex.value = Math.min(soundCheckStreamIndex.value, Math.max(0, contextStreamCount.value - 1))
  soundCheckDialog.value = true
}

const cleanupSoundCheckAudio = () => {
  if (soundCheckAudioEl.value) {
    try { soundCheckAudioEl.value.pause() } catch {}
    try { soundCheckAudioEl.value.currentTime = 0 } catch {}
  }
  soundCheckAudioEl.value = null
  if (soundCheckAudioUrl) {
    URL.revokeObjectURL(soundCheckAudioUrl)
    soundCheckAudioUrl = ''
  }
}

const buildStrictContextVoiceFromRows = (rows: GridRowData[], streamIdx: number, stepIdx: number) => {
  const dimsLen = contextInputDimensions.length
  const baseIndex = streamIdx * dimsLen
  const getRowValue = (key: keyof typeof contextInputIndexByKey, fallback: unknown) => {
    const row = rows[baseIndex + contextInputIndexByKey[key]]
    return row?.data?.[stepIdx] ?? fallback
  }

  const absNotes = parseAbsNoteCell(getRowValue('abs_note', ''))
  const vol = Number(getRowValue('vol', 1))
  const brightness = Number(getRowValue('brightness', 0.5))
  const noise = Number(getRowValue('noise', 0.2))
  const harmonicity = Number(getRowValue('harmonicity', 0.5))
  const attack = Number(getRowValue('attack', 0.05))
  const decaySustain = Number(getRowValue('decay_sustain', 0.20))
  const release = Number(getRowValue('release', 0.75))
  const legato = Number(getRowValue('legato', 0))

  return [
    absNotes,
    Math.max(0, Math.min(1, vol)),
    Math.max(0, Math.min(1, brightness)),
    Math.max(0, Math.min(1, noise)),
    Math.max(0, Math.min(1, harmonicity)),
    Math.max(0, Math.min(1, attack)),
    Math.max(0, Math.min(1, decaySustain)),
    Math.max(0, Math.min(1, release)),
    0,
    0,
    0.5,
    Math.max(0, Math.min(1, legato))
  ]
}

const buildSoundCheckVoice = (streamIdx: number) => {
  // Sound Check uses the same simplified strict tuple assembly as normal generation.
  // Its rows are a 1-step slice cloned from the selected initial-context column.
  return buildStrictContextVoiceFromRows(soundCheckRows.value.slice(1), streamIdx, 0)
}

const decodeBase64AudioToObjectUrl = (audioData: string) => {
  const base64 = audioData.includes(',') ? audioData.split(',')[1] : audioData
  const binary = atob(base64)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  const blob = new Blob([bytes.buffer], { type: 'audio/wav' })
  return URL.createObjectURL(blob)
}

const playSoundCheckTone = async () => {
  if (!soundCheckDialog.value) return

  const streamIdx = Math.max(0, Math.min(contextStreamCount.value - 1, Number(soundCheckStreamIndex.value) || 0))
  const bpm = normalizeBpm(soundCheckRows.value[0]?.data?.[0] ?? DEFAULT_BPM)
  const voice = buildSoundCheckVoice(streamIdx)
  soundCheckPlaying.value = true
  try {
    const response = await axios.post('/api/web/supercolliders/render_polyphonic', {
      time_series: [[voice]],
      bpm,
      future_bpm: [bpm],
      initial_context_bpm: [bpm],
      tail_pad_seconds: 0.05
    })

    if (response?.data?.error) {
      console.error('Sound check render error:', response.data.error)
      return
    }

    const audioData = String(response?.data?.audio_data ?? '')
    if (!audioData) return

    cleanupSoundCheckAudio()
    soundCheckAudioUrl = decodeBase64AudioToObjectUrl(audioData)
    const audio = new Audio(soundCheckAudioUrl)
    soundCheckAudioEl.value = audio
    const played = audio.play()
    if (played && typeof (played as Promise<void>).catch === 'function') {
      ;(played as Promise<void>).catch((err) => {
        console.error('Sound check play failed:', err)
      })
    }
  } catch (err) {
    console.error('Sound check request failed:', err)
  } finally {
    soundCheckPlaying.value = false
  }
}

const saveSoundCheckToInitialContext = () => {
  if (!canOpenSoundCheck.value || soundCheckRows.value.length === 0) return
  const colIndex = selectedContextColumnForSoundCheck.value as number

  const nextRows = contextRowsForGrid.value.map((row, idx) => {
    const next = { ...row, config: { ...row.config }, data: [...row.data] }
    if (colIndex >= next.data.length) return next
    next.data[colIndex] = soundCheckRows.value[idx]?.data?.[0] ?? next.data[colIndex]
    return next
  })

  contextRowsForGrid.value = nextRows
  soundCheckDialog.value = false
}

watch(soundCheckDialog, (isOpen) => {
  if (!isOpen) {
    cleanupSoundCheckAudio()
    soundCheckPlaying.value = false
  }
})

const makeContextConfig = (dimKey: string) => {
  if (dimKey === 'abs_note') {
    return { min: 12, max: 120, isInt: true, step: 1, inputMode: 'note-array' as const }
  } else {
    // vol + 6-axis timbre controls
    return { min: 0, max: 1, isInt: false, step: 0.01 }
  }
}

const makeContextRow = (streamIdx: number, dimIdx: number): GridRowData => {
  const dim = contextInputDimensions[dimIdx]
  const base = defaultContextInputBase[dimIdx] ?? 0
  return {
    name: `S${streamIdx + 1} ${dim.name}`,
    shortName: `S${streamIdx + 1} ${dim.shortName}`,
    data: Array(contextSteps.value).fill(dim.key === 'abs_note' ? `[${base}]` : base),
    config: makeContextConfig(dim.key)
  }
}

const parseAbsNoteCell = (raw: unknown): number[] => {
  if (Array.isArray(raw)) {
    return raw
      .map((value) => Number(value))
      .filter((value) => isFinite(value))
      .map((value) => Math.round(value))
  }

  const text = String(raw ?? '').trim()
  if (text === '') return []

  const hasBracketWrapper = text.charAt(0) === '[' && text.charAt(text.length - 1) === ']'
  const body = hasBracketWrapper ? text.slice(1, -1) : text
  return body
    .split(',')
    .map((part) => part.trim())
    .filter((part) => part.length > 0)
    .map((part) => Number(part))
    .filter((part) => isFinite(part))
    .map((part) => Math.round(part))
}

const formatAbsNoteCell = (notes: unknown): string => {
  const parsed = parseAbsNoteCell(notes)
  return parsed.length > 0 ? `[${parsed.join(', ')}]` : ''
}

const getLastContextStepIndex = () => Math.max(contextSteps.value - 1, 0)

const getObservedChordRangeAndDensity = (rawNotes: unknown) => {
  const parsed = parseAbsNoteCell(rawNotes)
  if (parsed.length === 0) {
    return { chordRange: 0, density: 0 }
  }

  const uniqueSorted = [...parsed].sort((left, right) => left - right).filter((value, idx, arr) => (
    idx === 0 || value !== arr[idx - 1]
  ))
  const minNote = uniqueSorted[0]
  const maxNote = uniqueSorted[uniqueSorted.length - 1]
  const chordRange = Math.max(0, Math.round(maxNote - minNote))
  const slotCount = Math.max(1, chordRange + 1)
  const density = Math.max(0, Math.min(1, uniqueSorted.length / slotCount))

  return { chordRange, density }
}

const getLastContextAreaFixedValue = () => {
  const lastStepIndex = getLastContextStepIndex()
  const absNotes: number[] = []

  for (let streamIdx = 0; streamIdx < contextStreamCount.value; streamIdx++) {
    const rowIndex = streamIdx * contextInputDimensions.length
    const row = contextRows.value[rowIndex]
    const notes = parseAbsNoteCell(row?.data[lastStepIndex] ?? '')
    absNotes.push(...notes)
  }

  if (absNotes.length === 0) {
    return managedDimPolicyConfigs.area.defaultFixedValue
  }

  const sorted = [...absNotes].sort((left, right) => left - right)
  const anchor = sorted[Math.ceil(sorted.length / 2) - 1] ?? defaultContextBase[0]
  const bandLow = Math.min(areaBandLowMax, Math.max(areaBandLowMin, Math.floor(anchor / areaBandSize) * areaBandSize))
  const bandCount = Math.max(Math.floor((areaBandLowMax - areaBandLowMin) / areaBandSize), 0)
  if (bandCount === 0) return 0

  return clampDimensionFixedValue('area', (bandLow - areaBandLowMin) / bandCount)
}

const getLastContextAreaFixedValues = () => {
  const lastStepIndex = getLastContextStepIndex()
  const values: number[] = []

  for (let streamIdx = 0; streamIdx < contextStreamCount.value; streamIdx++) {
    const rowIndex = streamIdx * contextInputDimensions.length
    const row = contextRows.value[rowIndex]
    const notes = parseAbsNoteCell(row?.data[lastStepIndex] ?? '')

    if (notes.length === 0) {
      values.push(managedDimPolicyConfigs.area.defaultFixedValue)
      continue
    }

    const sorted = [...notes].sort((left, right) => left - right)
    const anchor = sorted[Math.ceil(sorted.length / 2) - 1] ?? defaultContextBase[0]
    const bandLow = Math.min(areaBandLowMax, Math.max(areaBandLowMin, Math.floor(anchor / areaBandSize) * areaBandSize))
    const bandCount = Math.max(Math.floor((areaBandLowMax - areaBandLowMin) / areaBandSize), 0)
    if (bandCount === 0) {
      values.push(0)
      continue
    }

    values.push(clampDimensionFixedValue('area', (bandLow - areaBandLowMin) / bandCount))
  }

  return values
}

const getLastContextManagedDimensionFixedValue = (key: Exclude<ManagedDimKey, 'area'>) => {
  if (key === 'chord_range' || key === 'density') {
    const lastStepIndex = getLastContextStepIndex()
    const values: number[] = []

    for (let streamIdx = 0; streamIdx < contextStreamCount.value; streamIdx++) {
      const rowIndex = streamIdx * contextInputDimensions.length
      const row = contextRows.value[rowIndex]
      const observed = getObservedChordRangeAndDensity(row?.data[lastStepIndex] ?? '')
      values.push(key === 'chord_range' ? observed.chordRange : observed.density)
    }

    if (values.length === 0) {
      return managedDimPolicyConfigs[key].defaultFixedValue
    }

    const average = values.reduce((sum, value) => sum + value, 0) / values.length
    return clampDimensionFixedValue(key, average)
  }

  const dimIndex = contextManagedDimensionIndex[key]
  const lastStepIndex = getLastContextStepIndex()
  const values: number[] = []

  for (let streamIdx = 0; streamIdx < contextStreamCount.value; streamIdx++) {
    const rowIndex = streamIdx * contextInputDimensions.length + dimIndex
    const row = contextRows.value[rowIndex]
    values.push(coerceFiniteNumber(row?.data[lastStepIndex], managedDimPolicyConfigs[key].defaultFixedValue))
  }

  if (values.length === 0) {
    return managedDimPolicyConfigs[key].defaultFixedValue
  }

  const average = values.reduce((sum, value) => sum + value, 0) / values.length
  return clampDimensionFixedValue(key, average)
}

const getLastContextManagedDimensionFixedValues = (key: Exclude<ManagedDimKey, 'area'>) => {
  if (key === 'chord_range' || key === 'density') {
    const lastStepIndex = getLastContextStepIndex()
    const values: number[] = []

    for (let streamIdx = 0; streamIdx < contextStreamCount.value; streamIdx++) {
      const rowIndex = streamIdx * contextInputDimensions.length
      const row = contextRows.value[rowIndex]
      const observed = getObservedChordRangeAndDensity(row?.data[lastStepIndex] ?? '')
      values.push(key === 'chord_range' ? observed.chordRange : observed.density)
    }

    return values.map((value) => clampDimensionFixedValue(key, value))
  }

  const dimIndex = contextManagedDimensionIndex[key]
  const lastStepIndex = getLastContextStepIndex()
  const values: number[] = []

  for (let streamIdx = 0; streamIdx < contextStreamCount.value; streamIdx++) {
    const rowIndex = streamIdx * contextInputDimensions.length + dimIndex
    const row = contextRows.value[rowIndex]
    values.push(clampDimensionFixedValue(key, row?.data[lastStepIndex]))
  }

  return values
}

const getResolvedDimensionPolicyFixedValue = (key: ManagedDimKey) => {
  const policy = dimensionPolicy.value[key]
  if (policy.fixedValueSource === 'initial_context_last_step') {
    return key === 'area'
      ? getLastContextAreaFixedValue()
      : getLastContextManagedDimensionFixedValue(key)
  }
  return clampDimensionFixedValue(key, policy.fixedValue)
}

const formatDimensionPolicyDerivedValue = (raw: unknown) => {
  const key = resolveManagedDimKey(raw)
  const policy = dimensionPolicy.value[key]

  if (policy.fixedValueSource === 'initial_context_last_step') {
    const values = key === 'area'
      ? getLastContextAreaFixedValues()
      : getLastContextManagedDimensionFixedValues(key)
    const rendered = values.map((value) => (
      managedDimPolicyConfigs[key].isInt ? `${Math.round(value)}` : value.toFixed(2)
    ))
    return `Last ${rendered.join(' / ')}`
  }

  const value = getResolvedDimensionPolicyFixedValue(key)
  return managedDimPolicyConfigs[key].isInt ? `Last ${Math.round(value)}` : `Last ${value.toFixed(2)}`
}

// 初期化
const initContextRows = () => {
  const rows: GridRowData[] = []
  for (let s = 0; s < contextStreamCount.value; s++) {
    for (let d = 0; d < contextInputDimensions.length; d++) {
      rows.push(makeContextRow(s, d))
    }
  }
  contextRows.value = rows
}
initContextRows()

// Steps が増減したとき: 行データを合わせる
watch(contextSteps, (len) => {
  if (suppressContextWatch.value) return
  if (selectedContextColumnForSoundCheck.value != null && selectedContextColumnForSoundCheck.value >= len) {
    selectedContextColumnForSoundCheck.value = null
  }
  contextRows.value = contextRows.value.map((row) => {
    const data = [...row.data]
    while (data.length < len) {
      data.push(data.length > 0 ? data[data.length - 1] : (row.config.inputMode === 'note-array' ? '' : 0))
    }
    if (data.length > len) data.splice(len)
    return { ...row, data }
  })
  initialContextBpm.value = normalizeBpmSeries(initialContextBpm.value, len)
})

// Streams が増減したとき: 7行単位で追加/削除
watch(
  contextStreamCount,
  (newVal, oldVal) => {
    if (suppressContextWatch.value) return
    if (oldVal == null) return
    const prev = oldVal as number
    const curr = newVal as number
    const rowsPerStream = contextInputDimensions.length

    if (curr > prev) {
      for (let s = prev; s < curr; s++) {
        for (let d = 0; d < contextInputDimensions.length; d++) {
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

  const initial: any[] = []

  for (let step = 0; step < steps; step++) {
    const stepArr: any[] = []
    for (let s = 0; s < streams; s++) {
      stepArr.push(buildStrictContextVoiceFromRows(contextRows.value, s, step))
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
  note?: string
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
  atMax: string,
  note?: string
): RowHelp => ({
  overview,
  range: makeRangeText(meta),
  atMin,
  atMax,
  note
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

const makeTimbreDimensionRows = (
  shortName: string,
  name: string,
  key: string,
  overview: string,
  atMin: string,
  atMax: string
): GenRowMeta[] => [
  { shortName: `${shortName} G`, name: `${name} Global Complexity`, key: `${key}_global`, min: 0, max: 1, step: 0.01, defaultFactory: (len) => constant(0, len) },
  { shortName: `${shortName} C`, name: `${name} Center`, key: `${key}_center`, min: 0, max: 1, step: 0.01, defaultFactory: (len) => constant(0, len) },
  { shortName: `${shortName} S`, name: `${name} Spread`, key: `${key}_spread`, min: 0, max: 1, step: 0.01, defaultFactory: (len) => constant(0, len) },
  { shortName: `${shortName} Conc`, name: `${name} Conformity (Conc)`, key: `${key}_conc`, min: -1, max: 1, step: 0.01, defaultFactory: (len) => constant(0, len) },
  {
    shortName: `${shortName} Target`,
    name: `${name} Target`,
    key: `${key}_target`,
    min: 0,
    max: 1,
    step: 0.1,
    defaultFactory: (len) => constant(0.5, len),
    help: H(
      { min: 0, max: 1, step: 0.1 },
      overview,
      atMin,
      atMax
    )
  },
  {
    shortName: `${shortName} Spread`,
    name: `${name} Spread (Target Window)`,
    key: `${key}_target_spread`,
    min: 0,
    max: 1,
    step: 0.1,
    defaultFactory: (len) => constant(1, len),
    help: H(
      { min: 0, max: 1, step: 0.1 },
      `${name} の探索許容幅（中心±幅、0.1刻み）です。`,
      "0：中心値のみ探索。",
      "1：ほぼ全域を探索。"
    )
  }
]

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
  {
    shortName: "LEG C",
    name: "Legato Center",
    key: "legato_center",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "同じ stream で前 step と同じ note/chord が続くときだけ有効な legato 実値の中心です。生成探索の複雑度には使わず、SuperCollider render 時に同音連打を結合するかを決めます。",
      "0：全体に step ごとに発音し直す方向です。",
      "1：全体に同音連打を音響的に切らず、1つの長い音として持続する方向です。",
      "render では各streamの legato が 0.5 以上で結合します。Attack/Decay は結合 run の先頭、Sustain/Release は末尾 step の値を使います。"
    )
  },
  {
    shortName: "LEG S",
    name: "Legato Spread",
    key: "legato_spread",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(0, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "Legato Center を中心に、同一step内のstreamごとの legato 実値をどれだけ広げるかです。center±spread/2 をstream数ぶん線形に割り当てます。",
      "0：全streamが Legato Center と同じ値になります。",
      "1：stream間の legato 差が最大になります。"
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
  {
    shortName: "REG Freedom",
    name: "Note Register Freedom",
    key: "note_register_freedom",
    min: 0,
    max: 1,
    step: 0.01,
    defaultFactory: (len) => constant(1, len),
    help: H(
      { min: 0, max: 1, step: 0.01 },
      "各ストリームが現在の音域からどれだけ離れてよいかを制御します。低いほど同じ音域に留まり、高いほど広い音域移動を許します。",
      "0：現在の音域付近に強く留まり、累積的な大ジャンプを起こしにくい。",
      "1：音域拘束をほぼかけず、広いレジスタ移動を許す。"
    )
  },

  // =========================================================
  // scoring weights (global / stream ; dist / qty / comp)
  // =========================================================
  {
    shortName: "G-D W",
    name: "Global Distance Weight",
    key: "global_dist_weight",
    min: 0,
    max: 5,
    step: 0.01,
    defaultFactory: (len) => constant(0.2, len),
  },
  {
    shortName: "G-Q W",
    name: "Global Quantity Weight",
    key: "global_qty_weight",
    min: 0,
    max: 5,
    step: 0.01,
    defaultFactory: (len) => constant(2, len),
  },
  {
    shortName: "G-C W",
    name: "Global Complexity Weight",
    key: "global_comp_weight",
    min: 0,
    max: 5,
    step: 0.01,
    defaultFactory: (len) => constant(2, len),
  },
  {
    shortName: "S-D W",
    name: "Stream Distance Weight",
    key: "stream_dist_weight",
    min: 0,
    max: 5,
    step: 0.01,
    defaultFactory: (len) => constant(0.2, len),
  },
  {
    shortName: "S-Q W",
    name: "Stream Quantity Weight",
    key: "stream_qty_weight",
    min: 0,
    max: 5,
    step: 0.01,
    defaultFactory: (len) => constant(2, len),
  },
  {
    shortName: "S-C W",
    name: "Stream Complexity Weight",
    key: "stream_comp_weight",
    min: 0,
    max: 5,
    step: 0.01,
    defaultFactory: (len) => constant(2, len),
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
  {
    shortName: "BPM",
    name: "Future BPM",
    key: "future_bpm",
    min: 1,
    max: 960,
    step: 1,
    isInt: true,
    defaultFactory: (len) => constant(DEFAULT_BPM, len),
    help: H(
      { min: 1, max: 960, step: 1, isInt: true },
      "各 future step の BPM です。生成後の各 step 長と wav 生成のテンポに使われます。",
      "1：非常に遅く、1 step が長い。",
      "960：非常に速く、1 step が短い。"
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
  // vol + timbre dimensions : global / center / spread / conc (+ target window)
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
  ...makeTimbreDimensionRows('BRI', 'BRIGHTNESS', 'brightness', 'BRIGHTNESS の探索中心値です（0.1刻み）。', '0：暗め中心。', '1：明るめ中心。'),
  ...makeTimbreDimensionRows('NOI', 'NOISE', 'noise', 'NOISE の探索中心値です（0.1刻み）。', '0：滑らかで純音寄り。', '1：ざらつきと粗さが強い。'),
  ...makeTimbreDimensionRows('HAR', 'HARMONICITY', 'harmonicity', 'HARMONICITY の探索中心値です（0.1刻み）。', '0：非整数次倍音寄り。', '1：整数次倍音寄り。'),
  ...makeTimbreDimensionRows('ATK', 'ATTACK', 'attack', 'ATTACK の探索中心値です。Attack / Decay / SustainRelease の比率で音全体の長さに正規化されます。', '0：立ち上がりほぼなし。', '1：Attack 比率が大きい。'),
  ...makeTimbreDimensionRows('DEC', 'DECAY', 'decay_sustain', 'DECAY の探索中心値です。Attack / Decay / SustainRelease の比率で音全体の長さに正規化されます。', '0：減衰ほぼなし。', '1：Decay 比率が大きい。'),
  ...makeTimbreDimensionRows('S/R', 'SUSTAIN/RELEASE', 'release', 'SUSTAIN/RELEASE の探索中心値です。Attack / Decay / SustainRelease の比率で音全体の長さに正規化され、この区間のうち 70% を sustain、30% を release に使います。', '0：末尾区間ほぼなし。', '1：Sustain/Release 比率が大きい。'),
]

const adsrRenderNote = 'SuperCollider では Attack / Decay / SustainRelease の3値を 0〜1 に clamp し、合計が 1 を超える場合は 1 step 内に収まるよう比率で正規化します。合計が 1 以下の場合はその合計分だけ鳴り、残りは無音になります。SustainRelease は 70% を sustain、30% を release に分けます。例: BPM 480 では 1 step = 0.125 秒です。'

const dimHelp: Record<string, { label: string; value: string; min: string; max: string; note?: string }> = {
  area: {
    label: 'AREA',
    value: '4半音幅の音域バンドの基点（tmp anchor）',
    min: '低い複雑度では、直近の音域バンドに留まる候補や小さい移動が選ばれやすくなります。',
    max: '高い複雑度では、直近から離れた音域バンドや大きい移動が選ばれやすくなります。',
    note: 'AREA は最終音そのものではなく、後段で実音候補を作るための大まかな音域移動を決めます。'
  },
  chord_range: {
    label: 'CHORD_RANGE',
    value: '各ストリームの和音幅（最低音から最高音までの半音幅）',
    min: '低い値では単音または狭い和音幅を中心に探索します。',
    max: '高い値ではオクターブに近い広い和音幅まで探索します。'
  },
  density: {
    label: 'DENSITY',
    value: '和音内にどれだけ音を詰めるか',
    min: '低い値では少ない構成音、隙間のある和音が選ばれやすくなります。',
    max: '高い値では構成音が増え、密な和音が選ばれやすくなります。'
  },
  vol: {
    label: 'VOLUME',
    value: '各ストリームの音量。0 は休符扱いに近く、1 は最大音量です',
    min: '低い値ではそのストリームが弱く、場合によっては鳴らない候補が選ばれます。',
    max: '高い値ではそのストリームが前に出やすく、音量差も大きくなります。'
  },
  brightness: {
    label: 'BRIGHTNESS',
    value: 'SuperCollider 音色の明るさ。倍音量とフィルタの開きに反映されます',
    min: '低い値では暗く丸い音色に寄ります。',
    max: '高い値では高域成分が増え、明るく硬い音色に寄ります。'
  },
  noise: {
    label: 'NOISE',
    value: 'SuperCollider 音色に混ぜるノイズ量',
    min: '低い値では純音に近い滑らかな音になります。',
    max: '高い値ではざらつきや粗さが強くなります。'
  },
  harmonicity: {
    label: 'HARMONICITY',
    value: '倍音比率の整数倍らしさ',
    min: '低い値では非整数倍音寄りになり、金属的・不安定な質感が増えます。',
    max: '高い値では整数倍音寄りになり、基音感が明確になります。'
  },
  attack: {
    label: 'ATTACK',
    value: '1 step の長さの中で立ち上がりに割く比率',
    min: '低い値では立ち上がりが短く、すぐ鳴り始めます。',
    max: '高い値では立ち上がりが長く、フェードインに近くなります。',
    note: adsrRenderNote
  },
  decay_sustain: {
    label: 'DECAY',
    value: '1 step の長さの中で初期減衰に割く比率',
    min: '低い値では減衰区間が短く、すぐ sustain/release 側へ移ります。',
    max: '高い値では減衰区間が長く、音量変化がゆっくりになります。',
    note: adsrRenderNote
  },
  release: {
    label: 'SUSTAIN/RELEASE',
    value: '1 step の長さの中で保持と余韻に割く比率',
    min: '低い値では音の末尾が短く切れやすくなります。',
    max: '高い値では sustain と release が長くなり、余韻が残りやすくなります。',
    note: adsrRenderNote
  }
}

const dimKeysForHelp = Object.keys(dimHelp).sort((a, b) => b.length - a.length)

const detectDimKey = (key: string) => dimKeysForHelp.find((dim) => key === dim || key.startsWith(`${dim}_`))

const dimDisabledNote = (dim: string) =>
  `Dimension Policy で ${dimHelp[dim]?.label ?? dim} を固定値にしている場合、この行の値は生成探索には使われず固定値が出力されます。`

const buildGenHelp = (meta: GenRowMeta): RowHelp | undefined => {
  const k = meta.key

  if (k === 'stream_counts') {
    return H(
      meta,
      '生成する future step ごとのストリーム数（声部数）です。この配列の長さが生成 step 数になり、各 step で manager の stream lifecycle がこの数に合うように増減します。',
      '1：単一ストリームで生成します。和音は作れても、独立した声部間の配置や強度差はほぼ発生しません。',
      '16：最大16ストリームを同時に扱います。声部数は増えますが、候補評価の組み合わせと処理負荷も大きくなります。'
    )
  }

  if (k === 'stream_strength_target') {
    return H(
      meta,
      'ストリーム数が変わるときに、どの強さのストリームを残す・復活する・複製するかを決める中心値です。vol manager があれば vol の presence/strength を基準にします。',
      '0：弱いストリームも残りやすく、声部間の存在感を均しやすい設定です。',
      '1：強いストリームを優先しやすく、主役になる声部が残りやすい設定です。'
    )
  }

  if (k === 'stream_strength_spread') {
    return H(
      meta,
      'Stream Strength Target からストリームごとの強度ターゲットを作るときの広がりです。複数ストリームでは center±spread/2 の範囲に線形配置されます。',
      '0：全ストリームが同じ強度ターゲットを共有します。',
      '1：強度ターゲットが最大幅で分散し、強い声部と弱い声部が分かれやすくなります。'
    )
  }

  if (k === 'note_register_freedom') {
    return H(
      meta,
      '各ストリームの直近の音域中心から、次の AREA 候補と実音候補がどれだけ離れてよいかを制御します。AREA 選択と最終 chord 選択の両方で音域窓として使われます。',
      '0：直近の音域中心付近に強く制限します。大きい跳躍や急な音域移動を避けやすくなります。',
      '1：音域制限をほぼ外します。広いレジスタ移動や大きい跳躍を許します。'
    )
  }

  if (k === 'dissonance_target') {
    return H(
      meta,
      'AREA、CHORD_RANGE、DENSITY などで作った実音候補の組み合わせから、短期記憶つき roughness 評価がこの値に近いものを最後に選びます。音量も評価に使われます。',
      '0：協和寄りの組み合わせを選びます。濁りやぶつかりは少なくなります。',
      '1：不協和寄りの組み合わせを選びます。近接音程や粗い響きが選ばれやすくなります。'
    )
  }

  if (k === 'future_bpm') {
    return H(
      meta,
      '各 future step の BPM です。生成時の dissonance memory の onset と、最終 wav render の step duration（60 / BPM）に使われます。',
      '1：1 step が非常に長くなります。レンダー時間も長くなります。',
      '960：1 step が非常に短くなります。音価が詰まり、短いフレーズになります。'
    )
  }

  const weightMatch = k.match(/^(global|stream)_(dist|qty|comp)_weight$/)
  if (weightMatch) {
    const scope = weightMatch[1] === 'global' ? 'Global' : 'Stream'
    const metric = weightMatch[2]
    const metricText =
      metric === 'dist'
        ? 'distance metric（既存クラスタからの距離、新規性）'
        : metric === 'qty'
          ? 'quantity metric（候補がどの程度の量・頻度として扱われるか）'
          : 'complexity metric（クラスタ構造上の複雑さ）'
    const scopeText =
      weightMatch[1] === 'global'
        ? '全ストリームをまとめた polyphonic set の評価'
        : '各ストリームを独立時系列として見た評価'
    return H(
      meta,
      `${scope} 側の ${metricText} の重みです。通常 dimension と AREA の候補スコアを 0..1 に正規化するとき、この重みで dist / qty / comp の効き方を調整します。対象は ${scopeText} です。`,
      '0：この metric をほぼ無視します。他の weight と usage metric の影響が相対的に強くなります。',
      '5：この metric を強く見ます。この metric が target に近い候補ほど選ばれやすくなります。'
    )
  }

  const dim = detectDimKey(k)
  if (!dim) return meta.help
  const info = dimHelp[dim]

  if (k.endsWith('_global')) {
    return H(
      meta,
      `${info.label} の Global Complexity 目標です。${info.value} を全ストリームまとめて polyphonic set として仮追加し、dist / qty / comp / usage を合成した global score がこの値に近い候補を選びます。${info.note ?? ''} ${dimDisabledNote(dim)}`,
      `0：${info.min}`,
      `1：${info.max}`
    )
  }

  if (k.endsWith('_center')) {
    return H(
      meta,
      `${info.label} の Stream Complexity 目標の中心です。各ストリームを独立した時系列として評価し、stream score が center±spread/2 に線形配置された目標へ近い候補を選びます。${dimDisabledNote(dim)}`,
      '0：各ストリームを低複雑度寄りの動きにします。変化量や新規性を抑えやすくなります。',
      '1：各ストリームを高複雑度寄りの動きにします。変化量や新規性を増やしやすくなります。'
    )
  }

  if (k.endsWith('_spread') && !k.endsWith('_target_spread')) {
    return H(
      meta,
      `${info.label} の Stream Complexity 目標をストリーム間でどれだけ広げるかです。複数ストリームでは center±spread/2 の範囲に目標値を並べ、声部ごとの複雑度差を作ります。${dimDisabledNote(dim)}`,
      '0：全ストリームが同じ stream complexity 目標になります。',
      '1：stream complexity 目標が最大幅で分散し、単純な声部と複雑な声部が分かれやすくなります。'
    )
  }

  if (k.endsWith('_conc')) {
    const areaText = dim === 'area'
      ? 'AREA では stream 間の band anchor の平均距離を見ます。'
      : '通常 dimension では同一 step 内の stream 値のばらつきを discordance として見ます。'
    return H(
      meta,
      `${info.label} の stream 間 conformity / concordance の重みです。${areaText} 正の値は揃える方向、負の値は散らす方向に候補コストを加えます。${dimDisabledNote(dim)}`,
      '-1：stream 間で値や音域を大きく分ける候補を優先します。',
      '1：stream 間で値や音域を揃える候補を優先します。0 ではこの項を使いません。'
    )
  }

  if (k.endsWith('_target')) {
    return H(
      meta,
      `${info.label} の実値探索の中心です。候補値はまず target±target spread の窓で絞られ、その中から global / stream / conc の評価で最終選択されます。${info.value} を直接狙う入口になる値です。${dimDisabledNote(dim)}`,
      `${meta.min}：${info.min}`,
      `${meta.max}：${info.max}`,
      info.note
    )
  }

  if (k.endsWith('_target_spread')) {
    return H(
      meta,
      `${info.label} の実値探索窓の半幅です。サーバは target - spread から target + spread までの候補だけを残し、空になった場合は target に最も近い候補を使います。${dimDisabledNote(dim)}`,
      `${meta.min}：target 付近の値だけを探索します。値を固定に近づけたいときに使います。`,
      `${meta.max}：探索窓が広がり、global / stream / conc の評価で選べる候補が増えます。`
    )
  }

  return meta.help
}

genRowMetas.forEach((meta) => {
  meta.help = buildGenHelp(meta)
})

const complexityDimensionKeys = ['area', 'chord_range', 'density', 'vol', 'brightness', 'noise', 'harmonicity', 'attack', 'decay_sustain', 'release'] as const
const targetWindowDimensionKeys = ['vol', 'chord_range', 'density', 'brightness', 'noise', 'harmonicity', 'attack', 'decay_sustain', 'release'] as const

const makeGenRowData = (meta: GenRowMeta, data: number[]): GridRowData => ({
  name: meta.name,
  shortName: meta.shortName,
  data,
  config: {
    min: meta.min,
    max: meta.max,
    step: meta.step,
    isInt: meta.isInt
  },
  help: meta.help,
  disabled: isGenRowDisabled(meta.key)
})

const syncGenRowsDisabledState = () => {
  genRows.value = genRows.value.map((row: GridRowData, idx: number) => ({
    ...row,
    disabled: isGenRowDisabled(genRowMetas[idx]?.key ?? '')
  }))
}

// rows 実体
const genRows = ref<GridRowData[]>(
  genRowMetas.map((meta) => makeGenRowData(meta, meta.defaultFactory(genSteps.value)))
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
    return { ...row, data, disabled: isGenRowDisabled(meta.key) }
  })
})

watch(dimensionPolicy, syncGenRowsDisabledState, { deep: true })

// meta を key で引くマップ
const genMetaByKey: Record<string, GenRowMeta> = {}
genRowMetas.forEach((m) => { genMetaByKey[m.key] = m })

// rows からサーバ送信用パラメータ構築
const buildGenParamsFromRows = () => {
  const len = genSteps.value

  const ensureLen = (arr: number[] | undefined, meta: GenRowMeta) => {
    const fallback = meta.defaultFactory(len)
    const out: number[] = []
    for (let i = 0; i < len; i++) {
      let v = (arr && i < arr.length && arr[i] != null)
        ? Number(arr[i])
        : Number(fallback[i])

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
  result.global_dist_weight = get('global_dist_weight')
  result.global_qty_weight = get('global_qty_weight')
  result.global_comp_weight = get('global_comp_weight')
  result.stream_dist_weight = get('stream_dist_weight')
  result.stream_qty_weight = get('stream_qty_weight')
  result.stream_comp_weight = get('stream_comp_weight')
  result.note_register_freedom  = get('note_register_freedom')
  result.dissonance_target      = get('dissonance_target')
  result.future_bpm             = get('future_bpm')
  result.legato_center          = get('legato_center')
  result.legato_spread          = get('legato_spread')

  complexityDimensionKeys.forEach((key) => {
    result[`${key}_global`] = get(`${key}_global`)
    result[`${key}_center`] = get(`${key}_center`)
    result[`${key}_spread`] = get(`${key}_spread`)
    result[`${key}_conc`] = get(`${key}_conc`)
  })

  targetWindowDimensionKeys.forEach((key) => {
    result[`${key}_target`] = get(`${key}_target`)
    result[`${key}_target_spread`] = get(`${key}_target_spread`)
  })

  return result
}

const normalizeNumber = (val: any, fallback: number) => {
  const num = Number(val)
  return Number.isFinite(num) ? num : fallback
}

const normalizeBpm = (val: any) => {
  const bpm = normalizeNumber(val, DEFAULT_BPM)
  if (!Number.isFinite(bpm) || bpm < 1) return DEFAULT_BPM
  return Math.round(bpm)
}

const normalizeBpmSeries = (val: any, expectedLength: number) => {
  const source = Array.isArray(val)
    ? val
    : (val == null ? [] : [val])
  const targetLength = Math.max(1, expectedLength)
  const fallback = source.length > 0 ? source[source.length - 1] : DEFAULT_BPM
  const out: number[] = []

  for (let i = 0; i < targetLength; i++) {
    const raw = i < source.length ? source[i] : fallback
    out.push(normalizeBpm(raw))
  }

  return out
}

const normalizeArray = (val: any) => {
  if (Array.isArray(val)) return val
  if (val == null) return []
  return [val]
}

const applyInitialContextFromPayload = async (ctxRaw: any, bpmRaw?: any) => {
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
    for (let d = 0; d < contextInputDimensions.length; d++) {
      const row = makeContextRow(s, d)
      const key = contextInputDimensions[d]?.key as keyof typeof strictContextIndexByKey
      const strictIndex = strictContextIndexByKey[key]
      const base = defaultContextBase[strictIndex] ?? 0
      const data: Array<number | string> = []
      for (let step = 0; step < steps; step++) {
        const stepArr = ctxRaw[step]
        const streamArr = Array.isArray(stepArr) ? stepArr[s] : null
        let rawVal: any = null
        if (Array.isArray(streamArr)) {
          if (streamArr.length >= 12) {
            rawVal = streamArr[strictIndex]
          }
        }
        if (d === 0) {
          data.push(formatAbsNoteCell(rawVal))
          continue
        }
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
  initialContextBpm.value = normalizeBpmSeries(bpmRaw, steps)
  await nextTick()
  suppressContextWatch.value = false
}

const applyGenParamsFromPayload = async (payload: any) => {
  const candidate = payload?.generate_polyphonic ?? payload ?? {}
  if (candidate.merge_threshold_ratio != null) {
    const v = normalizeNumber(candidate.merge_threshold_ratio, mergeThresholdRatio.value)
    mergeThresholdRatio.value = Math.min(1, Math.max(0, Number(v)))
  }
  applyDimensionPolicyFromPayload(candidate.dimension_policy)

  const getCandidateParam = (key: string) => {
    if (key === 'future_bpm') return candidate.future_bpm ?? candidate.bpm
    if (key === 'legato_center') return candidate.legato_center ?? candidate.legato ?? candidate.same_note_legato
    if (key === 'legato_spread') return candidate.legato_spread
    return candidate[key]
  }

  const lengths = genRowMetas.map((meta) => {
    const val = getCandidateParam(meta.key)
    return Array.isArray(val) ? val.length : (val != null ? 1 : 0)
  })
  const steps = Math.max(1, ...lengths)

  suppressGenWatch.value = true
  genSteps.value = steps

  genRows.value = genRowMetas.map((meta) => {
    const rawVal = getCandidateParam(meta.key)
    const arr = normalizeArray(rawVal).map((v: any) => (
      meta.key === 'future_bpm'
        ? normalizeBpm(v)
        : normalizeNumber(v, meta.isInt ? meta.min : 0)
    ))
    const defaults = meta.defaultFactory(steps)
    const data: number[] = []
    for (let i = 0; i < steps; i++) {
      let v = arr[i]
      if (v == null) {
        v = defaults[i]
      }
      if (meta.isInt) v = Math.round(v)
      else v = Number(Number(v).toFixed(2))
      if (v < meta.min) v = meta.min
      if (v > meta.max) v = meta.max
      data.push(v)
    }

    return makeGenRowData(meta, data)
  })

  await nextTick()
  suppressGenWatch.value = false
}

const buildParamsPayload = (jobIdOverride?: string) => {
  const genParams = buildGenParamsFromRows()
  const initialContext = buildInitialContext()
  const futureBpm = normalizeBpmSeries(genParams.future_bpm, genSteps.value)
  const jobId = jobIdOverride || uuidv4()

  const payload: any = {
    generate_polyphonic: {
      job_id: jobId,
      bpm: futureBpm[0] ?? DEFAULT_BPM,
      future_bpm: futureBpm,
      stream_counts: genParams.stream_counts,
      legato_center: genParams.legato_center,
      legato_spread: genParams.legato_spread,
      initial_context: initialContext,
      initial_context_bpm: normalizeBpmSeries(initialContextBpm.value, contextSteps.value),
      dimension_policy: buildDimensionPolicyPayload(),
      merge_threshold_ratio: mergeThresholdRatio.value,
      use_recent_position_weight: false,
      stream_strength_target: genParams.stream_strength_target,
      stream_strength_spread: genParams.stream_strength_spread,
      global_dist_weight: genParams.global_dist_weight,
      global_qty_weight: genParams.global_qty_weight,
      global_comp_weight: genParams.global_comp_weight,
      stream_dist_weight: genParams.stream_dist_weight,
      stream_qty_weight: genParams.stream_qty_weight,
      stream_comp_weight: genParams.stream_comp_weight,
      note_register_freedom: genParams.note_register_freedom,
      debug_score: true,
      debug_score_key: 'vol',
      debug_score_top_n: 20,
      dissonance_target: genParams.dissonance_target
    }
  }

  complexityDimensionKeys.forEach((k) => {
    payload.generate_polyphonic[`${k}_global`] = genParams[`${k}_global`]
    payload.generate_polyphonic[`${k}_center`] = genParams[`${k}_center`]
    payload.generate_polyphonic[`${k}_spread`] = genParams[`${k}_spread`]
    payload.generate_polyphonic[`${k}_conc`] = genParams[`${k}_conc`]
  })
  targetWindowDimensionKeys.forEach((k) => {
    payload.generate_polyphonic[`${k}_target`] = genParams[`${k}_target`]
    payload.generate_polyphonic[`${k}_target_spread`] = genParams[`${k}_target_spread`]
  })

  return payload
}

const applyParamsPayload = async (payload: any) => {
  if (!payload || typeof payload !== 'object') return
  const candidate = payload.generate_polyphonic ?? payload
  await applyInitialContextFromPayload(candidate.initial_context, candidate.initial_context_bpm ?? candidate.bpm)
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

onUnmounted(() => {
  cleanupProgress()
  cleanupSoundCheckAudio()
})

/** 親から open を操作したい場合用 */
defineExpose({ open, applyParamsPayload, buildParamsPayload })

watch(open, (next, prev) => {
  if (prev && !next) {
    emit('params-updated', buildParamsPayload())
  }
})
</script>

<style scoped>
.dialog-body {
  max-height: 100vh;
  overflow-y: auto;
  overflow-x: hidden;
}
.header-controls {
  gap: 8px;
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
  height: 85vh;
  margin-bottom: 0;
}
.step-input {
  width: 60px;
  border: 1px solid #ccc;
  padding: 2px 5px;
  border-radius: 4px;
  background: white;
}
.dimension-policy-row-slot {
  width: 120px;
  min-height: 66px;
  display: flex;
  align-items: flex-start;
  justify-content: flex-start;
  gap: 3px;
  padding-top: 1px;
  box-sizing: border-box;
}
.dimension-policy-checkbox {
  width: 14px;
  height: 14px;
  margin: 0;
}
.dim-policy-input {
  width: 36px;
  height: 20px;
  font-size: 0.72rem;
}
.dim-policy-select {
  width: 66px;
  height: 20px;
  font-size: 0.72rem;
}
.sound-check-layout {
  display: flex;
  flex-direction: column;
  gap: 12px;
}
.sound-check-grid-card {
  height: clamp(240px, 44vh, 520px);
}
.sound-check-controls {
  display: flex;
  gap: 12px;
  align-items: center;
}
.sound-check-controls :deep(.v-input) {
  max-width: 260px;
}
.sound-check-fft-card {
  overflow-x: auto;
}
</style>
