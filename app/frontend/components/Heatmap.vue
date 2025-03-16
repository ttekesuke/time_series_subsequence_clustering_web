<template>
  <div class="heatmap">
    <div class="row" v-for="(key, rowIndex) in reversedKeys" :key="key">
      <div class="label">{{ keyNames[key] }}</div>
      <div
        class="cell"
        v-for="(value, colIndex) in data[key]"
        :key="colIndex"
        :style="{ backgroundColor: getColor(value) }"
      ></div>
    </div>
  </div>
</template>

<script>
export default {
  props: {
    data: Object, // { 0: [...], 1: [...], ..., 11: [...] }
  },
  computed: {
    reversedKeys() {
      return Object.keys(this.data).map(Number).sort((a, b) => b - a);
    },
    keyNames() {
      return {
        0: "C",
        1: "C#",
        2: "D",
        3: "D#",
        4: "E",
        5: "F",
        6: "F#",
        7: "G",
        8: "G#",
        9: "A",
        10: "A#",
        11: "B",
      };
    },
  },
  methods: {
    getColor(value) {
      const hue = 30; // オレンジ系（30度付近）
      const saturation = 100;
      const lightness = 100 - value * 70; // 低い値ほど濃く
      return `hsl(${hue}, ${saturation}%, ${lightness}%)`;
    },
  },
};
</script>

<style scoped>
.heatmap {
  display: flex;
  flex-direction: column;
  height: 100%; /* 外部要素の高さに依存 */
  width: 100%;  /* 外部要素の幅に依存 */
}
.row {
  display: flex;
  align-items: center;
  flex-grow: 1; /* 均等に割り当て */
}
.label {
  min-width: 20px;
  text-align: right;
  margin-right: 5px;
  font-size: 12px;
}
.cell {
  flex: 1; /* 幅を自動調整 */
  min-height: 10px; /* 最小高さを設定して色を見えるように */
  margin: 1px;
  border-radius: 3px;
}
</style>
