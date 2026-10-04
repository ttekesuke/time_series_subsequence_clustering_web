import {
  clampDimensionFixedValue,
  coerceFiniteNumber,
  managedDimPolicyConfigs,
  type ManagedDimKey,
} from './dimensionPolicy'

export type InitialContextRowLike = {
  data: Array<number | string>
}

export const strictContextIndexByKey = {
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
  tie: 10,
} as const

export const contextInputIndexByKey = {
  abs_note: 0,
  vol: 1,
  brightness: 2,
  noise: 3,
  harmonicity: 4,
  attack: 5,
  decay_sustain: 6,
  release: 7,
  tie: 8,
  lyrics: 9,
} as const

const contextManagedDimensionIndex: Record<Exclude<ManagedDimKey, 'area'>, number> = {
  vol: contextInputIndexByKey.vol,
  brightness: contextInputIndexByKey.brightness,
  noise: contextInputIndexByKey.noise,
  harmonicity: contextInputIndexByKey.harmonicity,
  attack: contextInputIndexByKey.attack,
  decay_sustain: contextInputIndexByKey.decay_sustain,
  release: contextInputIndexByKey.release,
  chord_range: -1,
  density: -1,
}

const CONTEXT_ROWS_PER_STREAM = Object.keys(contextInputIndexByKey).length
const AREA_BAND_SIZE = 4
const AREA_BAND_LOW_MIN = 24
const AREA_BAND_LOW_MAX = 120
const DEFAULT_NOTE = 60

export const parseAbsNoteCell = (raw: unknown): number[] => {
  if (Array.isArray(raw)) {
    return raw
      .map((value) => Number(value))
      .filter((value) => Number.isFinite(value))
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
    .filter((part) => Number.isFinite(part))
    .map((part) => Math.round(part))
}

export const formatAbsNoteCell = (notes: unknown): string => {
  const parsed = parseAbsNoteCell(notes)
  return parsed.length > 0 ? `[${parsed.join(', ')}]` : ''
}

export const getObservedChordRangeAndDensity = (rawNotes: unknown) => {
  const parsed = parseAbsNoteCell(rawNotes)
  if (parsed.length === 0) {
    return { chordRange: 0, density: 0 }
  }

  const uniqueSorted = [...parsed]
    .sort((left, right) => left - right)
    .filter((value, index, values) => index === 0 || value !== values[index - 1])
  const minNote = uniqueSorted[0]
  const maxNote = uniqueSorted[uniqueSorted.length - 1]
  if (minNote === undefined || maxNote === undefined) {
    return { chordRange: 0, density: 0 }
  }

  const chordRange = Math.max(0, Math.round(maxNote - minNote))
  const slotCount = Math.max(1, chordRange + 1)
  const density = Math.max(0, Math.min(1, uniqueSorted.length / slotCount))
  return { chordRange, density }
}

export const buildStrictContextVoiceFromRows = (
  rows: InitialContextRowLike[],
  streamIndex: number,
  stepIndex: number,
) => {
  const baseIndex = streamIndex * CONTEXT_ROWS_PER_STREAM
  const getRowValue = (
    key: keyof typeof contextInputIndexByKey,
    fallback: unknown,
  ) => rows[baseIndex + contextInputIndexByKey[key]]?.data?.[stepIndex] ?? fallback

  const absNotes = parseAbsNoteCell(getRowValue('abs_note', ''))
  const vol = Number(getRowValue('vol', 1))
  const brightness = Number(getRowValue('brightness', 0.5))
  const noise = Number(getRowValue('noise', 0.2))
  const harmonicity = Number(getRowValue('harmonicity', 0.5))
  const attack = Number(getRowValue('attack', 0.05))
  const decaySustain = Number(getRowValue('decay_sustain', 0.20))
  const release = Number(getRowValue('release', 0.75))
  const tie = Number(getRowValue('tie', 0))

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
    Math.round(Math.max(0, Math.min(1, tie)) * 2) / 2,
  ]
}

export const buildInitialContextFromRows = (
  rows: InitialContextRowLike[],
  steps: number,
  streams: number,
) => Array.from({ length: steps }, (_, stepIndex) =>
  Array.from({ length: streams }, (_, streamIndex) =>
    buildStrictContextVoiceFromRows(rows, streamIndex, stepIndex),
  ),
)

const lastContextStepIndex = (steps: number) => Math.max(steps - 1, 0)

const lastContextAreaFixedValue = (
  rows: InitialContextRowLike[],
  steps: number,
  streamCount: number,
) => {
  const stepIndex = lastContextStepIndex(steps)
  const absNotes: number[] = []

  for (let streamIndex = 0; streamIndex < streamCount; streamIndex++) {
    const row = rows[streamIndex * CONTEXT_ROWS_PER_STREAM + contextInputIndexByKey.abs_note]
    absNotes.push(...parseAbsNoteCell(row?.data?.[stepIndex] ?? ''))
  }

  if (absNotes.length === 0) {
    return managedDimPolicyConfigs.area.defaultFixedValue
  }

  const sorted = [...absNotes].sort((left, right) => left - right)
  const anchor = sorted[Math.ceil(sorted.length / 2) - 1] ?? DEFAULT_NOTE
  const bandLow = Math.min(
    AREA_BAND_LOW_MAX,
    Math.max(AREA_BAND_LOW_MIN, Math.floor(anchor / AREA_BAND_SIZE) * AREA_BAND_SIZE),
  )
  const bandCount = Math.max(
    Math.floor((AREA_BAND_LOW_MAX - AREA_BAND_LOW_MIN) / AREA_BAND_SIZE),
    0,
  )
  if (bandCount === 0) return 0
  return clampDimensionFixedValue(
    'area',
    (bandLow - AREA_BAND_LOW_MIN) / bandCount,
  )
}

const lastContextManagedDimensionFixedValue = (
  key: Exclude<ManagedDimKey, 'area'>,
  rows: InitialContextRowLike[],
  steps: number,
  streamCount: number,
) => {
  const stepIndex = lastContextStepIndex(steps)

  if (key === 'chord_range' || key === 'density') {
    const values: number[] = []
    for (let streamIndex = 0; streamIndex < streamCount; streamIndex++) {
      const row = rows[streamIndex * CONTEXT_ROWS_PER_STREAM + contextInputIndexByKey.abs_note]
      const observed = getObservedChordRangeAndDensity(row?.data?.[stepIndex] ?? '')
      values.push(key === 'chord_range' ? observed.chordRange : observed.density)
    }
    if (values.length === 0) return managedDimPolicyConfigs[key].defaultFixedValue
    return clampDimensionFixedValue(
      key,
      values.reduce((sum, value) => sum + value, 0) / values.length,
    )
  }

  const dimensionIndex = contextManagedDimensionIndex[key]
  const values: number[] = []
  for (let streamIndex = 0; streamIndex < streamCount; streamIndex++) {
    const row = rows[streamIndex * CONTEXT_ROWS_PER_STREAM + dimensionIndex]
    values.push(coerceFiniteNumber(
      row?.data?.[stepIndex],
      managedDimPolicyConfigs[key].defaultFixedValue,
    ))
  }

  if (values.length === 0) return managedDimPolicyConfigs[key].defaultFixedValue
  return clampDimensionFixedValue(
    key,
    values.reduce((sum, value) => sum + value, 0) / values.length,
  )
}

export const resolveInitialContextFixedValue = (
  key: ManagedDimKey,
  rows: InitialContextRowLike[],
  steps: number,
  streamCount: number,
) => key === 'area'
  ? lastContextAreaFixedValue(rows, steps, streamCount)
  : lastContextManagedDimensionFixedValue(key, rows, steps, streamCount)
