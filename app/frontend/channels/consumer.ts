
import { createConsumer } from "@rails/actioncable"
const cableUrl = (import.meta as any).env.VITE_CABLE_URL || "ws://localhost:3000/cable"
const consumer = createConsumer(cableUrl)

export default consumer
