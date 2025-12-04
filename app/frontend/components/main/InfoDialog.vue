<template>
  <v-dialog width="1000" v-model="open">
    <v-card>
      <v-card-text>
        <h3>What is this site?</h3>
        <div>The site can cluster and display substrings of various lengths that are similar to each other in the time series data entered by the user.</div>
        <h3>How to use</h3>
        <h5>Analye</h5>
        <ul class="custom-list">
          <li>Click "ANALYSE".</li>
          <li>Enter your time series data into the large input field. For example, 1,3,5,1,3,5.</li>
          <li>If you find it bothersome to input data, you can also set random numbers by entering values into the three input fields under "generate randoms" and pressing "SET RANDOMS".</li>
          <li>Click "SUBMIT" to display the results.</li>
        </ul>
        <h5>Generate</h5>
        <ul class="custom-list">
          <a href="https://youtu.be/vAQeHWESkEk" target="_blank">movie</a>
        </ul>
        <h3>Attention</h3>
        <ul class="custom-list">
          <li>All of them are free of charge.</li>
          <li>Input values and results are not saved.</li>
          <li>The system may change without notice.</li>
          <li>We do not guarantee the correctness of the results.</li>
          <li>Due to the circumstances of being operated for free, it may take about 50 seconds to re-access the site if there is no access for a while. Please wait.</li>
        </ul>
        <h3>Developer</h3>
        <div>
          <a href='https://tekesuke1986.tumblr.com' target='_blank'>Takuya SHIMIZU</a>
        </div>
      </v-card-text>
    </v-card>
  </v-dialog>
</template>

<script setup lang="ts">
import { computed } from 'vue'
const props = defineProps({ modelValue: Boolean })
const emit = defineEmits(['update:modelValue'])
const open = computed({ get: () => props.modelValue, set: (v: boolean) => emit('update:modelValue', v) })
</script>

<style scoped>
.custom-list { padding-left: 1rem; }
</style>
