import { AbsoluteFill, Easing, Img, Sequence, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig } from 'remotion'
import beatsFile from '../public/beats.json'
import shots from '../shots.json'

// The Hub tour: real screens from capture.ts in a window, a camera that moves to what the line is about, and a cursor
// where a person clicks. The look follows the Mac's tour (site/assets/tour.mp4): a tag and a line over indigo.

type Rect = { x: number; y: number; width: number; height: number }
const screen = beatsFile.size
const beats = beatsFile.beats as Record<string, { image: string; marks: Record<string, Rect> }>
const full: Rect = { x: 0, y: 0, width: screen.width, height: screen.height }
const mark = (beat: string, name: string) => beats[beat].marks[name]
const around = (r: Rect, width: number, height = (width * screen.height) / screen.width): Rect => ({ x: r.x + r.width / 2 - width / 2, y: r.y + r.height / 2 - height / 2, width, height })

const below = (r: Rect, width: number): Rect => ({ ...around(r, width), y: around(r, width).y + 60 })

/** At what share of the shot each picture starts, the camera's stops, and where the cursor goes and clicks. */
interface Scene {
  pictures: { at: number; beat: string }[]
  camera: { at: number; rect: Rect }[]
  click?: { at: number; target: Rect }
}

const scenes: Record<string, Scene> = {
  note: { pictures: [{ at: 0, beat: 'note' }], camera: [{ at: 0.05, rect: around(mark('note', 'body'), 1040) }, { at: 0.6, rect: around(mark('note', 'body'), 820) }] },
  distill: {
    pictures: [{ at: 0, beat: 'distill-before' }, { at: 0.5, beat: 'distill-after' }],
    camera: [{ at: 0.05, rect: full }, { at: 0.3, rect: around(mark('distill-before', 'proposal'), 700) }, { at: 0.62, rect: around(mark('distill-before', 'proposal'), 700) }, { at: 0.85, rect: around({ x: 277, y: 150, width: 370, height: 300 }, 900) }],
    click: { at: 0.48, target: mark('distill-before', 'accept') },
  },
  flow: {
    pictures: [{ at: 0, beat: 'card-before' }, { at: 0.55, beat: 'card-after' }],
    camera: [{ at: 0.05, rect: full }, { at: 0.35, rect: around(mark('card-after', 'plan'), 900) }],
  },
  // Close on the hint: the demo agent's access setting sits just above it, and isn't what this line is about.
  worktree: { pictures: [{ at: 0, beat: 'worktree' }], camera: [{ at: 0.05, rect: below(mark('worktree', 'hint'), 660) }, { at: 0.8, rect: below(mark('worktree', 'hint'), 610) }] },
  changeset: {
    pictures: [{ at: 0, beat: 'changeset' }],
    camera: [{ at: 0.05, rect: full }, { at: 0.35, rect: around({ ...mark('changeset', 'stack'), height: 120 }, 960) }, { at: 0.72, rect: around(mark('changeset', 'approve'), 760) }],
  },
  challenge: {
    pictures: [{ at: 0, beat: 'challenge' }],
    camera: [{ at: 0.05, rect: full }, { at: 0.3, rect: around(mark('challenge', 'blind'), 1000) }, { at: 0.68, rect: around(mark('challenge', 'finding'), 1000) }],
  },
  delivery: {
    pictures: [{ at: 0, beat: 'delivery-before' }, { at: 0.56, beat: 'delivery-after' }],
    camera: [{ at: 0.05, rect: full }, { at: 0.3, rect: around(mark('delivery-before', 'promote'), 1200) }],
    click: { at: 0.54, target: mark('delivery-before', 'promote') },
  },
}

const bounded = (r: Rect): Rect => {
  const width = Math.min(r.width, screen.width)
  const height = Math.min(r.height, screen.height)
  return { width, height, x: Math.max(0, Math.min(screen.width - width, r.x)), y: Math.max(0, Math.min(screen.height - height, r.y)) }
}

const smooth = Easing.bezier(0.65, 0, 0.2, 1)

/** Where the camera is at this share of the shot, moving between stops over the time before each. */
function cameraAt(stops: Scene['camera'], share: number): Rect {
  let rect = bounded(stops[0].rect)
  stops.slice(1).forEach((stop, i) => {
    const t = interpolate(share, [stops[i].at + (stop.at - stops[i].at) * 0.35, stop.at], [0, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: smooth })
    const to = bounded(stop.rect)
    rect = { x: rect.x + (to.x - rect.x) * t, y: rect.y + (to.y - rect.y) * t, width: rect.width + (to.width - rect.width) * t, height: rect.height + (to.height - rect.height) * t }
  })
  return rect
}

const Backdrop = () => {
  const frame = useCurrentFrame()
  const drift = Math.sin(frame / 90) * 6
  return <AbsoluteFill style={{ background: `radial-gradient(120% 120% at ${18 + drift}% ${-6 + drift}%, #7a69ff 0%, #4c38df 42%, #2a1aa6 100%)` }} />
}

const windowWidth = 1344
const windowHeight = (windowWidth * screen.height) / screen.width

function Cursor({ click, share, camera, scale }: { click: NonNullable<Scene['click']>; share: number; camera: Rect; scale: number }) {
  const { fps } = useVideoConfig()
  const frame = useCurrentFrame()
  const start = click.at - 0.2
  const t = interpolate(share, [start, click.at], [0, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: smooth })
  const tx = click.target.x + click.target.width / 2
  const ty = click.target.y + click.target.height / 2
  const x = (tx + 160 * (1 - t) - camera.x) * scale
  const y = (ty + 120 * (1 - t) - camera.y) * scale
  const appear = interpolate(share, [start - 0.04, start, click.at + 0.1, click.at + 0.16], [0, 1, 1, 0], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' })
  const clickFrame = (click.at * shotFrames.current)
  const ripple = spring({ frame: frame - clickFrame, fps, config: { damping: 200 }, durationInFrames: 18 })
  return (
    <div style={{ position: 'absolute', left: x, top: y, opacity: appear, pointerEvents: 'none' }}>
      {frame >= clickFrame && <div style={{ position: 'absolute', left: -30, top: -30, width: 60, height: 60, borderRadius: '50%', border: '3px solid #fff', opacity: 1 - ripple, transform: `scale(${0.3 + ripple * 1.1})` }} />}
      <svg width="34" height="40" viewBox="0 0 24 28" style={{ filter: 'drop-shadow(0 3px 5px rgba(0,0,0,.5))', transform: `scale(${frame >= clickFrame && frame < clickFrame + 5 ? 0.86 : 1})`, transformOrigin: '0 0' }}>
        <path d="M2 2 L2 21 L7.5 16.5 L11 25 L14.5 23.5 L11 15 L18 15 Z" fill="#fff" stroke="#111" strokeWidth="1.4" strokeLinejoin="round" />
      </svg>
    </div>
  )
}

const shotFrames = { current: 0 }

function Shot({ shot, frames }: { shot: (typeof shots.shots)[number]; frames: number }) {
  const frame = useCurrentFrame()
  const { fps } = useVideoConfig()
  shotFrames.current = frames
  const scene = scenes[shot.id]
  const share = frame / frames
  const camera = cameraAt(scene.camera, share)
  const scale = windowWidth / camera.width
  const enter = spring({ frame, fps, config: { damping: 18, stiffness: 90 } })
  const leave = interpolate(frame, [frames - 12, frames], [0, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.in(Easing.cubic) })
  const lineIn = spring({ frame: frame - 4, fps, config: { damping: 20, stiffness: 110 } })
  return (
    <AbsoluteFill style={{ opacity: 1 - leave }}>
      <div style={{ position: 'absolute', top: 44, left: 0, right: 0, display: 'flex', justifyContent: 'center', alignItems: 'center', gap: 22, opacity: lineIn, transform: `translateY(${(1 - lineIn) * -18}px)` }}>
        <span style={{ background: '#fff', color: '#2a1aa6', fontWeight: 800, fontSize: 25, padding: '9px 22px', borderRadius: 12, boxShadow: '0 0 0 4px rgba(255,255,255,.28)' }}>{shot.tag}</span>
        <span style={{ color: '#fff', fontWeight: 800, fontSize: 39, letterSpacing: -0.4, textShadow: '0 2px 12px rgba(20,10,90,.45)' }}>{shot.line}</span>
      </div>
      <div style={{ position: 'absolute', left: (1920 - windowWidth) / 2, top: 142, width: windowWidth, height: windowHeight + 34, borderRadius: 14, overflow: 'hidden', background: '#000', boxShadow: '0 40px 90px -20px rgba(8,4,50,.75)', transform: `translateY(${(1 - enter) * 90 - leave * 50}px) scale(${0.95 + enter * 0.05 - leave * 0.03})` }}>
        <div style={{ height: 34, background: '#17171a', display: 'flex', alignItems: 'center', gap: 8, paddingLeft: 14 }}>
          {['#ff5f57', '#febc2e', '#28c840'].map((color) => <i key={color} style={{ width: 12, height: 12, borderRadius: 6, background: color }} />)}
        </div>
        <div style={{ position: 'relative', width: windowWidth, height: windowHeight, overflow: 'hidden' }}>
          {scene.pictures.map((picture, i) => {
            const next = scene.pictures[i + 1]
            const shown = i === 0 ? 1 : interpolate(share, [picture.at, picture.at + 0.03], [0, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' })
            if (next && share > next.at + 0.04) return null
            return <Img key={picture.beat} src={staticFile(beats[picture.beat].image)} style={{ position: 'absolute', opacity: shown, width: screen.width * scale, height: screen.height * scale, left: -camera.x * scale, top: -camera.y * scale, maxWidth: 'none' }} />
          })}
          {scene.click && <Cursor click={scene.click} share={share} camera={camera} scale={scale} />}
        </div>
      </div>
    </AbsoluteFill>
  )
}

const pipeline = ['Note', 'Distill', 'Cards', 'Agents', 'Pull requests', 'Change set', 'CI/CD']

function End({ line }: { line: string }) {
  const frame = useCurrentFrame()
  const { fps } = useVideoConfig()
  const title = spring({ frame, fps, config: { damping: 18, stiffness: 90 } })
  return (
    <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', gap: 44 }}>
      <div style={{ color: '#fff', fontWeight: 800, fontSize: 104, letterSpacing: -2, opacity: title, transform: `translateY(${(1 - title) * 30}px)` }}>{line}</div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
        {pipeline.map((step, i) => {
          const shown = spring({ frame: frame - 14 - i * 5, fps, config: { damping: 20, stiffness: 120 } })
          return (
            <span key={step} style={{ display: 'flex', alignItems: 'center', gap: 16, opacity: shown, transform: `translateY(${(1 - shown) * 14}px)` }}>
              {i > 0 && <span style={{ color: 'rgba(255,255,255,.6)', fontSize: 30 }}>→</span>}
              <span style={{ color: '#fff', fontWeight: 700, fontSize: 30 }}>{step}</span>
            </span>
          )
        })}
      </div>
    </AbsoluteFill>
  )
}

export function Tour() {
  const { fps } = useVideoConfig()
  let from = 0
  return (
    <AbsoluteFill style={{ fontFamily: 'Nunito, sans-serif' }}>
      <style>{`@font-face { font-family: Nunito; src: url(${staticFile('fonts/nunito-latin.woff2')}) format('woff2'); font-weight: 200 1000; }`}</style>
      <Backdrop />
      {shots.shots.map((shot) => {
        const frames = shot.seconds * fps
        const at = from
        from += frames
        return <Sequence key={shot.id} from={at} durationInFrames={frames}>{shot.id === 'end' ? <End line={shot.line} /> : <Shot shot={shot} frames={frames} />}</Sequence>
      })}
      <div style={{ position: 'absolute', right: 40, bottom: 26, display: 'flex', alignItems: 'center', gap: 10, color: '#fff', fontWeight: 700, fontSize: 25 }}>
        <Img src={staticFile('icon-128.png')} style={{ width: 32, height: 32, borderRadius: 7 }} />binders.io
      </div>
    </AbsoluteFill>
  )
}
