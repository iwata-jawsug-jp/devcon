import { afterEach, describe, expect, it, vi } from 'vitest';
import { flushPromises, mount } from '@vue/test-utils';
import HealthBadge from '../HealthBadge.vue';

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

    const wrapper = mount(HealthBadge);
    await flushPromises();

    expect(wrapper.text()).toContain('API: ok');
    expect(wrapper.get('.health-badge').attributes('data-status')).toBe('ok');
  });

  it('shows an error state when the request fails', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('network down')));

    const wrapper = mount(HealthBadge);
    await flushPromises();

    expect(wrapper.text()).toContain('API: error');
  });
});
