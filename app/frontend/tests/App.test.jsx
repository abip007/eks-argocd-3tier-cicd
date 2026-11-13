import React from 'react';
import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { vi } from 'vitest';
import App from '../src/App';
import api from '../src/api';

vi.mock('../src/api', () => ({ default: { get: vi.fn(), post: vi.fn() } }));
vi.mock('react-chartjs-2', () => ({ Line: () => <div data-testid="line-chart" /> }));

const row = (id, bmi) => ({
  id, bmi, bmi_category: 'Normal', bmr: 1649, daily_calories: 2556,
  measurement_date: '2026-01-15T00:00:00.000Z', created_at: '2026-01-15T08:00:00.000Z'
});

function mockApi(rows) {
  api.get.mockImplementation((url) =>
    url === '/measurements' ? Promise.resolve({ data: { rows } }) : Promise.resolve({ data: { rows: [] } }));
}

beforeEach(() => vi.spyOn(console, 'log').mockImplementation(() => {}));

describe('App', () => {
  test('shows the header and an empty state when there are no measurements', async () => {
    mockApi([]);
    render(<App />);
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent(/BMI & Health Tracker/);
    expect(await screen.findByText(/no measurements yet/i)).toBeInTheDocument();
  });

  test('shows stats from the latest measurement and lists recent ones', async () => {
    mockApi([row(2, 23.1), row(1, 22.9)]);
    render(<App />);
    const list = await screen.findByRole('list');
    expect(within(list).getAllByRole('listitem')).toHaveLength(2);
    expect(screen.getByText('Current BMI').previousSibling).toHaveTextContent('23.1');
    expect(screen.getByText('Total Records').previousSibling).toHaveTextContent('2');
  });

  test('lists at most 10 measurements', async () => {
    mockApi(Array.from({ length: 12 }, (_, i) => row(i + 1, 22)));
    render(<App />);
    const list = await screen.findByRole('list');
    expect(within(list).getAllByRole('listitem')).toHaveLength(10);
  });

  test('falls back to created_at when measurement_date is missing', async () => {
    mockApi([{ ...row(1, 22), measurement_date: null }]);
    render(<App />);
    expect(await screen.findByText(/Jan 15, 2026/)).toBeInTheDocument();
  });

  test('shows the API error', async () => {
    api.get.mockImplementation((url) =>
      url === '/measurements'
        ? Promise.reject({ response: { data: { error: 'Failed to fetch measurements' } } })
        : Promise.resolve({ data: { rows: [] } }));
    render(<App />);
    expect(await screen.findByText('Failed to fetch measurements')).toBeInTheDocument();
  });

  test('shows a generic error when the API gives no message', async () => {
    api.get.mockImplementation((url) =>
      url === '/measurements' ? Promise.reject(new Error('Network Error')) : Promise.resolve({ data: { rows: [] } }));
    render(<App />);
    expect(await screen.findByText('Failed to load measurements')).toBeInTheDocument();
  });

  test('reloads the list after a measurement is saved', async () => {
    mockApi([]);
    api.post.mockResolvedValue({ data: {} });
    render(<App />);
    await screen.findByText(/no measurements yet/i);
    const before = api.get.mock.calls.filter(([u]) => u === '/measurements').length;
    await userEvent.click(screen.getByRole('button', { name: /save measurement/i }));
    await screen.findByText(/saved successfully/i);
    expect(api.get.mock.calls.filter(([u]) => u === '/measurements').length).toBe(before + 1);
  });
});
