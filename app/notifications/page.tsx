import Link from "next/link";
import { redirect } from "next/navigation";
import { Bell, CheckCheck, Circle } from "lucide-react";
import { signOut } from "@/app/actions/auth";
import { createClient } from "@/lib/supabase/server";
import { markAllNotificationsRead, markNotificationRead } from "./actions";

export const instant = false;

type NotificationsPageProps = { searchParams: Promise<Record<string, string | undefined>> };

export default async function NotificationsPage({ searchParams }: NotificationsPageProps) {
  const params = await searchParams;
  const supabase = await createClient();
  const { data: claimsData, error: claimsError } = await supabase.auth.getClaims();
  if (!claimsData?.claims || claimsError) redirect("/login");
  const { data: membership, error: membershipError } = await supabase.from("clinic_memberships").select("clinic_id")
    .eq("user_id", String(claimsData.claims.sub ?? "")).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (membershipError || !membership) redirect("/");
  const { data: notifications, error } = await supabase.from("clinic_notifications")
    .select("id, kind, title, message, href, created_at, read_at").eq("clinic_id", membership.clinic_id)
    .order("created_at", { ascending: false }).limit(100);
  const unreadCount = notifications?.filter((notification) => !notification.read_at).length ?? 0;

  return (
    <main className="patients-page notifications-page">
      <header className="patients-topbar"><Link className="patients-brand" href="/">✚ <b>cliniccare<span>pro</span></b></Link><nav><Link href="/">Overview</Link><span>/</span><strong>Notifications</strong></nav><div className="patients-user"><Link href="/">{String(claimsData.claims.email ?? "Clinic account")}</Link><form action={signOut}><button>Sign out</button></form></div></header>
      <div className="patients-content">
        <div className="patients-title-row"><div><p className="patients-eyebrow">WORKSPACE / INBOX</p><h1>Notifications</h1><p>Your clinic activity alerts · {unreadCount} unread</p></div>{unreadCount > 0 && <form action={markAllNotificationsRead}><button className="patient-add-button"><CheckCheck size={15} /> Mark all read</button></form>}</div>
        {params.read && <div className="patient-alert success" role="status">Notification status updated.</div>}
        {params.error && <div className="patient-alert error" role="alert">The notification action could not be completed.</div>}
        <section className="patients-table-card">
          <div className="patients-table-heading"><div><h2>Recent activity</h2><p>Notifications are private to your user account.</p></div><Bell size={18} color="#377ae0" /></div>
          {error ? <div className="patients-empty"><b>Unable to load notifications</b><p>Check your clinic membership and database policies.</p></div> : notifications?.length ? <div className="notification-list">{notifications.map((notification) => <article className={notification.read_at ? "notification-row read" : "notification-row unread"} key={notification.id}>
            <span className="notification-dot">{notification.read_at ? <Circle size={13} /> : <span />}</span><div className="notification-main"><div><b>{notification.title}</b><small>{notification.kind.replaceAll("_", " ")} · {new Intl.DateTimeFormat("en-PK", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Karachi" }).format(new Date(notification.created_at))}</small></div><p>{notification.message}</p><div className="notification-actions"><Link href={notification.href}>Open workspace →</Link>{!notification.read_at && <form action={markNotificationRead}><input type="hidden" name="notificationId" value={notification.id} /><button type="submit">Mark read</button></form>}</div></div>
          </article>)}</div> : <div className="patients-empty"><span><Bell size={18} /></span><b>You’re all caught up</b><p>New appointments and diagnostic orders will appear here.</p></div>}
        </section>
        <p className="patients-pagination">These are in-app alerts only. Email, SMS, and push delivery are not configured.</p>
      </div>
    </main>
  );
}
