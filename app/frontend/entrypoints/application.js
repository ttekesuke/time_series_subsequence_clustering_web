
import { createApp } from 'vue'
import 'vuetify/styles'
import { createVuetify } from 'vuetify'
import * as components from 'vuetify/components'
import * as directives from 'vuetify/directives'
import Main from './time_series/Main.vue'

const vuetify = createVuetify()
createApp(Main).use(vuetify).mount('#app')
