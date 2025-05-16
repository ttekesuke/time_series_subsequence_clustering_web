<template>
  <div
    :style="{
      left: x + 'px',
      width: '2px',
      height: height + 'px',
      zIndex: 10,
      top: 0,
      backgroundColor: 'red',
      position: 'absolute'
    }"
  >

  </div>
</template>

<script setup lang="ts">

defineProps<{
  x: number;
  height: number;
}>();
</script>
