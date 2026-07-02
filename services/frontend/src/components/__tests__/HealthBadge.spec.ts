import { afterEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { QueryClient, VueQueryPlugin } from '@tanstack/vue-query';
import HealthBadge from '../HealthBadge.vue';

function mountWithQueryClient() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  return mount(HealthBadge, {
    global: {
      plugins: [[VueQueryPlugin, { queryClient }]],
    },
  });
}

describe('HealthBadge', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('renders the health status returned by the API', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        statusText: 'OK',
        json: async () => ({ status: 'ok' }),
      }),
    );

    const wrapper = mountWithQueryClient();
    await flushPromises();

    expect(wrapper.text()).toContain('API: ok');
    expect(wrapper.get('.health-badge').attributes('data-status')).toBe('ok');
  });

  it('shows an error state when the request fails', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('network down')));

    const wrapper = mountWithQueryClient();
    await flushPromises();

    expect(wrapper.text()).toContain('API: error');
  });
});
