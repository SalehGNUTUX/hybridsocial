import { api } from './client.js';
import type { Group, Identity, Post, PaginatedResponse } from './types.js';

export interface GroupDetail extends Group {
  rules: string[];
  join_policy: 'open' | 'screening' | 'approval' | 'invite_only';
  pending_request: boolean;
}

export interface GroupMember {
  // Always present from the backend (serialize_member returns member.id); it's
  // the membership id used for role/ban/remove endpoints (/members/:mid).
  id: string;
  identity_id?: string;
  account: Identity;
  role: 'owner' | 'admin' | 'moderator' | 'member';
  joined_at: string;
  status?: 'pending' | 'approved' | 'rejected' | 'banned';
  /**
   * Status with a lapsed timed ban already taken into account — prefer this
   * over `status` for display. The row isn't rewritten until the expiry
   * sweeper runs, so `status` can read `banned` for a ban that is no longer
   * being enforced.
   */
  effective_status?: 'pending' | 'approved' | 'rejected' | 'banned';
  /** Actions currently withheld. Already excludes lapsed sanctions. */
  restrictions?: GroupRestriction[];
  /** When the sanction lapses; null = permanent. */
  restricted_until?: string | null;
  restriction_reason?: string | null;
}

export interface GroupApplication {
  id: string;
  account: Identity;
  answers: { question: string; answer: string }[];
  created_at: string;
}

export interface GroupSettings {
  name?: string;
  description?: string;
  visibility?: 'public' | 'private' | 'local_only';
  join_policy?: 'open' | 'screening' | 'approval' | 'invite_only';
  avatar_url?: string | null;
  header_url?: string | null;
  rules?: string[];
}

export interface GroupInvite {
  id: string;
  group_id: string;
  invited_by: string;
  invited_id: string;
  invited: Identity | null;
  inviter: Identity | null;
  status: 'pending' | 'accepted' | 'declined';
  created_at: string;
}

export function getGroups(filter: 'member' | 'discover' = 'member', cursor?: string): Promise<PaginatedResponse<Group>> {
  const params: Record<string, string> = { filter };
  if (cursor) params.cursor = cursor;
  return api.get('/api/v1/groups', params);
}

export function getGroup(id: string): Promise<GroupDetail> {
  return api.get(`/api/v1/groups/${id}`);
}

// Each question is stored as an object on the backend (jsonb array of maps).
// The settings UI works with plain strings and converts at the call site.
export interface ScreeningQuestion {
  text: string;
}

export interface GroupScreening {
  questions: ScreeningQuestion[];
  min_account_age_days: number;
  require_profile_image: boolean;
}

export function getGroupScreening(id: string): Promise<GroupScreening> {
  return api.get(`/api/v1/groups/${id}/screening`);
}

// Screening config has its own endpoint (PATCH /groups/:id/screening). The
// generic updateGroup (PATCH /groups/:id) does NOT persist screening — the
// backend's group changeset drops the key — so it must be saved separately.
export function updateGroupScreening(id: string, data: GroupScreening): Promise<GroupScreening> {
  return api.patch(`/api/v1/groups/${id}/screening`, data);
}

export type FederationMode = 'local_only' | 'public_federated';

export function createGroup(data: {
  name: string;
  description?: string;
  visibility?: string;
  join_policy?: string;
  federation_mode?: FederationMode;
}): Promise<GroupDetail> {
  return api.post('/api/v1/groups', data);
}

export function updateGroup(id: string, data: GroupSettings): Promise<GroupDetail> {
  return api.patch(`/api/v1/groups/${id}`, data);
}

// `reason` is only meaningful for a staff (instance-moderator) takedown of a
// group they don't own: the backend opens a takedown + notifies the owner
// (who can then appeal) when a staff actor deletes with a reason. An owner
// deleting their own group passes none.
export function deleteGroup(id: string, opts?: { reason?: string }): Promise<void> {
  const body = opts?.reason ? { reason: opts.reason } : undefined;
  return api.delete(`/api/v1/groups/${id}`, body);
}

// Staff-only: soft-deleted groups (from a takedown or owner deletion) and
// restoring one — the moderator side of the takedown appeal loop.
export function listDeletedGroups(): Promise<Group[]> {
  return api.get<Group[]>('/api/v1/groups/deleted');
}

export function restoreGroup(id: string): Promise<Group> {
  return api.post<Group>(`/api/v1/groups/${id}/restore`);
}

export function joinGroup(id: string): Promise<{ status: 'joined' | 'pending' }> {
  return api.post(`/api/v1/groups/${id}/join`);
}

export function leaveGroup(id: string): Promise<void> {
  return api.post(`/api/v1/groups/${id}/leave`);
}

export function getGroupMembers(id: string, cursor?: string): Promise<PaginatedResponse<GroupMember>> {
  const params: Record<string, string> = {};
  if (cursor) params.cursor = cursor;
  return api.get(`/api/v1/groups/${id}/members`, params);
}

export function getGroupTimeline(id: string, cursor?: string): Promise<PaginatedResponse<Post>> {
  const params: Record<string, string> = {};
  if (cursor) params.cursor = cursor;
  return api.get(`/api/v1/timelines/group/${id}`, params);
}

export function getGroupApplications(id: string, cursor?: string): Promise<PaginatedResponse<GroupApplication>> {
  const params: Record<string, string> = {};
  if (cursor) params.cursor = cursor;
  return api.get(`/api/v1/groups/${id}/applications`, params);
}

export function approveApplication(groupId: string, applicationId: string): Promise<void> {
  return api.post(`/api/v1/groups/${groupId}/applications/${applicationId}/approve`);
}

export function rejectApplication(groupId: string, applicationId: string): Promise<void> {
  return api.post(`/api/v1/groups/${groupId}/applications/${applicationId}/reject`);
}

export function inviteToGroup(groupId: string, accountId: string): Promise<void> {
  // Backend reads `invited_id` (matches the GroupInvite schema column);
  // sending `account_id` made every invite fail validation silently
  // since the changeset's validate_required([:invited_id]) kicked in.
  return api.post(`/api/v1/groups/${groupId}/invite`, { invited_id: accountId });
}

export function listGroupInvites(groupId: string): Promise<GroupInvite[]> {
  return api.get(`/api/v1/groups/${groupId}/invites`);
}

export function cancelGroupInvite(groupId: string, inviteId: string): Promise<void> {
  return api.delete(`/api/v1/groups/${groupId}/invites/${inviteId}`);
}

// The `:mid` path param is the GroupMember membership id (member.id), NOT the
// account id — get_member_by_id looks up by GroupMember.id on the backend.
export function updateMemberRole(groupId: string, memberId: string, role: string): Promise<void> {
  return api.patch(`/api/v1/groups/${groupId}/members/${memberId}`, { role });
}

/**
 * Full ban. This POSTed to `/members/:mid/ban`, which has never existed in the
 * router — so banning from the UI 404'd from all three call sites. The real
 * endpoint is DELETE on the member, which the backend maps to `ban_member/3`.
 */
export function banMember(groupId: string, memberId: string): Promise<void> {
  return api.delete(`/api/v1/groups/${groupId}/members/${memberId}`);
}

/** Which actions a partial ban can withhold. Must match the backend's list. */
export type GroupRestriction = 'post' | 'comment' | 'react';

/**
 * Partial or timed ban.
 *
 * `restrictions` withholds specific actions while leaving the member in the
 * group; `full` bans outright. `until` (ISO8601) makes it lapse on its own —
 * omit for permanent. Passing neither restrictions nor `full` clears it.
 */
export function restrictMember(
  groupId: string,
  memberId: string,
  opts: {
    restrictions?: GroupRestriction[];
    full?: boolean;
    until?: string | null;
    reason?: string;
  },
): Promise<GroupMember> {
  return api.post(`/api/v1/groups/${groupId}/members/${memberId}/restrict`, {
    restrictions: opts.restrictions ?? [],
    full: opts.full ?? false,
    until: opts.until ?? null,
    reason: opts.reason ?? null,
  });
}

/** Lift any sanction, returning the member to good standing. */
export function unrestrictMember(groupId: string, memberId: string): Promise<GroupMember> {
  return api.delete(`/api/v1/groups/${groupId}/members/${memberId}/restrict`);
}

export function searchGroups(query: string, cursor?: string): Promise<PaginatedResponse<Group>> {
  const params: Record<string, string> = { q: query };
  if (cursor) params.cursor = cursor;
  return api.get('/api/v1/groups/search', params);
}

/** A report routed to a group's own moderation queue (#86). */
export interface GroupReport {
  id: string;
  category: string;
  description: string | null;
  status: string;
  tier: 'group' | 'instance';
  target_type: string | null;
  target_id: string | null;
  /** Set once it has gone to instance staff, by escalation or by category. */
  escalated_at: string | null;
  created_at: string;
  reporter: { id: string; handle: string; display_name: string | null; avatar_url: string | null } | null;
  reported: { id: string; handle: string; display_name: string | null; avatar_url: string | null } | null;
}

/** The group's own moderation queue. Moderator-tier; 403 otherwise. */
export function getGroupReports(groupId: string, status?: string): Promise<GroupReport[]> {
  return api.get(`/api/v1/groups/${groupId}/reports`, status ? { status } : undefined);
}

/**
 * Hand a group report up to instance staff. Open to the reporter and to the
 * group's own moderators — a group mod who is out of their depth shouldn't
 * need to make an accusation to get help.
 */
export function escalateReport(reportId: string): Promise<{ id: string; tier: string }> {
  return api.post(`/api/v1/reports/${reportId}/escalate`);
}
