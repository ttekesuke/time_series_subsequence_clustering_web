
import { createApp } from 'vue'
import vuetify from '../../plugins/vuetify';
import Main from '../../components/main/Main.vue'
const app = createApp(Main);
app.use(vuetify);
app.mount('#app');
