.pragma library

// Deterministic 3D value noise on a hashed integer lattice, smoothstep
// interpolated.
//
// Noise is used because it is spatially coherent: thresholding it yields
// connected blobs rather than speckle, so the "scary" digits read as clusters
// rather than as scattered individuals. The third axis advances slowly over
// time, which makes those clusters drift.

function hash3(i, j, k, seed) {
  var h = Math.imul(i, 374761393) + Math.imul(j, 668265263) + Math.imul(k, 1442695040) + Math.imul(seed, 1013904223)
  h = (h ^ (h >>> 13)) >>> 0
  h = Math.imul(h, 1274126177) >>> 0
  return ((h ^ (h >>> 16)) >>> 0) / 4294967295
}

function smooth(t) {
  return t * t * (3 - 2 * t)
}

function value3(x, y, z, seed) {
  var xi = Math.floor(x), yi = Math.floor(y), zi = Math.floor(z)
  var xf = smooth(x - xi), yf = smooth(y - yi), zf = smooth(z - zi)

  var c000 = hash3(xi, yi, zi, seed)
  var c100 = hash3(xi + 1, yi, zi, seed)
  var c010 = hash3(xi, yi + 1, zi, seed)
  var c110 = hash3(xi + 1, yi + 1, zi, seed)
  var c001 = hash3(xi, yi, zi + 1, seed)
  var c101 = hash3(xi + 1, yi, zi + 1, seed)
  var c011 = hash3(xi, yi + 1, zi + 1, seed)
  var c111 = hash3(xi + 1, yi + 1, zi + 1, seed)

  var x00 = c000 + (c100 - c000) * xf
  var x10 = c010 + (c110 - c010) * xf
  var x01 = c001 + (c101 - c001) * xf
  var x11 = c011 + (c111 - c011) * xf

  var y0 = x00 + (x10 - x00) * yf
  var y1 = x01 + (x11 - x01) * yf

  return y0 + (y1 - y0) * zf
}

// Two octaves. The second adds enough irregularity to the cluster edges that
// they stop looking like smooth ellipses, without costing much.
function fbm3(x, y, z, seed) {
  return value3(x, y, z, seed) * 0.68 + value3(x * 2.3, y * 2.3, z * 1.7, seed + 101) * 0.32
}
