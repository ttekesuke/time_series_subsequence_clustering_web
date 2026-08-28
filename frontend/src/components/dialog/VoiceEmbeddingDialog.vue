<template>
  <v-dialog v-model="dialogOpen" max-width="1120" scrollable>
    <v-card>
      <v-card-title class="text-h6 d-flex align-center justify-space-between">
        <span>Voice Token Acoustic Space</span>
        <v-btn icon @click="dialogOpen = false"><v-icon>mdi-close</v-icon></v-btn>
      </v-card-title>
      <v-card-subtitle>
        {{ inventoryLabel }} — PCA component 1 / 2 / 3. Drag to rotate; use the wheel to zoom.
      </v-card-subtitle>
      <v-card-text>
        <v-alert v-if="loadError" type="error" density="compact" class="mb-3">{{ loadError }}</v-alert>
        <div v-else-if="loading" class="py-8 text-center">Loading acoustic tokens…</div>
        <div v-else class="embedding-layout">
          <div class="embedding-chart-wrap">
            <svg
              class="embedding-chart"
              viewBox="0 0 720 500"
              role="img"
              aria-label="Three-dimensional acoustic embedding of voice tokens"
              @pointerdown="startDrag"
              @pointermove="drag"
              @pointerup="stopDrag"
              @pointerleave="stopDrag"
              @wheel.prevent="zoom"
            >
              <rect width="720" height="500" fill="#10141d" rx="8" />
              <g class="axis" opacity="0.75">
                <line x1="360" y1="250" :x2="axisEndpoints.x.x" :y2="axisEndpoints.x.y" />
                <line x1="360" y1="250" :x2="axisEndpoints.y.x" :y2="axisEndpoints.y.y" />
                <line x1="360" y1="250" :x2="axisEndpoints.z.x" :y2="axisEndpoints.z.y" />
                <text :x="axisEndpoints.x.x" :y="axisEndpoints.x.y">PC1</text>
                <text :x="axisEndpoints.y.x" :y="axisEndpoints.y.y">PC2</text>
                <text :x="axisEndpoints.z.x" :y="axisEndpoints.z.y">PC3</text>
              </g>
              <g v-for="point in projectedPoints" :key="point.id">
                <circle
                  :cx="point.x"
                  :cy="point.y"
                  :r="point.id === selectedId ? 8 : 5.5"
                  :fill="point.color"
                  :opacity="point.opacity"
                  :stroke="point.id === selectedId ? '#fff' : 'none'"
                  stroke-width="2"
                  class="point"
                  @click.stop="selectedId = point.id"
                >
                  <title>{{ point.text }} ({{ point.phones.join(' · ') }})</title>
                </circle>
                <text v-if="showLabels || point.id === selectedId" :x="point.x + 9" :y="point.y - 8" class="point-label">{{ point.text }}</text>
              </g>
            </svg>
          </div>
          <aside class="embedding-side">
            <v-switch v-model="showLabels" label="Show all labels" density="compact" hide-details />
            <v-select
              v-model="selectedId"
              :items="tokenItems"
              item-title="title"
              item-value="value"
              label="Selected token"
              density="compact"
              hide-details
            />
            <v-card v-if="selectedToken" variant="outlined" class="pa-3 mt-3">
              <div class="text-h5">{{ selectedToken.text }}</div>
              <div class="text-caption">{{ selectedToken.id }} · {{ selectedToken.phones.join(' / ') }}</div>
              <div class="text-caption mt-3">PC1–PC3</div>
              <code>{{ selectedToken.embedding.slice(0, 3).map(value => value.toFixed(3)).join(', ') }}</code>
            </v-card>
            <p class="text-caption mt-4 mb-0">
              点間が近いほど、抽出した MFCC・スペクトル・時間特徴が近いトークンです。
            </p>
          </aside>
        </div>
      </v-card-text>
    </v-card>
  </v-dialog>
</template>

<script setup lang="ts">
import axios from 'axios'
import { computed, ref, watch } from 'vue'

type VoiceToken = { id: string; text: string; phones: string[]; embedding: number[] }

const props = defineProps<{ modelValue: boolean; inventoryId: string }>()
const emit = defineEmits<{ 'update:modelValue': [value: boolean] }>()
const dialogOpen = computed({ get: () => props.modelValue, set: (value: boolean) => emit('update:modelValue', value) })
const tokens = ref<VoiceToken[]>([])
const dimensions = ref(0)
const loading = ref(false)
const loadError = ref('')
const selectedId = ref('')
const showLabels = ref(false)
const yaw = ref(-0.55)
const pitch = ref(0.35)
const scale = ref(205)
let dragOrigin: { x: number; y: number } | null = null

const inventoryLabel = computed(() => `${props.inventoryId} · ${dimensions.value} dimensions · ${tokens.value.length} tokens`)
const selectedToken = computed(() => tokens.value.find(token => token.id === selectedId.value) ?? null)
const tokenItems = computed(() => tokens.value.map(token => ({ title: `${token.text} — ${token.phones.join(' / ')}`, value: token.id })))

const rotate = (vector: [number, number, number]): [number, number, number] => {
  const [x, y, z] = vector
  const cy = Math.cos(yaw.value); const sy = Math.sin(yaw.value)
  const cp = Math.cos(pitch.value); const sp = Math.sin(pitch.value)
  const rx = x * cy - z * sy
  const rz = x * sy + z * cy
  return [rx, y * cp - rz * sp, y * sp + rz * cp]
}

const project = (vector: [number, number, number]) => {
  const [x, y, z] = rotate(vector)
  const perspective = 1 / Math.max(0.45, 1.85 - z * 0.38)
  return { x: 360 + x * scale.value * perspective, y: 250 - y * scale.value * perspective, z, perspective }
}

const axisEndpoints = computed(() => ({
  x: project([0.9, 0, 0]), y: project([0, 0.9, 0]), z: project([0, 0, 0.9]),
}))
const projectedPoints = computed(() => tokens.value.map(token => {
  const embedding = token.embedding
  const point = project([((embedding[0] ?? 0.5) - 0.5) * 2, ((embedding[1] ?? 0.5) - 0.5) * 2, ((embedding[2] ?? 0.5) - 0.5) * 2])
  const hue = (Math.atan2((embedding[1] ?? 0.5) - 0.5, (embedding[0] ?? 0.5) - 0.5) * 180 / Math.PI + 380) % 360
  return { ...token, ...point, color: `hsl(${hue} 78% 64%)`, opacity: 0.55 + Math.min(0.45, (point.z + 1) * 0.18) }
}).sort((a, b) => a.z - b.z))

const loadInventory = async () => {
  loading.value = true; loadError.value = ''
  try {
    const response = await axios.post('/api/web/time_series/voice_inventory', { id: props.inventoryId })
    tokens.value = Array.isArray(response.data?.tokens) ? response.data.tokens : []
    dimensions.value = Number(response.data?.dimensions) || 0
    selectedId.value = tokens.value[0]?.id ?? ''
  } catch (error: any) {
    loadError.value = error?.response?.data?.error || 'Voice inventory could not be loaded.'
  } finally { loading.value = false }
}
const startDrag = (event: PointerEvent) => { dragOrigin = { x: event.clientX, y: event.clientY }; (event.currentTarget as SVGElement).setPointerCapture(event.pointerId) }
const drag = (event: PointerEvent) => {
  if (!dragOrigin) return
  yaw.value += (event.clientX - dragOrigin.x) * 0.012
  pitch.value = Math.max(-1.45, Math.min(1.45, pitch.value + (event.clientY - dragOrigin.y) * 0.012))
  dragOrigin = { x: event.clientX, y: event.clientY }
}
const stopDrag = () => { dragOrigin = null }
const zoom = (event: WheelEvent) => { scale.value = Math.max(90, Math.min(430, scale.value * (event.deltaY > 0 ? 0.9 : 1.1))) }
watch(dialogOpen, open => { if (open) loadInventory() })
watch(() => props.inventoryId, () => { if (dialogOpen.value) loadInventory() })
</script>

<style scoped>
.embedding-layout { display: grid; grid-template-columns: minmax(0, 1fr) 240px; gap: 18px; }
.embedding-chart { width: 100%; min-height: 500px; cursor: grab; touch-action: none; user-select: none; }
.embedding-chart:active { cursor: grabbing; }
.axis line { stroke: #77839a; stroke-width: 1.5; }
.axis text { fill: #bbc5d6; font-size: 14px; }
.point { cursor: pointer; }
.point-label { fill: white; font-size: 13px; paint-order: stroke; stroke: #10141d; stroke-width: 3px; stroke-linejoin: round; }
.embedding-side { min-width: 0; }
@media (max-width: 760px) { .embedding-layout { grid-template-columns: 1fr; } .embedding-chart { min-height: 360px; } }
</style>
