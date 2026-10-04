type BenchmarkSpan = {
  window_min: number
  window_max: number
  cluster_ids: number[]
  indices: number[]
  fit_limits: number[]
  parent_index: number | null
}

const clamp01 = (value: number) => Math.max(0, Math.min(1, value))

const normalizedWave = (step: number, phase: number, period: number) =>
  clamp01(0.5 + 0.45 * Math.sin((step + phase) / period))

const metricAxes = (steps: number, phase: number) => ({
  prediction: Array.from({ length: steps }, (_, step) => normalizedWave(step, phase, 13)),
  diversity: Array.from({ length: steps }, (_, step) => normalizedWave(step, phase + 17, 23)),
  shape: Array.from({ length: steps }, (_, step) => normalizedWave(step, phase + 31, 37)),
  mass: Array.from({ length: steps }, (_, step) => normalizedWave(step, phase + 47, 53)),
})

const compressedSpans = (steps: number): BenchmarkSpan[] => {
  const windows = [4, 8, 16, 32, 64].filter(window => window <= steps)
  return windows.map((window, index) => {
    const stride = Math.max(window * 3, 17)
    const indices: number[] = []
    for (let start = index * 3; start + window <= steps; start += stride) {
      indices.push(start)
    }
    const windowMax = Math.min(window + 3, Math.max(window, steps))
    const sizeCount = windowMax - window + 1
    return {
      window_min: window,
      window_max: windowMax,
      cluster_ids: Array.from({ length: sizeCount }, (_, offset) => index * 100 + offset + 1),
      indices,
      fit_limits: Array.from({ length: sizeCount }, () => steps),
      parent_index: null,
    }
  })
}

const makeDimension = (steps: number, streamCount: number, phase: number) => {
  const streams: Record<string, Array<number | null>> = {}
  const analysisStreams: Record<string, { axes: ReturnType<typeof metricAxes>; raw: Record<string, never> }> = {}
  const compressedStreams: Record<string, BenchmarkSpan[]> = {}

  for (let streamIndex = 0; streamIndex < streamCount; streamIndex++) {
    const streamId = String(streamIndex + 1)
    const streamPhase = phase + streamIndex * 11
    streams[streamId] = Array.from(
      { length: steps },
      (_, step) => normalizedWave(step, streamPhase, 19 + streamIndex),
    )
    analysisStreams[streamId] = {
      axes: metricAxes(steps, streamPhase),
      raw: {},
    }
    compressedStreams[streamId] = compressedSpans(steps)
  }

  return {
    values: {
      global: Array.from({ length: steps }, (_, step) => normalizedWave(step, phase, 29)),
      streams,
      concordance: Array.from({ length: steps }, (_, step) => normalizedWave(step, phase + 7, 41)),
    },
    analysis: {
      global: {
        axes: metricAxes(steps, phase),
        raw: {},
      },
      streams: analysisStreams,
    },
    compressedClusters: {
      global: compressedSpans(steps),
      streams: compressedStreams,
    },
  }
}

export const buildVisualizerBenchmarkFixture = (
  steps = 2352,
  streamCount = 6,
) => {
  const safeSteps = Math.max(1, Math.round(steps))
  const safeStreamCount = Math.max(1, Math.min(32, Math.round(streamCount)))

  const streamIds = Array.from({ length: safeStreamCount }, (_, index) => index + 1)
  const streamLabels = streamIds.map(id => `benchmark stream ${id}`)

  const pianoStreams = streamIds.map((streamId) =>
    Array.from({ length: safeSteps }, (_, step) => [
      48 + ((step + streamId * 5) % 36),
    ]),
  )
  const pianoVelocities = streamIds.map((streamId) =>
    Array.from(
      { length: safeSteps },
      (_, step) => 0.25 + 0.7 * normalizedWave(step, streamId * 7, 31),
    ),
  )

  const dimensions = {
    note: makeDimension(safeSteps, safeStreamCount, 3),
    area: makeDimension(safeSteps, safeStreamCount, 17),
    vol: makeDimension(safeSteps, safeStreamCount, 29),
    stream_count: {
      values: {
        global: Array.from(
          { length: safeSteps },
          (_, step) => 1 + ((step >> 6) % safeStreamCount),
        ),
        streams: {},
        concordance: Array.from({ length: safeSteps }, () => null),
      },
    },
  }

  return {
    metadata: {
      sourceType: 'benchmark-fixture',
      filename: `visualizer-${safeSteps}-steps.json`,
      composer: '',
      title: 'Visualizer benchmark fixture',
      folder: '',
      xmlScore: '',
    },
    timing: {
      exact: true,
      gridDenominator: 16,
      quarterUnit: '1/16',
      stepCount: safeSteps,
      totalQuarterLength: safeSteps / 16,
      tempoSeries: Array.from({ length: safeSteps }, () => 120),
    },
    streams: streamIds.map((id) => ({
      id,
      label: streamLabels[id - 1],
      partId: 'P1',
      staff: String(id),
      voice: '1',
      lane: String(id),
      sourceVoices: ['1'],
    })),
    pianoRoll: {
      streams: pianoStreams,
      velocities: pianoVelocities,
      streamIds,
      streamLabels,
    },
    dimensionOrder: ['note', 'area', 'vol', 'stream_count'],
    dimensions,
    streamCountSeries: dimensions.stream_count.values.global,
    soundingNoteCountSeries: Array.from(
      { length: safeSteps },
      (_, step) => 1 + ((step >> 5) % safeStreamCount),
    ),
  }
}
