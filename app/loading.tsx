export default function Loading() {
  return (
    <main className="route-loading" role="status" aria-live="polite">
      <span className="route-loading-spinner" aria-hidden="true" />
      <p>Loading clinic workspace…</p>
    </main>
  );
}
