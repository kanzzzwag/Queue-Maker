// Shrinks an image in the browser before upload.
// Output is WebP (or JPEG on browsers that cannot encode WebP, e.g. older Safari).
export const MAX_SOURCE_BYTES = 5 * 1024 * 1024;

function canvasBlob(canvas, type, quality) {
  return new Promise((resolve) => canvas.toBlob(resolve, type, quality));
}

// square: crop to a square of `size` px (avatars).
// Otherwise scale down to at most maxWidth x maxHeight, keeping the shape.
export async function shrinkImage(file, { square = 0, maxWidth = 1200, maxHeight = 1200, maxBytes = 300 * 1024 }) {
  if (!file || !file.type.startsWith('image/')) throw new Error('Pick an image file.');
  if (file.size > MAX_SOURCE_BYTES) throw new Error('Image is too large (max 5 MB).');

  let bmp;
  try { bmp = await createImageBitmap(file); } catch { throw new Error('Could not read this image.'); }

  let sx = 0, sy = 0, sw = bmp.width, sh = bmp.height, w, h;
  if (square) {
    const side = Math.min(sw, sh);           // center crop
    sx = (sw - side) / 2; sy = (sh - side) / 2; sw = sh = side;
    w = h = square;
  } else {
    const k = Math.min(1, maxWidth / sw, maxHeight / sh);
    w = Math.round(sw * k); h = Math.round(sh * k);
  }

  const canvas = document.createElement('canvas');
  canvas.width = w; canvas.height = h;
  const g = canvas.getContext('2d');
  g.imageSmoothingQuality = 'high';
  g.drawImage(bmp, sx, sy, sw, sh, 0, 0, w, h);
  bmp.close?.();

  // Lower the quality until the file is small enough.
  let type = 'image/webp';
  let blob;
  for (const q of [0.85, 0.75, 0.65, 0.55, 0.45, 0.35]) {
    blob = await canvasBlob(canvas, type, q);
    if (blob && blob.type !== type) { type = 'image/jpeg'; blob = await canvasBlob(canvas, type, q); }
    if (blob && blob.size <= maxBytes) break;
  }
  if (!blob) throw new Error('Could not process this image.');
  return blob;
}

// Random file name inside the user's folder: "{userId}/{uuid}.webp"
export function filePath(userId, blob) {
  const ext = blob.type === 'image/webp' ? 'webp' : 'jpg';
  const id = crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  return `${userId}/${id}.${ext}`;
}
