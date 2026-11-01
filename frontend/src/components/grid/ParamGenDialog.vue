<template>
  <v-dialog :model-value="modelValue" @update:model-value="$emit('update:modelValue', $event)" width="780">
    <v-card>
      <v-card-title class="text-h6 bg-grey-lighten-3">Generate Parameters</v-card-title>
      <v-card-text class="pt-4">
        <v-row>
          <v-col cols="12">
            <v-tabs v-model="localParams.mode" density="compact" color="primary">
              <v-tab value="transition">Transition</v-tab>
              <v-tab value="random">Random</v-tab>
              <v-tab value="multiple">Multiple Transition</v-tab>
            </v-tabs>

            <v-window v-model="localParams.mode" class="mt-4">
              <v-window-item value="transition">
                <v-row>
                  <v-col cols="12">
                    <v-text-field
                      label="Steps to Generate"
                      type="number"
                      v-model.number="localParams.steps"
                      min="1"
                      step="1"
                      hint="Number of cells to fill from cursor"
                      persistent-hint
                    ></v-text-field>
                  </v-col>
                  <v-col cols="6">
                    <v-text-field label="Start Value" type="number" v-model.number="localParams.start" :step="valueStep"></v-text-field>
                  </v-col>
                  <v-col cols="6">
                    <v-text-field label="End Value" type="number" v-model.number="localParams.end" :step="valueStep"></v-text-field>
                  </v-col>
                  <v-col cols="12">
                    <v-select
                      label="Curve Type"
                      :items="easingFunctions"
                      item-title="title"
                      item-value="value"
                      v-model="localParams.curve"
                    ></v-select>
                  </v-col>
                </v-row>
              </v-window-item>

              <v-window-item value="random">
                <v-row>
                  <v-col cols="12">
                    <v-text-field
                      label="Steps to Generate"
                      type="number"
                      v-model.number="localParams.steps"
                      min="1"
                      step="1"
                      hint="Number of cells to fill from cursor"
                      persistent-hint
                    ></v-text-field>
                  </v-col>
                  <v-col cols="6">
                    <v-text-field label="Min Value" type="number" v-model.number="localParams.randMin" :step="valueStep"></v-text-field>
                  </v-col>
                  <v-col cols="6">
                    <v-text-field label="Max Value" type="number" v-model.number="localParams.randMax" :step="valueStep"></v-text-field>
                  </v-col>
                </v-row>
              </v-window-item>

              <v-window-item value="multiple">
                <v-row dense>
                  <v-col cols="12">
                    <div class="text-caption mb-2">Transition blocks</div>
                    <div class="d-flex flex-wrap ga-2">
                      <v-btn
                        v-for="preset in transitionPresets"
                        :key="preset.value"
                        size="small"
                        variant="outlined"
                        color="primary"
                        class="transition-preset-button"
                        :aria-label="preset.label"
                        :title="preset.label"
                        @click="addBlock(preset.value)"
                      >
                        <svg
                          class="transition-arrow"
                          viewBox="0 0 30 24"
                          role="img"
                          :aria-label="preset.label"
                        >
                          <path :d="arrowLinePath(preset.value)" />
                          <path :d="arrowHeadPath(preset.value)" />
                        </svg>
                      </v-btn>
                    </div>
                  </v-col>

                  <v-col cols="4">
                    <v-text-field label="Min" type="number" v-model.number="multiMin" :step="valueStep"></v-text-field>
                  </v-col>
                  <v-col cols="4">
                    <v-text-field label="Max" type="number" v-model.number="multiMax" :step="valueStep"></v-text-field>
                  </v-col>
                  <v-col cols="4">
                    <v-text-field label="Steps" type="number" v-model.number="multiSteps" min="1" step="1"></v-text-field>
                  </v-col>

                  <v-col cols="12">
                    <div class="d-flex ga-2 flex-wrap">
                      <v-btn size="small" color="secondary" @click="addBlock(currentMultiKind)">Add Block</v-btn>
                      <v-btn size="small" variant="tonal" color="error" @click="deleteSelection" :disabled="selectedBlockIndexes.length === 0">Delete Selected</v-btn>
                      <v-btn size="small" variant="tonal" color="primary" @click="copySelection" :disabled="selectedBlockIndexes.length === 0">Copy</v-btn>
                      <v-btn size="small" variant="tonal" color="primary" @click="cutSelection" :disabled="selectedBlockIndexes.length === 0">Cut</v-btn>
                      <v-btn size="small" variant="tonal" color="primary" @click="appendClipboard" :disabled="clipboard.length === 0">Paste</v-btn>
                      <v-btn size="small" variant="tonal" color="primary" @click="insertClipboard" :disabled="clipboard.length === 0">Insert at Selection</v-btn>
                      <v-btn size="small" variant="tonal" color="primary" @click="overwriteSelection" :disabled="selectedBlockIndexes.length === 0 || clipboard.length === 0">Overwrite Selected</v-btn>
                    </div>
                  </v-col>

                  <v-col cols="12">
                    <div class="text-caption mb-2">Bulk edit selected blocks</div>
                    <v-row dense>
                      <v-col cols="3">
                        <v-text-field label="Bulk min" type="number" v-model.number="bulkMin" :step="valueStep"></v-text-field>
                      </v-col>
                      <v-col cols="3">
                        <v-text-field label="Bulk max" type="number" v-model.number="bulkMax" :step="valueStep"></v-text-field>
                      </v-col>
                      <v-col cols="3">
                        <v-text-field label="Bulk steps" type="number" v-model.number="bulkSteps" min="1" step="1"></v-text-field>
                      </v-col>
                      <v-col cols="3">
                        <div class="kind-selector d-flex align-center ga-1" aria-label="Bulk transition kind">
                          <v-btn
                            v-for="preset in transitionPresets"
                            :key="preset.value"
                            size="x-small"
                            min-width="30"
                            variant="outlined"
                            :color="bulkKind === preset.value ? 'primary' : 'default'"
                            :aria-label="preset.label"
                            :aria-pressed="bulkKind === preset.value"
                            :title="preset.label"
                            @click="bulkKind = preset.value"
                          >
                            <svg class="kind-arrow" viewBox="0 0 30 24" aria-hidden="true">
                              <path :d="arrowLinePath(preset.value)" />
                              <path :d="arrowHeadPath(preset.value)" />
                            </svg>
                          </v-btn>
                        </div>
                      </v-col>
                    </v-row>
                    <div class="d-flex ga-2 flex-wrap">
                      <v-btn size="small" color="primary" @click="applyBulkToSelected" :disabled="selectedBlockIndexes.length === 0">Set selected</v-btn>
                      <v-btn size="small" color="secondary" @click="randomizeSelected" :disabled="selectedBlockIndexes.length === 0">Randomize selected</v-btn>
                    </div>
                  </v-col>

                  <v-col cols="12">
                    <div class="block-list" aria-label="multiple transition blocks">
                      <div v-if="localParams.blocks.length === 0" class="text-caption text-medium-emphasis">
                        No blocks yet.
                      </div>

                      <div
                        v-for="(block, index) in localParams.blocks"
                        :key="`${block.kind}-${index}`"
                        class="block-item"
                        :class="{ selected: selectedBlockIndexes.includes(index) }"
                        role="button"
                        tabindex="0"
                        :aria-pressed="selectedBlockIndexes.includes(index)"
                        @click="toggleSelection(index)"
                        @keydown.enter.stop="toggleSelection(index)"
                        @keydown.space.prevent.stop="toggleSelection(index)"
                      >
                        <div class="block-top-row">
                          <span class="block-value">{{ formatValue(getBlockStartValue(block)) }}</span>
                          <svg class="block-arrow" viewBox="0 0 30 24" aria-hidden="true">
                            <path :d="arrowLinePath(block.kind)" />
                            <path :d="arrowHeadPath(block.kind)" />
                          </svg>
                          <span class="block-value">{{ formatValue(getBlockEndValue(block)) }}</span>
                          <v-btn
                            class="block-delete"
                            icon="mdi-delete-outline"
                            variant="text"
                            size="x-small"
                            density="compact"
                            aria-label="Delete block"
                            @click.stop="removeBlock(index)"
                          ></v-btn>
                        </div>
                        <div class="block-steps">steps: {{ block.steps }}</div>
                      </div>
                    </div>
                  </v-col>
                </v-row>
              </v-window-item>
            </v-window>
          </v-col>
        </v-row>
      </v-card-text>
      <v-card-actions>
        <v-spacer></v-spacer>
        <v-btn color="grey" text @click="$emit('update:modelValue', false)">Cancel</v-btn>
        <v-btn color="primary" @click="onApply">Generate & Paste</v-btn>
      </v-card-actions>
    </v-card>
  </v-dialog>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue'

type TransitionKind = 'min->min' | 'min->max' | 'max->max' | 'max->min'

type MultiBlock = {
  kind: TransitionKind
  minValue: number
  maxValue: number
  steps: number
}

const props = defineProps({
  modelValue: Boolean,
  valueStep: {
    type: Number,
    default: 0.1
  },
  initialParams: {
    type: Object,
    default: () => ({
      steps: 10,
      mode: 'transition',
      start: 0,
      end: 1,
      curve: 'linear',
      randMin: 0,
      randMax: 1,
      blocks: [] as MultiBlock[]
    })
  }
})

const emit = defineEmits(['update:modelValue', 'apply'])

const localParams = ref({
  steps: 10,
  mode: 'transition',
  start: 0,
  end: 1,
  curve: 'linear',
  randMin: 0,
  randMax: 1,
  blocks: [] as MultiBlock[]
})

const transitionPresets = [
  { label: 'min → min', value: 'min->min' },
  { label: 'min → max', value: 'min->max' },
  { label: 'max → max', value: 'max->max' },
  { label: 'max → min', value: 'max->min' },
] as const

const getDecimalPlaces = (step: number): number => {
  if (!Number.isFinite(step) || step <= 0) return 0
  const text = String(step).toLowerCase()
  if (text.includes('e-')) return Math.min(12, Number(text.split('e-')[1]) || 0)
  return Math.min(12, (text.split('.')[1] || '').length)
}

const decimalPlaces = computed(() => getDecimalPlaces(props.valueStep))

const formatValue = (value: number): string =>
  Number(value).toFixed(decimalPlaces.value)

const arrowLinePath = (kind: TransitionKind): string => ({
  'min->min': 'M3 19 H27',
  'min->max': 'M3 19 L27 5',
  'max->max': 'M3 5 H27',
  'max->min': 'M3 5 L27 19',
}[kind])

const arrowHeadPath = (kind: TransitionKind): string => ({
  'min->min': 'M20 13 L27 19 L20 23',
  'min->max': 'M20 4 L27 5 L24 12',
  'max->max': 'M20 1 L27 5 L20 9',
  'max->min': 'M20 12 L27 19 L20 23',
}[kind])

const getBlockStartValue = (block: MultiBlock): number =>
  block.kind.startsWith('min->') ? block.minValue : block.maxValue

const getBlockEndValue = (block: MultiBlock): number =>
  block.kind.endsWith('->min') ? block.minValue : block.maxValue

const multiMin = ref(0)
const multiMax = ref(1)
const multiSteps = ref(10)
const currentMultiKind = ref<TransitionKind>('min->max')
const bulkMin = ref(0)
const bulkMax = ref(1)
const bulkSteps = ref(10)
const bulkKind = ref<TransitionKind>('min->max')
const clipboard = ref<MultiBlock[]>([])
const selectedBlockIndexes = ref<number[]>([])

const easingFunctions = [
  { title: 'Linear', value: 'linear' },
  { title: 'Ease In (Quad)', value: 'easeInQuad' },
  { title: 'Ease Out (Quad)', value: 'easeOutQuad' },
  { title: 'Ease In Out (Quad)', value: 'easeInOutQuad' },
]

const normalizeBlock = (block: Partial<MultiBlock>): MultiBlock => ({
  kind: (block.kind as TransitionKind) || 'min->max',
  minValue: Number(block.minValue ?? 0),
  maxValue: Number(block.maxValue ?? 1),
  steps: Math.max(1, Number(block.steps ?? 1)),
})



const resetMultiDefaults = () => {
  multiMin.value = Number(localParams.value.randMin ?? 0)
  multiMax.value = Number(localParams.value.randMax ?? 1)
  multiSteps.value = 10
  bulkMin.value = Number(localParams.value.randMin ?? 0)
  bulkMax.value = Number(localParams.value.randMax ?? 1)
  bulkSteps.value = 10
  bulkKind.value = 'min->max'
  currentMultiKind.value = 'min->max'
}

watch(() => props.modelValue, (open) => {
  if (!open) return

  const init = { ...props.initialParams }
  localParams.value = {
    steps: Number(init.steps ?? 10),
    mode: init.mode ?? 'transition',
    start: Number(init.start ?? 0),
    end: Number(init.end ?? 1),
    curve: init.curve ?? 'linear',
    randMin: Number(init.randMin ?? 0),
    randMax: Number(init.randMax ?? 1),
    blocks: Array.isArray(init.blocks) ? init.blocks.map(normalizeBlock) : [],
  }
  selectedBlockIndexes.value = []
  resetMultiDefaults()
})

const selectedIndices = () => [...selectedBlockIndexes.value].sort((a, b) => a - b)

const addBlock = (kind: TransitionKind) => {
  const block = normalizeBlock({
    kind,
    minValue: Number(multiMin.value),
    maxValue: Number(multiMax.value),
    steps: Math.max(1, Number(multiSteps.value || 1)),
  })
  localParams.value.blocks = [...localParams.value.blocks, block]
  selectedBlockIndexes.value = []
}

const toggleSelection = (index: number) => {
  const next = selectedBlockIndexes.value.includes(index)
    ? selectedBlockIndexes.value.filter(item => item !== index)
    : [...selectedBlockIndexes.value, index]
  selectedBlockIndexes.value = next
}

const removeBlock = (index: number) => {
  localParams.value.blocks = localParams.value.blocks.filter((_, i) => i !== index)
  selectedBlockIndexes.value = selectedBlockIndexes.value
    .filter(i => i !== index)
    .map(i => (i > index ? i - 1 : i))
}

const deleteSelection = () => {
  if (selectedBlockIndexes.value.length === 0) return
  const selected = selectedIndices()
  localParams.value.blocks = localParams.value.blocks.filter((_, index) => !selected.includes(index))
  selectedBlockIndexes.value = []
}

const copySelection = () => {
  const blocks = localParams.value.blocks
  clipboard.value = selectedIndices().flatMap(index => {
    const block = blocks[index]
    return block ? [normalizeBlock(block)] : []
  })
}

const cutSelection = () => {
  copySelection()
  deleteSelection()
}

const appendClipboard = () => {
  if (clipboard.value.length === 0) return
  localParams.value.blocks = [...localParams.value.blocks, ...clipboard.value.map(normalizeBlock)]
  selectedBlockIndexes.value = []
}

const insertClipboard = () => {
  if (clipboard.value.length === 0) return
  const selected = selectedIndices()
  const insertionIndex = selected[0] ?? localParams.value.blocks.length
  const next = [...localParams.value.blocks]
  next.splice(insertionIndex, 0, ...clipboard.value.map(normalizeBlock))
  localParams.value.blocks = next
  selectedBlockIndexes.value = []
}

const overwriteSelection = () => {
  if (selectedBlockIndexes.value.length === 0 || clipboard.value.length === 0) return
  const selected = selectedIndices()
  const next = [...localParams.value.blocks]
  const replacement = clipboard.value.map(normalizeBlock)
  const fallback = replacement.at(-1)
  selected.forEach((index, offset) => {
    const replacementBlock = replacement[offset] ?? fallback
    if (replacementBlock && index >= 0 && index < next.length) {
      next[index] = replacementBlock
    }
  })
  localParams.value.blocks = next
  selectedBlockIndexes.value = []
}

const applyBulkToSelected = () => {
  if (selectedBlockIndexes.value.length === 0) return
  const next = [...localParams.value.blocks]
  selectedIndices().forEach((index) => {
    next[index] = normalizeBlock({
      ...next[index],
      kind: bulkKind.value,
      minValue: Number(bulkMin.value),
      maxValue: Number(bulkMax.value),
      steps: Math.max(1, Number(bulkSteps.value || 1)),
    })
  })
  localParams.value.blocks = next
}

const randomizeSelected = () => {
  if (selectedBlockIndexes.value.length === 0) return
  const next = [...localParams.value.blocks]
  const kinds: TransitionKind[] = ['min->min', 'min->max', 'max->max', 'max->min']
  const lo = Math.min(Number(bulkMin.value), Number(bulkMax.value))
  const hi = Math.max(Number(bulkMin.value), Number(bulkMax.value))
  const maxSteps = Math.max(2, Math.floor(Number(bulkSteps.value || 1)))

  selectedIndices().forEach((index) => {
    const block = next[index]
    if (!block) return

    const availableKinds = kinds.filter(kind => kind !== block.kind)
    const kind = availableKinds[Math.floor(Math.random() * availableKinds.length)]
    const availableSteps = Array.from({ length: maxSteps }, (_, stepIndex) => stepIndex + 1)
      .filter(steps => steps !== block.steps)
    const steps = availableSteps.length > 0
      ? availableSteps[Math.floor(Math.random() * availableSteps.length)]
      : maxSteps

    const first = lo + Math.random() * (hi - lo)
    const second = lo + Math.random() * (hi - lo)
    next[index] = normalizeBlock({
      ...block,
      kind,
      minValue: Math.min(first, second),
      maxValue: Math.max(first, second),
      steps,
    })
  })
  localParams.value.blocks = next
}

const flattenBlockValues = (blocks: MultiBlock[]) => {
  const values: number[] = []
  blocks.forEach((block) => {
    const steps = Math.max(1, Number(block.steps ?? 1))
    const minVal = Number(block.minValue ?? 0)
    const maxVal = Number(block.maxValue ?? 1)

    let start = minVal
    let end = maxVal
    if (block.kind === 'min->min') {
      start = minVal; end = minVal
    } else if (block.kind === 'min->max') {
      start = minVal; end = maxVal
    } else if (block.kind === 'max->max') {
      start = maxVal; end = maxVal
    } else if (block.kind === 'max->min') {
      start = maxVal; end = minVal
    }

    for (let i = 0; i < steps; i++) {
      const t = steps > 1 ? i / (steps - 1) : 0
      const value = start + (end - start) * t
      values.push(Number(value.toFixed(decimalPlaces.value)))
    }
  })
  return values
}

const onApply = () => {
  if (localParams.value.mode === 'multiple') {
    const blocks = localParams.value.blocks.map(normalizeBlock)
    const generatedValues = flattenBlockValues(blocks)
    emit('apply', {
      ...localParams.value,
      mode: 'multiple',
      blocks,
      generatedValues,
      steps: generatedValues.length,
    })
    return
  }

  emit('apply', { ...localParams.value })
}
</script>

<style scoped>
.block-list {
  display: flex;
  flex-direction: row;
  align-items: flex-start;
  gap: 6px;
  max-width: 100%;
  min-height: 48px;
  overflow-x: auto;
  overflow-y: hidden;
  padding: 2px 2px 6px;
}

.block-item {
  box-sizing: border-box;
  display: flex;
  flex: 0 0 64px;
  flex-direction: column;
  justify-content: space-between;
  width: 64px;
  height: 42px;
  padding: 2px 3px;
  border: 1px solid #d9d9d9;
  border-radius: 6px;
  background: #fafafa;
  cursor: pointer;
  user-select: none;
}

.block-item.selected {
  border-color: #1976d2;
  background: #edf5ff;
}

.block-top-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 1px;
  min-width: 0;
  height: 21px;
}

.block-value {
  overflow: hidden;
  font-size: 9px;
  line-height: 1;
  text-overflow: clip;
  white-space: nowrap;
}

.block-arrow {
  flex: 0 0 15px;
  width: 15px;
  height: 15px;
  overflow: visible;
}

.block-arrow path,
.transition-arrow path {
  fill: none;
  stroke: currentColor;
  stroke-width: 2;
  stroke-linecap: round;
  stroke-linejoin: round;
}

.transition-preset-button {
  min-width: 42px;
  padding-inline: 7px;
}

.kind-selector {
  min-height: 40px;
}

.kind-arrow {
  width: 21px;
  height: 18px;
}

.kind-arrow path {
  fill: none;
  stroke: currentColor;
  stroke-width: 2;
  stroke-linecap: round;
  stroke-linejoin: round;
}

.transition-arrow {
  width: 25px;
  height: 21px;
}

.block-delete.v-btn {
  flex: 0 0 17px;
  width: 17px;
  min-width: 17px;
  height: 17px;
  padding: 0;
}

.block-steps {
  overflow: hidden;
  font-size: 9px;
  line-height: 11px;
  text-align: center;
  white-space: nowrap;
}
</style>
