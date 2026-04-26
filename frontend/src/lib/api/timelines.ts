import { api } from './client.js';
import type { Post, PaginatedResponse } from './types.js';

interface TimelineParams {
  cursor?: string;
  limit?: string;
  // Backend cursor params — pages by row-tuple compare on
  // (timestamp, id). Earlier this helper only forwarded `cursor`
  // and `limit`, so any caller that set `max_id` had it silently
  // dropped — the server returned the same first page over and
  // over and home pagination froze at 20.
  max_id?: string;
  min_id?: string;
  since_id?: string;
  // Home-feed tab toggle: "true" → algorithmic, "trending" → top.
  algorithm?: string;
}

function buildParams(params?: TimelineParams | Record<string, string>): Record<string, string> {
  if (!params) return {};
  const query: Record<string, string> = {};
  for (const [k, v] of Object.entries(params)) {
    if (typeof v === 'string' && v.length > 0) query[k] = v;
  }
  return query;
}

export function getHomeTimeline(params?: TimelineParams): Promise<PaginatedResponse<Post>> {
  return api.get('/api/v1/timelines/home', buildParams(params));
}

export function getPublicTimeline(params?: TimelineParams & { local?: boolean }): Promise<PaginatedResponse<Post>> {
  const query = buildParams(params);
  if (params?.local) query.local = 'true';
  return api.get('/api/v1/timelines/public', query);
}

export function getHashtagTimeline(tag: string, params?: TimelineParams): Promise<PaginatedResponse<Post>> {
  return api.get(`/api/v1/timelines/tag/${encodeURIComponent(tag)}`, buildParams(params));
}

export function getListTimeline(listId: string, params?: TimelineParams): Promise<PaginatedResponse<Post>> {
  return api.get(`/api/v1/timelines/list/${listId}`, buildParams(params));
}

export function getGroupTimeline(groupId: string, params?: TimelineParams): Promise<PaginatedResponse<Post>> {
  return api.get(`/api/v1/timelines/group/${groupId}`, buildParams(params));
}

export function getBookmarks(params?: TimelineParams): Promise<PaginatedResponse<Post>> {
  return api.get('/api/v1/bookmarks', buildParams(params));
}
