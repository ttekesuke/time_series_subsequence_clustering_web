import { chromium } from 'playwright'

const baseUrl = process.env.VISUALIZER_BENCHMARK_BASE_URL ?? 'http://127.0.0.1:4173'
const iterations = Math.max(10, Number(process.env.VISUALIZER_BENCHMARK_ITERATIONS ?? 120))
const streams = Math.max(1, Number(process.env.VISUALIZER_BENCHMARK_STREAMS ?? 6))

const cases = [
  { steps: 2352, mode: 'Complexity' },
  { steps: 2352, mode: 'Cluster' },
  { steps: 20000, mode: 'Complexity' },
  { steps: 20000, mode: 'Cluster' },
]

const browser = await chromium.launch({
  headless: true,
  args: ['--enable-precise-memory-info'],
})

try {
  const page = await browser.newPage({
    viewport: { width: 1440, height: 1000 },
    deviceScaleFactor: 1,
  })

  await page.goto(`${baseUrl}/?visualizerBenchmark=1`, {
    waitUntil: 'networkidle',
    timeout: 120000,
  })
  await page.waitForFunction(
    () => typeof window.loadMusicAnalyseBenchmarkFixture === 'function',
    null,
    { timeout: 30000 },
  )

  for (const benchmarkCase of cases) {
    const loadStarted = Date.now()
    const loaded = await page.evaluate(
      async ({ steps, streams, mode }) =>
        await window.loadMusicAnalyseBenchmarkFixture(steps, streams, mode),
      {
        steps: benchmarkCase.steps,
        streams,
        mode: benchmarkCase.mode,
      },
    )
    await page.waitForTimeout(250)

    const report = await page.evaluate(
      async ({ label, iterations }) => {
        const module = await import('/benchmark-visualizers.js')
        return await module.runVisualizerBenchmark({ label, iterations })
      },
      {
        label: `${benchmarkCase.steps}-step-${benchmarkCase.mode.toLowerCase()}`,
        iterations,
      },
    )

    const output = {
      case: benchmarkCase,
      streams,
      iterations,
      fixture_load_ms: Date.now() - loadStarted,
      loaded,
      report,
    }
    console.log('visualizer_browser_benchmark=' + JSON.stringify(output))
  }
} finally {
  await browser.close()
}
