import consumer from '../channels/consumer'

export function useJobChannel(jobId: string, onProgress: (data: any) => void) {
  const subscription = consumer.subscriptions.create(
    { channel: 'ProgressChannel', job_id: jobId },
    {
      received(data) {
        onProgress(data)
      }
    }
  )

  return {
    unsubscribe() {
      subscription.unsubscribe()
    }
  }
}
