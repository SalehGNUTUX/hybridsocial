<script lang="ts">
  // Previous/Next pager for admin lists that are fetched in full and
  // sliced client-side. Renders nothing when everything already fits on
  // one page, so a caller can drop it under any list unconditionally.
  //
  // The caller owns the slice — this component only moves `currentPage`
  // and reports where you are.
  let {
    currentPage = $bindable(1),
    totalItems,
    pageSize,
    itemLabel = 'items',
    ariaLabel = 'Pagination',
  }: {
    currentPage?: number;
    totalItems: number;
    pageSize: number;
    /** Plural noun for the total count, e.g. "instances". */
    itemLabel?: string;
    ariaLabel?: string;
  } = $props();

  let totalPages = $derived(Math.max(1, Math.ceil(totalItems / pageSize)));
</script>

{#if totalItems > pageSize}
  <nav class="pagination" aria-label={ariaLabel}>
    <button
      type="button"
      class="page-btn"
      onclick={() => (currentPage = Math.max(1, currentPage - 1))}
      disabled={currentPage <= 1}
    >
      Previous
    </button>
    <span class="page-info" aria-live="polite">
      Page {currentPage} of {totalPages}
      <span class="page-info-count">({totalItems.toLocaleString()} {itemLabel})</span>
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

<style>
  .pagination {
    display: flex;
    align-items: center;
    justify-content: center;
    flex-wrap: wrap;
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
    text-align: center;
  }

  .page-info-count {
    color: var(--color-text-tertiary);
  }
</style>
