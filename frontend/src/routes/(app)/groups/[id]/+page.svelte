<script lang="ts">
  import { instanceName } from '$lib/stores/instance.js';
  import { onMount } from 'svelte';
  import { page } from '$app/state';
  import { goto } from '$app/navigation';
  import { get } from 'svelte/store';
  import type { Post } from '$lib/api/types.js';
  import type { GroupDetail, GroupMember } from '$lib/api/groups.js';
  import { getGroup, getGroupTimeline, getGroupMembers, joinGroup, leaveGroup, updateMemberRole, banMember } from '$lib/api/groups.js';
  import { authStore, isStaffMember } from '$lib/stores/auth.js';
  import EntityHeader from '$lib/components/entity/EntityHeader.svelte';
  import GroupManageModal from '$lib/components/group/GroupManageModal.svelte';
  import ComposerTrigger from '$lib/components/post/ComposerTrigger.svelte';
  import MediaGrid from '$lib/components/feed/MediaGrid.svelte';
  import { addToast } from '$lib/stores/toast.js';
  import Tabs from '$lib/components/ui/Tabs.svelte';
  import FeedList from '$lib/components/feed/FeedList.svelte';
  import Avatar from '$lib/components/ui/Avatar.svelte';
  import Spinner from '$lib/components/ui/Spinner.svelte';
  import AdminProfileActions from '$lib/components/admin/AdminProfileActions.svelte';
  import { createEntityFeed } from '$lib/feed/entity-feed.svelte.js';

  let group = $state<GroupDetail | null>(null);
  let members = $state<GroupMember[]>([]);
  let loading = $state(true);
  let membersLoading = $state(false);
  let hasMoreMembers = $state(true);
  let activeTab = $state('posts');
  let membersLoaded = $state(false);

  // Shared paginated post feed (Posts + Media tabs).
  const feed = createEntityFeed(async (cursor) => {
    const r = await getGroupTimeline(groupId, cursor ?? undefined);
    return Array.isArray(r) ? r : ((r as any).data ?? []);
  });

  // Admin controls — the unified manage modal replaces the previous
  // pair of "Edit Group" / "Delete Group" buttons. All admin actions
  // (rename, change images, manage members, applications, invites,
  // delete) live behind one gear icon now.
  let manageModalOpen = $state(false);
  let showMemberActions = $state<string | null>(null);

  let groupId = $derived(page.params.id!);
  let currentUserId = $derived(get(authStore)?.user?.id);
  let isAdmin = $derived(group?.role === 'owner' || group?.role === 'admin');
  let isOwner = $derived(group?.role === 'owner');
  // Mirror the Pages header: in-group owners/admins OR instance staff can
  // manage. Staff aren't usually group members, so without the staff check
  // a site admin could never open the manage modal — even though the modal
  // and backend (`Groups.can_manage?/2`) already grant them the rights.
  let canManage = $derived(isAdmin || $isStaffMember);

  const tabs = [
    { id: 'posts', label: 'Posts' },
    { id: 'media', label: 'Media' },
    { id: 'members', label: 'Members' },
    { id: 'about', label: 'About' }
  ];

  onMount(() => {
    // Header + feed load in parallel.
    (async () => {
      try {
        group = await getGroup(groupId);
      } catch {
        // Error loading group
      } finally {
        loading = false;
      }
    })();
    feed.reset();
  });

  $effect(() => {
    if (activeTab === 'members' && !membersLoaded) {
      loadMembers();
    }
  });

  async function loadMembers() {
    membersLoading = true;
    try {
      const result = await getGroupMembers(groupId);
      members = Array.isArray(result) ? result : (result as any).data || [];
      hasMoreMembers = members.length >= 20;
      membersLoaded = true;
    } catch {
      // Error loading members
    } finally {
      membersLoading = false;
    }
  }

  async function handleJoin() {
    if (!group) return;
    try {
      const result = await joinGroup(groupId);
      if (result.status === 'joined') {
        group = { ...group, is_member: true, member_count: group.member_count + 1, pending_request: false };
      } else {
        group = { ...group, pending_request: true };
      }
    } catch {}
  }

  async function handleLeave() {
    if (!group) return;
    try {
      await leaveGroup(groupId);
      group = { ...group, is_member: false, member_count: Math.max(0, group.member_count - 1), role: null };
    } catch (err) {
      // The server rejects a lone owner trying to leave; surface a
      // helpful message instead of swallowing it like other errors.
      const apiErr = err as { body?: { error?: string; detail?: string } };
      if (apiErr?.body?.error === 'group.owner_must_transfer') {
        addToast(
          apiErr.body.detail ||
            "You're the only owner — promote another member first, or delete the group.",
          'error',
        );
      }
    }
  }

  // --- Admin: Member Management ---
  async function handleChangeRole(memberId: string, newRole: string) {
    try {
      await updateMemberRole(groupId, memberId, newRole);
      members = members.map(m =>
        m.id === memberId ? { ...m, role: newRole as GroupMember['role'] } : m
      );
      showMemberActions = null;
    } catch {}
  }

  async function handleRemoveMember(memberId: string) {
    if (!confirm('Remove this member from the group?')) return;
    try {
      await banMember(groupId, memberId);
      members = members.filter(m => m.id !== memberId);
      if (group) group = { ...group, member_count: Math.max(0, group.member_count - 1) };
      showMemberActions = null;
    } catch {}
  }

  function openSettings() {
    manageModalOpen = true;
  }

  function roleBadge(role: string): string {
    switch (role) {
      case 'owner': return 'Owner';
      case 'admin': return 'Admin';
      case 'moderator': return 'Mod';
      default: return '';
    }
  }
</script>

<svelte:head>
  <title>{group?.name ?? 'Group'} - {$instanceName}</title>
</svelte:head>

<div class="group-detail-page">
  {#if loading}
    <div class="page-loading"><Spinner /></div>
  {:else if group}
    <EntityHeader
      name={group.name}
      avatarUrl={group.avatar_url}
      coverUrl={group.header_url}
      description={group.description}
    >
      {#snippet meta()}
        {#if group}
          <span class="eh-cap">{group.visibility}</span>
          <span class="eh-dot" aria-hidden="true">·</span>
          <span>{group.member_count === 1 ? '1 member' : `${group.member_count.toLocaleString()} members`}</span>
        {/if}
      {/snippet}
      {#snippet adminActions()}
        {#if $isStaffMember && !isOwner && group?.identity}
          <AdminProfileActions account={group.identity} />
        {/if}
        {#if canManage}
          <button type="button" class="btn btn-ghost icon-btn" onclick={openSettings} aria-label="Group settings" title="Group settings">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <circle cx="12" cy="12" r="3" />
              <path d="M19.4 15a1.65 1.65 0 00.33 1.82l.06.06a2 2 0 010 2.83 2 2 0 01-2.83 0l-.06-.06a1.65 1.65 0 00-1.82-.33 1.65 1.65 0 00-1 1.51V21a2 2 0 01-4 0v-.09A1.65 1.65 0 009 19.4a1.65 1.65 0 00-1.82.33l-.06.06a2 2 0 01-2.83-2.83l.06-.06A1.65 1.65 0 004.68 15a1.65 1.65 0 00-1.51-1H3a2 2 0 010-4h.09A1.65 1.65 0 004.6 9a1.65 1.65 0 00-.33-1.82l-.06-.06a2 2 0 012.83-2.83l.06.06A1.65 1.65 0 009 4.68a1.65 1.65 0 001-1.51V3a2 2 0 014 0v.09a1.65 1.65 0 001 1.51 1.65 1.65 0 001.82-.33l.06-.06a2 2 0 012.83 2.83l-.06.06A1.65 1.65 0 0019.4 9a1.65 1.65 0 001.51 1H21a2 2 0 010 4h-.09a1.65 1.65 0 00-1.51 1z" />
            </svg>
          </button>
        {/if}
      {/snippet}
      {#snippet primaryAction()}
        {#if group}
          {#if group.is_member}
            {#if !isOwner}
              <button type="button" class="btn btn-outline" onclick={handleLeave}>Leave</button>
            {/if}
          {:else if group.pending_request}
            <button type="button" class="btn btn-outline" disabled>Pending</button>
          {:else}
            <button type="button" class="btn btn-primary" onclick={handleJoin}>Join</button>
          {/if}
        {/if}
      {/snippet}
    </EntityHeader>

    <div class="group-content">
      <Tabs {tabs} bind:active={activeTab}>
        {#if activeTab === 'posts'}
          {#if group?.is_member}
            <ComposerTrigger
              groupId={group.id}
              contextLabel={`Posting to ${group.name || 'group'}`}
              placeholder={`Share something with ${group.name || 'the group'}…`}
            />
          {/if}
          <FeedList
            posts={feed.posts}
            loading={feed.loading}
            hasMore={feed.hasMore}
            viewerContext="group"
            emptyMessage="No posts in this group yet"
            onloadmore={feed.loadMore}
          />
        {:else if activeTab === 'media'}
          <!-- Media tab shares the same feed as the Posts tab — we just
               filter for image / video attachments and render them as a
               grid. Loading more posts feeds both tabs. -->
          <MediaGrid
            posts={feed.posts}
            loading={feed.loading}
            hasMore={feed.hasMore}
            onloadmore={feed.loadMore}
            emptyMessage="No photos or videos posted in this group yet"
          />
        {:else if activeTab === 'members'}
          {#if membersLoading}
            <div class="tab-loading"><Spinner /></div>
          {:else if members.length === 0}
            <div class="tab-empty"><p class="empty-text">No members</p></div>
          {:else}
            <ul class="member-list">
              {#each members as member (member.id || member.identity_id)}
                {@const acct = member.account || {}}
                <li class="member-item">
                  <a href="/@{acct.handle || ''}" class="member-link">
                    <Avatar
                      src={acct.avatar_url}
                      name={acct.display_name || acct.handle || 'Member'}
                      size="md"
                    />
                    <div class="member-info">
                      <span class="member-name">{acct.display_name || acct.handle || 'Member'}</span>
                      <span class="member-handle">@{acct.handle || '...'}</span>
                    </div>
                  </a>

                  {#if member.role && member.role !== 'member'}
                    <span class="role-badge role-{member.role}">{roleBadge(member.role)}</span>
                  {/if}

                  {#if isAdmin && member.identity_id !== currentUserId && member.role !== 'owner'}
                    <div class="member-actions-wrapper">
                      <button
                        type="button"
                        class="member-actions-btn"
                        onclick={(e) => { e.stopPropagation(); showMemberActions = showMemberActions === member.id ? null : member.id!; }}
                        aria-label="Member actions"
                      >
                        ···
                      </button>

                      {#if showMemberActions === member.id}
                        <div class="member-actions-menu">
                          {#if member.role !== 'admin'}
                            <button type="button" class="menu-item" onclick={() => handleChangeRole(member.id!, 'admin')}>
                              Make Admin
                            </button>
                          {/if}
                          {#if member.role !== 'moderator'}
                            <button type="button" class="menu-item" onclick={() => handleChangeRole(member.id!, 'moderator')}>
                              Make Moderator
                            </button>
                          {/if}
                          {#if member.role !== 'member'}
                            <button type="button" class="menu-item" onclick={() => handleChangeRole(member.id!, 'member')}>
                              Remove Role
                            </button>
                          {/if}
                          <button type="button" class="menu-item menu-item-danger" onclick={() => handleRemoveMember(member.id!)}>
                            Remove from Group
                          </button>
                        </div>
                      {/if}
                    </div>
                  {/if}
                </li>
              {/each}
            </ul>
          {/if}
        {:else if activeTab === 'about'}
          <div class="about-section">
            {#if group.description}
              <div class="about-block">
                <h3 class="about-heading">Description</h3>
                <p class="about-text">{group.description}</p>
              </div>
            {/if}

            <div class="about-block">
              <h3 class="about-heading">Info</h3>
              <dl class="info-list">
                <div class="info-row">
                  <dt class="info-label">Created</dt>
                  <dd class="info-value">{new Date(group.created_at).toLocaleDateString(undefined, { year: 'numeric', month: 'long', day: 'numeric' })}</dd>
                </div>
                <div class="info-row">
                  <dt class="info-label">Visibility</dt>
                  <dd class="info-value" style="text-transform: capitalize">{group.visibility}</dd>
                </div>
                <div class="info-row">
                  <dt class="info-label">Join Policy</dt>
                  <dd class="info-value" style="text-transform: capitalize">{group.join_policy}</dd>
                </div>
                <div class="info-row">
                  <dt class="info-label">Members</dt>
                  <dd class="info-value">{group.member_count}</dd>
                </div>
              </dl>
            </div>
          </div>
        {/if}
      </Tabs>
    </div>
  {:else}
    <div class="page-error"><p>Group not found</p></div>
  {/if}
</div>

<GroupManageModal
  bind:open={manageModalOpen}
  bind:group
  isStaff={$isStaffMember}
  ondeleted={() => goto('/groups')}
/>

<style>
  .group-detail-page {
    max-width: var(--feed-max-width);
    margin: 0 auto;
    width: 100%;
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }

  /* Header snippet helpers (rendered in this page's scope). */
  .eh-cap {
    text-transform: capitalize;
  }

  .eh-dot {
    color: var(--color-text-tertiary);
  }

  .icon-btn {
    width: 40px;
    height: 40px;
    padding: 0;
  }

  .page-loading, .page-error {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: var(--space-16);
    color: var(--color-text-tertiary);
  }

  .admin-bar {
    display: flex;
    gap: var(--space-2);
    padding: var(--space-3) var(--space-4);
    border-block-end: 1px solid var(--color-border);
    background: var(--color-surface);
    border-radius: var(--radius-md);
    margin-block-start: var(--space-2);
  }

  .btn-danger-outline {
    color: var(--color-danger);
    border-color: var(--color-danger);
  }
  .btn-danger-outline:hover { background: var(--color-danger-soft); }

  .btn-danger {
    background: var(--color-danger);
    color: white;
    border: none;
    padding: var(--space-2) var(--space-4);
    border-radius: var(--radius-md);
    font-weight: 600;
    cursor: pointer;
  }
  .btn-danger:hover { opacity: 0.9; }

  .group-content {
    background: var(--color-surface-raised);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-xl);
    padding: 0 var(--space-4) var(--space-4);
  }
  .tab-loading { display: flex; justify-content: center; padding: var(--space-8); }
  .tab-empty { text-align: center; padding: var(--space-12); }
  .empty-text { color: var(--color-text-tertiary); }

  .member-list { display: flex; flex-direction: column; }
  .member-item {
    display: flex;
    align-items: center;
    padding: var(--space-3) var(--space-2);
    border-block-end: 1px solid var(--color-border);
  }
  .member-item:last-child { border-block-end: none; }

  .member-link {
    display: flex;
    align-items: center;
    gap: var(--space-3);
    flex: 1;
    min-width: 0;
    text-decoration: none;
    color: inherit;
  }
  .member-link:hover { text-decoration: none; }

  .member-info { display: flex; flex-direction: column; min-width: 0; }
  .member-name {
    font-size: var(--text-sm);
    font-weight: 600;
    color: var(--color-text);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .member-handle { font-size: var(--text-xs); color: var(--color-text-secondary); }

  .role-badge {
    font-size: var(--text-xs);
    font-weight: 600;
    padding: var(--space-1) var(--space-2);
    border-radius: var(--radius-full);
    flex-shrink: 0;
    margin-inline-start: var(--space-2);
  }
  .role-owner { background: var(--color-warning-soft); color: var(--color-warning); }
  .role-admin { background: var(--color-info-soft); color: var(--color-info); }
  .role-moderator { background: var(--color-success-soft); color: var(--color-success); }

  .member-actions-wrapper { position: relative; margin-inline-start: var(--space-2); }
  .member-actions-btn {
    background: none;
    border: none;
    padding: var(--space-1) var(--space-2);
    color: var(--color-text-secondary);
    cursor: pointer;
    font-size: var(--text-lg);
    border-radius: var(--radius-md);
  }
  .member-actions-btn:hover { background: var(--color-surface); }

  .member-actions-menu {
    position: absolute;
    inset-inline-end: 0;
    inset-block-start: 100%;
    background: var(--color-surface-raised);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    box-shadow: var(--shadow-lg);
    z-index: var(--z-dropdown);
    min-width: 180px;
    overflow: hidden;
  }

  .menu-item {
    display: block;
    width: 100%;
    padding: var(--space-2) var(--space-3);
    background: none;
    border: none;
    text-align: start;
    font-size: var(--text-sm);
    color: var(--color-text);
    cursor: pointer;
  }
  .menu-item:hover { background: var(--color-surface); }
  .menu-item-danger { color: var(--color-danger); }
  .menu-item-danger:hover { background: var(--color-danger-soft); }

  .about-section { display: flex; flex-direction: column; gap: var(--space-6); }
  .about-block { display: flex; flex-direction: column; gap: var(--space-2); }
  .about-heading {
    font-size: var(--text-sm);
    font-weight: 700;
    color: var(--color-text);
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }
  .about-text { font-size: var(--text-sm); color: var(--color-text-secondary); line-height: 1.6; }

  .info-list { display: flex; flex-direction: column; gap: var(--space-2); }
  .info-row { display: flex; justify-content: space-between; align-items: center; }
  .info-label { font-size: var(--text-sm); color: var(--color-text-secondary); }
  .info-value { font-size: var(--text-sm); color: var(--color-text); font-weight: 500; }

  /* Modal styles */
  .modal-overlay {
    position: fixed;
    inset: 0;
    background: var(--color-overlay, rgba(0,0,0,0.5));
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: var(--z-modal, 40);
  }
  .modal-dialog {
    background: var(--color-surface-raised, #fff);
    border-radius: var(--radius-lg);
    padding: var(--space-6);
    max-width: 480px;
    width: 90%;
    box-shadow: var(--shadow-xl);
  }
  .modal-title {
    font-size: var(--text-lg);
    font-weight: 600;
    margin-block-end: var(--space-4);
  }
  .modal-message {
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
    margin-block-end: var(--space-6);
    line-height: 1.6;
  }
  .form-group { margin-block-end: var(--space-4); }
  .form-label {
    display: block;
    font-size: var(--text-sm);
    font-weight: 500;
    margin-block-end: var(--space-1);
  }
  .modal-actions {
    display: flex;
    justify-content: flex-end;
    gap: var(--space-3);
    margin-block-start: var(--space-6);
  }

</style>
