# ClinicCare Pro

ClinicCare Pro is a clinic operations ERP built with Next.js App Router, TypeScript, Tailwind CSS, and Supabase. Implemented foundations include responsive dashboards, email/password sign-in, clinic-scoped access, and patient, doctor, appointment, and laboratory workflows.

## Current foundation

- Supabase Auth sign-in and session refresh through the Next.js 16 Proxy convention.
- Clinic-scoped tables for memberships, departments, patients, doctors, appointments, structured encounters, vitals, diagnoses, notes, a configurable lab catalog, lab orders, specimen tracking, results, verification events, pharmacy catalog/stock/prescriptions, imaging orders/reports, service catalog, bills, payments, notifications, and ledger entries.
- RLS policies that scope access through active clinic memberships.
- A database constraint that prevents overlapping active appointments for the same doctor.
- Server-backed dashboard counts and today’s schedule, plus patient, doctor, appointment, and LIMS pages.
- Database-enforced doctor appointment overlap prevention and atomic daily appointment tokens.
- Database-enforced lab pricing snapshots, configurable result fields, abnormal/critical flags, and technician/doctor verification order.
- Database-backed billing primitives and a `/billing` workspace: server-priced invoice snapshots, atomic invoice numbering, immutable issued line items, payment receipts, reversals, an audited expense log, and append-only double-entry payment journals. Invoice creation, issue, payment, reversal, and catalog actions are role-checked.
- `/pharmacy` tracks medication products, stock lots, expiry, receipts, prescription fulfillment, and append-only stock movements. Dispensing consumes eligible lots by earliest expiry.
- `/encounters` captures structured clinical notes, diagnoses, vitals, and prescriptions, and supports clinician sign-off. Starting a consultation from an appointment opens an encounter.
- `/imaging` handles service catalog setup, imaging orders, accession workflow, and signed/corrected radiology reports. A PACS/DICOM service must attach and validate studies before image acquisition can be completed.
- `/reports` provides date-filtered aggregated activity and finance totals with CSV export; `/notifications` provides in-app appointment and diagnostic-order alerts.
- `/staff`, `/settings`, and `/audit` provide clinic role assignment for provisioned accounts, clinic/department configuration, and a redacted event log.

PACS/DICOM image transfer, validation, and viewing are not connected; imaging orders and reports require that external integration to complete image acquisition. Initial clinic and first administrator provisioning still require a trusted setup workflow. Billing has an expense log but not full double-entry expense accounting, vendor reconciliation, or accounting-period workflows. Email/SMS/push delivery, document storage, and deployment hardening remain to be implemented. This project is not yet a production clinical system.

## Local setup

1. Create a Supabase project and copy its project URL and publishable key.
2. Copy .env.example to .env.local and set NEXT_PUBLIC_SUPABASE_URL, NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, and NEXT_PUBLIC_SITE_URL. Add the deployed callback URL to Supabase Auth redirect URLs.
3. Apply the migrations using Supabase CLI: run npx supabase login, npx supabase link --project-ref YOUR_PROJECT_REF, then npx supabase db push. Review the SQL before applying it.
4. Provision the first clinic, auth user, profile, and membership through a trusted administrator workflow or Supabase SQL editor. Public self-registration is intentionally disabled. For later staff invitations, deploy the `invite-clinic-staff` Edge Function; it uses Supabase's server-side service-role secret to invite and create the profile, then the app assigns membership through a role-checked RPC.
5. After linking the Supabase project, deploy staff invitations with `npx supabase functions deploy invite-clinic-staff`.
6. Run npm install and npm run dev.

The first migration creates the schema and RLS foundation, but it does not create a clinic administrator or clinic record. Add future schema changes as new migrations; do not rewrite migrations already applied.

## Security

- Only the Supabase URL and publishable key belong in NEXT_PUBLIC variables.
- Never add a Supabase service-role key to client code or commit real credentials.
- Keep RLS enabled for every patient-related table. Route handlers and server actions must validate inputs and enforce permissions independently of UI visibility.
- Audit entries are append-only. Represent corrections as new events.
- Imaging needs an authenticated DICOM/PACS integration; this project does not currently store or view medical images.

