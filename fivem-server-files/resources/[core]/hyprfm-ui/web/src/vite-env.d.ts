/// <reference types="vite/client" />

// Explicit fallback — covers cases where vite/client types don't resolve
// during TS server startup before node_modules is fully indexed.
declare module '*.css' {
  const sheet: string
  export default sheet
}
declare module '*.svg' {
  const src: string
  export default src
}
declare module '*.png' {
  const src: string
  export default src
}
declare module '*.webp' {
  const src: string
  export default src
}