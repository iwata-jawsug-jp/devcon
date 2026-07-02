import { afterEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import { createPinia } from 'pinia';
import { QueryClient, VueQueryPlugin } from '@tanstack/vue-query';
import { createHead } from '@unhead/vue/client';
import HomeView from '../HomeView.vue';

function mountHomeView() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  return mount(HomeView, {
    global: {
      plugins: [createPinia(), createHead(), [VueQueryPlugin, { queryClient }]],
    },
  });
}

describe('HomeView', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('renders the counter and increments it through the store', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        statusText: 'OK',
        json: async () => ({ status: 'ok' }),
      }),
    );

    const wrapper = mountHomeView();
    await flushPromises();

    expect(wrapper.text()).toContain('Count: 0 (doubled: 0)');

    await wrapper.get('button').trigger('click');

    expect(wrapper.text()).toContain('Count: 1 (doubled: 2)');
  });
});
