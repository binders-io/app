// Writes the tour's WebVTT from shots.json, so the captions can't drift from the lines on screen.
import { readFileSync, writeFileSync } from 'node:fs'

const here = new URL('.', import.meta.url)
const { shots } = JSON.parse(readFileSync(new URL('shots.json', here), 'utf8'))
const stamp = (s) => `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}.000`

let at = 0
const cues = shots.map((shot) => {
  const cue = `${stamp(at)} --> ${stamp(at + shot.seconds)}\n${shot.line}`
  at += shot.seconds
  return cue
})
writeFileSync(process.argv[2], `WEBVTT\n\n${cues.join('\n\n')}\n`)
console.log(`${shots.length} cues, ${at} seconds`)
