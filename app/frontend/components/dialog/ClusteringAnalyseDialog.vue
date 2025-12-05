<template>
  <v-dialog width="1000" v-model="open">
    <v-form  fast-fail>
      <v-card>
        <v-card-title>
          <v-row>
            <v-col cols="5">
              <div class="text-h4 d-flex align-center fill-height">Clustering Analyse</div>
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
            <GridContainer
              v-model:rows="rows"
              v-model:steps="steps"
              :showRowsLength="false"
            />

          <v-row>
            <v-col>
              <v-row>
                <v-col cols="4">
                  <v-text-field
                    label="merge threshold ratio"
                    type="number"
                    v-model="mergeThreshold"
                    min="0"
                    max="1"
                    step="0.01"
                  ></v-text-field>
                </v-col>
                  <v-col cols="4">
                  <v-btn @click="handleAnalyseTimeseries" :loading="loading">Submit</v-btn>
                  <span v-if="props.progress.status == 'start' || props.progress.status == 'progress'">{{props.progress.percent}}%</span>
                </v-col>
              </v-row>
            </v-col>
          </v-row>
        </v-card-text>
      </v-card>
    </v-form>
  </v-dialog>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue'
const props = defineProps({
  modelValue: Boolean,
  progress: { type: Object, required: false },
  onFileSelected: { type: Function, required: false },
  jobId: { type: String, required: false }
})
const emit = defineEmits(['update:modelValue', 'analysed'])

const open = computed({
  get: () => props.modelValue,
  set: (v: boolean) => emit('update:modelValue', v)
})

import GridContainer from '../grid/GridContainer.vue'
import axios from 'axios'

const timeseriesMax = 100

const rows = ref([{ name: 'values', data: [null, null, null], config: { min: 0, isInt: true, step: 1 } }])
const steps = ref(3)
const mergeThreshold = ref(0.02)
const loading = ref(false)

const handleFileSelected = (e) => {
  if (props.onFileSelected) props.onFileSelected(e)
}

const handleAnalyseTimeseries = async () => {
  loading.value = true
  try {
    const time_series = (rows.value && rows.value[0] && rows.value[0].data) ? rows.value[0].data : []
    const data = { analyse: { time_series: time_series, merge_threshold_ratio: mergeThreshold.value, job_id: props.jobId } }
    const resp = await axios.post('/api/web/time_series/analyse', data)
    // emit full response data to parent; do not mutate parent props here
    emit('analysed', resp.data)
    // close dialog
    open.value = false
  } catch (err) {
    console.error('Analyse request failed', err)
  } finally {
    loading.value = false
  }
}
</script>

<style scoped>
/* keep styling minimal; using existing app styles */
</style>
