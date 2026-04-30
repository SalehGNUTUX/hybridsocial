<script lang="ts">
  import { goto } from '$app/navigation';
  import { onMount } from 'svelte';

  // /admin/user-management has no content of its own — open it and you
  // land on the Users tab. SPA-replace so the back button skips the
  // empty intermediate.
  onMount(() => {
    goto('/admin/user-management/users', { replaceState: true });
  });
</script>
