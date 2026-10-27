type RuntimeEnv = Record<string, string | undefined>;

export function resolveRemoteApiUrl(env: RuntimeEnv): string {
  const explicitRemote = env.REMOTE_API_URL?.trim();
  if (explicitRemote) return explicitRemote;

  const publicApi = env.NEXT_PUBLIC_API_URL?.trim();
  if (publicApi) return publicApi;

  // `PORT` is deliberately absent: Next.js assigns `process.env.PORT` the
  // web server's own listening port before next.config.ts is evaluated, so
  // inside a Next process it never carries the backend's port. Reading it
  // made the SSR proxy forward `/api` and `/auth` calls back to the web app
  // itself — every API request died with a socket hang up (HTTP 500) and
  // the console could never load. The backend port comes from the explicit
  // aliases, or from the repo-root .env, which next.config.ts reads
  // separately for exactly this reason.
  const port =
    env.BACKEND_PORT?.trim() ||
    env.API_PORT?.trim() ||
    env.SERVER_PORT?.trim();
  if (port) return `http://localhost:${port}`;

  return "http://localhost:8080";
}
