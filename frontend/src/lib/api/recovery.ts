import { api } from './client.js';

export interface RecoveryCodeStatus {
  enabled: boolean;
  generated_at: string | null;
  last_used_at: string | null;
}

export interface GeneratedRecoveryCode {
  recovery_code: string;
  generated_at: string;
  warning: string;
}

export interface RecoverResponse {
  status: 'ok';
  message: 'auth.recovered';
  new_recovery_code: string;
}

export function getRecoveryCodeStatus(): Promise<RecoveryCodeStatus> {
  return api.get('/api/v1/accounts/recovery_code');
}

export function generateRecoveryCode(password: string): Promise<GeneratedRecoveryCode> {
  return api.post('/api/v1/accounts/recovery_code', { password });
}

export function deleteRecoveryCode(password: string): Promise<{ status: 'ok' }> {
  return api.delete('/api/v1/accounts/recovery_code', { password });
}

export function recoverAccount(input: {
  handle: string;
  recovery_code: string;
  new_password: string;
  new_password_confirmation: string;
}): Promise<RecoverResponse> {
  return api.post('/api/v1/auth/recover', input);
}
