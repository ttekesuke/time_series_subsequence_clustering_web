import { POLYPHONIC_BPM_DEFAULT } from '../constants/musicDefaults'

export const legacyParamKeyForCanonical = (key: string) => key
  .replace(/_global_complexity_target$/, '_global')
  .replace(/_stream_complexity_center$/, '_center')
  .replace(/_stream_complexity_span$/, '_spread')
  .replace(/_concordance$/, '_conc')
  .replace(/_value_target$/, '_target')
  .replace(/_value_radius$/, '_target_spread')

export const normalizeGenerationNumber = (value: unknown, fallback: number) => {
  const numberValue = Number(value)
  return Number.isFinite(numberValue) ? numberValue : fallback
}

export const normalizeGenerationBpm = (value: unknown) => {
  const bpm = normalizeGenerationNumber(value, POLYPHONIC_BPM_DEFAULT)
  if (!Number.isFinite(bpm) || bpm < 1) return POLYPHONIC_BPM_DEFAULT
  return Math.round(bpm)
}

export const normalizeGenerationBpmSeries = (value: unknown, expectedLength: number) => {
  const source = Array.isArray(value)
    ? value
    : (value == null ? [] : [value])
  const targetLength = Math.max(1, expectedLength)
  const fallback = source.length > 0 ? source[source.length - 1] : POLYPHONIC_BPM_DEFAULT

  return Array.from({ length: targetLength }, (_, index) =>
    normalizeGenerationBpm(index < source.length ? source[index] : fallback)
  )
}

export const normalizeGenerationArray = (value: unknown): unknown[] => {
  if (Array.isArray(value)) return value
  if (value == null) return []
  return [value]
}

export const generationCandidateParam = (
  candidate: Record<string, any>,
  key: string,
) => {
  if (key === 'future_bpm') return candidate.future_bpm ?? candidate.bpm
  if (key === 'recency_center') return candidate.recency_center
  if (key === 'recency_spread') return candidate.recency_spread
  if (key === 'tie_value_target') {
    return candidate.tie_value_target ?? candidate.tie_rate_target
  }
  if (
    key === 'tie_value_radius' &&
    candidate.tie_value_radius == null &&
    candidate.tie_rate_target != null
  ) {
    return 0
  }

  const canonicalValue = candidate[key]
  if (canonicalValue != null) return canonicalValue
  return candidate[legacyParamKeyForCanonical(key)]
}

export const generationSeriesLength = (value: unknown) =>
  Array.isArray(value) ? value.length : (value != null ? 1 : 0)

export const normalizeLegacyTieSeries = (
  value: unknown,
  steps: number,
) => {
  const source = normalizeGenerationArray(value)
  const fallback = source.length > 0 ? source[source.length - 1] : 0
  return Array.from({ length: steps }, (_, index) =>
    Math.max(
      0,
      Math.min(
        1,
        normalizeGenerationNumber(source[index] ?? fallback, 0),
      ),
    )
  )
}
