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

          <div class="dimension-policy-toolbar mr-4">
            <div
              v-for="dimKey in managedDimKeys"
              :key="dimKey"
              class="dimension-policy-item"
            >
              <label class="dimension-policy-label">
                <input
                  type="checkbox"
                  :checked="getDimensionPolicyValue(dimKey).useFixedValue"
                  @change="onDimensionPolicyAcceptChange(resolveManagedDimKey(dimKey), $event)"
                >
                <span>{{ getDimensionPolicyConfig(dimKey).label }}</span>
              </label>
              <template v-if="getDimensionPolicyValue(dimKey).useFixedValue">
                <select
                  :value="getDimensionPolicyValue(dimKey).fixedValueSource"
                  @change="onDimensionPolicyFixedValueSourceChange(resolveManagedDimKey(dimKey), $event)"
                  class="step-input dim-policy-select"
                >
                  <option value="initial_context_last_step">Last Step</option>
                  <option value="manual_input">Manual</option>
                </select>
                <input
                  v-if="getDimensionPolicyValue(dimKey).fixedValueSource === 'manual_input'"
                  type="number"
                  :value="getDimensionPolicyValue(dimKey).fixedValue"
                  @input="onDimensionPolicyFixedValueInput(resolveManagedDimKey(dimKey), $event)"
                  :min="getDimensionPolicyConfig(dimKey).min"
                  :max="getDimensionPolicyConfig(dimKey).max"
                  :step="getDimensionPolicyConfig(dimKey).step"
                  class="step-input dim-policy-input"
                >
                <span
                  v-else
                  class="dimension-policy-preview"
                >
                  {{ formatDimensionPolicyDerivedValue(dimKey) }}
                </span>
              </template>
            </div>
          </div>

          <v-text-field
            v-model.number="generationBpm"
            label="BPM"
            type="number"
            min="1"
            density="compact"
            hide-details
            variant="outlined"
            class="mr-2 bpm-input-dialog"
          />

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
const generationBpm = ref<number>(240)

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

type ManagedDimKey = 'area' | 'chord_range' | 'density' | 'sustain' | 'vol' | 'brightness' | 'articulation' | 'tonalness' | 'resonance'

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
  sustain: { label: 'SUS', min: 0, max: 1, step: 0.25, defaultUseFixedValue: false, defaultFixedValue: 0.5 },
  vol: { label: 'VOL', min: 0, max: 1, step: 0.01, defaultUseFixedValue: false, defaultFixedValue: 1 },
  brightness: { label: 'BRI', min: 0, max: 1, step: 0.01, defaultUseFixedValue: false, defaultFixedValue: 0.5 },
  articulation: { label: 'ART', min: 0, max: 1, step: 0.01, defaultUseFixedValue: false, defaultFixedValue: 0.5 },
  tonalness: { label: 'TON', min: 0, max: 1, step: 0.01, defaultUseFixedValue: false, defaultFixedValue: 0.5 },
  resonance: { label: 'RES', min: 0, max: 1, step: 0.01, defaultUseFixedValue: false, defaultFixedValue: 0.5 }
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
  sustain: { useFixedValue: managedDimPolicyConfigs.sustain.defaultUseFixedValue, fixedValue: managedDimPolicyConfigs.sustain.defaultFixedValue, fixedValueSource: 'manual_input' },
  vol: { useFixedValue: managedDimPolicyConfigs.vol.defaultUseFixedValue, fixedValue: managedDimPolicyConfigs.vol.defaultFixedValue, fixedValueSource: 'manual_input' },
  brightness: { useFixedValue: managedDimPolicyConfigs.brightness.defaultUseFixedValue, fixedValue: managedDimPolicyConfigs.brightness.defaultFixedValue, fixedValueSource: 'manual_input' },
  articulation: { useFixedValue: managedDimPolicyConfigs.articulation.defaultUseFixedValue, fixedValue: managedDimPolicyConfigs.articulation.defaultFixedValue, fixedValueSource: 'manual_input' },
  tonalness: { useFixedValue: managedDimPolicyConfigs.tonalness.defaultUseFixedValue, fixedValue: managedDimPolicyConfigs.tonalness.defaultFixedValue, fixedValueSource: 'manual_input' },
  resonance: { useFixedValue: managedDimPolicyConfigs.resonance.defaultUseFixedValue, fixedValue: managedDimPolicyConfigs.resonance.defaultFixedValue, fixedValueSource: 'manual_input' }
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
  if (key === 'sustain') value = Math.round(Math.min(1, Math.max(0, value)) * 4) / 4
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
  cr: 'chord_range',
  chord_range: 'chord_range',
  chordrange: 'chord_range',
  'chord-range': 'chord_range',
  den: 'density',
  density: 'density',
  sus: 'sustain',
  sustain: 'sustain',
  vol: 'vol',
  volume: 'vol',
  bri: 'brightness',
  brightness: 'brightness',
  art: 'articulation',
  articulation: 'articulation',
  ton: 'tonalness',
  tonalness: 'tonalness',
  res: 'resonance',
  resonance: 'resonance'
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

// 次元(9D): [abs_note(midi), vol, brightness, articulation, tonalness, resonance, chord_range(semitones), density, sustain]
const dimensions = [
  { key: 'abs_note', shortName: 'NOTE_ABS', name: 'NOTE (Abs MIDI)' },
  { key: 'vol', shortName: 'VOLUME', name: 'VOLUME' },
  { key: 'brightness', shortName: 'BRIGHTNESS', name: 'BRIGHTNESS' },
  { key: 'articulation', shortName: 'ARTICULATION', name: 'ARTICULATION' },
  { key: 'tonalness', shortName: 'TONALNESS', name: 'TONALNESS' },
  { key: 'resonance', shortName: 'RESONANCE', name: 'RESONANCE' },
  { key: 'chord_range', shortName: 'CHORD_RANGE', name: 'CHORD RANGE (semitones)' },
  { key: 'density', shortName: 'DENSITY', name: 'DENSITY' },
  { key: 'sustain', shortName: 'SUSTAIN', name: 'SUSTAIN' }
]


// 各次元のデフォルト値 (1ストリーム分) [abs_note, vol, brightness, articulation, tonalness, resonance, chord_range, density, sustain]
const defaultContextBase = [60, 1, 0.5, 0.5, 0.5, 0.5, 0, 0, 0.5]
const areaBandSize = 4
const areaBandLowMin = 24
const areaBandLowMax = 120

const contextManagedDimensionIndex: Record<Exclude<ManagedDimKey, 'area'>, number> = {
  vol: 1,
  brightness: 2,
  articulation: 3,
  tonalness: 4,
  resonance: 5,
  chord_range: 6,
  density: 7,
  sustain: 8
}

const contextSteps = ref(3)
const contextStreamCount = ref(1)
const contextRows = ref<GridRowData[]>([])
const suppressContextWatch = ref(false)

const makeContextConfig = (dimKey: string) => {
  if (dimKey === 'abs_note') {
    return { min: 12, max: 120, isInt: true, step: 1, inputMode: 'note-array' as const }
  } else if (dimKey === 'chord_range') {
    return { min: 0, max: 127, isInt: true, step: 1 }
  } else if (dimKey === 'density') {
    return { min: 0, max: 1, isInt: false, step: 0.01 }
  } else if (dimKey === 'sustain') {
    return { min: 0, max: 1, isInt: false, step: 0.25 }
  } else {
    // vol/brightness/articulation/tonalness/resonance
    return { min: 0, max: 1, isInt: false, step: 0.01 }
  }
}

const makeContextRow = (streamIdx: number, dimIdx: number): GridRowData => {
  const dim = dimensions[dimIdx]
  const base = defaultContextBase[dimIdx] ?? 0
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

const getLastContextAreaFixedValue = () => {
  const lastStepIndex = getLastContextStepIndex()
  const absNotes: number[] = []

  for (let streamIdx = 0; streamIdx < contextStreamCount.value; streamIdx++) {
    const rowIndex = streamIdx * dimensions.length
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
    const rowIndex = streamIdx * dimensions.length
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
  const dimIndex = contextManagedDimensionIndex[key]
  const lastStepIndex = getLastContextStepIndex()
  const values: number[] = []

  for (let streamIdx = 0; streamIdx < contextStreamCount.value; streamIdx++) {
    const rowIndex = streamIdx * dimensions.length + dimIndex
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
  const dimIndex = contextManagedDimensionIndex[key]
  const lastStepIndex = getLastContextStepIndex()
  const values: number[] = []

  for (let streamIdx = 0; streamIdx < contextStreamCount.value; streamIdx++) {
    const rowIndex = streamIdx * dimensions.length + dimIndex
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
      data.push(data.length > 0 ? data[data.length - 1] : (row.config.inputMode === 'note-array' ? '' : 0))
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
      const vals: Array<number | number[]> = []
      for (let d = 0; d < dimsLen; d++) {
        const rowIndex = s * dimsLen + d
        const row = contextRows.value[rowIndex]
        const rawValue = row?.data[step] ?? (row?.config?.inputMode === 'note-array' ? '' : 0)
        const cfg = row?.config
        if (cfg?.inputMode === 'note-array') {
          vals.push(parseAbsNoteCell(rawValue))
          continue
        }

        let v = Number(rawValue ?? 0)
        if (cfg) {
          if (cfg.isInt) v = Math.round(v)
          if (v < cfg.min) v = cfg.min
          if (v > cfg.max) v = cfg.max
        }
        vals.push(v)
      }

      // vals: [abs_note, vol, brightness, articulation, tonalness, resonance, chord_range, density, sustain]
      const absNotes = (Array.isArray(vals[0]) ? vals[0] : []).map((value) => Math.round(Number(value))).filter((value) => isFinite(value))
      const vol = Number(vals[1] ?? 0)
      const brightness = Number(vals[2] ?? 0.5)
      const articulation = Number(vals[3] ?? 0.5)
      const tonalness = Number(vals[4] ?? 0.5)
      const resonance = Number(vals[5] ?? 0.5)
      const chordRange = Math.round(Number(vals[6] ?? 0))
      const density = Number(vals[7] ?? 0)
      const sustain = Number(vals[8] ?? 0.5)

      // server strict: [abs_notes(Int[]), vol, brightness, articulation, tonalness, resonance, chord_range(Int), density, sustain]
      stepArr.push([absNotes.length > 0 ? absNotes : [Math.round(defaultContextBase[0])], vol, brightness, articulation, tonalness, resonance, chordRange, density, sustain])
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
      "音のゲート長とタイの度合いの変化複雑度です。",
      "0：短さ/つながり方が変わりにくい。",
      "1：短さ/つながり方がよく変わる。"
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
      "0：1ステップの 1/4 だけ鳴って残りは無音。",
      "1：同音同ストリームなら次音へ完全タイ。"
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
  ...makeTimbreDimensionRows('ART', 'ARTICULATION', 'articulation', 'ARTICULATION の探索中心値です（0.1刻み）。', '0：丸い立ち上がり中心。', '1：鋭い立ち上がり中心。'),
  ...makeTimbreDimensionRows('TON', 'TONALNESS', 'tonalness', 'TONALNESS の探索中心値です（0.1刻み）。', '0：ノイズ寄り中心。', '1：有音高寄り中心。'),
  ...makeTimbreDimensionRows('RES', 'RESONANCE', 'resonance', 'RESONANCE の探索中心値です（0.1刻み）。', '0：乾いた短い鳴り中心。', '1：響きの長い鳴り中心。'),
]

const complexityDimensionKeys = ['area', 'chord_range', 'density', 'sustain', 'vol', 'brightness', 'articulation', 'tonalness', 'resonance'] as const
const targetWindowDimensionKeys = ['vol', 'chord_range', 'density', 'sustain', 'brightness', 'articulation', 'tonalness', 'resonance'] as const

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
  const bpm = normalizeNumber(val, 240)
  if (!Number.isFinite(bpm) || bpm < 1) return 240
  return Math.round(bpm)
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
      const data: Array<number | string> = []
      for (let step = 0; step < steps; step++) {
        const stepArr = ctxRaw[step]
        const streamArr = Array.isArray(stepArr) ? stepArr[s] : null
        let rawVal = Array.isArray(streamArr) ? streamArr[d] : null
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
  await nextTick()
  suppressContextWatch.value = false
}

const applyGenParamsFromPayload = async (payload: any) => {
  const candidate = payload?.generate_polyphonic ?? payload ?? {}
  generationBpm.value = normalizeBpm(candidate.bpm)
  if (candidate.merge_threshold_ratio != null) {
    const v = normalizeNumber(candidate.merge_threshold_ratio, mergeThresholdRatio.value)
    mergeThresholdRatio.value = Math.min(1, Math.max(0, Number(v)))
  }
  applyDimensionPolicyFromPayload(candidate.dimension_policy)

  const lengths = genRowMetas.map((meta) => {
    const val = candidate[meta.key]
    return Array.isArray(val) ? val.length : (val != null ? 1 : 0)
  })
  const steps = Math.max(1, ...lengths)

  suppressGenWatch.value = true
  genSteps.value = steps

  genRows.value = genRowMetas.map((meta) => {
    const arr = normalizeArray(candidate[meta.key]).map((v: any) => normalizeNumber(v, meta.isInt ? meta.min : 0))
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
  const jobId = jobIdOverride || uuidv4()

  const payload: any = {
    generate_polyphonic: {
      job_id: jobId,
      bpm: normalizeBpm(generationBpm.value),
      stream_counts: genParams.stream_counts,
      initial_context: initialContext,
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
.dimension-policy-toolbar {
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 6px;
  max-width: min(100%, 860px);
}
.dimension-policy-item {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 2px 6px;
  border: 1px solid #d0d0d0;
  border-radius: 4px;
  background: rgba(255, 255, 255, 0.82);
  font-size: 0.78rem;
}
.dimension-policy-label {
  display: flex;
  align-items: center;
  gap: 4px;
  white-space: nowrap;
}
.dim-policy-input {
  width: 64px;
}
.dim-policy-select {
  width: 88px;
}
.dimension-policy-preview {
  min-width: 68px;
  text-align: right;
  font-variant-numeric: tabular-nums;
}
.bpm-input-dialog {
  width: 88px;
}
</style>
