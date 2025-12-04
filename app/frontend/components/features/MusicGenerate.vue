<template>
  <div class="pa-4">

    <MusicGenerateDialog v-model="setDataDialog" :progress="progress" @generate-polyphonic="onGeneratePolyphonic" />
  </div>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue'
import MusicGenerateDialog from '../dialog/MusicGenerateDialog.vue'
import axios from 'axios'
import { v4 as uuidv4 } from 'uuid'
import { useJobChannel } from '../../composables/useJobChannel'

const progress = ref({ percent: 0, status: 'idle' })
const setDataDialog = ref(false)

const openParams = () => { setDataDialog.value = true }
import { defineExpose } from 'vue'
defineExpose({ openParams })

const onGeneratePolyphonic = async (payload) => {
  // payload is prepared by the dialog; send to server and subscribe to progress
  const jobId = uuidv4()
  progress.value = { percent: 0, status: 'start' }
  const { unsubscribe } = useJobChannel(jobId, (data) => {
    progress.value.status = data.status
    progress.value.percent = data.progress
    if (data.status === 'done') unsubscribe()
  })

  try {
    await axios.post('/api/web/time_series/generate_polyphonic', payload)
  } catch (err) {
    console.error('generate_polyphonic error', err)
    progress.value.status = 'error'
  }
}
</script>
