import Link from "next/link";
import { redirect } from "next/navigation";
import { ShieldCheck, UserRoundPlus, Users } from "lucide-react";
import { signOut } from "@/app/actions/auth";
import { createClient } from "@/lib/supabase/server";
import { inviteStaffMember, saveStaffMembership } from "./actions";

export const instant = false;
type StaffPageProps = { searchParams: Promise<Record<string, string | undefined>> };
const roleOptions = ["super_admin", "admin", "receptionist", "doctor", "lab_technician", "radiology_technician", "radiologist", "pharmacist", "accountant", "auditor"] as const;

export default async function StaffPage({ searchParams }: StaffPageProps) {
  const params = await searchParams;
  const supabase = await createClient();
  const { data: claimsData, error: claimsError } = await supabase.auth.getClaims();
  if (!claimsData?.claims || claimsError) redirect("/login");
  const { data: membership, error: membershipError } = await supabase.from("clinic_memberships").select("clinic_id, role")
    .eq("user_id", String(claimsData.claims.sub ?? "")).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (membershipError || !membership || !["super_admin", "admin"].includes(membership.role)) redirect("/");
  const [clinicResult, membershipResult] = await Promise.all([
    supabase.from("clinics").select("name").eq("id", membership.clinic_id).maybeSingle(),
    supabase.from("clinic_memberships").select("id, user_id, role, active, created_at")
      .eq("clinic_id", membership.clinic_id).order("created_at", { ascending: true }),
  ]);
  const userIds = (membershipResult.data ?? []).map((member) => member.user_id);
  const profilesResult = userIds.length ? await supabase.from("profiles").select("id, full_name, phone, active").in("id", userIds) : { data: [], error: null };
  const profiles = new Map((profilesResult.data ?? []).map((profile) => [profile.id, profile]));
  const canAssignAdmin = membership.role === "super_admin";
  const errors: Record<string, string> = {
    invalid: "Enter a valid Auth user UUID and role.", forbidden: "Your role cannot change that staff access.",
    save: "The membership could not be saved. Confirm the user has an active profile and the assignment is allowed.",
    exists: "An Auth user with that email already exists. Use their user UUID in the role assignment form.",
    invite: "The invitation could not be sent. Deploy the invite-clinic-staff Edge Function and check its Auth email settings.",
    assignment: "The invitation was sent, but clinic role assignment failed. Use the invited user's UUID to assign access.",
  };

  return (
    <main className="patients-page staff-page">
      <header className="patients-topbar"><Link className="patients-brand" href="/">✚ <b>cliniccare<span>pro</span></b></Link><nav><Link href="/">Overview</Link><span>/</span><strong>Staff</strong></nav><div className="patients-user"><Link href="/">{String(claimsData.claims.email ?? "Clinic account")}</Link><form action={signOut}><button>Sign out</button></form></div></header>
      <div className="patients-content">
        <div className="patients-title-row"><div><p className="patients-eyebrow">ADMINISTRATION / ACCESS</p><h1>Staff access</h1><p>{clinicResult.data?.name ?? "Your clinic"} · Manage roles for provisioned staff accounts</p></div><span className="appointment-count"><Users size={15} /> {membershipResult.data?.filter((member) => member.active).length ?? 0} active members</span></div>
        {params.saved && <div className="patient-alert success" role="status">Staff membership saved.</div>}
        {params.invited && <div className="patient-alert success" role="status">Invitation sent and clinic role assigned.</div>}
        {params.error && errors[params.error] && <div className="patient-alert error" role="alert">{errors[params.error]}</div>}

        {membership.role === "super_admin" || membership.role === "admin" ? <section className="patient-form-card" id="invite"><div className="patient-form-heading"><span><UserRoundPlus size={17} /></span><div><h2>Invite staff member</h2><p>Send an Auth invitation and assign the selected clinic role.</p></div></div>
          <form action={inviteStaffMember} className="patient-form staff-form"><label>Full name *<input name="fullName" required minLength={2} maxLength={160} /></label><label>Email *<input name="email" type="email" required maxLength={254} /></label><label>Phone<input name="phone" type="tel" maxLength={32} /></label><label>Role *<select name="role" defaultValue="receptionist">{roleOptions.filter((role) => canAssignAdmin || !["super_admin", "admin"].includes(role)).map((role) => <option key={role} value={role}>{role.replaceAll("_", " ")}</option>)}</select></label><div className="patient-form-actions"><span>Only super administrators can invite administrator roles.</span><button type="submit">Invite staff</button></div></form>
        </section> : null}

        <div className="patient-alert" role="note"><b>Existing accounts:</b> to give clinic access to a user who already has a Supabase Auth account, assign their UUID below. Auth invitations require the `invite-clinic-staff` Edge Function to be deployed.</div>

        <section className="patient-form-card"><div className="patient-form-heading"><span><UserRoundPlus size={17} /></span><div><h2>Assign clinic role</h2><p>Enter the UUID of a provisioned Auth user with an active profile.</p></div></div>
          <form action={saveStaffMembership} className="patient-form staff-form"><label>Auth user UUID *<input name="userId" required pattern="[0-9a-fA-F-]{36}" placeholder="00000000-0000-0000-0000-000000000000" /></label><label>Role *<select name="role" defaultValue="receptionist">{roleOptions.filter((role) => canAssignAdmin || !["super_admin", "admin"].includes(role)).map((role) => <option key={role} value={role}>{role.replaceAll("_", " ")}</option>)}</select></label><input type="hidden" name="active" value="true" /><div className="patient-form-actions"><span>Only super administrators can assign admin roles.</span><button type="submit">Save staff access</button></div></form>
        </section>

        <section className="patients-table-card"><div className="patients-table-heading"><div><h2>Clinic memberships</h2><p>Role assignments are audited and scoped to this clinic.</p></div><ShieldCheck size={18} color="#377ae0" /></div>
          {membershipResult.error ? <div className="patients-empty"><b>Unable to load staff memberships</b><p>Check database setup and administrator policies.</p></div> : membershipResult.data?.length ? <div className="patients-table-scroll"><table className="patients-table staff-table"><thead><tr><th>Staff member</th><th>Role</th><th>Account</th><th>Clinic access</th><th>Update access</th></tr></thead><tbody>{membershipResult.data.map((member) => {
            const profile = profiles.get(member.user_id);
            const rolesForMember = canAssignAdmin ? roleOptions : roleOptions.filter((role) => !["super_admin", "admin"].includes(role));
            return <tr key={member.id}><td><b>{profile?.full_name ?? "Profile unavailable"}</b><small>{profile?.phone ?? member.user_id}</small></td><td>{member.role.replaceAll("_", " ")}</td><td>{profile?.active ? "Active" : "Inactive"}</td><td>{member.active ? "Active" : "Disabled"}</td><td><form action={saveStaffMembership} className="staff-inline-form"><input type="hidden" name="userId" value={member.user_id} /><select name="role" defaultValue={member.role}>{rolesForMember.map((role) => <option key={role} value={role}>{role.replaceAll("_", " ")}</option>)}</select><select name="active" defaultValue={String(member.active)}><option value="true">Active</option><option value="false">Disabled</option></select><button type="submit">Save</button></form></td></tr>;
          })}</tbody></table></div> : <div className="patients-empty"><b>No clinic memberships</b><p>Provision staff profiles and assign roles to grant access.</p></div>}
        </section>
      </div>
    </main>
  );
}
