import base44 from "@base44/vite-plugin"
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'
import fs from 'node:fs'

// Handle ?raw imports of non-JS files (.sh, .py, .html, .sql, .conf, ...)
// at the load hook so the base44 plugin doesn't try to parse them as JS.
function rawTextFallback() {
  const nonJs = ['sh','py','html','txt','sql','conf','ini','toml','yaml','yml','c','h','service','md']
  return {
    name: 'raw-text-fallback',
    enforce: 'pre',
    load(id) {
      if (!id) return null
      const filePath = id.split('?raw')[0].replace(/[?#].*$/, '')
      if (filePath.endsWith('/index.html')) return null
      const ext = filePath.split('.').pop()?.toLowerCase()
      if (!ext || !nonJs.includes(ext)) return null
      try {
        const content = fs.readFileSync(filePath, 'utf-8')
        return `export default ${JSON.stringify(content)}`
      } catch {
        return null
      }
    }
  }
}

// https://vite.dev/config/
export default defineConfig({
  plugins: [
    rawTextFallback(),
    base44({
      // Support for legacy code that imports the base44 SDK with @/integrations, @/entities, etc.
      // can be removed if the code has been updated to use the new SDK imports from @base44/sdk
      legacySDKImports: process.env.BASE44_LEGACY_SDK_IMPORTS === 'true',
      hmrNotifier: true,
      navigationNotifier: true,
      analyticsTracker: true,
      visualEditAgent: true
    }),
    react()
  ],
  assetsInclude: ['**/*.sh','**/*.py','**/*.html','**/*.sql','**/*.conf','**/*.service','**/*.txt','**/*.ini','**/*.toml','**/*.yaml','**/*.yml']
});