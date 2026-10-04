const { chromium } = require('playwright')

const mode = process.env.RENDER_BROWSER_MODE || 'binary'
const baseUrl = process.env.RENDER_BENCHMARK_BASE_URL || 'http://127.0.0.1:19115'
const steps = Number(process.env.RENDER_BENCHMARK_STEPS || 500)
const bpm = Number(process.env.RENDER_BENCHMARK_BPM || 240)
const text = process.env.RENDER_BENCHMARK_TEXT || 'あ'

const voice = [[60], 0.8, 0.5, 0.1, 0.8, 0.1, 0.3, 0.6, 0.0, 0.0, 0.0]
const payload = {
  time_series: Array.from({ length: steps }, () => [voice]),
  stream_ids: Array.from({ length: steps }, () => [1]),
  voice_plan: Array.from({ length: steps }, () => [{ streamId: 1, mode: 'voice', text }]),
  bpm,
  future_bpm: Array.from({ length: steps }, () => bpm),
  tail_pad_seconds: 0.05,
  ...(mode === 'binary' ? { return_audio_base64: false } : {}),
}

async function main() {
  const browser = await chromium.launch({
    headless: true,
    args: ['--enable-precise-memory-info'],
  })

  try {
  const page = await browser.newPage()
  await page.goto(baseUrl + '/api/health', { waitUntil: 'load', timeout: 120000 })

  const result = await page.evaluate(async ({ mode, payload }) => {
    if (!performance.memory) throw new Error('performance.memory is unavailable')

    let peak = performance.memory.usedJSHeapSize
    const before = peak
    const timer = setInterval(() => {
      peak = Math.max(peak, performance.memory.usedJSHeapSize)
    }, 5)

    let renderResult
    let finalAudioBytes = 0
    let renderResponseBytes = 0
    let audioTransferSeconds = null
    let cleanupPayload = null
    const started = performance.now()

    try {
      const renderResponse = await fetch('/api/web/supercolliders/render_polyphonic', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      })
      const renderText = await renderResponse.text()
      renderResponseBytes = new TextEncoder().encode(renderText).byteLength
      if (!renderResponse.ok) throw new Error('render HTTP ' + renderResponse.status + ': ' + renderText)
      renderResult = JSON.parse(renderText)
      if (renderResult.error) throw new Error(String(renderResult.error))
      peak = Math.max(peak, performance.memory.usedJSHeapSize)

      if (mode === 'legacy') {
        let audio = String(renderResult.audio_data || '')
        if (audio.includes(',')) audio = audio.split(',', 2)[1]
        if (!audio) throw new Error('legacy render returned no audio_data')
        const decoded = atob(audio)
        const bytes = new Uint8Array(decoded.length)
        for (let i = 0; i < decoded.length; i++) bytes[i] = decoded.charCodeAt(i)
        finalAudioBytes = bytes.byteLength
        peak = Math.max(peak, performance.memory.usedJSHeapSize)
        cleanupPayload = {
          cleanup: {
            scd_file_path: renderResult.scd_file_path || '',
            sound_file_path: renderResult.sound_file_path || '',
          },
        }
      } else {
        const jobId = String(renderResult.render_job_id || '')
        if (!jobId) throw new Error('binary render returned no render_job_id')
        const transferStarted = performance.now()
        const audioResponse = await fetch('/api/web/supercolliders/render_audio', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ render_job_id: jobId }),
        })
        const blob = await audioResponse.blob()
        audioTransferSeconds = (performance.now() - transferStarted) / 1000
        if (!audioResponse.ok) throw new Error('render_audio HTTP ' + audioResponse.status)
        finalAudioBytes = blob.size
        const objectUrl = URL.createObjectURL(blob)
        peak = Math.max(peak, performance.memory.usedJSHeapSize)
        URL.revokeObjectURL(objectUrl)
        cleanupPayload = { cleanup: { render_job_id: jobId } }
      }

      await new Promise(resolve => setTimeout(resolve, 100))
      peak = Math.max(peak, performance.memory.usedJSHeapSize)
      return {
        mode,
        render_seconds: (performance.now() - started) / 1000,
        render_response_bytes: renderResponseBytes,
        final_audio_bytes: finalAudioBytes,
        audio_transfer_seconds: audioTransferSeconds,
        heap_before_bytes: before,
        heap_peak_bytes: peak,
        heap_peak_delta_bytes: Math.max(0, peak - before),
        heap_after_bytes: performance.memory.usedJSHeapSize,
        voice_audio_bytes: Number(renderResult.voiceAudioBytes || 0),
      }
    } finally {
      clearInterval(timer)
      if (cleanupPayload) {
        try {
          await fetch('/api/web/supercolliders/cleanup', {
            method: 'DELETE',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(cleanupPayload),
          })
        } catch {}
      }
    }
  }, { mode, payload })

  console.log('render_browser_memory_benchmark=' + JSON.stringify({
    ...result,
    steps,
    bpm,
    estimated_duration_seconds: steps * 60 / bpm + 0.05,
  }))
} finally {
    await browser.close()
  }
}

main().catch(error => {
  console.error(error)
  process.exitCode = 1
})
