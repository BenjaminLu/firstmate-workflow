// The victory cue (p4): a short heroic fanfare, written out as notes so it is the same
// every time and testable. 132 bpm, D major, two phrases and a held final chord:
//   lead     a brass melody that leaps a fourth, climbs, and lands on the high tonic
//   harmony  horn triads on every change (I - IV - V - vi - IV - V - I)
//   bass     root on the beats, an octave leap into each bar
//   drums    timpani on the downbeats, a snare roll into the last chord, a crash on it
// It is distinct from the merge salvo and the older "fanfare" (those are a rising
// square arpeggio); nothing here is a file, the audio module synthesises every note.
const BPM = 132;
export const BEAT = 60 / BPM;
const NOTE = { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 };
// "F#4" -> Hz
export function hz(n) {
  const m = /^([A-G])(#|b)?(-?\d)$/.exec(n);
  const semis = NOTE[m[1]] + (m[2] === "#" ? 1 : m[2] === "b" ? -1 : 0) + (+m[3] + 1) * 12;
  return 440 * 2 ** ((semis - 69) / 12);
}
// [beat, note, beats]
const LEAD = [
  [0, "A4", 0.5], [0.5, "D5", 1.5], [2, "D5", 0.5], [2.5, "E5", 0.5], [3, "F#5", 1],
  [4, "G5", 0.75], [4.75, "F#5", 0.25], [5, "E5", 0.5], [5.5, "D5", 0.5], [6, "E5", 2],
  [8, "A4", 0.5], [8.5, "D5", 1.5], [10, "F#5", 0.5], [10.5, "A5", 1.5], [12, "B5", 0.75], [12.75, "A5", 0.25],
  [13, "G5", 0.5], [13.5, "E5", 0.5], [14, "D6", 3],
];
const CHORDS = [
  [0, ["D4", "F#4", "A4"], 2], [2, ["G3", "B3", "D4"], 2], [4, ["A3", "C#4", "E4"], 2], [6, ["B3", "D4", "F#4"], 2],
  [8, ["G3", "B3", "D4"], 2], [10, ["A3", "C#4", "E4"], 2], [12, ["A3", "C#4", "G4"], 2], [14, ["D4", "F#4", "A4", "D5"], 3],
];
const BASS = [
  [0, "D2", 1], [1, "D3", 1], [2, "G2", 1], [3, "G3", 1], [4, "A2", 1], [5, "A3", 1], [6, "B2", 1], [7, "B2", 1],
  [8, "G2", 1], [9, "G3", 1], [10, "A2", 1], [11, "A3", 1], [12, "A2", 1], [13, "A2", 1], [14, "D2", 3],
];
const DRUMS = [
  [0, "timp"], [2, "timp"], [4, "timp"], [6, "timp"], [8, "timp"], [10, "timp"], [12, "timp"],
  ...Array.from({ length: 8 }, (_, i) => [13 + i * 0.125, "snare"]),
  [14, "crash"], [14, "timp"],
];
export function victoryScore() {
  const out = [];
  for (const [b, n, d] of LEAD) out.push({ t: b * BEAT, part: "lead", f: hz(n), dur: d * BEAT });
  for (const [b, ns, d] of CHORDS) for (const n of ns) out.push({ t: b * BEAT, part: "harmony", f: hz(n), dur: d * BEAT });
  for (const [b, n, d] of BASS) out.push({ t: b * BEAT, part: "bass", f: hz(n), dur: d * BEAT });
  for (const [b, k] of DRUMS) out.push({ t: b * BEAT, part: "drums", kind: k, dur: k === "crash" ? 2.2 : 0.4 });
  return out.sort((a, b) => a.t - b.t);
}
export const VICTORY_LENGTH = 17 * BEAT;
