<template>
  <v-dialog width="1000" v-model="open">
    <v-card>
      <v-card-title class="text-h5">About this site</v-card-title>
      <v-card-text>
        <section class="mb-6">
          <h3>Overview</h3>
          <p>
            This site provides end-to-end tooling for exploring time-series structure, generating new sequences, and creating
            multi-part music based on those sequences.
          </p>
        </section>

        <section class="mb-6">
          <h3>Core capabilities</h3>
          <ul class="custom-list">
            <li>
              <strong>Time-series analysis:</strong> The system scans the series from the beginning, clusters similar
              subsequences of varying lengths, and visualizes them for quick inspection.
            </li>
            <li>
              <strong>Sequence generation:</strong> From clustering results the system estimates structural complexity. By
              providing a desired progression of complexity values, it searches candidate sequences and returns one that
              matches the requested profile.
            </li>
            <li>
              <strong>Music generation:</strong> The generator can create music with multiple auditory streams (voices),
              including pitch, octave, loudness, and timbre, guided by the same complexity transitions. The resulting
              arrangement accounts for the combined listening experience across parts.
            </li>
          </ul>
        </section>

        <section class="mb-6">
          <h3>Working with modes</h3>
          <p>
            Use the mode selector in the header to switch between clustering analysis, sequence generation, and music
            generation. Each feature exposes its own parameter dialog and display; closing a dialog returns you to the last
            selected view.
          </p>
        </section>

        <section>
          <h3>Notes</h3>
          <ul class="custom-list">
            <li>Usage is free; inputs and results are not saved.</li>
            <li>System behavior may change without notice, and result correctness is not guaranteed.</li>
            <li>If the app has been idle, the first request may take additional time while services restart.</li>
          </ul>
        </section>
      </v-card-text>
    </v-card>
  </v-dialog>
</template>

<script setup lang="ts">
import { computed } from 'vue'
const props = defineProps({ modelValue: Boolean })
const emit = defineEmits(['update:modelValue'])
const open = computed({
  get: () => props.modelValue,
  set: (v: boolean) => emit('update:modelValue', v)
})
</script>

<style scoped>
.custom-list {
  padding-left: 1rem;
}

.custom-list li + li {
  margin-top: 0.5rem;
}
</style>
