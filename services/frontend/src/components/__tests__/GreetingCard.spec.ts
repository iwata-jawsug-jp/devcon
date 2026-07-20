import { afterEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { QueryClient, VueQueryPlugin } from '@tanstack/vue-query';
import GreetingCard from '../GreetingCard.vue';

function mountWithQueryClient() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  return mount(GreetingCard, {
    global: {
      plugins: [[VueQueryPlugin, { queryClient }]],
    },
  });
}

describe('GreetingCard', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('renders the greeting returned by the API', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        statusText: 'OK',
        json: async () => ({ message: 'Hello, JAWS-UG!', name: 'JAWS-UG' }),
      }),
    );

    const wrapper = mountWithQueryClient();
    await flushPromises();

    expect(wrapper.get('[data-testid="greeting-message"]').text()).toBe('Hello, JAWS-UG!');
  });

  it('shows an error state when the request fails', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('network down')));

    const wrapper = mountWithQueryClient();
    await flushPromises();

    expect(wrapper.text()).toContain('エラーが発生しました');
  });
});
