"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import {
  Activity, CalendarDays, ChartNoAxesCombined, FileText, FlaskConical,
  History, LayoutDashboard, Pill, Receipt, ScanLine, Settings, Stethoscope, Users,
} from "lucide-react";
import type { ReactNode } from "react";
import { signOut } from "@/app/actions/auth";

const links = [
  { label: "Overview", href: "/", Icon: LayoutDashboard },
  { label: "Appointments", href: "/appointments", Icon: CalendarDays },
  { label: "Patients", href: "/patients", Icon: Users },
  { label: "Doctors", href: "/doctors", Icon: Stethoscope },
  { label: "Encounters", href: "/encounters", Icon: Activity },
  { label: "Laboratory", href: "/laboratory", Icon: FlaskConical },
  { label: "Imaging", href: "/imaging", Icon: ScanLine },
  { label: "Reports", href: "/reports", Icon: FileText },
  { label: "Pharmacy", href: "/pharmacy", Icon: Pill },
  { label: "Billing", href: "/billing", Icon: Receipt },
  { label: "Staff", href: "/staff", Icon: Users },
  { label: "Audit log", href: "/audit", Icon: History },
  { label: "Settings", href: "/settings", Icon: Settings },
];

const hiddenRoutes = new Set(["/login", "/reset-password", "/reset-password/update"]);

export default function AppFrame({ children }: { children: ReactNode }) {
  const pathname = usePathname();
  if (pathname === "/" || hiddenRoutes.has(pathname) || pathname.startsWith("/auth/")) {
    return <>{children}</>;
  }

  return (
    <div className="app-shell global-app-shell">
      <aside className="sidebar" aria-label="Clinic navigation">
        <Link className="brand" href="/">
          <span className="brand-mark"><span>✚</span></span>
          <span className="brand-copy"><strong>cliniccare<span>pro</span></strong><small>CARE, CONNECTED.</small></span>
        </Link>
        <div className="clinic-switch">
          <span className="clinic-avatar">CC</span>
          <span className="clinic-copy"><b>ClinicCare Clinic</b><small>Clinic workspace</small></span>
          <span className="chevron">⌄</span>
        </div>
        <nav aria-label="Main navigation" className="nav-groups global-nav-groups">
          <section className="nav-group">
            <p className="nav-heading">CLINIC WORKSPACE</p>
            {links.map(({ label, href, Icon }) => {
              const selected = href === "/" ? pathname === "/" : pathname === href || pathname.startsWith(`${href}/`);
              return (
                <Link key={href} href={href} className={`nav-link${selected ? " selected" : ""}`} aria-current={selected ? "page" : undefined}>
                  <span className="icon" aria-hidden="true"><Icon size={16} strokeWidth={1.8} /></span>
                  <span>{label}</span>
                </Link>
              );
            })}
          </section>
        </nav>
        <div className="sidebar-bottom global-sidebar-bottom">
          <form action={signOut}><button className="user-profile" type="submit"><span className="user-avatar">CC</span><span><b>Clinic account</b><small>Sign out</small></span><span className="more">↗</span></button></form>
        </div>
      </aside>
      <section className="main-area global-main-area">{children}</section>
    </div>
  );
}
