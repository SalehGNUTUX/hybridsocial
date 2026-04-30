<script lang="ts">
  import { onMount } from 'svelte';
  import DataTable from '$lib/components/admin/DataTable.svelte';
  import Modal from '$lib/components/ui/Modal.svelte';
  import { addToast } from '$lib/stores/toast.js';
  import {
    getAdminUsers, suspendUser, unsuspendUser, warnUser,
    silenceUser, unsilenceUser, shadowBanUser, unshadowBanUser,
    forceSensitiveUser, unforceSensitiveUser, revokeAllSessions,
    setTrustLevel, getModerationNotes, createModerationNote, deleteModerationNote,
    resetUserPassword, sendUserPasswordResetEmail, disableUserTwoFactor, changeUserEmail,
    confirmUserEmail, changeUserTier,
    getRoles, getUserRoles, assignUserRole, revokeUserRole,
    type UserRoleAssignment
  } from '$lib/api/admin.js';
  import type { AdminUser, ModerationNote, AdminRole } from '$lib/api/types.js';

  let users: AdminUser[] = $state([]);
  let loading = $state(true);
  let search = $state('');
  // When the URL carries `?id=<identity_id>` the list is pinned to
  // exactly that one row — no substring fuzziness, no risk of also
  // matching other users whose handles happen to share a prefix.
  // Cleared as soon as the admin edits the search box.
  let exactIdFilter: string | null = $state(null);
  let statusFilter = $state('all');
  let locationFilter = $state<'all' | 'local' | 'remote'>('all');
  // Email-verification filter only applies to local accounts — remote
  // users go through their origin instance's verification flow.
  let emailFilter = $state<'all' | 'verified' | 'unverified'>('all');
  let sortKey = $state('created_at');
  let sortDir = $state<'asc' | 'desc'>('desc');

  // Client-side pagination — the admin endpoint returns the full set
  // and we slice locally so search/filter/sort can stay snappy without
  // round-tripping for every keystroke.
  const PAGE_SIZE = 50;
  let currentPage = $state(1);

  // Warn modal
  let warnModalOpen = $state(false);
  let warnTarget: AdminUser | null = $state(null);
  let warnMessage = $state('');

  // Action confirmation modal
  let actionModalOpen = $state(false);
  let actionTarget: AdminUser | null = $state(null);
  let actionType = $state('');
  let actionReason = $state('');
  let actionSubmitting = $state(false);

  // Trust level modal
  let trustModalOpen = $state(false);
  let trustTarget: AdminUser | null = $state(null);
  let trustLevel = $state(0);

  // Moderation notes modal
  let notesModalOpen = $state(false);
  let notesTarget: AdminUser | null = $state(null);
  let notes: ModerationNote[] = $state([]);
  let notesLoading = $state(false);
  let newNote = $state('');

  // Change email modal
  let emailModalOpen = $state(false);
  let emailTarget: AdminUser | null = $state(null);
  let emailValue = $state('');
  let emailSubmitting = $state(false);

  // Reset password result modal — shows the generated password once.
  // Admins must copy it before closing; we don't persist plaintext.
  let passwordModalOpen = $state(false);
  let passwordTarget: AdminUser | null = $state(null);
  let generatedPassword = $state('');
  let passwordSubmitting = $state(false);

  // Verification tier modal
  let tierModalOpen = $state(false);
  let tierTarget: AdminUser | null = $state(null);
  let tierValue = $state('free');
  let tierSubmitting = $state(false);

  const tierOptions: { value: string; label: string; description: string }[] = [
    { value: 'free', label: 'Free (L0)', description: 'Default — unverified account' },
    { value: 'verified_starter', label: 'Starter (L1)', description: 'Small creators & casual users' },
    { value: 'verified_creator', label: 'Creator (L2)', description: 'Active creators & community builders' },
    { value: 'verified_pro', label: 'Pro (L3)', description: 'Professional accounts — highest limits' },
  ];

  // Manage roles modal
  let rolesModalOpen = $state(false);
  let rolesTarget: AdminUser | null = $state(null);
  let allRoles: AdminRole[] = $state([]);
  let userRoleAssignments: UserRoleAssignment[] = $state([]);
  let rolesLoading = $state(false);
  let rolesBusyRoleId: string | null = $state(null);

  // Actions dropdown
  let openDropdownId: string | null = $state(null);
  let dropdownPos = $state({ top: 0, left: 0 });

  const columns = [
    { key: 'handle', label: 'Handle', sortable: true },
    { key: 'email', label: 'Email', sortable: true },
    { key: 'created_at', label: 'Created', sortable: true },
    { key: 'status', label: 'Status', sortable: true },
    { key: 'flags', label: 'Flags' },
    { key: 'trust_level', label: 'Trust', sortable: true },
    { key: 'actions', label: 'Actions', width: '220px' }
  ];

  let filteredUsers = $derived(
    users.filter((u) => {
      // Exact-id filter short-circuits everything else. Used when a
      // deep-link (e.g. "View author in admin" on a post) wants to
      // pin the list to one specific identity regardless of search
      // / status / location filters.
      if (exactIdFilter) return u.id === exactIdFilter;

      const matchesSearch =
        !search ||
        u.handle.toLowerCase().includes(search.toLowerCase()) ||
        ((u as any).acct || '').toLowerCase().includes(search.toLowerCase()) ||
        (u.display_name || '').toLowerCase().includes(search.toLowerCase()) ||
        ((u as any).domain || '').toLowerCase().includes(search.toLowerCase()) ||
        u.email?.toLowerCase().includes(search.toLowerCase());
      const matchesStatus =
        statusFilter === 'all' ||
        (statusFilter === 'suspended' && u.is_suspended) ||
        (statusFilter === 'active' && !u.is_suspended);
      const matchesLocation =
        locationFilter === 'all' ||
        (locationFilter === 'local' && (u as any).is_local !== false) ||
        (locationFilter === 'remote' && (u as any).is_local === false);
      const isLocal = (u as any).is_local !== false;
      const isSubaccountUser = !!(u as any).parent_identity_id;
      const matchesEmail =
        emailFilter === 'all' ||
        // Only apply the email filter to top-level local accounts.
        // Remote rows have no local verification state we control;
        // subaccounts (bots/groups/pages) inherit their parent's,
        // so they never own an email of their own.
        !isLocal ||
        isSubaccountUser ||
        (emailFilter === 'verified' && (u as any).email_confirmed === true) ||
        (emailFilter === 'unverified' && (u as any).email_confirmed === false);
      return matchesSearch && matchesStatus && matchesLocation && matchesEmail;
    })
  );

  // Reset to page 1 whenever a filter changes — pagination keyed off a
  // larger result set is meaningless once the result set shrinks.
  $effect(() => {
    void search; void statusFilter; void locationFilter; void emailFilter; void exactIdFilter;
    currentPage = 1;
  });

  let sortedUsers = $derived(
    [...filteredUsers].sort((a, b) => {
      const aVal = a[sortKey as keyof AdminUser] ?? '';
      const bVal = b[sortKey as keyof AdminUser] ?? '';
      const cmp = String(aVal).localeCompare(String(bVal));
      return sortDir === 'asc' ? cmp : -cmp;
    })
  );

  // Nest subaccounts under their parent. Each parent is followed
  // immediately by its child rows (in the same sort order), so the
  // table reads like a tree. If the parent isn't in the visible set
  // (filtered out, remote, whatever), orphan children fall back to
  // rendering as top-level rows — no surprise empty gaps.
  let groupedUsers = $derived.by(() => {
    const byId = new Map(sortedUsers.map((u) => [u.id, u]));
    const childrenOf = new Map<string, AdminUser[]>();
    for (const u of sortedUsers) {
      if (u.parent_identity_id && byId.has(u.parent_identity_id)) {
        const list = childrenOf.get(u.parent_identity_id) ?? [];
        list.push(u);
        childrenOf.set(u.parent_identity_id, list);
      }
    }

    const out: AdminUser[] = [];
    const seen = new Set<string>();
    for (const u of sortedUsers) {
      if (u.parent_identity_id && byId.has(u.parent_identity_id)) continue;
      if (seen.has(u.id)) continue;
      out.push(u);
      seen.add(u.id);
      for (const child of childrenOf.get(u.id) ?? []) {
        if (!seen.has(child.id)) {
          out.push(child);
          seen.add(child.id);
        }
      }
    }
    return out;
  });

  let tableRows = $derived(
    groupedUsers.map((u) => ({
      ...u,
      is_subaccount: !!(u.parent_identity_id && groupedUsers.some((p) => p.id === u.parent_identity_id)),
    } as Record<string, unknown>))
  );

  let totalPages = $derived(Math.max(1, Math.ceil(tableRows.length / PAGE_SIZE)));
  let pagedRows = $derived(
    tableRows.slice((currentPage - 1) * PAGE_SIZE, currentPage * PAGE_SIZE),
  );

  // Paint local rows whose email isn't confirmed in a warning tint so
  // an admin scanning the table can spot stalled signups at a glance.
  // Remote rows are excluded — we don't own their email confirmation
  // state and would otherwise tint half the federated table.
  // Subaccounts (bots, groups, pages owned by another user) inherit
  // their parent's verification, so they never carry their own email
  // and shouldn't show the unverified marker either.
  function isSubaccount(row: Record<string, unknown>): boolean {
    return !!row['parent_identity_id'];
  }

  function shouldFlagUnverified(row: Record<string, unknown>): boolean {
    const isLocal = row['is_local'] !== false;
    return isLocal && !isSubaccount(row) && row['email_confirmed'] === false;
  }

  function rowClassFor(row: Record<string, unknown>): string {
    return shouldFlagUnverified(row) ? 'row-email-unverified' : '';
  }

  onMount(async () => {
    // Deep-link params:
    //   ?id=<identity_id>  — pin to exactly that user
    //   ?search=<text>     — pre-fill the search box with substring match
    // `id` wins when both are set (used by "View author in admin"
    // which has the precise id). Search is the older shape we keep
    // for bookmarks and for cases where only a handle is known.
    if (typeof window !== 'undefined') {
      const url = new URL(window.location.href);
      const exactId = url.searchParams.get('id');
      const q = url.searchParams.get('search');
      if (exactId) exactIdFilter = exactId;
      if (q) search = q.replace(/^@/, '');
    }

    await loadUsers();
  });

  // Any manual edit to search/status/location drops the pinned
  // single-user filter, so the admin can broaden the view without
  // having to reload the page.
  function clearExactFilter() {
    if (exactIdFilter) exactIdFilter = null;
  }

  async function loadUsers() {
    loading = true;
    try {
      const result = await getAdminUsers();
      users = result.data;
    } catch {
      addToast('Failed to load users', 'error');
    } finally {
      loading = false;
    }
  }

  async function handleSuspend(user: AdminUser) {
    try {
      await suspendUser(user.id);
      users = users.map((u) => (u.id === user.id ? { ...u, is_suspended: true } : u));
      addToast(`Suspended @${user.handle}`, 'success');
    } catch {
      addToast('Failed to suspend user', 'error');
    }
  }

  async function handleUnsuspend(user: AdminUser) {
    try {
      await unsuspendUser(user.id);
      users = users.map((u) => (u.id === user.id ? { ...u, is_suspended: false } : u));
      addToast(`Unsuspended @${user.handle}`, 'success');
    } catch {
      addToast('Failed to unsuspend user', 'error');
    }
  }

  function openWarnModal(user: AdminUser) {
    warnTarget = user;
    warnMessage = '';
    warnModalOpen = true;
    openDropdownId = null;
  }

  async function handleWarn() {
    if (!warnTarget || !warnMessage.trim()) return;
    try {
      await warnUser(warnTarget.id, warnMessage);
      addToast(`Warning sent to @${warnTarget.handle}`, 'success');
      warnModalOpen = false;
    } catch {
      addToast('Failed to send warning', 'error');
    }
  }

  function openActionModal(user: AdminUser, type: string) {
    actionTarget = user;
    actionType = type;
    actionReason = '';
    actionModalOpen = true;
    openDropdownId = null;
  }

  async function handleAction() {
    if (!actionTarget) return;
    actionSubmitting = true;
    try {
      let updated: AdminUser;
      switch (actionType) {
        case 'silence':
          updated = await silenceUser(actionTarget.id, { reason: actionReason || undefined });
          updated.is_silenced = true;
          break;
        case 'unsilence':
          updated = await unsilenceUser(actionTarget.id);
          updated.is_silenced = false;
          break;
        case 'shadow_ban':
          updated = await shadowBanUser(actionTarget.id);
          updated.is_shadow_banned = true;
          break;
        case 'unshadow_ban':
          updated = await unshadowBanUser(actionTarget.id);
          updated.is_shadow_banned = false;
          break;
        case 'force_sensitive':
          updated = await forceSensitiveUser(actionTarget.id);
          updated.force_sensitive = true;
          break;
        case 'unforce_sensitive':
          updated = await unforceSensitiveUser(actionTarget.id);
          updated.force_sensitive = false;
          break;
        case 'revoke_sessions':
          await revokeAllSessions(actionTarget.id);
          updated = actionTarget;
          break;
        default:
          return;
      }
      users = users.map((u) => (u.id === actionTarget!.id ? { ...u, ...updated } : u));
      actionModalOpen = false;
      addToast(`${actionLabel(actionType)} applied to @${actionTarget.handle}`, 'success');
    } catch {
      addToast(`Failed to ${actionType.replace(/_/g, ' ')} user`, 'error');
    } finally {
      actionSubmitting = false;
    }
  }

  function openEmailModal(user: AdminUser) {
    emailTarget = user;
    emailValue = user.email || '';
    emailModalOpen = true;
    openDropdownId = null;
  }

  async function handleChangeEmail() {
    if (!emailTarget || !emailValue.trim()) return;
    emailSubmitting = true;
    try {
      const res = await changeUserEmail(emailTarget.id, emailValue.trim());
      users = users.map((u) => (u.id === emailTarget!.id ? { ...u, email: res.email } : u));
      addToast(`Email updated for @${emailTarget.handle}`, 'success');
      emailModalOpen = false;
    } catch {
      addToast('Failed to change email', 'error');
    } finally {
      emailSubmitting = false;
    }
  }

  async function handleResetPassword(user: AdminUser) {
    openDropdownId = null;
    if (!confirm(`Generate a new password for @${user.handle}? All their sessions will be revoked.`)) return;
    passwordTarget = user;
    passwordSubmitting = true;
    passwordModalOpen = true;
    generatedPassword = '';
    try {
      const res = await resetUserPassword(user.id);
      generatedPassword = res.password;
    } catch {
      addToast('Failed to reset password', 'error');
      passwordModalOpen = false;
    } finally {
      passwordSubmitting = false;
    }
  }

  async function handleSendPasswordResetEmail(user: AdminUser) {
    openDropdownId = null;
    try {
      await sendUserPasswordResetEmail(user.id);
      addToast(`Password reset email sent to @${user.handle}`, 'success');
    } catch (e: any) {
      // Backend returns a message for the useful cases
      // (email.not_configured, email.delivery_failed) — surface it so
      // the admin understands why nothing was sent instead of staring
      // at a generic "failed" toast.
      const msg = e?.body?.message || e?.message || 'Failed to send password reset email';
      addToast(msg, 'error');
    }
  }

  async function handleDisableTwoFactor(user: AdminUser) {
    openDropdownId = null;
    if (!confirm(`Disable two-factor authentication for @${user.handle}? They'll need to set it up again.`)) return;
    try {
      await disableUserTwoFactor(user.id);
      users = users.map((u) => (u.id === user.id ? { ...u, two_factor_enabled: false } : u));
      addToast(`2FA disabled for @${user.handle}`, 'success');
    } catch {
      addToast('Failed to disable 2FA', 'error');
    }
  }

  async function handleConfirmEmail(user: AdminUser) {
    openDropdownId = null;
    if (!confirm(`Mark @${user.handle}'s email as verified? They'll skip the confirmation link.`)) return;
    try {
      const res = await confirmUserEmail(user.id);
      users = users.map((u) =>
        u.id === user.id ? { ...u, email_confirmed: true, confirmed_at: res.confirmed_at ?? u.confirmed_at ?? new Date().toISOString() } : u
      );
      if (res.status === 'already_confirmed') {
        addToast(`@${user.handle} was already verified`, 'info');
      } else {
        addToast(`Email verified for @${user.handle}`, 'success');
      }
    } catch (e: any) {
      const msg = e?.body?.message || 'Failed to mark email as verified';
      addToast(msg, 'error');
    }
  }

  function openTierModal(user: AdminUser) {
    tierTarget = user;
    tierValue = user.verification_tier || 'free';
    tierModalOpen = true;
    openDropdownId = null;
  }

  async function handleChangeTier() {
    if (!tierTarget) return;
    tierSubmitting = true;
    try {
      const res = await changeUserTier(tierTarget.id, tierValue);
      const updated = (res as any).data;
      users = users.map((u) =>
        u.id === tierTarget!.id ? { ...u, verification_tier: updated?.verification_tier || tierValue } : u
      );
      const label = tierOptions.find((t) => t.value === tierValue)?.label || tierValue;
      addToast(`@${tierTarget.handle} set to ${label}`, 'success');
      tierModalOpen = false;
    } catch {
      addToast('Failed to change tier', 'error');
    } finally {
      tierSubmitting = false;
    }
  }

  async function copyGeneratedPassword() {
    try {
      await navigator.clipboard.writeText(generatedPassword);
      addToast('Password copied to clipboard', 'success');
    } catch {
      addToast('Could not copy — select and copy manually', 'error');
    }
  }

  function actionLabel(type: string): string {
    switch (type) {
      case 'silence': return 'Silence';
      case 'unsilence': return 'Unsilence';
      case 'shadow_ban': return 'Shadow Ban';
      case 'unshadow_ban': return 'Unshadow Ban';
      case 'force_sensitive': return 'Force Sensitive';
      case 'unforce_sensitive': return 'Unforce Sensitive';
      case 'revoke_sessions': return 'Revoke Sessions';
      default: return type;
    }
  }

  function openTrustModal(user: AdminUser) {
    trustTarget = user;
    trustLevel = user.trust_level ?? 0;
    trustModalOpen = true;
    openDropdownId = null;
  }

  async function handleSetTrustLevel() {
    if (!trustTarget) return;
    try {
      const updated = await setTrustLevel(trustTarget.id, trustLevel);
      users = users.map((u) => (u.id === trustTarget!.id ? { ...u, trust_level: updated.trust_level } : u));
      trustModalOpen = false;
      addToast(`Trust level set to ${trustLevel} for @${trustTarget.handle}`, 'success');
    } catch {
      addToast('Failed to set trust level', 'error');
    }
  }

  async function openNotesModal(user: AdminUser) {
    notesTarget = user;
    notes = [];
    newNote = '';
    notesModalOpen = true;
    openDropdownId = null;
    notesLoading = true;
    try {
      notes = await getModerationNotes(user.id);
    } catch {
      addToast('Failed to load notes', 'error');
    } finally {
      notesLoading = false;
    }
  }

  async function openRolesModal(user: AdminUser) {
    rolesTarget = user;
    rolesModalOpen = true;
    openDropdownId = null;
    rolesLoading = true;
    try {
      const [roles, assignments] = await Promise.all([
        getRoles(),
        getUserRoles(user.id)
      ]);
      allRoles = roles;
      userRoleAssignments = assignments;
    } catch {
      addToast('Failed to load roles', 'error');
    } finally {
      rolesLoading = false;
    }
  }

  function assignmentForRole(roleId: string): UserRoleAssignment | undefined {
    return userRoleAssignments.find((a) => a.role_id === roleId);
  }

  async function handleToggleRole(role: AdminRole) {
    if (!rolesTarget) return;
    const existing = assignmentForRole(role.id);
    rolesBusyRoleId = role.id;
    try {
      if (existing) {
        await revokeUserRole(rolesTarget.id, existing.id);
        userRoleAssignments = userRoleAssignments.filter((a) => a.id !== existing.id);
        addToast(`Removed ${role.name}`, 'success');
      } else {
        const assignment = await assignUserRole(rolesTarget.id, role.id);
        userRoleAssignments = [...userRoleAssignments, assignment];
        addToast(`Assigned ${role.name}`, 'success');
      }
    } catch (err: unknown) {
      const e = err as { body?: { error?: string; required?: string } };
      if (e?.body?.error === 'permission.denied') {
        addToast(`Need "${e.body.required}" permission to change roles`, 'error');
      } else {
        addToast('Failed to update role', 'error');
      }
    } finally {
      rolesBusyRoleId = null;
    }
  }

  async function handleAddNote() {
    if (!notesTarget || !newNote.trim()) return;
    try {
      const note = await createModerationNote(notesTarget.id, newNote);
      notes = [...notes, note];
      newNote = '';
      addToast('Note added', 'success');
    } catch {
      addToast('Failed to add note', 'error');
    }
  }

  async function handleDeleteNote(id: string) {
    try {
      await deleteModerationNote(id);
      notes = notes.filter((n) => n.id !== id);
      addToast('Note deleted', 'success');
    } catch {
      addToast('Failed to delete note', 'error');
    }
  }

  function toggleDropdown(userId: string, e?: MouseEvent) {
    // The trigger click bubbles to the window-level close handler
    // below, so if we don't stop it here the handler that *just*
    // opened the menu would also close it on the same click.
    e?.stopPropagation();
    if (openDropdownId === userId) {
      openDropdownId = null;
      return;
    }
    openDropdownId = userId;
    if (e) {
      const btn = (e.currentTarget as HTMLElement);
      const rect = btn.getBoundingClientRect();
      const spaceBelow = window.innerHeight - rect.bottom;
      const menuHeight = 320; // approximate
      dropdownPos = {
        top: spaceBelow < menuHeight ? rect.top - menuHeight : rect.bottom + 4,
        left: rect.right - 180,
      };
    }
  }

  // Close the row dropdown on any click outside it. Without this a
  // user clicking a different row's ⋯ would leave the previous menu
  // visible until that handler ran, and clicking off the table didn't
  // close it at all.
  $effect(() => {
    if (!openDropdownId) return;
    function close() { openDropdownId = null; }
    window.addEventListener('click', close);
    return () => window.removeEventListener('click', close);
  });

  function formatDate(iso: string): string {
    return new Date(iso).toLocaleDateString(undefined, {
      year: 'numeric',
      month: 'short',
      day: 'numeric'
    });
  }

  function statusClass(status: string): string {
    switch (status) {
      case 'active': return 'status-active';
      case 'suspended': return 'status-suspended';
      case 'pending': return 'status-pending';
      default: return '';
    }
  }
</script>

<svelte:head>
  <title>Users - Admin</title>
</svelte:head>

<div class="users-page">
  <h1 class="page-title">Users</h1>

  <div class="location-tabs" role="tablist">
    <button type="button" role="tab" class="loc-tab" class:loc-tab-active={locationFilter === 'all'} onclick={() => locationFilter = 'all'}>All</button>
    <button type="button" role="tab" class="loc-tab" class:loc-tab-active={locationFilter === 'local'} onclick={() => locationFilter = 'local'}>Local</button>
    <button type="button" role="tab" class="loc-tab" class:loc-tab-active={locationFilter === 'remote'} onclick={() => locationFilter = 'remote'}>Remote</button>
  </div>

  {#if exactIdFilter}
    <div class="pinned-banner">
      <span>Pinned to one user from a deep link.</span>
      <button type="button" class="pinned-banner-btn" onclick={clearExactFilter}>
        Show all users
      </button>
    </div>
  {/if}

  <div class="toolbar">
    <div class="search-bar">
      <input
        type="search"
        class="input"
        placeholder="Search users..."
        bind:value={search}
        oninput={clearExactFilter}
      />
    </div>
    <select class="input status-select" bind:value={statusFilter}>
      <option value="all">All Statuses</option>
      <option value="active">Active</option>
      <option value="suspended">Suspended</option>
      <option value="pending">Pending</option>
    </select>
    <select class="input status-select" bind:value={emailFilter} aria-label="Filter by email verification">
      <option value="all">All emails</option>
      <option value="verified">Verified email</option>
      <option value="unverified">Unverified email</option>
    </select>
  </div>

  <DataTable
    {columns}
    rows={pagedRows}
    bind:sortKey
    bind:sortDir
    {loading}
    rowClass={rowClassFor}
    emptyMessage="No users found"
  >
    {#snippet rowContent(row)}
      <td class:subaccount-row={row['is_subaccount']}>
        <div class="user-identity">
          {#if row['is_subaccount']}
            <!-- Angle marker indicating this row belongs to the
                 account above it (bot/page/group attached to a user). -->
            <span class="subaccount-angle" aria-hidden="true">&#x2937;</span>
          {/if}
          {#if row['avatar_url']}
            <img src={row['avatar_url'] as string} alt="" class="user-avatar" />
          {:else}
            <div class="user-avatar user-avatar-placeholder">
              {((row['display_name'] as string) || (row['handle'] as string) || '?').charAt(0).toUpperCase()}
            </div>
          {/if}
          <div class="user-info-col">
            {#if row['display_name']}
              <span class="user-display-name">{row['display_name']}</span>
            {/if}
            <span class="user-handle">@{row['acct'] || row['handle']}</span>
            {#if row['domain']}
              <span class="user-domain-badge">
                <span class="material-symbols-outlined" style="font-size: 12px">public</span>
                {row['domain']}
              </span>
            {:else if isSubaccount(row)}
              <span class="user-local-badge user-subaccount-badge">Sub-Account</span>
            {:else}
              <span class="user-local-badge">Local</span>
            {/if}
          </div>
        </div>
      </td>
      <td>
        <div class="email-cell">
          <span>{row['email'] || ''}</span>
          {#if shouldFlagUnverified(row)}
            <span class="email-unverified-pill" title="Email not confirmed">unverified</span>
          {/if}
        </div>
      </td>
      <td>{formatDate(row['created_at'] as string)}</td>
      <td>
        <span class="status-badge {statusClass(row['is_suspended'] ? 'suspended' : 'active')}">
          {row['is_suspended'] ? 'suspended' : 'active'}
        </span>
      </td>
      <td>
        <div class="flag-badges">
          {#if row['is_silenced']}
            <span class="flag-badge flag-silenced">silenced</span>
          {/if}
          {#if row['is_shadow_banned']}
            <span class="flag-badge flag-shadow">shadow banned</span>
          {/if}
          {#if row['force_sensitive']}
            <span class="flag-badge flag-sensitive">force sensitive</span>
          {/if}
        </div>
      </td>
      <td>
        <span class="trust-level">Lv {row['trust_level'] ?? 0}</span>
      </td>
      <td>
        <div class="action-buttons">
          {#if row['is_suspended']}
            <button
              class="btn btn-sm btn-outline"
              type="button"
              onclick={() => handleUnsuspend(row as unknown as AdminUser)}
            >Unsuspend</button>
          {:else}
            <button
              class="btn btn-sm btn-danger"
              type="button"
              onclick={() => handleSuspend(row as unknown as AdminUser)}
            >Suspend</button>
          {/if}
          <div class="dropdown">
            <button
              class="btn btn-sm btn-ghost"
              type="button"
              onclick={(e) => toggleDropdown(row['id'] as string, e)}
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor">
                <circle cx="12" cy="5" r="2" />
                <circle cx="12" cy="12" r="2" />
                <circle cx="12" cy="19" r="2" />
              </svg>
            </button>
            {#if openDropdownId === row['id']}
              <!-- Close on any bubbled click from a menu item — every
                   row action either opens a modal or kicks off a
                   request, and the user expects the menu to disappear
                   the moment they pick something. Doing it here means
                   we don't have to remember to clear openDropdownId in
                   every handler. -->
              <div
                class="dropdown-menu"
                style="top: {dropdownPos.top}px; left: {dropdownPos.left}px"
                onclick={(e) => { e.stopPropagation(); openDropdownId = null; }}
              >
                <button class="dropdown-item" type="button" onclick={() => openWarnModal(row as unknown as AdminUser)}>
                  Warn
                </button>
                {#if row['is_silenced']}
                  <button class="dropdown-item" type="button" onclick={() => openActionModal(row as unknown as AdminUser, 'unsilence')}>
                    Unsilence
                  </button>
                {:else}
                  <button class="dropdown-item" type="button" onclick={() => openActionModal(row as unknown as AdminUser, 'silence')}>
                    Silence
                  </button>
                {/if}
                {#if row['is_shadow_banned']}
                  <button class="dropdown-item" type="button" onclick={() => openActionModal(row as unknown as AdminUser, 'unshadow_ban')}>
                    Unshadow Ban
                  </button>
                {:else}
                  <button class="dropdown-item" type="button" onclick={() => openActionModal(row as unknown as AdminUser, 'shadow_ban')}>
                    Shadow Ban
                  </button>
                {/if}
                {#if row['force_sensitive']}
                  <button class="dropdown-item" type="button" onclick={() => openActionModal(row as unknown as AdminUser, 'unforce_sensitive')}>
                    Unforce Sensitive
                  </button>
                {:else}
                  <button class="dropdown-item" type="button" onclick={() => openActionModal(row as unknown as AdminUser, 'force_sensitive')}>
                    Force Sensitive
                  </button>
                {/if}
                <button class="dropdown-item" type="button" onclick={() => openActionModal(row as unknown as AdminUser, 'revoke_sessions')}>
                  Revoke Sessions
                </button>
                <button class="dropdown-item" type="button" onclick={() => openTrustModal(row as unknown as AdminUser)}>
                  Set Trust Level
                </button>
                <button class="dropdown-item" type="button" onclick={() => openRolesModal(row as unknown as AdminUser)}>
                  Manage Roles
                </button>
                {#if row['is_local'] && row['email']}
                  <!-- Account-management actions only apply to local
                       identities that have a User row attached (i.e.
                       a real login). Subaccounts like bots/pages/
                       groups are local but reuse their parent user's
                       credentials and have no email of their own —
                       hide the actions instead of 404ing on click. -->
                  <hr class="dropdown-divider" />
                  <button class="dropdown-item" type="button" onclick={() => openEmailModal(row as unknown as AdminUser)}>
                    Change Email
                  </button>
                  <button class="dropdown-item" type="button" onclick={() => handleResetPassword(row as unknown as AdminUser)}>
                    Reset Password
                  </button>
                  <button class="dropdown-item" type="button" onclick={() => handleSendPasswordResetEmail(row as unknown as AdminUser)}>
                    Send Password Reset Email
                  </button>
                  {#if row['two_factor_enabled']}
                    <button class="dropdown-item" type="button" onclick={() => handleDisableTwoFactor(row as unknown as AdminUser)}>
                      Disable 2FA
                    </button>
                  {/if}
                  {#if !row['email_confirmed']}
                    <button class="dropdown-item" type="button" onclick={() => handleConfirmEmail(row as unknown as AdminUser)}>
                      Mark Email Verified
                    </button>
                  {/if}
                  <button class="dropdown-item" type="button" onclick={() => openTierModal(row as unknown as AdminUser)}>
                    Set Verification Tier…
                  </button>
                {/if}
                <hr class="dropdown-divider" />
                <button class="dropdown-item" type="button" onclick={() => openNotesModal(row as unknown as AdminUser)}>
                  Moderation Notes
                </button>
              </div>
            {/if}
          </div>
        </div>
      </td>
    {/snippet}
  </DataTable>

  {#if !loading && tableRows.length > PAGE_SIZE}
    <nav class="pagination" aria-label="User list pagination">
      <button
        type="button"
        class="page-btn"
        onclick={() => (currentPage = Math.max(1, currentPage - 1))}
        disabled={currentPage === 1}
      >
        Previous
      </button>
      <span class="page-info">
        Page {currentPage} of {totalPages}
        <span class="page-info-count">({tableRows.length.toLocaleString()} users)</span>
      </span>
      <button
        type="button"
        class="page-btn"
        onclick={() => (currentPage = Math.min(totalPages, currentPage + 1))}
        disabled={currentPage >= totalPages}
      >
        Next
      </button>
    </nav>
  {/if}
</div>

<!-- Warn Modal -->
<Modal bind:open={warnModalOpen} title="Warn User">
  {#if warnTarget}
    <p class="modal-text">Send a warning to <strong>@{warnTarget.handle}</strong></p>
    <textarea
      class="textarea"
      bind:value={warnMessage}
      placeholder="Warning message..."
      rows="4"
    ></textarea>
    <div class="modal-actions">
      <button class="btn btn-ghost" type="button" onclick={() => (warnModalOpen = false)}>Cancel</button>
      <button
        class="btn btn-primary"
        type="button"
        disabled={!warnMessage.trim()}
        onclick={handleWarn}
      >Send Warning</button>
    </div>
  {/if}
</Modal>

<!-- Action Confirmation Modal -->
<Modal bind:open={actionModalOpen} title="{actionLabel(actionType)} User">
  {#if actionTarget}
    <p class="modal-text">
      Apply <strong>{actionLabel(actionType)}</strong> to <strong>@{actionTarget.handle}</strong>?
    </p>
    {#if actionType === 'silence' || actionType === 'shadow_ban' || actionType === 'force_sensitive'}
      <div class="form-group">
        <label class="form-label" for="action-reason">Reason (optional)</label>
        <textarea
          id="action-reason"
          class="textarea"
          bind:value={actionReason}
          placeholder="Reason..."
          rows="3"
        ></textarea>
      </div>
    {/if}
    <div class="modal-actions">
      <button class="btn btn-ghost" type="button" onclick={() => (actionModalOpen = false)}>Cancel</button>
      <button
        class="btn btn-primary"
        type="button"
        disabled={actionSubmitting}
        onclick={handleAction}
      >
        {actionSubmitting ? 'Applying...' : 'Confirm'}
      </button>
    </div>
  {/if}
</Modal>

<!-- Trust Level Modal -->
<Modal bind:open={trustModalOpen} title="Set Trust Level">
  {#if trustTarget}
    <p class="modal-text">Set trust level for <strong>@{trustTarget.handle}</strong></p>
    <div class="form-group">
      <label class="form-label" for="trust-level">Trust Level (0-4)</label>
      <input
        id="trust-level"
        class="input"
        type="number"
        min="0"
        max="4"
        bind:value={trustLevel}
      />
    </div>
    <div class="modal-actions">
      <button class="btn btn-ghost" type="button" onclick={() => (trustModalOpen = false)}>Cancel</button>
      <button class="btn btn-primary" type="button" onclick={handleSetTrustLevel}>Set Level</button>
    </div>
  {/if}
</Modal>

<!-- Verification Tier Modal -->
<Modal bind:open={tierModalOpen} title="Set Verification Tier">
  {#if tierTarget}
    <p class="modal-text">
      Grant <strong>@{tierTarget.handle}</strong> a verification tier without
      requiring them to purchase a subscription. Takes effect immediately.
    </p>
    <div class="tier-options">
      {#each tierOptions as opt (opt.value)}
        <label class="tier-option" class:tier-option-active={tierValue === opt.value}>
          <input
            type="radio"
            name="tier"
            value={opt.value}
            bind:group={tierValue}
          />
          <div class="tier-option-body">
            <span class="tier-option-label">{opt.label}</span>
            <span class="tier-option-desc">{opt.description}</span>
          </div>
        </label>
      {/each}
    </div>
    <div class="modal-actions">
      <button class="btn btn-ghost" type="button" onclick={() => (tierModalOpen = false)}>Cancel</button>
      <button
        class="btn btn-primary"
        type="button"
        disabled={tierSubmitting || tierValue === (tierTarget.verification_tier || 'free')}
        onclick={handleChangeTier}
      >
        {tierSubmitting ? 'Saving...' : 'Save'}
      </button>
    </div>
  {/if}
</Modal>

<!-- Change Email Modal -->
<Modal bind:open={emailModalOpen} title="Change Email">
  {#if emailTarget}
    <p class="modal-text">Set a new email for <strong>@{emailTarget.handle}</strong>.</p>
    <div class="form-group">
      <label class="form-label" for="new-email">Email</label>
      <input
        id="new-email"
        class="input"
        type="email"
        bind:value={emailValue}
        placeholder="user@example.com"
        autocomplete="off"
      />
    </div>
    <div class="modal-actions">
      <button class="btn btn-ghost" type="button" onclick={() => (emailModalOpen = false)}>Cancel</button>
      <button
        class="btn btn-primary"
        type="button"
        disabled={emailSubmitting || !emailValue.trim() || emailValue.trim() === emailTarget.email}
        onclick={handleChangeEmail}
      >
        {emailSubmitting ? 'Saving...' : 'Save'}
      </button>
    </div>
  {/if}
</Modal>

<!-- Reset Password Result Modal -->
<Modal bind:open={passwordModalOpen} title="New Password Generated">
  {#if passwordTarget}
    {#if passwordSubmitting}
      <p class="modal-text">Generating new password for <strong>@{passwordTarget.handle}</strong>…</p>
    {:else if generatedPassword}
      <p class="modal-text">
        New password for <strong>@{passwordTarget.handle}</strong>.
        Copy it now — it won't be shown again. All their sessions have been revoked.
      </p>
      <div class="password-display">
        <code class="password-code">{generatedPassword}</code>
        <button class="btn btn-sm btn-outline" type="button" onclick={copyGeneratedPassword}>Copy</button>
      </div>
    {/if}
    <div class="modal-actions">
      <button class="btn btn-primary" type="button" onclick={() => (passwordModalOpen = false)}>Done</button>
    </div>
  {/if}
</Modal>

<!-- Moderation Notes Modal -->
<Modal bind:open={notesModalOpen} title="Moderation Notes">
  {#if notesTarget}
    <p class="modal-text">Notes for <strong>@{notesTarget.handle}</strong></p>

    <form class="notes-add-form" onsubmit={(e) => { e.preventDefault(); handleAddNote(); }}>
      <textarea
        class="textarea"
        bind:value={newNote}
        placeholder="Add a moderation note..."
        rows="2"
      ></textarea>
      <button class="btn btn-sm btn-primary" type="submit" disabled={!newNote.trim()}>Add Note</button>
    </form>

    {#if notesLoading}
      <div class="skeleton" style="height: 40px; margin-top: var(--space-3)"></div>
    {:else}
      <div class="notes-list">
        {#each notes as note (note.id)}
          <div class="note-item">
            <div class="note-content">{note.content}</div>
            <div class="note-meta">
              <span class="text-secondary">@{note.author.handle} - {formatDate(note.created_at)}</span>
              <button
                class="btn btn-sm btn-ghost btn-danger-text"
                type="button"
                onclick={() => handleDeleteNote(note.id)}
              >Delete</button>
            </div>
          </div>
        {:else}
          <p class="empty-text">No moderation notes</p>
        {/each}
      </div>
    {/if}
  {/if}
</Modal>

<Modal bind:open={rolesModalOpen} title="Manage Roles">
  {#if rolesTarget}
    <p class="modal-text">
      Grant or revoke roles for <strong>@{rolesTarget.handle}</strong>.
      Role permissions are additive — a user gets every permission from every role they hold.
    </p>
    {#if rolesLoading}
      <div class="skeleton" style="height: 60px"></div>
      <div class="skeleton" style="height: 60px; margin-block-start: 8px"></div>
    {:else if allRoles.length === 0}
      <p class="empty-text">No roles defined.</p>
    {:else}
      <ul class="roles-list">
        {#each allRoles as role (role.id)}
          {@const assigned = assignmentForRole(role.id)}
          <li class="role-row" class:role-assigned={!!assigned}>
            <div class="role-info">
              <div class="role-name-row">
                <span class="role-name">{role.name}</span>
                {#if role.is_system}
                  <span class="role-system-badge">system</span>
                {/if}
              </div>
              {#if role.description}
                <div class="role-description">{role.description}</div>
              {/if}
              <div class="role-permissions-summary">
                {role.permissions.length} {role.permissions.length === 1 ? 'permission' : 'permissions'}
              </div>
              {#if assigned}
                <div class="role-granted">
                  Granted {new Date(assigned.granted_at).toLocaleDateString()}
                </div>
              {/if}
            </div>
            <button
              class="btn btn-sm {assigned ? 'btn-danger' : 'btn-primary'}"
              type="button"
              disabled={rolesBusyRoleId === role.id}
              onclick={() => handleToggleRole(role)}
            >
              {rolesBusyRoleId === role.id ? '...' : (assigned ? 'Revoke' : 'Assign')}
            </button>
          </li>
        {/each}
      </ul>
    {/if}
    <div class="modal-actions">
      <button class="btn btn-ghost" type="button" onclick={() => (rolesModalOpen = false)}>Close</button>
    </div>
  {/if}
</Modal>

<style>
  .users-page {
    max-width: 1200px;
  }

  .page-title {
    font-size: var(--text-2xl);
    font-weight: 700;
    margin-block-end: var(--space-6);
  }

  .toolbar {
    display: flex;
    gap: var(--space-3);
    margin-block-end: var(--space-4);
  }

  .pinned-banner {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-3);
    padding: var(--space-2) var(--space-3);
    margin-block-end: var(--space-3);
    background: var(--color-secondary-container);
    border-radius: var(--radius-md);
    font-size: var(--text-sm);
    color: var(--color-primary);
  }

  .pinned-banner-btn {
    background: transparent;
    border: 1px solid var(--color-primary);
    color: var(--color-primary);
    padding: 4px 10px;
    border-radius: var(--radius-full);
    font-size: var(--text-xs);
    font-weight: 600;
    cursor: pointer;
  }

  .pinned-banner-btn:hover {
    background: var(--color-primary);
    color: var(--color-on-primary);
  }

  .search-bar {
    flex: 1;
    max-width: 400px;
  }

  .status-select {
    width: 160px;
  }

  .user-cell {
    display: flex;
    flex-direction: column;
  }

  .user-handle {
    font-weight: 600;
  }

  .user-display {
    font-size: var(--text-xs);
    color: var(--color-text-secondary);
  }

  .status-badge {
    font-size: var(--text-xs);
    font-weight: 600;
    padding: 2px var(--space-2);
    border-radius: var(--radius-full);
    text-transform: capitalize;
  }

  .status-active {
    background: var(--color-success-soft);
    color: #166534;
  }

  .status-suspended {
    background: var(--color-danger-soft);
    color: #991b1b;
  }

  .status-pending {
    background: var(--color-warning-soft);
    color: #92400e;
  }

  .flag-badges {
    display: flex;
    flex-wrap: wrap;
    gap: 2px;
  }

  .flag-badge {
    font-size: 10px;
    font-weight: 600;
    padding: 1px var(--space-1);
    border-radius: var(--radius-sm);
    text-transform: uppercase;
    white-space: nowrap;
  }

  .flag-silenced {
    background: var(--color-warning-soft);
    color: #92400e;
  }

  .flag-shadow {
    background: var(--color-surface);
    color: var(--color-text-secondary);
  }

  .flag-sensitive {
    background: var(--color-info-soft);
    color: #1e40af;
  }

  .trust-level {
    font-size: var(--text-xs);
    font-weight: 600;
    color: var(--color-text-secondary);
  }

  .action-buttons {
    display: flex;
    gap: var(--space-2);
    align-items: center;
  }

  .dropdown {
    position: relative;
  }

  .dropdown-menu {
    position: fixed;
    z-index: 9999;
    min-width: 180px;
    background: var(--color-surface-raised, white);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    box-shadow: var(--shadow-lg);
    padding: var(--space-1);
  }

  .dropdown-item {
    display: block;
    width: 100%;
    padding: var(--space-2) var(--space-3);
    border: none;
    background: none;
    font-size: var(--text-sm);
    color: var(--color-text);
    text-align: left;
    cursor: pointer;
    border-radius: var(--radius-sm);
    transition: background var(--transition-fast);
  }

  .dropdown-item:hover {
    background: var(--color-surface);
  }

  .dropdown-divider {
    margin: var(--space-1) 0;
    border: none;
    border-top: 1px solid var(--color-border);
  }

  .modal-text {
    margin-block-end: var(--space-3);
    font-size: var(--text-sm);
  }

  .form-group {
    margin-block-end: var(--space-4);
  }

  .form-label {
    display: block;
    font-size: var(--text-sm);
    font-weight: 600;
    margin-block-end: var(--space-1);
    color: var(--color-text);
  }

  .modal-actions {
    display: flex;
    justify-content: flex-end;
    gap: var(--space-2);
    margin-block-start: var(--space-4);
  }

  .password-display {
    display: flex;
    align-items: center;
    gap: var(--space-2);
    padding: var(--space-3);
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    margin-block: var(--space-3);
  }

  .password-code {
    flex: 1;
    font-family: var(--font-mono, monospace);
    font-size: var(--text-base);
    font-weight: 600;
    color: var(--color-text);
    word-break: break-all;
    user-select: all;
  }

  .notes-add-form {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    margin-block-end: var(--space-4);
  }

  .notes-add-form .btn {
    align-self: flex-end;
  }

  .notes-list {
    display: flex;
    flex-direction: column;
    gap: var(--space-3);
  }

  .note-item {
    border-block-end: 1px solid var(--color-border);
    padding-block-end: var(--space-3);
  }

  .note-content {
    font-size: var(--text-sm);
    margin-block-end: var(--space-1);
  }

  .note-meta {
    display: flex;
    align-items: center;
    justify-content: space-between;
    font-size: var(--text-xs);
  }

  .btn-danger-text {
    color: var(--color-danger);
  }

  .empty-text {
    color: var(--color-text-tertiary);
    font-size: var(--text-sm);
    text-align: center;
    padding: var(--space-4) 0;
  }

  @media (max-width: 768px) {
    .toolbar {
      flex-direction: column;
    }

    .search-bar {
      max-width: none;
    }

    .status-select {
      width: 100%;
    }
  }

  /* Location tabs */
  .location-tabs {
    display: flex;
    gap: 2px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 10px;
    padding: 3px;
    margin-block-end: var(--space-4);
    max-width: 300px;
  }

  .loc-tab {
    flex: 1;
    padding: 6px 14px;
    border: none;
    border-radius: 8px;
    background: transparent;
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--color-text-secondary);
    cursor: pointer;
    transition: all 150ms ease;
  }

  .loc-tab:hover { color: var(--color-text); }

  .loc-tab-active {
    background: var(--color-primary);
    color: white;
  }

  .loc-tab-active:hover { color: white; }

  /* User identity cell */
  .user-identity {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 4px 0;
  }

  .subaccount-row {
    padding-inline-start: 28px;
    position: relative;
  }

  .subaccount-row::before {
    content: '';
    position: absolute;
    inset-block: 0;
    inset-inline-start: 14px;
    width: 2px;
    background: var(--color-border);
  }

  .subaccount-angle {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 18px;
    font-size: 1.05rem;
    color: var(--color-text-tertiary);
    margin-inline-end: -4px;
    flex-shrink: 0;
    line-height: 1;
  }

  .user-avatar {
    width: 36px;
    height: 36px;
    border-radius: 50%;
    object-fit: cover;
    flex-shrink: 0;
  }

  .user-avatar-placeholder {
    display: flex;
    align-items: center;
    justify-content: center;
    background: var(--color-primary-soft);
    color: var(--color-primary);
    font-size: 0.875rem;
    font-weight: 700;
  }

  .user-info-col {
    display: flex;
    flex-direction: column;
    gap: 1px;
    min-width: 0;
  }

  .user-display-name {
    font-size: 0.875rem;
    font-weight: 600;
    color: var(--color-text);
    line-height: 1.3;
  }

  .user-handle {
    font-size: 0.8125rem;
    color: var(--color-text-secondary);
    font-weight: 400;
  }

  .user-domain-badge {
    display: inline-flex;
    align-items: center;
    gap: 3px;
    font-size: 0.65rem;
    color: var(--color-text-tertiary);
    background: var(--color-surface);
    padding: 1px 6px;
    border-radius: 4px;
    width: fit-content;
    margin-block-start: 2px;
  }

  .user-local-badge {
    display: inline-block;
    font-size: 0.6rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.03em;
    color: var(--color-success, #22c55e);
    background: rgba(34, 197, 94, 0.1);
    padding: 1px 6px;
    border-radius: 4px;
    width: fit-content;
    margin-block-start: 2px;
  }

  /* Sub-accounts (bots / groups / pages owned by a parent user)
     deserve their own pill so the row isn't visually conflated with
     a top-level local account. */
  .user-subaccount-badge {
    color: var(--color-primary);
    background: var(--color-primary-soft, rgba(20, 184, 166, 0.1));
  }

  .email-cell {
    display: inline-flex;
    align-items: center;
    gap: 6px;
  }

  .email-unverified-pill {
    font-size: 0.65rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.03em;
    color: #92400e;
    background: rgba(234, 179, 8, 0.18);
    padding: 1px 6px;
    border-radius: 4px;
  }

  /* Highlight local accounts that haven't confirmed their email yet —
     applied to the <tr> via DataTable's rowClass hook so it overrides
     both the zebra striping and the row hover background. */
  :global(.data-table tbody tr.row-email-unverified) {
    background: rgba(234, 179, 8, 0.10);
  }

  :global(.data-table tbody tr.row-email-unverified:hover) {
    background: rgba(234, 179, 8, 0.18);
  }

  :global(.data-table tbody tr.row-email-unverified:nth-child(even)) {
    background: rgba(234, 179, 8, 0.13);
  }

  /* Pagination footer below the user table. */
  .pagination {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: var(--space-3);
    margin-block-start: var(--space-4);
    padding: var(--space-2);
  }

  .page-btn {
    padding: 6px 14px;
    border: 1px solid var(--color-border);
    border-radius: 9999px;
    background: var(--color-surface);
    color: var(--color-text);
    font-size: var(--text-sm);
    font-weight: 600;
    cursor: pointer;
  }

  .page-btn:hover:not(:disabled) {
    border-color: var(--color-primary);
    color: var(--color-primary);
  }

  .page-btn:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  .page-info {
    font-size: var(--text-sm);
    color: var(--color-text-secondary);
    font-variant-numeric: tabular-nums;
  }

  .page-info-count {
    color: var(--color-text-tertiary);
    margin-inline-start: 6px;
  }

  /* Manage Roles modal */
  .roles-list {
    list-style: none;
    padding: 0;
    margin: var(--space-3) 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    max-height: 420px;
    overflow-y: auto;
  }

  .role-row {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: var(--space-3);
    padding: var(--space-3);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    transition: border-color var(--transition-fast), background var(--transition-fast);
  }

  .role-row.role-assigned {
    border-color: var(--color-primary);
    background: var(--color-secondary-container);
  }

  .role-info {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
    flex: 1;
  }

  .role-name-row {
    display: flex;
    align-items: center;
    gap: var(--space-2);
  }

  .role-name {
    font-weight: 600;
    font-size: var(--text-sm);
    text-transform: capitalize;
  }

  .role-system-badge {
    font-size: 0.65rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: var(--color-text-secondary);
    background: var(--color-surface);
    padding: 1px 6px;
    border-radius: var(--radius-full);
  }

  .role-description {
    font-size: var(--text-xs);
    color: var(--color-text-secondary);
    line-height: 1.4;
  }

  .role-permissions-summary {
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
    margin-block-start: 2px;
  }

  .role-granted {
    font-size: var(--text-xs);
    color: var(--color-primary);
    margin-block-start: 2px;
  }

  .tier-options {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    margin-block: var(--space-3);
  }

  .tier-option {
    display: flex;
    align-items: flex-start;
    gap: var(--space-3);
    padding: var(--space-3);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    cursor: pointer;
    transition: background 120ms ease, border-color 120ms ease;
  }

  .tier-option:hover {
    background: var(--color-surface);
  }

  .tier-option-active {
    border-color: var(--color-primary);
    background: var(--color-primary-soft, var(--color-surface));
  }

  .tier-option input[type='radio'] {
    margin-block-start: 4px;
  }

  .tier-option-body {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .tier-option-label {
    font-size: var(--text-sm);
    font-weight: 600;
    color: var(--color-text);
  }

  .tier-option-desc {
    font-size: var(--text-xs);
    color: var(--color-text-tertiary);
  }
</style>
