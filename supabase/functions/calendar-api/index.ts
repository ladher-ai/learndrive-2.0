// LearnDrive 2.0 internal calendar API.
// The LearnDrive diary is authoritative. No external calendar providers.

type Env = (name: string) => string | undefined;
type Json = Record<string, any>;

const version = '2.0.0.calendar.1';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const blockTypes = new Set(['unavailable', 'appointment', 'holiday', 'break', 'other']);

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
  if (!value) fail('setup_required', 'Calendar setup is not available yet.', 503);
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
      'X-LearnDrive-Calendar-Version': version,
    },
  });
}

async function readBody(req: Request, max = 16384): Promise<Json> {
  if (Number(req.headers.get('content-length') ?? 0) > max) {
    fail('invalid_request', 'Request too large.', 413);
  }
  const text = await req.text();
  if (text.length > max) fail('invalid_request', 'Request too large.', 413);
  let value: unknown;
  try {
    value = JSON.parse(text);
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

  private async call(path: string, body?: unknown): Promise<any> {
    const key = required(this.env, 'SUPABASE_SERVICE_ROLE_KEY');
    const response = await this.fetcher(
      `${required(this.env, 'SUPABASE_URL')}/rest/v1/${path}`,
      {
        method: body === undefined ? 'GET' : 'POST',
        headers: {
          apikey: key,
          Authorization: `Bearer ${key}`,
          'Content-Type': 'application/json',
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(12000),
        redirect: 'error',
      },
    );

    if (!response.ok) {
      let message = '';
      try {
        message = (await response.json()).message ?? '';
      } catch {
        // Never return a raw database response.
      }
      const conflictMessages = new Set([
        'Working hours overlap',
        'An existing lesson overlaps these dates',
        'This time is unavailable',
        'Learner already has a lesson at this time',
        'Outside instructor lesson hours',
      ]);
      if (conflictMessages.has(message)) {
        fail('calendar_conflict', message + '.', 409);
      }
      if (message === 'Instructor unavailable' || message === 'Instructor required') {
        fail('instructor_unavailable', 'Instructor unavailable.', 409);
      }
      fail('service_unavailable', 'The calendar service could not finish. Please retry.', 503);
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
    fail('account_closing', 'This account is not available for new calendar changes.', 409);
  }
}

function validDate(value: unknown): string {
  if (typeof value !== 'string' || !Number.isFinite(Date.parse(value))) {
    fail('invalid_request', 'Choose valid dates.');
  }
  return value;
}

export function createCalendarHandler(env: Env, fetcher: typeof fetch = fetch) {
  return async (req: Request): Promise<Response> => {
    try {
      const url = new URL(req.url);
      const path = url.pathname.replace(/^\/functions\/v1/, '').replace(/\/$/, '');
      if (path !== '/calendar-api') {
        return json({ error: { code: 'not_found', message: 'Not found.' } }, 404);
      }
      if (req.method !== 'POST') {
        return json({ error: { code: 'method_not_allowed', message: 'Use POST.' } }, 405);
      }

      const db = new Database(env, fetcher);
      const user = await currentUser(env, fetcher, db, req);
      const input = await readBody(req);

      if (input.action === 'status') {
        requireRole(user, 'instructor');
        return json(await db.rpc('calendar_status', { p_user: user.id }));
      }

      if (input.action === 'save_hours') {
        requireRole(user, 'instructor');
        requireActive(user);
        if (
          !Array.isArray(input.hours) ||
          input.hours.length > 21 ||
          input.hours.some((h: any) =>
            !h ||
            ![h.weekday, h.start_minute, h.end_minute].every(Number.isInteger)
          )
        ) {
          fail('invalid_request', 'Check your lesson hours.');
        }
        await db.rpc('calendar_save_hours', { p_user: user.id, p_hours: input.hours });
        return json({ saved: true });
      }

      if (input.action === 'add_block') {
        requireRole(user, 'instructor');
        requireActive(user);
        const type = input.type ?? 'unavailable';
        if (typeof type !== 'string' || !blockTypes.has(type)) {
          fail('invalid_request', 'Choose a valid block type.');
        }
        if (
          input.title !== undefined &&
          input.title !== null &&
          (typeof input.title !== 'string' || input.title.trim().length > 120)
        ) {
          fail('invalid_request', 'Block title is too long.');
        }
        const blockId = await db.rpc('calendar_add_block', {
          p_user: user.id,
          p_start: validDate(input.start),
          p_end: validDate(input.end),
          p_type: type,
          p_title: typeof input.title === 'string' ? input.title : null,
        });
        return json({ id: blockId }, 201);
      }

      if (input.action === 'remove_block') {
        requireRole(user, 'instructor');
        requireActive(user);
        await db.rpc('calendar_remove_block', {
          p_user: user.id,
          p_id: id(input.id, 'block id'),
        });
        return json({ removed: true });
      }

      if (input.action === 'availability') {
        requireActive(user);
        const instructor = id(input.instructor_id, 'instructor id');
        const availability = await db.rpc('calendar_availability', {
          p_instructor: instructor,
        });
        return json(availability);
      }

      fail('invalid_action', 'Unknown calendar action.');
    } catch (error) {
      if (error instanceof ApiError) {
        return json({ error: { code: error.code, message: error.message } }, error.status);
      }
      return json(
        {
          error: {
            code: 'service_unavailable',
            message: 'The calendar request could not finish. Please refresh and retry.',
          },
        },
        503,
      );
    }
  };
}

Deno.serve(createCalendarHandler((name: string) => Deno.env.get(name)));
