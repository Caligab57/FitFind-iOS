import sharp from 'sharp';

export class ServiceError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

export const categories = ['top', 'bottoms', 'shoes', 'outerwear', 'dress', 'bag', 'accessory'];
const stringSchema = (maxLength, minLength = 0) => ({ type: 'string', maxLength, minLength });
export const analysisSchema = {
  type: 'object', additionalProperties: false,
  properties: {
    summary: stringSchema(600, 1), limitations: stringSchema(600),
    garments: { type: 'array', maxItems: 12, items: {
      type: 'object', additionalProperties: false,
      properties: {
        id: stringSchema(80, 1), category: {type: 'string', enum: categories},
        name: stringSchema(120, 1), color: stringSchema(80),
        details: stringSchema(400), searchQuery: stringSchema(200, 1),
      }, required: ['id', 'category', 'name', 'color', 'details', 'searchQuery'],
    } },
  }, required: ['summary', 'limitations', 'garments'],
};

function object(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function text(value, max, required = false) {
  return typeof value === 'string' && value.length <= max && (!required || value.trim().length > 0);
}
export function validateAnalysis(value) {
  const invalid = () => { throw new ServiceError(502, 'Recognition returned an incomplete response. Try a clearer photo.'); };
  if (!object(value) || !text(value.summary, 600, true) || !text(value.limitations, 600) ||
      !Array.isArray(value.garments) || value.garments.length > 12) invalid();
  const ids = new Set();
  const garments = value.garments.map(g => {
    if (!object(g) || !text(g.id, 80, true) || ids.has(g.id) || !categories.includes(g.category) ||
        !text(g.name, 120, true) || !text(g.color, 80) || !text(g.details, 400) || !text(g.searchQuery, 200, true)) invalid();
    ids.add(g.id);
    // Only return the fields the iOS decoder expects. Ignore extraneous provider fields.
    return {id:g.id, category:g.category, name:g.name, color:g.color, details:g.details, searchQuery:g.searchQuery};
  });
  return {summary:value.summary, garments, limitations:value.limitations};
}

export function validateRequest(body, maxImageBytes) {
  if (!object(body) || Object.keys(body).some(k => !['imageBase64', 'context'].includes(k)) ||
      typeof body.imageBase64 !== 'string' || !text(body.context ?? '', 1000)) {
    throw new ServiceError(400, 'Send imageBase64 and an optional context of at most 1000 characters.');
  }
  const data = body.imageBase64;
  if (!data || data.length > Math.ceil(maxImageBytes / 3) * 4 || data.length % 4 !== 0 ||
      !/^[A-Za-z0-9+/]*={0,2}$/.test(data)) throw new ServiceError(400, 'Send a base64-encoded JPEG, PNG, or WebP smaller than 3 MB.');
  const bytes = Buffer.from(data, 'base64');
  if (bytes.length > maxImageBytes || bytes.toString('base64') !== data) {
    throw new ServiceError(400, 'The image encoding is invalid or too large.');
  }
  return {bytes, context:(body.context ?? '').trim()};
}

export async function prepareImage(bytes) {
  try {
    const image = sharp(bytes, {limitInputPixels:25_000_000, failOn:'warning', animated:false});
    const metadata = await image.metadata();
    if (!['jpeg', 'png', 'webp'].includes(metadata.format) || !metadata.width || !metadata.height ||
        metadata.width > 10000 || metadata.height > 10000 || (metadata.pages ?? 1) !== 1) throw new Error('format');
    // Decode, orient, resize and re-encode; sharp strips metadata by default.
    return await image.rotate().resize({width:1600, height:1600, fit:'inside', withoutEnlargement:true})
      .flatten({background:'#ffffff'}).jpeg({quality:82}).toBuffer();
  } catch {
    throw new ServiceError(400, 'The image could not be decoded. Use a valid still JPEG, PNG, or WebP.');
  }
}
