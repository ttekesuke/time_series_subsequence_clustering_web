<template>
  <v-dialog width="1000" v-model="open">
    <v-form>
      <v-card>
        <v-card-title>
          <v-row>
            <v-col cols="5">
              <div class="text-h4 d-flex align-center fill-height">Clustering Generate</div>
            </v-col>
            <!-- <v-col cols="7">
              <v-file-input
                label="upload json file"
                accept=".json"
                prepend-icon="mdi-upload"
                @change="handleFileSelected"
              ></v-file-input>
            </v-col> -->
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

          <div class="mb-4">
            <GridContainer
              v-model:rows="recencyRows"
              v-model:steps="recencySteps"
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
            <v-col cols="12">
              <v-btn color="success" :loading="loading" @click="handleGenerateTimeseries">Generate</v-btn>
              <span v-if="props.progress && (props.progress.status == 'start' || props.progress.status == 'progress')">{{props.progress.percent}}%</span>
            </v-col>
          </v-row>
        </v-card-text>
      </v-card>
    </v-form>
  </v-dialog>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue'
const props = defineProps({
  modelValue: Boolean,
  progress: { type: Object, required: false },
  onFileSelected: { type: Function, required: false },
  setRandoms: { type: Function, required: false },
  jobId: { type: String, required: false }
})
const emit = defineEmits(['update:modelValue', 'generated'])

const open = computed({ get: () => props.modelValue, set: (v: boolean) => emit('update:modelValue', v) })

import GridContainer from '../grid/GridContainer.vue'
import axios from 'axios'
/** 共通型 */
type GridRowData = {
  name: string;
  shortName: string;
  data: number[];
  config: {
    min: number;
    max: number;
    step?: number;
    isInt?: boolean;
  }
}
const rangeMin = ref(0)
const rangeMax = ref(11)

// rows[0] === firstElements, rows[1] === complexityTransition
const rows = ref<GridRowData[]>([
  {
    name: 'firstElements',
    shortName: 'First Elements',
    data: [0,0,0],
    config: {
      min: rangeMin.value,
      max: rangeMax.value,
      isInt: true,
      step: 1
    }
  },
  {
    name: 'complexityTransition',
    shortName: 'Complexity Transition',
    data: [0,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,0.9,0.8,0.7,0.6,0.5,0.4,0.3,0.2,0.1,0],
    config: {
      min: 0,
      max: 1,
      isInt: false,
      step: 0.01
    }
  },
  {
    name: 'recencyCenter',
    shortName: 'Recency Center',
    data: Array(31).fill(0),
    config: {
      min: 0,
      max: 1,
      isInt: false,
      step: 0.01
    }
  }
])
// computed mappings for two separate GridContainer instances
const firstSteps = ref(3)
const complexitySteps = ref(31)
const recencySteps = ref(31)

const fallbackFirstRow = (): GridRowData => ({
  name: 'firstElements',
  shortName: 'First Elements',
  data: Array(firstSteps.value).fill(0),
  config: { min: -9999, max: 9999, isInt: true, step: 1 }
})

const fallbackComplexityRow = (): GridRowData => ({
  name: 'complexityTransition',
  shortName: 'Complexity Transition',
  data: Array(complexitySteps.value).fill(0),
  config: { min: 0, max: 1, isInt: false, step: 0.01 }
})

const fallbackRecencyRow = (): GridRowData => ({
  name: 'recencyCenter',
  shortName: 'Recency Center',
  data: Array(recencySteps.value).fill(0),
  config: { min: 0, max: 1, isInt: false, step: 0.01 }
})

const firstRows = computed({
  get: () => [rows.value[0] || fallbackFirstRow()],
  set: (v) => { rows.value[0] = (v && v[0]) ? v[0] : (rows.value[0] || fallbackFirstRow()) }
})
const complexityRows = computed({
  get: () => [rows.value[1] || fallbackComplexityRow()],
  set: (v) => { rows.value[1] = (v && v[0]) ? v[0] : (rows.value[1] || fallbackComplexityRow()) }
})
const recencyRows = computed({
  get: () => [rows.value[2] || fallbackRecencyRow()],
  set: (v) => { rows.value[2] = (v && v[0]) ? v[0] : (rows.value[2] || fallbackRecencyRow()) }
})
const mergeThreshold = ref(0.02)
const loading = ref(false)

const handleGenerateTimeseries = async () => {
  loading.value = true
  try {
    // read values from rows: firstElements row and complexityTransition row
    const firstElems = (rows.value[0] && Array.isArray(rows.value[0].data)) ? rows.value[0].data.join(',') : ''
    const complexity = (rows.value[1] && Array.isArray(rows.value[1].data)) ? rows.value[1].data.join(',') : ''
    const recencyCenter = (rows.value[2] && Array.isArray(rows.value[2].data)) ? rows.value[2].data.join(',') : ''
    const payload = {
      generate: {
        complexity_transition: complexity,
        first_elements: firstElems,
        range_min: rangeMin.value,
        range_max: rangeMax.value,
        merge_threshold_ratio: mergeThreshold.value,
        recency_center: recencyCenter,
        job_id: props.jobId
      }
    }
    const resp = await axios.post('/api/web/time_series/generate', payload)
    emit('generated', resp.data)
    open.value = false
  } catch (err) {
    console.error('Generate request failed', err)
  } finally {
    loading.value = false
  }
}
</script>

<style scoped>
</style>
