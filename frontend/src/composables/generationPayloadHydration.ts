import {
  generationCandidateParam,
  generationSeriesLength,
  normalizeGenerationArray,
  normalizeGenerationBpm,
  normalizeGenerationNumber,
  normalizeLegacyTieSeries,
} from './generationPayloadNormalization'
import { tieParamKeys, type LegacyTieParams } from './generationPayloadBuilder'

export type GenerationHydrationMeta = {
  key: string
  min: number
  max: number
  isInt?: boolean
  defaultFactory: (length: number) => number[]
}

export type GenerationPayloadHydration = {
  steps: number
  rows: number[][]
  legacyTieParams: LegacyTieParams | null
  voiceInventoryId: string | null
  mergeThresholdRatio: number | null
}

const clamp = (value: number, min: number, max: number) =>
  Math.max(min, Math.min(max, value))

export const hydrateGenerationPayload = ({
  candidate,
  metas,
  voicevoxEnabled,
  mergeThresholdFallback,
}: {
  candidate: Record<string, any>
  metas: GenerationHydrationMeta[]
  voicevoxEnabled: boolean
  mergeThresholdFallback: number
}): GenerationPayloadHydration => {
  const getParam = (key: string) => generationCandidateParam(candidate, key)

  const hasCanonicalTieParams =
    tieParamKeys.some((key) => candidate[key] != null) ||
    candidate.tie_rate_target != null
  const hasLegacyTieParams = !hasCanonicalTieParams && (
    candidate.tie_center != null ||
    candidate.tie_spread != null
  )

  const lengths = metas.map((meta) =>
    generationSeriesLength(getParam(meta.key))
  )
  if (hasLegacyTieParams) {
    lengths.push(generationSeriesLength(candidate.tie_center))
    lengths.push(generationSeriesLength(candidate.tie_spread))
  }
  const steps = Math.max(1, ...lengths)

  const legacyTieParams: LegacyTieParams | null = hasLegacyTieParams
    ? {
        tie_center: normalizeLegacyTieSeries(candidate.tie_center, steps),
        tie_spread: normalizeLegacyTieSeries(candidate.tie_spread, steps),
      }
    : null

  const rows = metas.map((meta) => {
    const rawValue = getParam(meta.key)
    const values = normalizeGenerationArray(rawValue).map((value) =>
      meta.key === 'future_bpm'
        ? normalizeGenerationBpm(value)
        : normalizeGenerationNumber(value, meta.isInt ? meta.min : 0)
    )
    const defaults = meta.defaultFactory(steps)

    return Array.from({ length: steps }, (_, index) => {
      let value = values[index]
      if (value == null) {
        value = (values.length > 0
          ? values[values.length - 1]
          : defaults[index]) ?? 0
      }

      if (meta.key === 'tie_value_target' || meta.key === 'tie_value_radius') {
        value = Math.round(Number(value) * 2) / 2
      }
      if (meta.isInt) value = Math.round(Number(value))
      else value = Number(Number(value).toFixed(2))

      return clamp(Number(value), meta.min, meta.max)
    })
  })

  let voiceInventoryId: string | null = null
  if (voicevoxEnabled && typeof candidate.voice_inventory_id === 'string') {
    const sanitized = candidate.voice_inventory_id
      .replace(/[^A-Za-z0-9_-]/g, '')
      .slice(0, 64)
    if (sanitized) voiceInventoryId = sanitized
  }

  let mergeThresholdRatio: number | null = null
  if (candidate.merge_threshold_ratio != null) {
    const value = normalizeGenerationNumber(
      candidate.merge_threshold_ratio,
      mergeThresholdFallback,
    )
    mergeThresholdRatio = clamp(Number(value), 0, 1)
  }

  return {
    steps,
    rows,
    legacyTieParams,
    voiceInventoryId,
    mergeThresholdRatio,
  }
}
