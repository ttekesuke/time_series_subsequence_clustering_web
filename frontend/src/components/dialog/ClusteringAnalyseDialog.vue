<template>
  <v-dialog width="1000" v-model="open">
    <v-form ref="formRef" fast-fail>
      <v-card>
        <v-card-title>
          <v-row>
            <v-col cols="5">
              <div class="text-h4 d-flex align-center fill-height">Clustering Analyse</div>
            </v-col>
          </v-row>
        </v-card-title>
        <v-card-text>
          <GridContainer
            v-model:rows="rows"
            v-model:steps="steps"
            :showRowsLength="false"
          />

          <v-alert
            v-if="validationError"
            class="mt-3"
            type="error"
            density="compact"
            variant="tonal"
          >
            {{ validationError }}
          </v-alert>

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
                    :rules="ratioRules"
                  ></v-text-field>
                </v-col>
                <v-col cols="4">
                  <v-text-field
                    label="contextual min width"
                    type="number"
                    v-model="contextualMinWidth"
                    min="0"
                    step="0.1"
                    :rules="positiveNumberRules"
                  ></v-text-field>
                </v-col>
                <v-col cols="4">
                  <v-btn @click="handleAnalyseTimeseries" :loading="loading" color="success">Submit</v-btn>
                  <span v-if="props.progress?.status == 'start' || props.progress?.status == 'progress'">{{ props.progress.percent }}%</span>
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
import { computed, ref } from 'vue'
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

type GridRowData = {
  name: string;
  shortName: string;
  data: Array<number | string>;
  config: {
    min: number;
    max: number;
    isInt?: boolean;
    step?: number;
    inputMode?: 'number' | 'note-array';
  };
}

const rows = ref<GridRowData[]>([
  {
    name: 'analysingValues',
    shortName: 'Analysing Values',
    data: [0, 0, 0],
    config: {
      min: -1,
      max: 127,
      isInt: true,
      step: 1
    }
  },
])
const steps = ref(3)
const mergeThreshold = ref(0.02)
const contextualMinWidth = ref(1.0)
const loading = ref(false)
const formRef = ref()
const validationError = ref('')

const ratioRules = [
  (value: unknown) => Number.isFinite(Number(value)) || '数値を入力してください',
  (value: unknown) => (Number(value) >= 0 && Number(value) <= 1) || '0 から 1 の範囲で入力してください'
]

const positiveNumberRules = [
  (value: unknown) => Number.isFinite(Number(value)) || '数値を入力してください',
  (value: unknown) => Number(value) > 0 || '0 より大きい値を入力してください'
]

const validateTimeSeries = (raw: unknown[]) => {
  if (!Array.isArray(raw) || raw.length !== steps.value) return null
  const values: number[] = []
  for (const v of raw) {
    if (v == null || v === '') return null
    const n = Number(v)
    if (!Number.isFinite(n)) return null
    values.push(Math.round(n))
  }
  return values
}

const handleAnalyseTimeseries = async () => {
  validationError.value = ''
  const formResult = await formRef.value?.validate?.()
  if (formResult && formResult.valid === false) return

  const raw = (rows.value && rows.value[0] && rows.value[0].data) ? rows.value[0].data : []
  const time_series = validateTimeSeries(raw)
  const contextualMinWidthValue = Number(contextualMinWidth.value)
  const mergeThresholdValue = Number(mergeThreshold.value)
  if (!time_series || !Number.isFinite(contextualMinWidthValue) || contextualMinWidthValue <= 0 || !Number.isFinite(mergeThresholdValue)) {
    validationError.value = '分析する値は全セル必須です。空欄や数値以外の値を修正してください。'
    console.error('Analyse validation failed')
    return
  }

  loading.value = true
  try {
    const data = {
      analyse: {
        time_series,
        merge_threshold_ratio: mergeThresholdValue,
        contextual_min_width: contextualMinWidthValue,
        job_id: props.jobId
      }
    }
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
