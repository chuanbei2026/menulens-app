// Behind CloudFront (api.chuanbei.dev) this Lambda's routes arrive under /menu: CloudFront sends
// /menu/* here by path but can't strip the prefix. Builds that call the Lambda URL directly send the
// bare path, so both forms are accepted.

/**
 * "/menu/credits" → "/credits"; anything else unchanged — including a bare "/menu"
 * (ForeignMenu has a real POST /menu route that older builds call directly).
 */
export function stripPrefix(path) {
  return path.startsWith("/menu/") ? path.slice(5) : path;
}
