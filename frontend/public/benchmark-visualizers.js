const nextFrame = () => new Promise(resolve => requestAnimationFrame(resolve))

const percentile = (sorted, ratio) => {
  if (sorted.length === 0) return 0
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil(sorted.length * ratio) - 1))
  return sorted[index]
}

const frameStats = gaps => {
  const sorted = [...gaps].sort((a, b) => a - b)
  const sum = sorted.reduce((acc, value) => acc + value, 0)
  return {
    samples: sorted.length,
    meanMs: sorted.length ? sum / sorted.length : 0,
    p50Ms: percentile(sorted, 0.5),
    p95Ms: percentile(sorted, 0.95),
    maxMs: sorted.length ? sorted[sorted.length - 1] : 0,
    over16_7ms: sorted.filter(value => value > 16.7).length,
    over33_3ms: sorted.filter(value => value > 33.3).length,
  }
}

const heapSnapshot = () => {
  const memory = performance.memory
  if (!memory) return null
  return {
    usedJSHeapSize: memory.usedJSHeapSize,
    totalJSHeapSize: memory.totalJSHeapSize,
    jsHeapSizeLimit: memory.jsHeapSizeLimit,
  }
}

const rollName = wrapper => {
  const container = wrapper.closest('.roll-container')
  const title = container?.querySelector('.title-label')?.textContent?.trim()
  const kind = container?.querySelector('.label-column') ? 'clusters' : 'streams'
  return {
    title: title || '(untitled)',
    kind,
  }
}

const animateFrames = async (iterations, action) => {
  const gaps = []
  let previous = null
  for (let index = 0; index < iterations; index++) {
    const now = await nextFrame()
    if (previous !== null) gaps.push(now - previous)
    previous = now
    action(index, iterations)
  }
  await nextFrame()
  return frameStats(gaps)
}

const benchmarkRoll = async (wrapper, iterations) => {
  const canvas = wrapper.querySelector('canvas')
  const originalLeft = wrapper.scrollLeft
  const originalTop = wrapper.scrollTop
  const maxScrollLeft = Math.max(0, wrapper.scrollWidth - wrapper.clientWidth)
  const maxScrollTop = Math.max(0, wrapper.scrollHeight - wrapper.clientHeight)
  const identity = rollName(wrapper)
  const heapBefore = heapSnapshot()

  const scroll = await animateFrames(iterations, (index, count) => {
    const cycle = count <= 1 ? 0 : index / (count - 1)
    const normalized = cycle <= 0.5 ? cycle * 2 : (1 - cycle) * 2
    wrapper.scrollLeft = maxScrollLeft * normalized
    if (maxScrollTop > 0) wrapper.scrollTop = maxScrollTop * normalized
  })

  const mousemove = canvas
    ? await animateFrames(iterations, (index, count) => {
        const rect = canvas.getBoundingClientRect()
        const ratio = count <= 1 ? 0.5 : index / (count - 1)
        const clientX = rect.left + Math.max(1, rect.width * ratio)
        const clientY = rect.top + Math.max(1, rect.height * (0.2 + 0.6 * ((index % 17) / 16)))
        canvas.dispatchEvent(new MouseEvent('mousemove', {
          bubbles: true,
          clientX,
          clientY,
        }))
      })
    : null

  wrapper.scrollLeft = originalLeft
  wrapper.scrollTop = originalTop
  if (canvas) canvas.dispatchEvent(new MouseEvent('mouseleave', { bubbles: true }))
  await nextFrame()

  return {
    ...identity,
    viewport: {
      clientWidth: wrapper.clientWidth,
      clientHeight: wrapper.clientHeight,
      scrollWidth: wrapper.scrollWidth,
      scrollHeight: wrapper.scrollHeight,
      devicePixelRatio: window.devicePixelRatio,
    },
    scroll,
    mousemove,
    heapBefore,
    heapAfter: heapSnapshot(),
  }
}

export async function runVisualizerBenchmark(options = {}) {
  const {
    label = 'visualizer-benchmark',
    iterations = 120,
    selector = '.roll-container .scroll-wrapper',
  } = options

  const wrappers = [...document.querySelectorAll(selector)].filter(
    element => element instanceof HTMLElement && element.offsetParent !== null,
  )
  if (wrappers.length === 0) {
    throw new Error(`No visible visualizer scroll wrappers matched: ${selector}`)
  }

  await nextFrame()
  const startedAt = new Date().toISOString()
  const results = []
  for (const wrapper of wrappers) {
    results.push(await benchmarkRoll(wrapper, Math.max(10, Number(iterations) || 120)))
  }

  const report = {
    label,
    startedAt,
    userAgent: navigator.userAgent,
    viewport: {
      width: window.innerWidth,
      height: window.innerHeight,
      devicePixelRatio: window.devicePixelRatio,
    },
    heapApiAvailable: Boolean(performance.memory),
    rollCount: results.length,
    rolls: results,
  }

  console.log('[visualizer-benchmark]', report)
  console.log(JSON.stringify(report))
  return report
}

if (typeof window !== 'undefined') {
  window.runVisualizerBenchmark = runVisualizerBenchmark
}
