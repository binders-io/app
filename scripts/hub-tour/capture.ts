import { cp, mkdir, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { chromium, type Page } from 'playwright'

// The tour's pictures, each a real screen of a real hub holding only invented data (demo/ in binders-server), taken
// between real clicks and real changes. For each one it also writes where things are, so the film can point at them.
//   node capture.ts <binders-server folder>

const server = resolve(process.argv[2] ?? '')
const { startDemoHub } = await import(`${server}/demo/hub.ts`)
const { demoIds, demoPeople } = await import(`${server}/demo/data.ts`)
const { realWords } = await import(`${server}/demo/shoot.ts`)

const out = resolve(import.meta.dirname, 'public/beats')
await mkdir(out, { recursive: true })
await cp(resolve(import.meta.dirname, '../../site/assets/fonts'), resolve(import.meta.dirname, 'public/fonts'), { recursive: true })
await cp(resolve(import.meta.dirname, '../../site/assets/icon-128.png'), resolve(import.meta.dirname, 'public/icon-128.png'))

const size = { width: 1440, height: 900 }
const hub = await startDemoHub(4490)
const browser = await chromium.launch()
const context = await browser.newContext({ viewport: size, deviceScaleFactor: 2, colorScheme: 'dark', locale: 'en-US' })
const elsewhere: string[] = []
await context.route('**/*', (route) => {
  const asked = route.request().url()
  if (asked.startsWith(hub.url) || asked.startsWith('data:') || asked.startsWith('ws:')) return route.continue()
  elsewhere.push(asked)
  return route.abort()
})
const signedIn = await context.request.post(`${hub.url}/auth/dev`, { headers: { 'x-binders': '1' }, data: { login: demoPeople[0] } })
if (!signedIn.ok()) throw new Error(`Couldn’t sign in to the demo hub: ${signedIn.status()}`)
const page = await context.newPage()
const words: string[] = realWords()
const beats: Record<string, { image: string; marks: Record<string, { x: number; y: number; width: number; height: number }> }> = {}

const open = async (hash: string, ready: string) => {
  await page.goto(`${hub.binder}${hash}`)
  await page.locator(ready).first().waitFor()
  await page.evaluate(() => document.fonts.ready)
}

/** A picture of the screen as it is, and where each of `marks` is on it. */
async function beat(page: Page, name: string, marks: Record<string, string> = {}) {
  await page.waitForTimeout(700)
  const html = (await page.evaluate(() => document.documentElement.outerHTML)).toLowerCase()
  const found = words.filter((word) => html.includes(word))
  if (found.length) throw new Error(`${name} shows something real: ${found.join(', ')}`)
  if (elsewhere.length) throw new Error(`${name} asked for something elsewhere: ${elsewhere.join(', ')}`)
  const placed: (typeof beats)[string]['marks'] = {}
  for (const [mark, selector] of Object.entries(marks)) {
    const box = await page.locator(selector).first().boundingBox()
    if (!box) throw new Error(`${name}: nothing at ${selector}`)
    placed[mark] = box
  }
  await page.screenshot({ path: resolve(out, `${name}.png`), animations: 'disabled', caret: 'hide' })
  beats[name] = { image: `beats/${name}.png`, marks: placed }
  console.log(name, Object.keys(placed).join(' '))
}

try {
  const live = hub.hub
  const agent = { kind: 'agent', id: 'claude-web' }

  await open(`#/notes/${demoIds.note}`, '.cm-content, .note-editor, h1')
  await beat(page, 'note', { body: '.cm-content, .cm-editor' })

  await open('#/flow', '.columns .card.proposal')
  await beat(page, 'distill-before', { accept: '.card.proposal .mini-button.primary', proposal: '.card.proposal' })
  await page.locator('.card.proposal .mini-button.primary').first().click()
  await beat(page, 'distill-after', { proposal: '.card.proposal' })

  await open(`#/work/${demoIds.card}`, '.sdlc .now')
  await beat(page, 'card-before', { now: '.sdlc .now' })
  const card = live.state.cards.find((c: { id: string }) => c.id === demoIds.card)
  await live.record(agent, {
    type: 'card.update', id: demoIds.card, fields: {
      progress: 0.82, doing: 'Opening the pull request',
      plan: card.plan.map((step: { text: string }, i: number) => ({ ...step, done: i < 4 })),
    },
  })
  await beat(page, 'card-after', { now: '.sdlc .now', plan: 'h2:has-text("Plan"), h3:has-text("Plan")' })

  await open('#/agents', 'button:has-text("Edit")')
  await page.locator('button:has-text("Edit")').first().click()
  await page.locator(':text("Each in a worktree")').first().waitFor()
  await page.locator(':text("Each in a worktree")').first().scrollIntoViewIfNeeded()
  await beat(page, 'worktree', { hint: ':text("Each in a worktree")' })

  await open(`#/changes/${demoIds.set}`, '.stack .pull')
  await page.locator('#set-tab-changes').click()
  await page.locator('.stack .pull .diff').first().waitFor()
  await beat(page, 'changeset', { stack: '.stack .pull', approve: 'button:has-text("Approve 3 and merge")' })

  await page.locator('#set-tab-review').click()
  await page.locator('.findings .finding').first().waitFor()
  await beat(page, 'challenge', { finding: '.findings .finding', blast: ':text("Blast radius")', blind: ':text("from the diff, brief and done-when alone")' })

  await open('#/delivery', '.envs .env')
  await beat(page, 'delivery-before', { promote: 'button:has-text("Promote")' })
  await page.locator('button:has-text("Promote")').click()
  await beat(page, 'delivery-after', { production: '.envs .env >> nth=1' })

  await writeFile(resolve(import.meta.dirname, 'public/beats.json'), JSON.stringify({ size, beats }, null, 2))
} finally {
  await browser.close()
  await hub.stop()
}
