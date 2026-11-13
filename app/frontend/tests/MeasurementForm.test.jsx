import React from 'react';
import { act, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { vi } from 'vitest';
import MeasurementForm from '../src/components/MeasurementForm';
import api from '../src/api';

vi.mock('../src/api', () => ({ default: { get: vi.fn(), post: vi.fn() } }));

describe('MeasurementForm', () => {
  test('renders every field with sensible defaults', () => {
    render(<MeasurementForm />);
    expect(screen.getByLabelText(/weight/i)).toHaveValue(70);
    expect(screen.getByLabelText(/height/i)).toHaveValue(175);
    expect(screen.getByLabelText(/age/i)).toHaveValue(30);
    expect(screen.getByLabelText(/biological sex/i)).toHaveValue('male');
    expect(screen.getByLabelText(/activity level/i)).toHaveValue('moderate');
    expect(screen.getByLabelText(/measurement date/i)).toHaveValue(new Date().toISOString().split('T')[0]);
  });

  test('posts the edited values, shows success and calls onSaved', async () => {
    const user = userEvent.setup();
    const onSaved = vi.fn();
    api.post.mockResolvedValue({ data: {} });
    render(<MeasurementForm onSaved={onSaved} />);

    await user.clear(screen.getByLabelText(/weight/i));
    await user.type(screen.getByLabelText(/weight/i), '82');
    await user.clear(screen.getByLabelText(/height/i));
    await user.type(screen.getByLabelText(/height/i), '180');
    await user.clear(screen.getByLabelText(/age/i));
    await user.type(screen.getByLabelText(/age/i), '41');
    await user.selectOptions(screen.getByLabelText(/biological sex/i), 'female');
    await user.selectOptions(screen.getByLabelText(/activity level/i), 'active');
    await user.clear(screen.getByLabelText(/measurement date/i));
    await user.type(screen.getByLabelText(/measurement date/i), '2026-01-15');
    await user.click(screen.getByRole('button', { name: /save measurement/i }));

    expect(api.post).toHaveBeenCalledWith('/measurements', {
      weightKg: 82, heightCm: 180, age: 41, sex: 'female', activity: 'active', measurementDate: '2026-01-15'
    });
    expect(await screen.findByText(/saved successfully/i)).toBeInTheDocument();
    expect(onSaved).toHaveBeenCalledTimes(1);
  });

  test('works without an onSaved callback', async () => {
    api.post.mockResolvedValue({ data: {} });
    render(<MeasurementForm />);
    await userEvent.click(screen.getByRole('button', { name: /save measurement/i }));
    expect(await screen.findByText(/saved successfully/i)).toBeInTheDocument();
  });

  test('hides the success message after 3 seconds', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    api.post.mockResolvedValue({ data: {} });
    render(<MeasurementForm />);
    await userEvent.click(screen.getByRole('button', { name: /save measurement/i }));
    expect(await screen.findByText(/saved successfully/i)).toBeInTheDocument();
    await act(async () => { await vi.advanceTimersByTimeAsync(3100); });
    expect(screen.queryByText(/saved successfully/i)).not.toBeInTheDocument();
    vi.useRealTimers();
  });

  test('shows the API error message', async () => {
    api.post.mockRejectedValue({ response: { data: { error: 'Missing required fields' } } });
    render(<MeasurementForm />);
    await userEvent.click(screen.getByRole('button', { name: /save measurement/i }));
    expect(await screen.findByText('Missing required fields')).toBeInTheDocument();
  });

  test('shows a generic error when the API gives no message', async () => {
    api.post.mockRejectedValue(new Error('Network Error'));
    render(<MeasurementForm />);
    await userEvent.click(screen.getByRole('button', { name: /save measurement/i }));
    expect(await screen.findByText('Failed to save measurement')).toBeInTheDocument();
  });

  test('disables the button while saving', async () => {
    let resolve;
    api.post.mockReturnValue(new Promise((r) => { resolve = r; }));
    render(<MeasurementForm />);
    await userEvent.click(screen.getByRole('button', { name: /save measurement/i }));
    expect(screen.getByRole('button', { name: /saving/i })).toBeDisabled();
    resolve({ data: {} });
    expect(await screen.findByRole('button', { name: /save measurement/i })).toBeEnabled();
  });
});
