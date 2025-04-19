
import { createConsumer } from "@rails/actioncable"
const cableUrl = (import.meta as any).env.VITE_CABLE_URL || "wss://time-series-subsequence-clustering-web.onrender.com/cable"
const consumer = createConsumer(cableUrl)

export default consumer
