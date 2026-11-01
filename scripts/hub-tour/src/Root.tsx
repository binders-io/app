import { Composition } from 'remotion'
import shots from '../shots.json'
import { Tour } from './Tour'

const seconds = shots.shots.reduce((total, shot) => total + shot.seconds, 0)

export const Root = () => (
  <Composition id="HubTour" component={Tour} durationInFrames={seconds * shots.fps} fps={shots.fps} width={shots.width} height={shots.height} />
)
