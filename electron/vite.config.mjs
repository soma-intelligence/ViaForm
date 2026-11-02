import { defineConfig } from "vite";

// The renderer only: the main and preload scripts are plain tsc output.
export default defineConfig({
  root: "src/renderer",
  base: "./",
  build: { outDir: "../../out/renderer", emptyOutDir: true, target: "chrome140" },
});
