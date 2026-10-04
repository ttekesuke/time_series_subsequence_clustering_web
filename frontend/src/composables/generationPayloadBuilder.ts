import { normalizeGenerationBpmSeries } from './generationPayloadNormalization'

export type GenerationRowMetaLike = {
  key: string
  min: number
  max: number
  isInt?: boolean
  defaultFactory: (length: number) => number[]
}

export type GenerationRowLike = {
  data: Array<number | string>
}

export type LegacyTieParams = {
  tie_center: number[]
  tie_spread: number[]
}

export const complexityDimensionKeys = [
  'area',
  'chord_range',
  'density',
  'vol',
  'brightness',
  'noise',
  'harmonicity',
  'attack',
  'decay_sustain',
  'release',
] as const

export const targetWindowDimensionKeys = [
  'vol',
  'chord_range',
  'density',
  'brightness',
  'noise',
  'harmonicity',
  'attack',
  'decay_sustain',
  'release',
] as const

export const tieParamKeys = [
  'tie_global_complexity_target',
  'tie_stream_complexity_center',
  'tie_stream_complexity_span',
  'tie_concordance',
  'tie_value_target',
  'tie_value_radius',
] as const

export const complexityParamKeys = (key: string) => key === 'area'
  ? {
      global: 'area_global',
      center: 'area_center',
      span: 'area_spread',
      concordance: 'area_conc',
    }
  : {
      global: `${key}_global_complexity_target`,
      center: `${key}_stream_complexity_center`,
      span: `${key}_stream_complexity_span`,
      concordance: `${key}_concordance`,
    }

export const valueParamKeys = (key: string) => ({
  target: `${key}_value_target`,
  radius: `${key}_value_radius`,
})

export const buildGenerationParamsFromRows = ({
  steps,
  metas,
  rows,
  voicevoxEnabled,
}: {
  steps: number
  metas: GenerationRowMetaLike[]
  rows: GenerationRowLike[]
  voicevoxEnabled: boolean
}): Record<string, number[]> => {
  const metaByKey = new Map(metas.map((meta, index) => [meta.key, { meta, index }]))

  const get = (key: string): number[] => {
    const entry = metaByKey.get(key)
    if (!entry) throw new Error(`Unknown generation parameter: ${key}`)

    const { meta, index } = entry
    const source = rows[index]?.data
    const fallback = meta.defaultFactory(steps)
    const values: number[] = []

    for (let i = 0; i < steps; i++) {
      let value = source && i < source.length && source[i] != null
        ? Number(source[i])
        : Number(fallback[i] ?? meta.min)

      if (meta.isInt) value = Math.round(value)
      else value = Number(value.toFixed(2))

      if (value < meta.min) value = meta.min
      if (value > meta.max) value = meta.max
      values.push(value)
    }

    return values
  }

  const result: Record<string, number[]> = {
    stream_counts: get('stream_counts'),
    stream_strength_target: get('stream_strength_target'),
    stream_strength_spread: get('stream_strength_spread'),
    note_register_freedom: get('note_register_freedom'),
    dissonance_target: get('dissonance_target'),
    future_bpm: get('future_bpm'),
    recency_center: get('recency_center'),
    recency_spread: get('recency_spread'),
  }

  if (voicevoxEnabled) {
    result.voice_stream_counts = get('voice_stream_counts')
    result.voice_token_global_complexity_target = get('voice_token_global_complexity_target')
    result.voice_token_stream_complexity_center = get('voice_token_stream_complexity_center')
    result.voice_token_stream_complexity_span = get('voice_token_stream_complexity_span')
    result.voice_token_concordance = get('voice_token_concordance')
    result.voice_transition_weight = get('voice_transition_weight')
  }

  tieParamKeys.forEach((key) => {
    result[key] = get(key)
  })

  complexityDimensionKeys.forEach((key) => {
    const keys = complexityParamKeys(key)
    result[keys.global] = get(keys.global)
    result[keys.center] = get(keys.center)
    result[keys.span] = get(keys.span)
    result[keys.concordance] = get(keys.concordance)
  })

  targetWindowDimensionKeys.forEach((key) => {
    const keys = valueParamKeys(key)
    result[keys.target] = get(keys.target)
    result[keys.radius] = get(keys.radius)
  })

  return result
}

export const buildInitialContextVoicePlan = ({
  rows,
  steps,
  streamCount,
  dimensionCount,
  lyricsIndex,
}: {
  rows: GenerationRowLike[]
  steps: number
  streamCount: number
  dimensionCount: number
  lyricsIndex: number
}) =>
  Array.from({ length: steps }, (_, stepIndex) =>
    Array.from({ length: streamCount }, (_, streamIndex) => {
      const lyricsRow = rows[streamIndex * dimensionCount + lyricsIndex]
      const text = String(lyricsRow?.data?.[stepIndex] ?? '').trim()
      return {
        streamId: streamIndex + 1,
        mode: text ? 'voice' : 'synth',
        text: text || null,
      }
    }),
  )

export const buildGeneratePolyphonicPayload = ({
  jobId,
  genParams,
  genSteps,
  initialContext,
  initialContextVoicePlan,
  initialContextBpm,
  dimensionPolicy,
  mergeThresholdRatio,
  voicevoxEnabled,
  voiceInventoryId,
  legacyTieParams,
}: {
  jobId: string
  genParams: Record<string, number[]>
  genSteps: number
  initialContext: unknown
  initialContextVoicePlan: unknown
  initialContextBpm: unknown
  dimensionPolicy: unknown
  mergeThresholdRatio: number
  voicevoxEnabled: boolean
  voiceInventoryId: string
  legacyTieParams: LegacyTieParams | null
}) => {
  const futureBpm = normalizeGenerationBpmSeries(genParams.future_bpm, genSteps)

  const generatePolyphonic: Record<string, any> = {
    job_id: jobId,
    bpm: futureBpm[0],
    future_bpm: futureBpm,
    stream_counts: genParams.stream_counts,
    recency_center: genParams.recency_center,
    recency_spread: genParams.recency_spread,
    initial_context: initialContext,
    initial_context_voice_plan: initialContextVoicePlan,
    initial_context_bpm: normalizeGenerationBpmSeries(initialContextBpm, Array.isArray(initialContext) ? initialContext.length : 1),
    dimension_policy: dimensionPolicy,
    merge_threshold_ratio: mergeThresholdRatio,
    compact_cluster_view: true,
    stream_strength_target: genParams.stream_strength_target,
    stream_strength_spread: genParams.stream_strength_spread,
    note_register_freedom: genParams.note_register_freedom,
    dissonance_target: genParams.dissonance_target,
  }

  if (voicevoxEnabled) {
    generatePolyphonic.voice_stream_counts = genParams.voice_stream_counts.map(
      (value: number, index: number) => Math.min(value, genParams.stream_counts[index] ?? value),
    )
    generatePolyphonic.voice_inventory_id = voiceInventoryId || 'ja_voicevox_all'
    generatePolyphonic.voice_token_global_complexity_target = genParams.voice_token_global_complexity_target
    generatePolyphonic.voice_token_stream_complexity_center = genParams.voice_token_stream_complexity_center
    generatePolyphonic.voice_token_stream_complexity_span = genParams.voice_token_stream_complexity_span
    generatePolyphonic.voice_token_concordance = genParams.voice_token_concordance
    generatePolyphonic.voice_transition_weight = genParams.voice_transition_weight
  }

  if (legacyTieParams) {
    generatePolyphonic.tie_center = [...legacyTieParams.tie_center]
    generatePolyphonic.tie_spread = [...legacyTieParams.tie_spread]
  } else {
    tieParamKeys.forEach((key) => {
      generatePolyphonic[key] = genParams[key]
    })
  }

  complexityDimensionKeys.forEach((key) => {
    const keys = complexityParamKeys(key)
    generatePolyphonic[keys.global] = genParams[keys.global]
    generatePolyphonic[keys.center] = genParams[keys.center]
    generatePolyphonic[keys.span] = genParams[keys.span]
    generatePolyphonic[keys.concordance] = genParams[keys.concordance]
  })

  targetWindowDimensionKeys.forEach((key) => {
    const keys = valueParamKeys(key)
    generatePolyphonic[keys.target] = genParams[keys.target]
    generatePolyphonic[keys.radius] = genParams[keys.radius]
  })

  return { generate_polyphonic: generatePolyphonic }
}
