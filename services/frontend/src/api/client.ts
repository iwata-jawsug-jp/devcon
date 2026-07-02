import type { paths } from './schema';

/**
 * Base path for all API calls. In dev the Vite server proxies `/api` to the
 * backend (see vite.config.ts). Override via the `VITE_API_BASE` env var.
 */
const API_BASE = import.meta.env.VITE_API_BASE ?? '/api';

export interface HealthResponse {
  status: string;
}

/**
 * The single, typed entry point for talking to the backend API.
 *
 * Components MUST go through this client rather than calling `fetch` directly.
 * `paths` is imported from the generated `schema.ts` so request/response types
 * can be tightened as the OpenAPI schema grows.
 */
export class ApiClient {
  constructor(private readonly baseUrl: string = API_BASE) {}

  private async request<T>(path: string, init?: RequestInit): Promise<T> {
    const response = await fetch(`${this.baseUrl}${path}`, {
      headers: { Accept: 'application/json' },
      ...init,
    });
    if (!response.ok) {
      throw new Error(`API request failed: ${response.status} ${response.statusText}`);
    }
    return (await response.json()) as T;
  }

  /** GET /api/health -> { status: "ok" } */
  getHealth(): Promise<HealthResponse> {
    return this.request<HealthResponse>('/health');
  }
}

// Reference the generated schema so its types stay wired into the client.
export type ApiPaths = paths;

export const apiClient = new ApiClient();
