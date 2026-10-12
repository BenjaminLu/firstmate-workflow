// The populated board the design captures use (T-299), and the same data the
// prototype is served with for its own screenshots (T-289): one definition.
import { makeRoot, writeRegistry } from './fixture';

export function captureRoot() {
  const root = makeRoot(['working', 'gate', 'review', 'working', 'gate']);
  writeRegistry(root, 'fixture/capture');
  return root;
}
