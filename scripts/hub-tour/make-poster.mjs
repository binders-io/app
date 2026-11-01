// Turns a PNG into the tour's WebP poster, encoded by the browser so nothing more needs installing.
import { readFileSync, writeFileSync } from 'node:fs'
import { chromium } from 'playwright'

const [from, to] = process.argv.slice(2)
const browser = await chromium.launch()
const page = await browser.newPage()
const data = await page.evaluate(async ({ b64 }) => {
  const blob = await (await fetch(`data:image/png;base64,${b64}`)).blob()
  const image = await createImageBitmap(blob)
  const canvas = new OffscreenCanvas(image.width, image.height)
  canvas.getContext('2d').drawImage(image, 0, 0)
  const out = await canvas.convertToBlob({ type: 'image/webp', quality: 0.82 })
  const bytes = new Uint8Array(await out.arrayBuffer())
  let text = ''
  for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(text)
}, { b64: readFileSync(from).toString('base64') })
await browser.close()
writeFileSync(to, Buffer.from(data, 'base64'))
console.log(`${to}: ${Math.round(Buffer.from(data, 'base64').length / 1024)} KB`)
