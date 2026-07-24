import { api } from './client.js';

export interface PageRoleIdentity {
  id: string;
  handle: string;
  // Webfinger form. The backend serializer always sets this now;
  // `string | null` keeps older cached payloads parseable.
  acct?: string | null;
  display_name: string | null;
  avatar_url: string | null;
}

export interface PageRole {
  id: string;
  organization_id: string;
  identity_id: string;
  role: 'admin' | 'editor' | 'moderator';
  granted_by: string | null;
  created_at: string;
  identity: PageRoleIdentity | null;
}

export interface PageInvite {
  id: string;
  page_id: string;
  invited_by: string;
  invited_id: string;
  invited: PageRoleIdentity | null;
  inviter: PageRoleIdentity | null;
  status: 'pending' | 'accepted' | 'declined';
  created_at: string;
}

// `any` here matches the existing call sites in /pages and /pages/[id]
// — they treat the response as a free-form object. Tightening these
// would cascade into both pages, which is out of scope for the
// roles/invites feature.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function getPages(): Promise<any[]> {
  return api.get('/api/v1/pages');
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function createPage(data: any): Promise<any> {
  return api.post('/api/v1/pages', data);
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function getPage(id: string): Promise<any> {
  return api.get(`/api/v1/pages/${id}`);
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function updatePage(id: string, data: any): Promise<any> {
  return api.patch(`/api/v1/pages/${id}`, data);
}

// As with groups: a staff takedown of a page they don't own, with a `reason`,
// opens a takedown + notifies the owner (appealable). An owner deleting their
// own page passes none.
export function deletePage(id: string, opts?: { reason?: string }): Promise<void> {
  const body = opts?.reason ? { reason: opts.reason } : undefined;
  return api.delete(`/api/v1/pages/${id}`, body);
}

// Staff-only: soft-deleted pages and restoring one (moderator side of the
// takedown appeal loop). Loosely typed to match the rest of this module.
export function listDeletedPages(): Promise<any[]> {
  return api.get<any[]>('/api/v1/pages/deleted');
}

export function restorePage(id: string): Promise<any> {
  return api.post<any>(`/api/v1/pages/${id}/restore`);
}

// --- Roles ---

export function getPageRoles(id: string): Promise<PageRole[]> {
  return api.get(`/api/v1/pages/${id}/roles`);
}

export function addPageRole(
  id: string,
  identityId: string,
  role: PageRole['role'],
): Promise<PageRole> {
  return api.post(`/api/v1/pages/${id}/roles`, { identity_id: identityId, role });
}

export function removePageRole(id: string, roleId: string): Promise<void> {
  return api.delete(`/api/v1/pages/${id}/roles/${roleId}`);
}

// --- Invites ---

export function invitePageManager(id: string, invitedId: string): Promise<PageInvite> {
  return api.post(`/api/v1/pages/${id}/invite`, { invited_id: invitedId });
}

export function listMyPageInvites(): Promise<PageInvite[]> {
  return api.get('/api/v1/pages/invites');
}

export function acceptPageInvite(inviteId: string): Promise<PageInvite> {
  return api.post(`/api/v1/pages/invites/${inviteId}/accept`);
}

export function declinePageInvite(inviteId: string): Promise<PageInvite> {
  return api.post(`/api/v1/pages/invites/${inviteId}/decline`);
}

export function listPageInvitesSent(pageId: string): Promise<PageInvite[]> {
  return api.get(`/api/v1/pages/${pageId}/invites`);
}

export function cancelPageInvite(pageId: string, inviteId: string): Promise<void> {
  return api.delete(`/api/v1/pages/${pageId}/invites/${inviteId}`);
}
