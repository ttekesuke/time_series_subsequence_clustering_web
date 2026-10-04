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

const assertLongClusterInteractions = async (page) => {
  await page.waitForFunction(
    () => typeof window.getMusicAnalyseBenchmarkState === 'function',
    null,
    { timeout: 30000 },
  )

  const clusterCanvas = page.locator('.analysis-row .scroll-wrapper canvas').first()
  const clusterBox = await clusterCanvas.boundingBox()
  if (!clusterBox) throw new Error('Cluster canvas is not visible')

  // The synthetic fixture's first compressed span is window=4 with occurrence at step 0.
  await page.mouse.move(clusterBox.x + 1, clusterBox.y + 34)
  await page.waitForTimeout(50)
  const hovered = await page.evaluate(() => window.getMusicAnalyseBenchmarkState())
  if (hovered.highlightWindowSize !== 4 || hovered.highlightIndices[0] !== 0) {
    throw new Error(
      'Cluster hover did not map to exact step 0/window 4: ' + JSON.stringify(hovered),
    )
  }

  await page.mouse.move(1, 1)
  await page.waitForTimeout(50)
  const cleared = await page.evaluate(() => window.getMusicAnalyseBenchmarkState())
  if (cleared.highlightWindowSize !== 0 || cleared.highlightIndices.length !== 0) {
    throw new Error('Cluster mouseleave did not clear highlight: ' + JSON.stringify(cleared))
  }

  const labelCanvas = page.locator('.analysis-row .label-column canvas').first()
  const labelBox = await labelCanvas.boundingBox()
  if (!labelBox) throw new Error('Cluster label canvas is not visible')
  await page.mouse.click(labelBox.x + 10, labelBox.y + 34)
  await page.locator('.analysis-row .length-control').first().waitFor({
    state: 'visible',
    timeout: 5000,
  })
  await page.locator('.analysis-row .length-control button').first().click()
  await page.locator('.analysis-row .length-control').first().waitFor({
    state: 'hidden',
    timeout: 5000,
  })

  const source = page.locator('.analysis-row .scroll-wrapper').first()
  await source.evaluate((element) => {
    element.scrollLeft = 10000
    element.dispatchEvent(new Event('scroll', { bubbles: true }))
  })
  await page.waitForTimeout(100)

  const scrolled = await page.evaluate(() => window.getMusicAnalyseBenchmarkState())
  const concreteScrolls = scrolled.scrollLefts.filter(value => typeof value === 'number')
  if (concreteScrolls.length < 3 || concreteScrolls.some(value => Math.abs(value - 10000) > 1)) {
    throw new Error('Synchronized scroll position mismatch: ' + JSON.stringify(scrolled))
  }

  const stickyPosition = await source.evaluate((wrapper) => {
    const canvas = wrapper.querySelector('canvas')
    if (!canvas) return null
    const wrapperRect = wrapper.getBoundingClientRect()
    const canvasRect = canvas.getBoundingClientRect()
    return { wrapperLeft: wrapperRect.left, canvasLeft: canvasRect.left }
  })
  if (!stickyPosition || Math.abs(stickyPosition.wrapperLeft - stickyPosition.canvasLeft) > 1) {
    throw new Error('Sticky canvas position drifted after long scroll: ' + JSON.stringify(stickyPosition))
  }

  return { hovered, cleared, scrolled, stickyPosition }
}

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

    const correctness =
      benchmarkCase.steps === 20000 && benchmarkCase.mode === 'Cluster'
        ? await assertLongClusterInteractions(page)
        : null

    const output = {
      case: benchmarkCase,
      streams,
      iterations,
      fixture_load_ms: Date.now() - loadStarted,
      loaded,
      report,
      correctness,
    }
    console.log('visualizer_browser_benchmark=' + JSON.stringify(output))
  }
} finally {
  await browser.close()
}
