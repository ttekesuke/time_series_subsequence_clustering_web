<template>
  <v-dialog :model-value="modelValue" @update:model-value="$emit('update:modelValue', $event)" width="500">
    <v-card>
      <v-card-title class="text-h6 bg-grey-lighten-3">Generate Parameters</v-card-title>
      <v-card-text class="pt-4">
        <v-row>
          <v-col cols="12">
            <v-text-field
              label="Steps to Generate"
              type="number"
              v-model.number="localParams.steps"
              min="1"
              hint="Number of cells to fill from cursor"
              persistent-hint
            ></v-text-field>
          </v-col>

          <v-col cols="12">
            <v-tabs v-model="localParams.mode" density="compact" color="primary">
              <v-tab value="transition">Transition</v-tab>
              <v-tab value="random">Random</v-tab>
            </v-tabs>

            <v-window v-model="localParams.mode" class="mt-4">
              <!-- Transition Mode -->
              <v-window-item value="transition">
                <v-row>
                  <v-col cols="6">
                    <v-text-field label="Start Value" type="number" v-model.number="localParams.start" step="0.1"></v-text-field>
                  </v-col>
                  <v-col cols="6">
                    <v-text-field label="End Value" type="number" v-model.number="localParams.end" step="0.1"></v-text-field>
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

              <!-- Random Mode -->
              <v-window-item value="random">
                <v-row>
                  <v-col cols="6">
                    <v-text-field label="Min Value" type="number" v-model.number="localParams.randMin" step="0.1"></v-text-field>
                  </v-col>
                  <v-col cols="6">
                    <v-text-field label="Max Value" type="number" v-model.number="localParams.randMax" step="0.1"></v-text-field>
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
import { ref, watch } from 'vue'

const props = defineProps({
  modelValue: Boolean,
  initialParams: {
    type: Object,
    default: () => ({
      steps: 10,
      mode: 'transition',
      start: 0,
      end: 1,
      curve: 'linear',
      randMin: 0,
      randMax: 1
    })
  }
})

const emit = defineEmits(['update:modelValue', 'apply'])

const localParams = ref({ ...props.initialParams })

const easingFunctions = [
  { title: 'Linear', value: 'linear' },
  { title: 'Ease In (Quad)', value: 'easeInQuad' },
  { title: 'Ease Out (Quad)', value: 'easeOutQuad' },
  { title: 'Ease In Out (Quad)', value: 'easeInOutQuad' },
]

// ダイアログが開くたびに初期値を反映（親からの現在値セット用）
watch(() => props.modelValue, (val) => {
  if (val) {
    localParams.value = { ...props.initialParams }
  }
})

const onApply = () => {
  emit('apply', { ...localParams.value })
}
</script>
