import axios from 'axios'

export const generatePolyphonicEndpoint = (dispatchToGithub: boolean) =>
  dispatchToGithub
    ? '/api/web/time_series/dispatch_generate_polyphonic'
    : '/api/web/time_series/generate_polyphonic'

export const submitGeneratePolyphonic = async (
  payload: unknown,
  dispatchToGithub: boolean,
) => {
  const response = await axios.post(
    generatePolyphonicEndpoint(dispatchToGithub),
    payload,
  )
  return response.data
}

export type SoundCheckRenderResult = {
  blob: Blob | null
  error: string | null
}

export const renderSoundCheckBlob = async (
  voice: unknown,
  bpm: number,
): Promise<SoundCheckRenderResult> => {
  let renderJobId = ''
  try {
    const response = await axios.post('/api/web/supercolliders/render_polyphonic', {
      time_series: [[voice]],
      bpm,
      future_bpm: [bpm],
      initial_context_bpm: [bpm],
      tail_pad_seconds: 0.05,
      return_audio_base64: false,
    })
    renderJobId = String(response?.data?.render_job_id ?? '')

    if (response?.data?.error) {
      return { blob: null, error: String(response.data.error) }
    }
    if (!renderJobId) {
      throw new Error('Sound check render job ID was not returned.')
    }

    const audioResponse = await axios.post(
      '/api/web/supercolliders/render_audio',
      { render_job_id: renderJobId },
      { responseType: 'blob' },
    )
    const blob = audioResponse.data instanceof Blob
      ? audioResponse.data
      : new Blob([audioResponse.data], { type: 'audio/wav' })

    return { blob, error: null }
  } finally {
    if (renderJobId) {
      try {
        await axios.delete('/api/web/supercolliders/cleanup', {
          data: { cleanup: { render_job_id: renderJobId } },
        })
      } catch (error) {
        console.error('Sound check cleanup failed:', error)
      }
    }
  }
}
