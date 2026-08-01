import base44 from "@base44/vite-plugin"
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'
import fs from 'node:fs'
import path from 'node:path'

// Resolve + load non-JS text files (.sh, .py, .html, .sql, ...) imported via the
// @/ alias so the base44 plugin never gets to parse them as JavaScript.
function rawTextFallback() {
  const nonJs = ['sh','py','html','txt','sql','conf','ini','toml','yaml','yml','c','h','service','md']
  const root = process.cwd()
  const extOf = (p) => p.split('.').pop()?.toLowerCase()
  return {
    name: 'raw-text-fallback',
    enforce: 'pre',
    resolveId(source) {
      if (!source || !source.startsWith('@/')) return null
      const stripped = source.replace(/[?#].*$/, '')
      const abs = path.resolve(root, 'src', stripped.slice(3))
      if (!nonJs.includes(extOf(abs))) return null
      return abs
    },
    load(id) {
      if (!id) return null
      const filePath = id.replace(/[?#].*$/, '')
      if (filePath.endsWith('/index.html')) return null
      if (!nonJs.includes(extOf(filePath))) return null
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