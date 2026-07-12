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

export interface RecoverValidateResponse {
  status: 'ok';
  recovery_token: string;
  expires_in: number;
}

export interface RecoverCompleteResponse {
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

export function validateRecovery(input: {
  handle: string;
  recovery_code: string;
  otp_code: string;
  current_email: string;
  pow_prefix?: string;
  pow_nonce?: string;
  captcha_token?: string;
  cf_turnstile_token?: string;
}): Promise<RecoverValidateResponse> {
  return api.post('/api/v1/auth/recover/validate', input);
}

export function completeRecovery(input: {
  recovery_token: string;
  new_email: string;
  new_password: string;
  new_password_confirmation: string;
}): Promise<RecoverCompleteResponse> {
  return api.post('/api/v1/auth/recover/complete', input);
}
