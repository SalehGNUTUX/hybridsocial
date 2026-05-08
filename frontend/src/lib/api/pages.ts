import { api } from './client.js';

export interface PageRoleIdentity {
  id: string;
  handle: string;
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

export function deletePage(id: string): Promise<void> {
  return api.delete(`/api/v1/pages/${id}`);
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
