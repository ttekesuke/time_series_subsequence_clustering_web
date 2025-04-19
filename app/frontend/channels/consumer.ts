// frontend/channels/consumer.ts
import { createConsumer } from "@rails/actioncable"

const consumer = createConsumer("ws://localhost:3000/cable") // 適宜修正（Dockerなら backend:3000）

export default consumer
