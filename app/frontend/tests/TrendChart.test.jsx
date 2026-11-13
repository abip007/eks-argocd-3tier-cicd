import React from 'react';
import { render, screen } from '@testing-library/react';
import { vi } from 'vitest';
import TrendChart from '../src/components/TrendChart';
import api from '../src/api';

vi.mock('../src/api', () => ({ default: { get: vi.fn(), post: vi.fn() } }));
// Canvas does not exist in jsdom: replace the chart with a stub that shows its data.
vi.mock('react-chartjs-2', () => ({
  Line: ({ data }) => <div data-testid="line-chart">{data.datasets[0].data.join(',')}</div>
}));

beforeEach(() => vi.spyOn(console, 'log').mockImplementation(() => {}));

describe('TrendChart', () => {
  test('shows a loading state first', () => {
    api.get.mockReturnValue(new Promise(() => {}));
    render(<TrendChart />);
    expect(screen.getByText(/loading chart/i)).toBeInTheDocument();
  });

  test('draws the average BMI per day', async () => {
    api.get.mockResolvedValue({ data: { rows: [
      { day: '2026-01-01', avg_bmi: '22.50' },
      { day: '2026-01-02', avg_bmi: '22.10' }
    ] } });
    render(<TrendChart />);
    expect(await screen.findByTestId('line-chart')).toHaveTextContent('22.5,22.1');
    expect(api.get).toHaveBeenCalledWith('/measurements/trends');
  });

  test('shows an empty state when there is no data', async () => {
    api.get.mockResolvedValue({ data: { rows: [] } });
    render(<TrendChart />);
    expect(await screen.findByText(/no trend data available/i)).toBeInTheDocument();
  });

  test('shows an error when the request fails', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    api.get.mockRejectedValue(new Error('boom'));
    render(<TrendChart />);
    expect(await screen.findByText('Failed to load trend data')).toBeInTheDocument();
  });
});
