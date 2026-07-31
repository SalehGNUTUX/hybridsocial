import { api } from './client.js';

// A moderation takedown the current user owns — surfaced so they can see
// why their content was removed and appeal it before the 60-day purge.
// Contract mirrors AppealController.serialize_takedown/1.
export type TakedownTargetType = 'group' | 'page' | 'post' | 'media' | 'account_badge';
export type TakedownStatus = 'active' | 'appealed' | 'restored' | 'purged';

export interface Takedown {
  id: string;
  target_type: TakedownTargetType;
  target_id: string;
  reason: string | null;
  category: string | null;
  status: TakedownStatus;
  /** ISO timestamp after which an un-appealed takedown is permanently purged. */
  purge_after: string | null;
  created_at: string;
}

// The appeal row created by POST /takedowns/:id/appeal (Appeal serializer).
export interface TakedownAppeal {
  id: string;
  identity_id: string;
  action_type: string;
  reason: string | null;
  status: string;
  reviewed_by: string | null;
  reviewed_at: string | null;
  response: string | null;
  takedown_id: string | null;
  created_at: string;
}

export function getMyTakedowns(): Promise<Takedown[]> {
  return api.get<{ data: Takedown[] }>('/api/v1/takedowns').then((r) => r.data);
}

export function appealTakedown(id: string, reason: string): Promise<TakedownAppeal> {
  return api
    .post<{ data: TakedownAppeal }>(`/api/v1/takedowns/${id}/appeal`, { reason })
    .then((r) => r.data);
}
