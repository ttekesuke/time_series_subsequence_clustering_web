<template>
  <div class="flex gap-4 mt-2">
    <button @click="onPlay" class="px-4 py-2 rounded">Play</button>
    <button @click="onStop" class="px-4 py-2 rounded">Stop</button>
  </div>
</template>

<script setup lang="ts">
const emit = defineEmits(['play', 'stop']);

function onPlay() {
  emit('play');
}
function onStop() {
  emit('stop');
}
</script>
