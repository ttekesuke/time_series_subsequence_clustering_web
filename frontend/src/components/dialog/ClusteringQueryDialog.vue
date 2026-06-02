<template>
  <v-dialog width="1000" v-model="open">
    <v-form>
      <v-card>
        <v-card-title>
          <div class="text-h4">Clustering Query</div>
        </v-card-title>
        <v-card-text>
          <div style="height:240px; overflow:auto;" class="mb-4">
            <GridContainer
              v-model:rows="queryRows"
              v-model:steps="querySteps"
              :showRowsLength="false"
              :showColsLength="true"
            />
          </div>

                  <!-- DB preview removed: DB is provided by server-side InfluxDB -->

          <v-row class="mt-4">
            <v-col cols="3">
              <v-text-field label="range min" type="number" v-model.number="rangeMin"></v-text-field>
            </v-col>
            <v-col cols="3">
              <v-text-field label="range max" type="number" v-model.number="rangeMax"></v-text-field>
            </v-col>
            <v-col cols="3">
              <v-text-field
                label="merge threshold"
                type="number"
                v-model.number="mergeThreshold"
                min="0" step="0.01"
              ></v-text-field>
            </v-col>
            <v-col cols="3">
              <v-text-field
                label="min match window"
                type="number"
                v-model.number="minMatchWindow"
                min="2" step="1"
              ></v-text-field>
            </v-col>
            <v-col cols="3">
              <v-btn color="success" :loading="loading" @click="handleQuery">Query</v-btn>
            </v-col>
          </v-row>
        </v-card-text>
      </v-card>
    </v-form>
  </v-dialog>
</template>

<script setup lang="ts">
import { ref, computed, onMounted, watch } from 'vue'
import GridContainer from '../grid/GridContainer.vue'
import StreamsRoll from '../visualizer/StreamsRoll.vue'
import axios from 'axios'

const props = defineProps({ modelValue: Boolean })
const emit = defineEmits(['update:modelValue', 'queried'])
const open = computed({ get: () => props.modelValue, set: (v: boolean) => emit('update:modelValue', v) })

// query rows
type GridRowData = {
  name: string; shortName: string; data: number[]; config: { min:number; max:number; step?:number; isInt?:boolean }
}
const querySteps = ref(8)
const queryRows = ref<GridRowData[]>([
  { name: 'querySeries', shortName: 'Query', data: Array(querySteps.value).fill(0), config: { min:0, max:11, isInt:true, step:1 } }
])

const rangeMin = ref(0)
const rangeMax = ref(11)
const mergeThreshold = ref(0.02)
const minMatchWindow = ref(3)
const loading = ref(false)

// Keep query row length in sync when steps change
watch(() => querySteps.value, (len) => {
  const v = Math.max(1, Number(len) || 1)
  const row = queryRows.value[0]
  if (row) {
    const newData = Array.from(row.data || [])
    if (newData.length < v) {
      while (newData.length < v) newData.push(0)
    } else if (newData.length > v) {
      newData.splice(v)
    }
    row.data = newData
    queryRows.value.splice(0, 1, row)
  }
})

// no DB preview step width anymore

const euclidDist = (a: number[], b: number[]) => {
  let s = 0
  for (let i = 0; i < a.length; i++) s += Math.pow((a[i] || 0) - (b[i] || 0), 2)
  return Math.sqrt(s)
}

// naive incremental matching algorithm
const handleQuery = async () => {
  loading.value = true
  try {
    const querySeries = (queryRows.value[0] && Array.isArray(queryRows.value[0].data)) ? queryRows.value[0].data : []
    const payload = {
      query: {
        query_series: querySeries,
        measurement: 'timeseries',
        batch_size: 500,
        merge_threshold_ratio: mergeThreshold.value,
        range_min: rangeMin.value,
        range_max: rangeMax.value,
        min_match_window: minMatchWindow.value
      }
    }

    const resp = await axios.post('/api/web/time_series/query_db', payload)
    // pass through response
    const data = resp.data
    emit('queried', data)
    open.value = false
  } catch (err) {
    console.error('Query request failed', err)
  } finally {
    loading.value = false
  }
}
</script>

<style scoped>
</style>
