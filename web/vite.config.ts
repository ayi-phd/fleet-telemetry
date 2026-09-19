import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// For local development against a deployed stack:
//   API_TARGET=http://<dashboard_url> npm run dev
const target = process.env.API_TARGET ?? "http://localhost:8080";

export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      "/api": { target, changeOrigin: true },
      "/auth": { target, changeOrigin: true },
    },
  },
});
