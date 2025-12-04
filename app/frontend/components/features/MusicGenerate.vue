<template>
  <div class="pa-4">
    <v-row class="align-center">
      <v-col>
        <div class="text-h5">Music — Polyphonic Generate</div>
      </v-col>
      <v-col class="v-col-auto">
        <v-btn color="primary" @click="openDialog = true">SET PARAMS</v-btn>
      </v-col>
    </v-row>

    <div class="mt-4">Polyphonic generation UI will appear here.</div>
  </div>
</template>

<script setup lang="ts">
import { ref } from 'vue'
const openDialog = ref(false)
</script>
