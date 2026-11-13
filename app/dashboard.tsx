"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";

type DashboardStats = {
  patients: number | null;
  appointments: number | null;
  doctors: number | null;
  encounters: number | null;
};

type AppointmentPreview = {
  id: string;
  startsAt: string;
  status: string;
  patientName: string;
  doctorName: string;
};

const metrics = [
  { label: "Registered patients", hint: "Active patient records", icon: "♙", key: "patients" },
  { label: "Appointments today", hint: "Scheduled for today", icon: "▦", key: "appointments" },
  { label: "Active doctors", hint: "Available clinic doctors", icon: "✚", key: "doctors" },
  { label: "Open encounters", hint: "Awaiting completion", icon: "≋", key: "encounters" },
];

export default function Dashboard({
  userEmail,
  role,
  stats,
  schedule,
}: {
  userEmail: string;
  role: string;
  stats: DashboardStats;
  schedule: AppointmentPreview[] | null;
}) {
  const router = useRouter();
  const displayName = userEmail ? userEmail.split("@")[0] : "Clinic administrator";
  const today = new Intl.DateTimeFormat("en-US", { weekday: "long", month: "long", day: "numeric", timeZone: "Asia/Karachi" }).format(new Date());
  const shortDate = new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", timeZone: "Asia/Karachi" }).format(new Date());
  const [active, setActive] = useState("Overview");
  const [query, setQuery] = useState("");
  const [notice, setNotice] = useState("");
  function choose(label: string) {
    if (["Patients", "Appointments", "Doctors", "Laboratory", "Billing", "Pharmacy", "Inventory", "Imaging", "Reports", "Analytics", "Audit log", "Settings"].includes(label)) {
      router.push(label === "Patients" ? "/patients" : label === "Doctors" ? "/doctors" : label === "Laboratory" ? "/laboratory" : label === "Billing" ? "/billing" : ["Pharmacy", "Inventory"].includes(label) ? "/pharmacy" : label === "Imaging" ? "/imaging" : ["Reports", "Analytics"].includes(label) ? "/reports" : label === "Audit log" ? "/audit" : label === "Settings" ? "/settings" : "/appointments");
      return;
    }
    if (label === "Staff") {
      router.push("/staff");
      return;
    }
    if (label === "Queue") {
      router.push(role === "doctor" ? "/encounters" : "/appointments");
      return;
    }
    setActive(label);
    setNotice(label === "Overview" ? "" : `${label} workspace is ready to connect.`);
  }

  return (
    <main className="dashboard-page">
      <section className="main-area">
        <header className="topbar">
          <div className="breadcrumb"><span>Clinic</span><b>/</b><strong>{active}</strong></div>
          <div className="top-actions">
            <label className="search"><span>⌕</span><input aria-label="Search workspace" placeholder="Search anything..." value={query} onChange={(e) => setQuery(e.target.value)} /><kbd>⌘ K</kbd></label>
            <button className="icon-button notification" aria-label="Notifications" onClick={() => router.push("/notifications")}>♧<i /></button>
            <span className="top-divider" /><button className="top-user" onClick={() => setNotice("Signed in as " + (userEmail || "clinic administrator") + ".")}><span className="user-avatar">CC</span><span>{userEmail || "Clinic administrator"}</span><b>⌄</b></button>
          </div>
        </header>

        <div className="page-content">
          <div className="welcome-row">
            <div><div className="eyebrow"><span className="live-dot" /> {today.toUpperCase()}</div><h1>Welcome, {displayName} <span>✳</span></h1><p>Here’s what’s happening at your clinic today.</p></div>
            <button className="primary-button" onClick={() => setNotice("Choose a module from the sidebar to create a new record.")}><span>＋</span> Create new <b>⌄</b></button>
          </div>

          {notice && <div className="notice" role="status"><span>ⓘ</span>{notice}<button aria-label="Dismiss" onClick={() => setNotice("")}>×</button></div>}

          <div className="section-heading"><div><h2>Your clinic at a glance</h2><p>Live overview across your clinic</p></div><button className="date-button" onClick={() => setNotice("Showing today’s clinic activity.")}>◷ <span>Today, {shortDate}</span><b>⌄</b></button></div>

          <div className="metric-grid">
            {metrics.map((metric, i) => <article className="metric-card" key={metric.label}>
              <div className="metric-top"><span className={`metric-icon metric-${i}`}>{metric.icon}</span><button className="card-menu" aria-label={`More about ${metric.label}`} onClick={() => setNotice(`Data for ${metric.label.toLowerCase()} will appear when your clinic database is connected.`)}>···</button></div>
              <p className="metric-label">{metric.label}</p><div className="metric-value">{stats[metric.key as keyof DashboardStats] ?? "—"}</div><div className="metric-foot"><span className="empty-indicator">{stats[metric.key as keyof DashboardStats] === null ? "Unavailable" : "Live clinic data"}</span><span>{metric.hint}</span></div>
            </article>)}
          </div>

          <div className="content-grid">
            <article className="panel activity-panel">
              <div className="panel-header"><div><h3>Clinic activity</h3><p>Appointments and patient visits</p></div><button className="subtle-button" onClick={() => choose("Appointments")}>View appointments <span>→</span></button></div>
              <div className="chart-legend"><span><i className="legend-blue" /> Patient visits</span><span><i className="legend-mint" /> Appointments</span><button onClick={() => setNotice("Activity chart is waiting for connected clinic data.")}>This week⌄</button></div>
              <div className="chart-wrap">
                <div className="y-labels"><span>40</span><span>30</span><span>20</span><span>10</span><span>0</span></div>
                <div className="chart">
                  {[0, 1, 2, 3, 4].map((n) => <div className="gridline" key={n}><span /></div>)}
                  <div className="chart-empty"><span className="chart-empty-icon">⌁</span><b>Activity will show here</b><small>Connect your clinic data to see patient and appointment trends.</small></div>
                  <div className="x-labels"><span>Mon</span><span>Tue</span><span>Wed</span><span>Thu</span><span>Fri</span><span>Sat</span><span>Sun</span></div>
                </div>
              </div>
            </article>

            <article className="panel schedule-panel">
              <div className="panel-header"><div><h3>Today’s schedule</h3><p>Your upcoming appointments</p></div><button className="round-arrow" aria-label="Open appointments" onClick={() => choose("Appointments")}>↗</button></div>
              {schedule === null ? (
                <div className="schedule-empty"><div className="empty-calendar">▦</div><b>Schedule unavailable</b><p>We could not load appointment records.</p></div>
              ) : schedule.length === 0 ? (
                <div className="schedule-empty"><div className="empty-calendar">▦<span>✓</span></div><b>Nothing scheduled yet</b><p>Appointments booked for today will appear here.</p><button onClick={() => choose("Appointments")}>Go to appointments <span>→</span></button></div>
              ) : (
                <div className="schedule-list">{schedule.map((appointment) => <div className="schedule-row" key={appointment.id}>
                  <time>{new Intl.DateTimeFormat("en", { hour: "numeric", minute: "2-digit", timeZone: "Asia/Karachi" }).format(new Date(appointment.startsAt))}</time>
                  <span className="schedule-person"><b>{appointment.patientName}</b><small>Dr. {appointment.doctorName}</small></span>
                  <span className="appointment-status">{appointment.status.replaceAll("_", " ")}</span>
                </div>)}</div>
              )}
              <div className="schedule-footer"><span><i className="green-dot" /> Clinic is open</span><span>Until 6:00 PM</span></div>
            </article>
          </div>

          <div className="lower-grid">
            <article className="panel lower-panel">
              <div className="panel-header"><div><h3>Diagnostic orders</h3><p>Recent lab and imaging requests</p></div><button className="text-link" onClick={() => choose("Laboratory")}>View all →</button></div>
              <div className="table-empty"><span>▤</span><b>No diagnostic orders</b><small>New lab and imaging orders will appear here.</small></div>
            </article>
            <article className="panel lower-panel">
              <div className="panel-header"><div><h3>Quick access</h3><p>Common tasks, all in one place</p></div></div>
              <div className="quick-actions">
                {[["＋", "Register patient", "Add a patient profile"], ["▦", "Book appointment", "Schedule a clinic visit"], ["⚗", "Create lab order", "Request a diagnostic test"]].map(([icon, label, detail]) => <button key={label} onClick={() => label === "Register patient" ? router.push("/patients#register") : label === "Book appointment" ? router.push("/appointments#book") : router.push("/laboratory")}><span className="quick-icon">{icon}</span><span><b>{label}</b><small>{detail}</small></span><i>→</i></button>)}
              </div>
            </article>
          </div>
          <footer className="page-footer"><span>© 2026 ClinicCare Pro</span><span><i /> All systems operational</span><a href="#" onClick={(e) => { e.preventDefault(); setNotice("ClinicCare Pro version 1.0 · Workspace preview."); }}>Help & support</a></footer>
        </div>
      </section>
    </main>
  );
}

