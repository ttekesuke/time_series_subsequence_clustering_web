import {
  formatAbsNoteCell,
  strictContextIndexByKey,
} from './initialContext'
import {
  normalizeGenerationBpmSeries,
  normalizeGenerationNumber,
} from './generationPayloadNormalization'

export type InitialContextHydrationSpec = {
  key: string
  min: number
  max: number
  isInt?: boolean
}

export type InitialContextHydration = {
  steps: number
  streamCount: number
  rowData: Array<Array<number | string>>
  bpm: number[]
}

export const hydrateInitialContextPayload = ({
  contextRaw,
  bpmRaw,
  specs,
  strictDefaults,
}: {
  contextRaw: unknown
  bpmRaw: unknown
  specs: InitialContextHydrationSpec[]
  strictDefaults: number[]
}): InitialContextHydration | null => {
  if (!Array.isArray(contextRaw)) return null

  const steps = Math.max(1, contextRaw.length)
  const streamCount = Math.max(
    1,
    ...contextRaw.map((step) => (Array.isArray(step) ? step.length : 0)),
  )

  const rowData: Array<Array<number | string>> = []

  for (let streamIndex = 0; streamIndex < streamCount; streamIndex++) {
    for (const spec of specs) {
      if (spec.key === 'lyrics') {
        rowData.push(Array.from({ length: steps }, () => ''))
        continue
      }

      const strictIndex =
        strictContextIndexByKey[spec.key as keyof typeof strictContextIndexByKey]
      const fallback = strictDefaults[strictIndex] ?? 0
      const data: Array<number | string> = []

      for (let stepIndex = 0; stepIndex < steps; stepIndex++) {
        const step = contextRaw[stepIndex]
        const stream = Array.isArray(step) ? step[streamIndex] : null
        const rawValue =
          Array.isArray(stream) && stream.length === 11
            ? stream[strictIndex]
            : null

        if (spec.key === 'abs_note') {
          data.push(formatAbsNoteCell(rawValue))
          continue
        }

        let value = normalizeGenerationNumber(rawValue, fallback)
        if (spec.key === 'tie') {
          value = Math.round(value * 2) / 2
        }
        if (spec.isInt) {
          value = Math.round(value)
        }
        value = Math.max(spec.min, Math.min(spec.max, value))
        data.push(value)
      }

      rowData.push(data)
    }
  }

  return {
    steps,
    streamCount,
    rowData,
    bpm: normalizeGenerationBpmSeries(bpmRaw, steps),
  }
}

export const hydrateInitialContextLyrics = ({
  rowData,
  voicePlan,
  steps,
  dimensionCount,
  lyricsIndex,
}: {
  rowData: Array<Array<number | string>>
  voicePlan: unknown
  steps: number
  dimensionCount: number
  lyricsIndex: number
}) => {
  const next = rowData.map((data) => [...data])
  if (!Array.isArray(voicePlan)) return next

  voicePlan.forEach((stepPlan, stepIndex) => {
    if (!Array.isArray(stepPlan) || stepIndex >= steps) return

    stepPlan.forEach((entry) => {
      const streamIndex = Number((entry as any)?.streamId) - 1
      if (!Number.isInteger(streamIndex) || streamIndex < 0) return
      const rowIndex = streamIndex * dimensionCount + lyricsIndex
      const row = next[rowIndex]
      if (!row) return
      row[stepIndex] =
        typeof (entry as any)?.text === 'string' ? (entry as any).text : ''
    })
  })

  return next
}
