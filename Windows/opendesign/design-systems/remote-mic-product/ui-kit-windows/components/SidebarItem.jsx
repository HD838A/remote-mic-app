export function SidebarItem({ icon, label, selected = false }) {
  return (
    <button className={`sidebar-item${selected ? " selected" : ""}`} aria-current={selected ? "page" : undefined}>
      <span className="sidebar-icon" aria-hidden="true">{icon}</span>
      <span>{label}</span>
    </button>
  );
}
