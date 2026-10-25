// Shared request/response plumbing for the routes.

export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
  ) {
    super(code);
  }
}

export interface RouteResult {
  status: number;
  body: Record<string, unknown>;
}

export function ok(body: Record<string, unknown> = {}): RouteResult {
  return { status: 200, body: { ok: true, ...body } };
}

export function json(
  body: Record<string, unknown>,
  status: number,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...extraHeaders },
  });
}

/** Reads a required string field from an untrusted JSON body. */
export function stringField(
  body: Record<string, unknown>,
  key: string,
  { min = 1, max = 200 }: { min?: number; max?: number } = {},
): string {
  const v = body[key];
  if (typeof v !== 'string') throw new HttpError(400, `invalid-${key}`);
  const trimmed = v.trim();
  if (trimmed.length < min || trimmed.length > max) {
    throw new HttpError(400, `invalid-${key}`);
  }
  return trimmed;
}
