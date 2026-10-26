// LearnDrive 2.0 owner/admin API.
// Privileged moderation and account-lifecycle operations only.

type Env = (name: string) => string | undefined;
type Json = Record<string, any>;

const version = '2.0.0.owner.1';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

class ApiError extends Error {
  constructor(public code: string, message: string, public status = 400) {
    super(message);
  }
}

function fail(code: string, message: string, status = 400): never {
  throw new ApiError(code, message, status);
}

function required(env: Env, key: string): string {
  const value = env(key)?.trim();
  if (!value) fail('setup_required', 'Owner services are not available yet.', 503);
  return value;
}

function id(value: unknown, field = 'id'): string {
  if (typeof value !== 'string' || !uuid.test(value)) {
    fail('invalid_request', `Invalid ${field}.`);
  }
  return value;
}

function json(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: {
      'Cache-Control': 'no-store',
      'X-LearnDrive-Owner-Version': version,
    },
  });
}

async function body(req: Request, max = 16384): Promise<Json> {
  if (Number(req.headers.get('content-length') ?? 0) > max) {
    fail('invalid_request', 'Request too large.', 413);
  }
  const raw = await req.text();
  if (raw.length > max) fail('invalid_request', 'Request too large.', 413);
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    fail('invalid_request', 'Invalid request.');
  }
  if (!value || Array.isArray(value) || typeof value !== 'object') {
    fail('invalid_request', 'Invalid request.');
  }
  return value as Json;
}

class Database {
  constructor(private env: Env, private fetcher: typeof fetch) {}

  private async call(path: string, payload?: unknown, method?: string): Promise<any> {
    const key = required(this.env, 'SUPABASE_SERVICE_ROLE_KEY');
    const response = await this.fetcher(
      `${required(this.env, 'SUPABASE_URL')}/rest/v1/${path}`,
      {
        method: method ?? (payload === undefined ? 'GET' : 'POST'),
        headers: {
          apikey: key,
          Authorization: `Bearer ${key}`,
          'Content-Type': 'application/json',
          Prefer: 'return=representation',
        },
        body: payload === undefined ? undefined : JSON.stringify(payload),
        signal: AbortSignal.timeout(12000),
        redirect: 'error',
      },
    );

    if (!response.ok) {
      let message = '';
      try {
        message = (await response.json()).message ?? '';
      } catch {
        // Never expose a raw database response.
      }
      if (message === 'Review not found') {
        fail('not_found', 'Review not found.', 404);
      }
      if (message === 'Future confirmed lessons must be resolved first') {
        fail('future_lessons', 'Future confirmed lessons must be resolved first.', 409);
      }
      if (message === 'Account not ready for deletion') {
        fail('account_not_ready', 'Account is not ready for deletion.', 409);
      }
      fail('service_unavailable', 'The owner service could not finish. Please retry.', 503);
    }

    const text = await response.text();
    return text ? JSON.parse(text) : null;
  }

  rows(table: string, filter: Json): Promise<Json[]> {
    return this.call(`${table}?${new URLSearchParams(filter)}`);
  }

  rpc(name: string, args: Json): Promise<any> {
    return this.call(`rpc/${name}`, args);
  }
}

async function requireAdmin(env: Env, fetcher: typeof fetch, db: Database, req: Request): Promise<string> {
  const authorization = req.headers.get('Authorization') ?? '';
  if (!/^Bearer \S+$/.test(authorization)) {
    fail('sign_in_required', 'Please sign in again.', 401);
  }

  const response = await fetcher(
    `${required(env, 'SUPABASE_URL')}/auth/v1/user`,
    {
      headers: {
        Authorization: authorization,
        apikey: required(env, 'SUPABASE_ANON_KEY'),
      },
      signal: AbortSignal.timeout(10000),
      redirect: 'error',
    },
  );

  if (!response.ok) fail('sign_in_required', 'Please sign in again.', 401);
  const authUser = await response.json();
  const userId = id(authUser.id, 'user');

  const rows = await db.rows('profiles', {
    id: `eq.${userId}`,
    select: 'role,account_status',
  });
  const profile = rows[0];
  if (!profile || profile.role !== 'admin' || profile.account_status !== 'active') {
    fail('admin_required', 'Administrator access is required.', 403);
  }

  return userId;
}

export function createOwnerHandler(env: Env, fetcher: typeof fetch = fetch) {
  return async (req: Request): Promise<Response> => {
    try {
      const url = new URL(req.url);
      const path = url.pathname.replace(/^\/functions\/v1/, '').replace(/\/$/, '');
      if (path !== '/owner-api') {
        return json({ error: { code: 'not_found', message: 'Not found.' } }, 404);
      }
      if (req.method !== 'POST') {
        return json({ error: { code: 'method_not_allowed', message: 'Use POST.' } }, 405);
      }

      const db = new Database(env, fetcher);
      await requireAdmin(env, fetcher, db, req);
      const input = await body(req);

      if (input.action === 'reviews_pending') {
        const limit = input.limit ?? 100;
        if (!Number.isInteger(limit) || limit < 1 || limit > 200) {
          fail('invalid_request', 'Invalid limit.');
        }
        const rows = await db.rows('instructor_reviews', {
          status: 'eq.pending',
          select: 'id,instructor_id,learner_id,reservation_id,rating,comment,created_at,updated_at',
          order: 'created_at.asc',
          limit: String(limit),
        });
        return json({ reviews: rows });
      }

      if (input.action === 'review_status') {
        const status = input.status;
        if (!['pending', 'published', 'rejected'].includes(status)) {
          fail('invalid_request', 'Invalid review status.');
        }
        await db.rpc('review_set_status', {
          p_review: id(input.review_id, 'review id'),
          p_status: status,
        });
        return json({ updated: true, status });
      }

      if (input.action === 'deletion_queue') {
        const rows = await db.rows('account_deletion_requests', {
          status: 'in.(requested,prepared)',
          select: 'id,user_id,requested_at,due_at,status,created_at,updated_at',
          order: 'due_at.asc',
          limit: '200',
        });
        return json({ requests: rows });
      }

      if (input.action === 'deletion_complete') {
        const userId = id(input.user_id, 'user id');
        await db.rpc('account_complete_deletion', {
          p_user: userId,
        });
        return json({
          completed: true,
          user_id: userId,
          auth_user_deletion_required: true,
        });
      }

      fail('invalid_action', 'Unknown owner action.');
    } catch (error) {
      if (error instanceof ApiError) {
        return json({ error: { code: error.code, message: error.message } }, error.status);
      }
      return json(
        {
          error: {
            code: 'service_unavailable',
            message: 'The owner request could not finish. Please refresh and retry.',
          },
        },
        503,
      );
    }
  };
}

Deno.serve(createOwnerHandler((name: string) => Deno.env.get(name)));
