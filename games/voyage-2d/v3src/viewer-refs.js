// Reference crops per character + the estimated camera for each (yaw, pitch,
// head roll in degrees, fov, distance in head-sized units, framing on the head).
// The artifact build replaces the file paths with data: URIs.
export const REFS = {
  captain: { face: "refs/captain-face.jpg", body: "refs/captain-body.jpg", src: "kf5", match: { yaw: -30, pitch: -10, roll: -5, fov: 30, dist: 2.2, expr: "joy", on: "head" } },
  "sailor-hammer": { face: "refs/sailor-hammer-face.jpg", body: "refs/sailor-hammer-body.jpg", src: "kf2", match: { yaw: 35, pitch: 5, roll: -6, fov: 30, dist: 2.1, expr: "grin", on: "head" } },
  "sailor-bandana": { face: "refs/sailor-bandana-face.jpg", body: "refs/sailor-bandana-body.jpg", src: "banner", match: { yaw: -30, pitch: 0, roll: 0, fov: 30, dist: 2.2, expr: "grin", on: "head" } },
  reviewer: { face: "refs/reviewer-face.jpg", body: "refs/reviewer-body.jpg", src: "banner / kf3", match: { yaw: 30, pitch: 5, roll: 5, fov: 30, dist: 2.1, expr: "grin", on: "head" } },
  "sailor-spyglass": { body: "refs/sailor-spyglass-body.jpg", src: "banner", match: { yaw: 30, pitch: 5, roll: 0, fov: 30, dist: 2.4, expr: "focus", on: "head" } },
  "sailor-laptop": { body: "refs/sailor-laptop-body.jpg", src: "kf3", match: { yaw: -25, pitch: 10, roll: 0, fov: 30, dist: 5, expr: "shout", on: "body" } },
  robot: { face: "refs/robot-face.jpg", body: "refs/robot-body.jpg", src: "kf2 / banner", match: { yaw: -20, pitch: 5, roll: 0, fov: 30, dist: 5, expr: "eyes", on: "body" } },
  corgi: { body: "refs/corgi-body.jpg", src: "kf1", match: { yaw: -30, pitch: 10, roll: 0, fov: 30, dist: 4, on: "body" } },
  parrot: { body: "refs/parrot-body.jpg", src: "kf1", match: { yaw: -40, pitch: 0, roll: 0, fov: 30, dist: 4, on: "body" } },
  kraken: { body: "refs/kraken-body.jpg", src: "kf4", match: { yaw: 20, pitch: 8, roll: 0, fov: 30, dist: 3.2, on: "body" } },
};
