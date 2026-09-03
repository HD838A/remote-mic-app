export function StatusCard({ title, detail, status, action }) {
  return (
    <section className="card status-card">
      <div>
        <h2>{title}</h2>
        <p>{detail}</p>
      </div>
      <div className="status-actions">
        <span className="status-pill">{status}</span>
        {action}
      </div>
    </section>
  );
}
