-- Repeatable demo data for ClinicCare Pro.
-- Run in Supabase SQL Editor after migrations and after creating the clinic
-- membership for the login account. Change only v_email if using another user.
-- All names/results below are fictional demo data; no existing rows are deleted.

begin;

do $$
declare
  v_email text := 'moheebalam90@gmail.com';
  v_user_id uuid;
  v_clinic_id uuid;
  v_department_id uuid;
  v_doctor_id uuid := '10000000-0000-4000-8000-000000000001';
  v_patient_id uuid := '10000000-0000-4000-8000-000000000002';
  v_appointment_id uuid := '10000000-0000-4000-8000-000000000003';
  v_encounter_id uuid := '10000000-0000-4000-8000-000000000004';
  v_lab_category_id uuid := '10000000-0000-4000-8000-000000000005';
  v_lab_test_id uuid := '10000000-0000-4000-8000-000000000006';
  v_lab_order_id uuid := '10000000-0000-4000-8000-000000000007';
  v_lab_item_id uuid := '10000000-0000-4000-8000-000000000008';
  v_lab_result_id uuid := '10000000-0000-4000-8000-000000000009';
  v_imaging_service_id uuid := '10000000-0000-4000-8000-000000000010';
  v_imaging_order_id uuid := '10000000-0000-4000-8000-000000000011';
  v_imaging_study_id uuid := '10000000-0000-4000-8000-000000000012';
  v_bill_id uuid := '10000000-0000-4000-8000-000000000013';
  v_service_id uuid := '10000000-0000-4000-8000-000000000014';
  v_payment_id uuid := '10000000-0000-4000-8000-000000000015';
  v_journal_id uuid := '10000000-0000-4000-8000-000000000016';
  v_product_id uuid := '10000000-0000-4000-8000-000000000017';
  v_lot_id uuid := '10000000-0000-4000-8000-000000000018';
  v_prescription_id uuid := '10000000-0000-4000-8000-000000000019';
  v_prescription_item_id uuid := '10000000-0000-4000-8000-000000000020';
  v_notification_source uuid := '10000000-0000-4000-8000-000000000021';
begin
  select u.id into v_user_id
  from auth.users u
  where lower(u.email) = lower(v_email)
  limit 1;
  if v_user_id is null then
    raise exception 'No Supabase Auth user found for %. Update v_email in this seed file.', v_email;
  end if;

  select m.clinic_id into v_clinic_id
  from public.clinic_memberships m
  join public.clinics c on c.id = m.clinic_id and c.active
  where m.user_id = v_user_id and m.active
  order by m.created_at
  limit 1;
  if v_clinic_id is null then
    raise exception 'No active clinic membership found for %. Run the clinic bootstrap query first.', v_email;
  end if;

  insert into public.profiles (id, full_name, active)
  values (v_user_id, 'Clinic Administrator', true)
  on conflict (id) do update set active = true;

  insert into public.departments (clinic_id, name, active)
  values (v_clinic_id, 'General Medicine', true)
  on conflict (clinic_id, name) do update set active = true
  returning id into v_department_id;

  insert into public.doctors (id, clinic_id, profile_id, department_id, full_name, specialization,
    qualification, experience_years, consultation_fee, active)
  values (v_doctor_id, v_clinic_id, null, v_department_id, 'Dr. Amina Sample', 'Family Medicine',
    'MBBS', 8, 1500, true)
  on conflict (id) do nothing;

  insert into public.patients (id, clinic_id, mr_number, full_name, father_name, gender, date_of_birth,
    phone, email, address, blood_group, registration_date, created_by)
  values (v_patient_id, v_clinic_id, 'DEMO-0001', 'Sara Demo', 'Khalid Demo', 'female', '1994-06-15',
    '+923001234567', 'sara.demo@example.test', 'Demo Street, Lahore', 'O+', current_date, v_user_id)
  on conflict (clinic_id, mr_number) do update set full_name = excluded.full_name
  returning id into v_patient_id;

  insert into public.appointments (id, clinic_id, patient_id, doctor_id, starts_at, ends_at,
    token_number, status, reason, created_by)
  values (v_appointment_id, v_clinic_id, v_patient_id, v_doctor_id, now() + interval '2 hours',
    now() + interval '2 hours 30 minutes', 1, 'scheduled', 'Routine demo consultation', v_user_id)
  on conflict (id) do nothing;

  insert into public.encounters (id, clinic_id, patient_id, appointment_id, doctor_id, started_at)
  values (v_encounter_id, v_clinic_id, v_patient_id, v_appointment_id, v_doctor_id, now())
  on conflict (id) do nothing;

  insert into public.encounter_notes (clinic_id, encounter_id, kind, content, author_id)
  select v_clinic_id, v_encounter_id, 'chief_complaint',
    'Demo patient reports a mild headache for one day.', v_user_id
  where not exists (select 1 from public.encounter_notes
    where clinic_id = v_clinic_id and encounter_id = v_encounter_id and kind = 'chief_complaint');
  insert into public.encounter_notes (clinic_id, encounter_id, kind, content, author_id)
  select v_clinic_id, v_encounter_id, 'assessment',
    'Demo assessment: routine review; fictional sample only.', v_user_id
  where not exists (select 1 from public.encounter_notes
    where clinic_id = v_clinic_id and encounter_id = v_encounter_id and kind = 'assessment');

  insert into public.encounter_diagnoses (clinic_id, encounter_id, code, description, is_primary, recorded_by)
  select v_clinic_id, v_encounter_id, 'DEMO-01', 'Demo diagnosis for testing only', true, v_user_id
  where not exists (select 1 from public.encounter_diagnoses
    where clinic_id = v_clinic_id and encounter_id = v_encounter_id and code = 'DEMO-01');

  insert into public.vitals (clinic_id, encounter_id, recorded_by, systolic_bp, diastolic_bp,
    temperature_c, pulse_bpm, weight_kg, height_cm)
  select v_clinic_id, v_encounter_id, v_user_id, 118, 76, 36.8, 72, 62.5, 164
  where not exists (select 1 from public.vitals where clinic_id = v_clinic_id and encounter_id = v_encounter_id);

  insert into public.lab_categories (id, clinic_id, name, sort_order, active)
  values (v_lab_category_id, v_clinic_id, 'Demo Hematology', 1, true)
  on conflict (clinic_id, name) do update set active = true
  returning id into v_lab_category_id;

  insert into public.lab_tests (id, clinic_id, category_id, code, name, description, price,
    turnaround_minutes, result_schema, active)
  values (v_lab_test_id, v_clinic_id, v_lab_category_id, 'DEMO-CBC', 'Demo Complete Blood Count',
    'Fictional test catalog entry for software demonstration.', 1200, 120,
    '[{"key":"hemoglobin","label":"Hemoglobin","type":"number","unit":"g/dL"}]'::jsonb, true)
  on conflict (clinic_id, code) do update set active = true
  returning id into v_lab_test_id;

  insert into public.lab_orders (id, clinic_id, patient_id, ordered_by_doctor_id, created_by,
    priority, status, clinical_notes)
  values (v_lab_order_id, v_clinic_id, v_patient_id, v_doctor_id, v_user_id,
    'routine', 'completed', 'Demo laboratory order; fictional values.')
  on conflict (id) do nothing;

  insert into public.lab_order_items (id, clinic_id, order_id, test_id, test_name_snapshot,
    price_snapshot, status, assigned_technician_id)
  values (v_lab_item_id, v_clinic_id, v_lab_order_id, v_lab_test_id, 'Demo Complete Blood Count',
    1200, 'completed', v_user_id)
  on conflict (id) do nothing;

  insert into public.lab_samples (clinic_id, order_item_id, sample_number, sample_type,
    status, collected_by, collected_at)
  values (v_clinic_id, v_lab_item_id, 'DEMO-SAMPLE-0001', 'EDTA blood', 'completed', v_user_id, now())
  on conflict (clinic_id, sample_number) do nothing;

  insert into public.lab_results (id, clinic_id, order_item_id, version, result_values,
    reference_snapshot, abnormal_fields, critical, entered_by)
  values (v_lab_result_id, v_clinic_id, v_lab_item_id, 1,
    '{"hemoglobin":"13.4","wbc":"6.8","platelets":"250"}'::jsonb,
    '{"note":"Fictional demo result; not for clinical use."}'::jsonb, '{}', false, v_user_id)
  on conflict (id) do nothing;

  insert into public.lab_result_verifications (clinic_id, result_id, level, verified_by, notes)
  values (v_clinic_id, v_lab_result_id, 'technician_verified', v_user_id, 'Demo verification record.')
  on conflict (clinic_id, result_id, level) do nothing;

  insert into public.imaging_services (id, clinic_id, modality, code, name, body_region, price, active)
  values (v_imaging_service_id, v_clinic_id, 'xray', 'DEMO-CXR', 'Demo Chest X-ray', 'Chest', 2500, true)
  on conflict (clinic_id, code) do update set active = true
  returning id into v_imaging_service_id;

  insert into public.imaging_orders (id, clinic_id, patient_id, ordered_by_doctor_id, service_id,
    service_name_snapshot, modality, price_snapshot, priority, status, clinical_question, created_by)
  values (v_imaging_order_id, v_clinic_id, v_patient_id, v_doctor_id, v_imaging_service_id,
    'Demo Chest X-ray', 'xray', 2500, 'routine', 'scheduled',
    'Demo imaging request; no real image is attached.', v_user_id)
  on conflict (id) do nothing;

  insert into public.imaging_studies (id, clinic_id, order_id, accession_number, modality,
    dicom_study_uid, pacs_study_id, performed_by, performed_at)
  values (v_imaging_study_id, v_clinic_id, v_imaging_order_id, 'DEMO-IMG-0001', 'xray',
    null, null, null, null)
  on conflict (id) do nothing;

  insert into public.service_catalog (id, clinic_id, code, name, kind, unit_price, active)
  values (v_service_id, v_clinic_id, 'DEMO-CONSULT', 'Demo Consultation', 'consultation', 1500, true)
  on conflict (clinic_id, code) do update set active = true
  returning id into v_service_id;

  insert into public.bills (id, clinic_id, patient_id, invoice_number, created_by, notes)
  values (v_bill_id, v_clinic_id, v_patient_id, 'DEMO-INV-0001', v_user_id, 'Demo invoice; fictional data.')
  on conflict (id) do nothing;

  insert into public.bill_items (id, clinic_id, bill_id, service_id, kind, description_snapshot,
    quantity, unit_price_snapshot, discount_amount, tax_amount)
  values ('10000000-0000-4000-8000-000000000022', v_clinic_id, v_bill_id, v_service_id,
    'consultation', 'Demo Consultation', 1, 1500, 0, 0)
  on conflict (id) do nothing;

  update public.bills set issued_at = coalesce(issued_at, now()), issued_by = coalesce(issued_by, v_user_id)
  where id = v_bill_id;

  insert into public.payments (id, clinic_id, bill_id, entry_type, amount, method, reference,
    idempotency_key, received_by)
  values (v_payment_id, v_clinic_id, v_bill_id, 'payment', 500, 'cash', 'DEMO-CASH-001',
    '20000000-0000-4000-8000-000000000001', v_user_id)
  on conflict (id) do nothing;

  insert into public.ledger_journals (id, clinic_id, source_type, source_id, actor_id)
  values (v_journal_id, v_clinic_id, 'payment', v_payment_id, v_user_id)
  on conflict (id) do nothing;

  insert into public.ledger_entries (clinic_id, journal_id, account_code, debit, credit)
  select v_clinic_id, v_journal_id, 'cash', 500, 0
  where not exists (select 1 from public.ledger_entries where clinic_id = v_clinic_id and journal_id = v_journal_id)
  union all
  select v_clinic_id, v_journal_id, 'accounts_receivable', 0, 500
  where not exists (select 1 from public.ledger_entries where clinic_id = v_clinic_id and journal_id = v_journal_id);

  insert into public.expenses (id, clinic_id, category, description, amount, spent_at, recorded_by)
  values ('10000000-0000-4000-8000-000000000023', v_clinic_id, 'Supplies',
    'Demo office supplies expense', 250, current_date, v_user_id)
  on conflict (id) do nothing;

  insert into public.pharmacy_products (id, clinic_id, code, name, generic_name, strength,
    dosage_form, unit_label, sale_price, reorder_level, active)
  values (v_product_id, v_clinic_id, 'DEMO-PARA-500', 'Demo Paracetamol', 'Paracetamol',
    '500 mg', 'tablet', 'tablet', 10, 20, true)
  on conflict (clinic_id, code) do update set active = true
  returning id into v_product_id;

  insert into public.pharmacy_stock_lots (id, clinic_id, product_id, batch_number, expires_on,
    quantity_received, quantity_remaining, purchase_unit_cost, received_by)
  values (v_lot_id, v_clinic_id, v_product_id, 'DEMO-BATCH-001', current_date + 365,
    100, 100, 5, v_user_id)
  on conflict (id) do nothing;

  insert into public.pharmacy_stock_movements (clinic_id, product_id, lot_id, movement_type,
    quantity, source_id, actor_id)
  select v_clinic_id, v_product_id, v_lot_id, 'receipt', 100, v_lot_id, v_user_id
  where not exists (select 1 from public.pharmacy_stock_movements
    where clinic_id = v_clinic_id and source_id = v_lot_id and movement_type = 'receipt');

  insert into public.prescriptions (id, clinic_id, encounter_id, patient_id, doctor_id, prescribed_by)
  values (v_prescription_id, v_clinic_id, v_encounter_id, v_patient_id, v_doctor_id, v_user_id)
  on conflict (id) do nothing;

  insert into public.prescription_items (id, clinic_id, prescription_id, product_id,
    product_name_snapshot, strength_snapshot, dosage_form_snapshot, dose, frequency,
    duration_days, quantity, instructions)
  values (v_prescription_item_id, v_clinic_id, v_prescription_id, v_product_id,
    'Demo Paracetamol', '500 mg', 'tablet', '1 tablet', 'As directed by clinician',
    3, 9, 'Fictional demo prescription; not for patient care.')
  on conflict (id) do nothing;

  insert into public.clinic_notifications (clinic_id, recipient_id, kind, title, message,
    href, source_table, source_id)
  values (v_clinic_id, v_user_id, 'demo', 'Demo data loaded',
    'Fictional sample records are available to preview the clinic modules.',
    '/reports', 'demo_seed', v_notification_source)
  on conflict (clinic_id, recipient_id, source_table, source_id) do nothing;

  insert into public.audit_logs (clinic_id, actor_id, action, module, record_id, reason, new_values)
  select v_clinic_id, v_user_id, 'demo_seed', 'system', v_clinic_id::text,
    'Inserted fictional sample data for application preview.',
    jsonb_build_object('seed', 'ClinicCare Pro demo', 'fictional', true)
  where not exists (select 1 from public.audit_logs
    where clinic_id = v_clinic_id and action = 'demo_seed' and module = 'system');
end $$;

commit;
