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
        <div class="preset-block">
          <div class="transfer-label">Sample params</div>
          <div class="preset-controls">
            <v-select
              v-model="selectedPreset"
              class="preset-select"
              :items="presets"
              item-title="label"
              item-value="file"
              density="compact"
              variant="outlined"
              hide-details
              clearable
              label="Choose a preset"
              :loading="presetsLoading"
              :disabled="presetsLoading || presets.length === 0"
            />
            <v-btn
              size="small"
              variant="outlined"
              color="primary"
              :loading="presetLoading"
              :disabled="!selectedPreset || presetLoading"
              @click="applySelectedPreset"
            >Apply</v-btn>
          </div>
          <div v-if="presetDescription" class="preset-description">
            {{ presetDescription }}
          </div>
          <div v-if="presetError" class="preset-error">{{ presetError }}</div>
        </div>
      </v-card-text>
    </v-card>
  </v-dialog>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'

type ParamsPreset = {
  file: string
  label: string
  description?: string
}

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
const presets = ref<ParamsPreset[]>([])
const selectedPreset = ref<string | null>(null)
const presetsLoading = ref(false)
const presetLoading = ref(false)
const presetError = ref('')

const presetDescription = computed(() => (
  presets.value.find(preset => preset.file === selectedPreset.value)?.description ?? ''
))

const publicAssetUrl = (relativePath: string) => {
  const base = String(import.meta.env.BASE_URL || '/')
  return `${base.replace(/\/$/, '')}/${relativePath.replace(/^\//, '')}`
}

onMounted(async () => {
  presetsLoading.value = true
  presetError.value = ''
  try {
    const response = await fetch(publicAssetUrl('params-presets/index.json'))
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const manifest = await response.json()
    presets.value = Array.isArray(manifest?.presets) ? manifest.presets : []
  } catch (error) {
    console.error('Failed to load sample params list', error)
    presetError.value = 'Sample params list could not be loaded.'
  } finally {
    presetsLoading.value = false
  }
})

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

const applySelectedPreset = async () => {
  if (!selectedPreset.value) return
  presetLoading.value = true
  presetError.value = ''
  try {
    const response = await fetch(publicAssetUrl(`params-presets/${selectedPreset.value}`))
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const text = await response.text()
    JSON.parse(text)
    const file = new File([text], selectedPreset.value, { type: 'application/json' })
    emit('upload-params-json', file)
  } catch (error) {
    console.error('Failed to load sample params', error)
    presetError.value = 'The selected sample params could not be loaded.'
  } finally {
    presetLoading.value = false
  }
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
.preset-controls {
  display: flex;
  align-items: center;
  gap: 6px;
  min-width: 330px;
}
.preset-block {
  margin-top: 12px;
  padding: 10px;
  border: 1px solid #ddd;
  border-radius: 8px;
  background: #fafafa;
}
.preset-block .preset-controls {
  margin-top: 6px;
}
.preset-select {
  min-width: 260px;
}
.preset-description {
  margin-top: 6px;
  color: #666;
  font-size: 0.75rem;
  line-height: 1.35;
}
.preset-error {
  color: #b00020;
  font-size: 0.75rem;
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
