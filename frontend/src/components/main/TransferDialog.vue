<template>
  <v-dialog v-model="open" width="720">
    <v-card>
      <v-card-title class="text-h6 d-flex align-center justify-space-between">
        <span>Upload / Download</span>
        <v-btn icon @click="open = false">
          <v-icon>mdi-close</v-icon>
        </v-btn>
      </v-card-title>
      <v-card-text>
        <div class="transfer-group d-flex align-center">
          <div class="transfer-block">
            <div class="transfer-label">Upload</div>
            <div class="transfer-controls">
              <v-file-input
                v-model="resultJsonModel"
                class="ga-file"
                prepend-icon=""
                density="compact"
                variant="outlined"
                hide-details
                label="result.json"
                accept=".json,application/json"
                @update:modelValue="onPickResultJson"
              />
              <v-file-input
                v-model="wavModel"
                class="ga-file"
                prepend-icon=""
                density="compact"
                variant="outlined"
                hide-details
                label="result.wav"
                accept=".wav,audio/wav"
                @update:modelValue="onPickWav"
              />
              <v-file-input
                v-model="paramsJsonModel"
                class="ga-file"
                prepend-icon=""
                density="compact"
                variant="outlined"
                hide-details
                label="params.json"
                accept=".json,application/json"
                @update:modelValue="onPickParamsJson"
              />
            </div>
          </div>
          <div class="transfer-divider"></div>
          <div class="transfer-block">
            <div class="transfer-label">Download</div>
            <div class="transfer-controls">
              <v-btn size="small" variant="outlined" @click="emitDownloadResultJson">result.json</v-btn>
              <v-btn size="small" variant="outlined" @click="emitDownloadResultWav">result.wav</v-btn>
              <v-btn size="small" variant="outlined" @click="emitDownloadParamsJson">params.json</v-btn>
            </div>
          </div>
        </div>
      </v-card-text>
    </v-card>
  </v-dialog>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue'

const props = defineProps<{
  modelValue: boolean
  runOnGithubActions: boolean
}>()
const emit = defineEmits([
  'update:modelValue',
  'upload-result-json',
  'upload-wav',
  'upload-params-json',
  'download-result-json',
  'download-result-wav',
  'download-params-json'
])

const open = computed({
  get: () => props.modelValue,
  set: (v: boolean) => emit('update:modelValue', v)
})

const resultJsonModel = ref<any>(null)
const wavModel = ref<any>(null)
const paramsJsonModel = ref<any>(null)

const normalizeSingleFile = (val: any): File | null => {
  if (!val) return null
  if (Array.isArray(val)) return (val[0] as File) ?? null
  return val as File
}

const onPickResultJson = (val: any) => {
  const file = normalizeSingleFile(val)
  if (file) emit('upload-result-json', file)
  resultJsonModel.value = null
}

const onPickWav = (val: any) => {
  const file = normalizeSingleFile(val)
  if (file) emit('upload-wav', file)
  wavModel.value = null
}

const onPickParamsJson = (val: any) => {
  const file = normalizeSingleFile(val)
  if (file) emit('upload-params-json', file)
  paramsJsonModel.value = null
}

const emitDownloadResultJson = () => emit('download-result-json')
const emitDownloadResultWav = () => emit('download-result-wav')
const emitDownloadParamsJson = () => emit('download-params-json')
</script>

<style scoped>
.ga-file {
  width: 100px;
}
.transfer-group {
  gap: 10px;
  flex-wrap: wrap;
  padding: 8px 10px;
  border: 1px solid #ddd;
  border-radius: 8px;
  background: #fafafa;
}
.transfer-block {
  display: flex;
  align-items: center;
  gap: 8px;
}
.transfer-label {
  font-size: 0.75rem;
  font-weight: 600;
  color: #666;
  text-transform: uppercase;
  letter-spacing: 0.04em;
}
.transfer-controls {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
}
.transfer-divider {
  width: 1px;
  align-self: stretch;
  background: #ddd;
}
</style>
