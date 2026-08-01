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
    buildStart() {
      try {
        const destDir = path.resolve(root, 'public')
        if (!fs.existsSync(destDir)) fs.mkdirSync(destDir, { recursive: true })
        const inst = path.resolve(root, 'instalador.sh')
        if (fs.existsSync(inst)) fs.copyFileSync(inst, path.resolve(destDir, 'instalador.sh'))
        const srcDir = path.resolve(root, 'src', 'pocsag-server')
        const destSrc = path.resolve(destDir, 'source', 'pocsag-server')
        try { fs.rmSync(destSrc, { recursive: true, force: true }) } catch {}
        const manifest = []
        const copyDir = (d, rel) => {
          if (!fs.existsSync(d)) return
          for (const e of fs.readdirSync(d)) {
            if (e === '__pycache__' || e === '.git') continue
            const fp = path.join(d, e)
            const r = rel ? rel + '/' + e : e
            const st = fs.statSync(fp)
            if (st.isDirectory()) copyDir(fp, r)
            else {
              const dp = path.resolve(destSrc, r)
              fs.mkdirSync(path.dirname(dp), { recursive: true })
              fs.copyFileSync(fp, dp)
              manifest.push('pocsag-server/' + r)
            }
          }
        }
        copyDir(srcDir, '')
        fs.writeFileSync(path.resolve(destDir, 'source-manifest.json'), JSON.stringify(manifest))
      } catch {}
    },
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