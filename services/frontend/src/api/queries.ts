import { useQuery } from '@tanstack/vue-query';
import { apiClient } from './client';
import type { Ref } from 'vue';

/**
 * TanStack Query composables for server state. Components use these instead
 * of calling `apiClient` or `useQuery` directly, so caching/retry behavior
 * stays consistent in one place. Client-only state still goes through Pinia
 * (see src/stores/) — this file is for anything that comes from the API.
 */
export function useHealthQuery() {
  return useQuery({
    queryKey: ['health'],
    queryFn: ({ signal }) => apiClient.getHealth({ signal }),
  });
}

export function useGreetingQuery(name: Ref<string>) {
  return useQuery({
    queryKey: ['greeting', name],
    queryFn: ({ signal }) => apiClient.getGreeting(name.value, { signal }),
  });
}
