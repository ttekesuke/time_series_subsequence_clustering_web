<template>
  <v-dialog width="1000" v-model="open">
    <v-form>
      <v-card>
        <v-card-title>
          <v-row>
            <v-col cols="5">
              <div class="text-h4 d-flex align-center fill-height">Clustering Generate</div>
            </v-col>
            <v-col cols="7">
              <v-file-input
                label="upload json file"
                accept=".json"
                prepend-icon="mdi-upload"
                @change="handleFileSelected"
              ></v-file-input>
            </v-col>
          </v-row>
        </v-card-title>
        <v-card-text>
          <div class="mb-4">
            <GridContainer
              v-model:rows="firstRows"
              v-model:steps="firstSteps"
              :showRowsLength="false"
              :showColsLength="true"
            />
          </div>

          <div class="mb-4">
            <GridContainer
              v-model:rows="complexityRows"
              v-model:steps="complexitySteps"
              :showRowsLength="false"
              :showColsLength="true"
            />
          </div>

          <v-row class="mt-4">
            <v-col cols="2">
              <v-text-field label="range min" type="number" v-model.number="rangeMin"></v-text-field>
            </v-col>
            <v-col cols="2">
              <v-text-field label="range max" type="number" v-model.number="rangeMax"></v-text-field>
            </v-col>
            <v-col cols="2">
              <v-text-field
                label="merge threshold ratio"
                type="number"
                v-model.number="mergeThreshold"
                min="0" max="1" step="0.01"
              ></v-text-field>
            </v-col>
            <v-col cols="4" class="d-flex align-center">
              <v-btn color="primary" :loading="loading || isProcessing" :disabled="isProcessing" @click="handleGenerateTimeseries">Generate</v-btn>
              <span class="ml-2" v-if="progress.status == 'start' || progress.status == 'progress'">{{ progress.percent }}%</span>
            </v-col>
          </v-row>
        </v-card-text>
      </v-card>
    </v-form>
  </v-dialog>
</template>

<script setup lang="ts">
import { computed, onUnmounted, ref, watch } from 'vue'
import { v4 as uuidv4 } from 'uuid'
import { useJobChannel } from '../../composables/useJobChannel'
const props = defineProps({
  modelValue: Boolean,
  progress: { type: Object, required: false },
  onFileSelected: { type: Function, required: false },
  setRandoms: { type: Function, required: false },
  jobId: { type: String, required: false }
})
const emit = defineEmits(['update:modelValue', 'generated', 'progress-update'])

const open = computed({ get: () => props.modelValue, set: (v: boolean) => emit('update:modelValue', v) })

const progress = ref(props.progress || { percent: 0, status: 'idle' })
watch(() => props.progress, (val) => { if (val) progress.value = val })

const updateProgress = (data) => {
  progress.value = data
  emit('progress-update', data)
}

let unsubscribeProgress: (() => void) | null = null
const cleanupProgress = () => {
  if (unsubscribeProgress) {
    unsubscribeProgress()
    unsubscribeProgress = null
  }
}

const startProgressTracking = (jobId: string) => {
  cleanupProgress()
  updateProgress({ percent: 0, status: 'start' })
  const { unsubscribe } = useJobChannel(jobId, (data) => {
    updateProgress({
      percent: data.progress ?? progress.value.percent,
      status: data.status
    })
    if (data.status === 'done') cleanupProgress()
  })
  unsubscribeProgress = unsubscribe
}

const isProcessing = computed(() => progress.value.status === 'start' || progress.value.status === 'progress')

import GridContainer from '../grid/GridContainer.vue'
import axios from 'axios'

// rows[0] === firstElements, rows[1] === complexityTransition
const rows = ref([
  { name: 'firstElements', data: [0,0,0], config: { min: -9999, max: 9999, isInt: true, step: 1 } },
  { name: 'complexityTransition', data: [0,0,0], config: { min: -9999, max: 9999, isInt: true, step: 1 } }
])
// computed mappings for two separate GridContainer instances
const firstSteps = ref(3)
const complexitySteps = ref(3)

const firstRows = computed({
  get: () => [ rows.value[0] || { name: 'firstElements', data: Array(firstSteps.value).fill(0), config: { min: -9999, max: 9999, isInt: true, step: 1 } } ],
  set: (v) => { rows.value[0] = (v && v[0]) ? v[0] : rows.value[0] }
})
const complexityRows = computed({
  get: () => [ rows.value[1] || { name: 'complexityTransition', data: Array(complexitySteps.value).fill(0), config: { min: -9999, max: 9999, isInt: true, step: 1 } } ],
  set: (v) => { rows.value[1] = (v && v[0]) ? v[0] : rows.value[1] }
})
const rangeMin = ref(0)
const rangeMax = ref(11)
const mergeThreshold = ref(0.02)
const loading = ref(false)

const handleFileSelected = (e) => { if (props.onFileSelected) props.onFileSelected(e) }

const handleGenerateTimeseries = async () => {
  loading.value = true
  try {
    const jobId = props.jobId || uuidv4()
    startProgressTracking(jobId)
    // read values from rows: firstElements row and complexityTransition row
    const firstElems = (rows.value[0] && Array.isArray(rows.value[0].data)) ? rows.value[0].data.join(',') : ''
    const complexity = (rows.value[1] && Array.isArray(rows.value[1].data)) ? rows.value[1].data.join(',') : ''
    const payload = {
      generate: {
        complexity_transition: complexity,
        first_elements: firstElems,
        range_min: rangeMin.value,
        range_max: rangeMax.value,
        merge_threshold_ratio: mergeThreshold.value,
        job_id: jobId
      }
    }
    const resp = await axios.post('/api/web/time_series/generate', payload)
    emit('generated', resp.data)
    open.value = false
  } catch (err) {
    console.error('Generate request failed', err)
    updateProgress({ percent: 0, status: 'idle' })
    cleanupProgress()
  } finally {
    loading.value = false
  }
}

onUnmounted(() => cleanupProgress())
</script>

<style scoped>
</style>
