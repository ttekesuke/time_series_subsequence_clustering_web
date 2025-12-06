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
          <ul class="custom-list">
            <li>Switch modes from the header select: ClusteringAnalyse, ClusteringGenerate, or MusicGenerate.</li>
            <li>Use the <strong>SET PARAMS</strong> button in the header (or the feature’s own controls) to open the parameter dialog for the active mode.</li>
            <li>Each feature remembers its state when you close a dialog so you can continue from the last view.</li>
            <li>In MusicGenerate mode, the Play/Stop control in the header becomes available after audio has been rendered.</li>
          </ul>
        </section>

        <section>
          <h3>Notes</h3>
          <ul class="custom-list">
            <li>Usage is free; inputs and results are not saved.</li>
            <li>System behavior may change without notice, and result correctness is not guaranteed.</li>
            <li>If the app has been idle, the first request may take additional time while services restart.</li>
            <li>Generated audio and previews are session-scoped and are cleared when you refresh the page.</li>
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
