
import { createApp } from 'vue'
import vuetify from '../../plugins/vuetify';
import Main from './Main.vue'
console.log("env.VITE_CABLE_URL:", import.meta.env.VITE_CABLE_URL)
const app = createApp(Main);
app.use(vuetify);
app.mount('#app');
