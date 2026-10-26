// LearnDrive 2.0 account and reviews API.
// User-facing account lifecycle and learner review actions only.
// Final deletion and review moderation remain admin/server responsibilities.

type Env = (name: string) => string | undefined;
type Json = Record<string, any>;

const version = '2.0.0.account.1';
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
  if (!value) fail('setup_required', 'Account services are not available yet.', 503);
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
      'X-LearnDrive-Account-Version': version,
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

  private async call(path: string, payload?: unknown): Promise<any> {
    const key = required(this.env, 'SUPABASE_SERVICE_ROLE_KEY');
    const response = await this.fetcher(
      `${required(this.env, 'SUPABASE_URL')}/rest/v1/${path}`,
      {
        method: payload === undefined ? 'GET' : 'POST',
        headers: {
          apikey: key,
          Authorization: `Bearer ${key}`,
          'Content-Type': 'application/json',
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
        // Never expose raw database responses.
      }

      const conflicts = new Map<string, [string, string, number]>([
        ['Past confirmed paid lesson required', ['review_not_eligible', 'A completed paid lesson is required before reviewing this instructor.', 409]],
        ['Instructor unavailable', ['instructor_unavailable', 'Instructor unavailable.', 409]],
        ['Learner account required', ['learner_required', 'A learner account is required.', 403]],
        ['No deletion request', ['no_deletion_request', 'There is no pending deletion request.', 409]],
        ['Account unavailable', ['account_unavailable', 'Account unavailable.', 409]],
      ]);
      const mapped = conflicts.get(message);
      if (mapped) fail(mapped[0], mapped[1], mapped[2]);

      fail('service_unavailable', 'The account service could not finish. Please retry.', 503);
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

async function currentUser(env: Env, fetcher: typeof fetch, db: Database, req: Request): Promise<Json> {
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
  id(authUser.id, 'user');

  const rows = await db.rows('profiles', {
    id: `eq.${authUser.id}`,
    select: 'role,account_status',
  });
  const profile = rows[0];
  if (!profile || !['learner', 'instructor'].includes(profile.role)) {
    fail('account_required', 'A LearnDrive account is required.', 403);
  }

  return {
    id: authUser.id,
    role: profile.role,
    account_status: profile.account_status,
  };
}

function requireRole(user: Json, role: 'learner' | 'instructor') {
  if (user.role !== role) {
    fail('role_required', `A ${role} account is required.`, 403);
  }
}

function requireActive(user: Json) {
  if (user.account_status !== 'active') {
    fail('account_closing', 'This account is not available for that action.', 409);
  }
}

export function createAccountHandler(env: Env, fetcher: typeof fetch = fetch) {
  return async (req: Request): Promise<Response> => {
    try {
      const url = new URL(req.url);
      const path = url.pathname.replace(/^\/functions\/v1/, '').replace(/\/$/, '');
      if (path !== '/account-api') {
        return json({ error: { code: 'not_found', message: 'Not found.' } }, 404);
      }
      if (req.method !== 'POST') {
        return json({ error: { code: 'method_not_allowed', message: 'Use POST.' } }, 405);
      }

      const db = new Database(env, fetcher);
      const user = await currentUser(env, fetcher, db, req);
      const input = await body(req);

      if (input.action === 'review_submit') {
        requireRole(user, 'learner');
        requireActive(user);
        if (!Number.isInteger(input.rating) || input.rating < 1 || input.rating > 5) {
          fail('invalid_request', 'Choose a rating from 1 to 5.');
        }
        const comment = input.comment ?? '';
        if (typeof comment !== 'string' || comment.trim().length > 1000) {
          fail('invalid_request', 'Review comments can be up to 1000 characters.');
        }
        const reviewId = await db.rpc('review_submit_for_learner', {
          p_learner: user.id,
          p_instructor: id(input.instructor_id, 'instructor id'),
          p_rating: input.rating,
          p_comment: comment,
        });
        return json({ id: reviewId, status: 'pending' }, 201);
      }

      if (input.action === 'reviews') {
        requireActive(user);
        const offset = input.offset ?? 0;
        if (!Number.isInteger(offset) || offset < 0 || offset > 100000) {
          fail('invalid_request', 'Invalid review offset.');
        }
        return json(await db.rpc('instructor_reviews_page', {
          p_instructor: id(input.instructor_id, 'instructor id'),
          p_offset: offset,
        }));
      }

      if (input.action === 'deletion_status') {
        const rows = await db.rows('account_deletion_requests', {
          user_id: `eq.${user.id}`,
          select: 'requested_at,due_at,status,completed_at',
        });
        return json({
          account_status: user.account_status,
          request: rows[0] ?? null,
        });
      }

      if (input.action === 'deletion_request') {
        if (user.account_status === 'deleted') {
          fail('account_unavailable', 'Account unavailable.', 409);
        }
        const request = await db.rpc('account_request_deletion_for_user', {
          p_user: user.id,
        });
        return json({
          requested: true,
          request,
        });
      }

      if (input.action === 'deletion_cancel') {
        await db.rpc('account_cancel_deletion_for_user', {
          p_user: user.id,
        });
        return json({ cancelled: true });
      }

      fail('invalid_action', 'Unknown account action.');
    } catch (error) {
      if (error instanceof ApiError) {
        return json({ error: { code: error.code, message: error.message } }, error.status);
      }
      return json(
        {
          error: {
            code: 'service_unavailable',
            message: 'The account request could not finish. Please refresh and retry.',
          },
        },
        503,
      );
    }
  };
}

Deno.serve(createAccountHandler((name: string) => Deno.env.get(name)));
