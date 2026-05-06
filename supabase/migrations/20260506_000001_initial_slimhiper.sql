-- SlimHiper - Initial Supabase/Postgres migration
-- Date: 2026-05-06
-- Scope: Foundational multi-tenant schemas, core entities, clinical/protocol flows,
--        engagement, documents, billing, integrations, audit/security and webhook ingest.

begin;

-- ============================================================
-- Extensions
-- ============================================================
create extension if not exists pgcrypto;

-- ============================================================
-- Schemas
-- ============================================================
create schema if not exists core;
create schema if not exists clinical;
create schema if not exists protocols;
create schema if not exists engagement;
create schema if not exists documents;
create schema if not exists billing;
create schema if not exists integrations;
create schema if not exists audit;
create schema if not exists security;

-- ============================================================
-- Helpers
-- ============================================================
create or replace function core.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- current tenant from request context/JWT claim
create or replace function core.current_tenant_id()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claim.tenant_id', true), '')::uuid;
$$;

-- ============================================================
-- CORE
-- ============================================================
create table if not exists core.tenants (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  legal_name text not null,
  trade_name text,
  status text not null default 'active' check (status in ('active','trial','suspended','cancelled')),
  timezone text not null default 'America/Sao_Paulo',
  locale text not null default 'pt-BR',
  asaas_subaccount_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists core.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  email text,
  phone text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists core.tenant_memberships (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  profile_id uuid not null references core.profiles(id) on delete cascade,
  role text not null,
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, profile_id),
  unique (tenant_id, profile_id, role)
);

create index if not exists idx_tenant_memberships_tenant on core.tenant_memberships(tenant_id);
create index if not exists idx_tenant_memberships_role on core.tenant_memberships(role);
create index if not exists idx_tenant_memberships_created_at on core.tenant_memberships(created_at desc);

create table if not exists core.tenant_roles (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  role_key text not null,
  description text,
  is_system boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, role_key)
);

create table if not exists core.tenant_role_permissions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  tenant_role_id uuid not null references core.tenant_roles(id) on delete cascade,
  permission_key text not null,
  created_at timestamptz not null default now(),
  unique (tenant_role_id, permission_key)
);

create index if not exists idx_tenant_roles_tenant on core.tenant_roles(tenant_id);
create index if not exists idx_tenant_role_permissions_tenant on core.tenant_role_permissions(tenant_id);

-- ============================================================
-- CLINICAL
-- ============================================================
create table if not exists clinical.patients (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  external_code text,
  full_name text not null,
  birth_date date,
  sex text,
  status text not null default 'active' check (status in ('active','inactive','archived')),
  asaas_customer_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, external_code)
);

create table if not exists clinical.patient_pii (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  patient_id uuid not null references clinical.patients(id) on delete cascade,
  cpf_hash text,
  email text,
  phone text,
  address_json jsonb,
  sensitive_json_encrypted text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, patient_id)
);

create table if not exists clinical.appointments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  patient_id uuid not null references clinical.patients(id) on delete restrict,
  provider_profile_id uuid references core.profiles(id) on delete set null,
  starts_at timestamptz not null,
  ends_at timestamptz,
  status text not null default 'scheduled' check (status in ('scheduled','confirmed','completed','cancelled','no_show')),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists clinical.queue_events (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  patient_id uuid not null references clinical.patients(id) on delete restrict,
  appointment_id uuid references clinical.appointments(id) on delete set null,
  event_type text not null,
  status text not null default 'open' check (status in ('open','in_progress','done','cancelled')),
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists clinical.encounters (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  patient_id uuid not null references clinical.patients(id) on delete restrict,
  appointment_id uuid references clinical.appointments(id) on delete set null,
  provider_profile_id uuid references core.profiles(id) on delete set null,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  status text not null default 'open' check (status in ('open','closed','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists clinical.soap_notes (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  encounter_id uuid not null references clinical.encounters(id) on delete cascade,
  patient_id uuid not null references clinical.patients(id) on delete restrict,
  subjective text,
  objective text,
  assessment text,
  plan text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists clinical.measurements (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  patient_id uuid not null references clinical.patients(id) on delete restrict,
  encounter_id uuid references clinical.encounters(id) on delete set null,
  measured_at timestamptz not null default now(),
  metric_key text not null,
  metric_value numeric(12,4) not null,
  unit text,
  status text not null default 'valid' check (status in ('valid','invalid')),
  created_at timestamptz not null default now()
);

create table if not exists clinical.bioimpedance_results (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  patient_id uuid not null references clinical.patients(id) on delete restrict,
  encounter_id uuid references clinical.encounters(id) on delete set null,
  measured_at timestamptz not null default now(),
  device_name text,
  result_json jsonb not null default '{}'::jsonb,
  status text not null default 'valid' check (status in ('valid','invalid')),
  created_at timestamptz not null default now()
);

create table if not exists clinical.lab_orders (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  patient_id uuid not null references clinical.patients(id) on delete restrict,
  encounter_id uuid references clinical.encounters(id) on delete set null,
  order_number text,
  status text not null default 'requested' check (status in ('requested','collected','resulted','cancelled')),
  requested_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, order_number)
);

create table if not exists clinical.lab_results (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  lab_order_id uuid not null references clinical.lab_orders(id) on delete cascade,
  patient_id uuid not null references clinical.patients(id) on delete restrict,
  result_json jsonb not null default '{}'::jsonb,
  status text not null default 'preliminary' check (status in ('preliminary','final','amended')),
  resulted_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists clinical.prescriptions_placeholder (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  patient_id uuid not null references clinical.patients(id) on delete restrict,
  encounter_id uuid references clinical.encounters(id) on delete set null,
  provider_key text not null,
  provider_payload_ref text,
  status text not null default 'draft' check (status in ('draft','sent','fulfilled','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ============================================================
-- PROTOCOLS
-- ============================================================
create table if not exists protocols.protocol_templates (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  name text not null,
  objective text,
  duration_days integer,
  status text not null default 'active' check (status in ('active','inactive','archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists protocols.protocol_instances (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  patient_id uuid not null references clinical.patients(id) on delete restrict,
  protocol_template_id uuid references protocols.protocol_templates(id) on delete set null,
  status text not null default 'active' check (status in ('active','paused','completed','cancelled')),
  starts_at date,
  ends_at date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists protocols.care_team_assignments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  protocol_instance_id uuid not null references protocols.protocol_instances(id) on delete cascade,
  profile_id uuid not null references core.profiles(id) on delete restrict,
  role text not null,
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now()
);

create table if not exists protocols.protocol_tasks (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  protocol_instance_id uuid not null references protocols.protocol_instances(id) on delete cascade,
  task_type text not null,
  title text not null,
  due_at timestamptz,
  status text not null default 'pending' check (status in ('pending','done','skipped','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists protocols.protocol_events (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  protocol_instance_id uuid not null references protocols.protocol_instances(id) on delete cascade,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'created' check (status in ('created','processed','failed')),
  created_at timestamptz not null default now()
);

-- ============================================================
-- ENGAGEMENT
-- ============================================================
create table if not exists engagement.nutrition_plans (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  patient_id uuid not null references clinical.patients(id) on delete restrict,
  protocol_instance_id uuid references protocols.protocol_instances(id) on delete set null,
  plan_name text not null,
  plan_json jsonb not null default '{}'::jsonb,
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists engagement.food_diary_entries (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  patient_id uuid not null references clinical.patients(id) on delete restrict,
  nutrition_plan_id uuid references engagement.nutrition_plans(id) on delete set null,
  consumed_at timestamptz not null,
  meal_type text,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists engagement.training_plans (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  patient_id uuid not null references clinical.patients(id) on delete restrict,
  protocol_instance_id uuid references protocols.protocol_instances(id) on delete set null,
  plan_name text not null,
  plan_json jsonb not null default '{}'::jsonb,
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists engagement.workout_logs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  patient_id uuid not null references clinical.patients(id) on delete restrict,
  training_plan_id uuid references engagement.training_plans(id) on delete set null,
  performed_at timestamptz not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'completed' check (status in ('completed','partial','skipped')),
  created_at timestamptz not null default now()
);

-- ============================================================
-- DOCUMENTS
-- ============================================================
create table if not exists documents.document_templates (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  name text not null,
  kind text not null,
  d4sign_template_id text,
  placeholders jsonb not null default '[]'::jsonb,
  status text not null default 'active' check (status in ('active','inactive','archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists documents.documents (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  patient_id uuid references clinical.patients(id) on delete set null,
  protocol_instance_id uuid references protocols.protocol_instances(id) on delete set null,
  document_template_id uuid references documents.document_templates(id) on delete set null,
  title text not null,
  storage_path text,
  sha256_hash text,
  status text not null default 'draft' check (status in ('draft','generated','sent','signed','rejected','archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists documents.signature_requests (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  document_id uuid not null references documents.documents(id) on delete cascade,
  provider text not null default 'd4sign',
  external_request_id text,
  signer_email text,
  status text not null default 'pending' check (status in ('pending','sent','viewed','signed','rejected','expired','cancelled')),
  requested_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists documents.d4sign_events (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  signature_request_id uuid references documents.signature_requests(id) on delete set null,
  external_event_id text,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'received' check (status in ('received','processed','failed')),
  created_at timestamptz not null default now(),
  unique (tenant_id, external_event_id)
);

-- ============================================================
-- BILLING
-- ============================================================
create table if not exists billing.platform_accounts (
  id uuid primary key default gen_random_uuid(),
  account_name text not null,
  asaas_account_id text,
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists billing.tenant_billing_accounts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  asaas_subaccount_id text,
  wallet_id text,
  status text not null default 'active' check (status in ('active','pending','blocked','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id)
);

create table if not exists billing.patient_customers (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  patient_id uuid not null references clinical.patients(id) on delete cascade,
  asaas_customer_id text not null,
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  unique (tenant_id, patient_id),
  unique (tenant_id, asaas_customer_id)
);

create table if not exists billing.invoices (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  patient_id uuid references clinical.patients(id) on delete set null,
  asaas_invoice_id text,
  amount numeric(12,2) not null,
  due_date date,
  status text not null default 'pending' check (status in ('pending','paid','overdue','cancelled','refunded')),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists billing.subscriptions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  patient_id uuid not null references clinical.patients(id) on delete restrict,
  asaas_subscription_id text,
  amount numeric(12,2) not null,
  interval text not null,
  next_due_date date,
  status text not null default 'active' check (status in ('active','paused','cancelled','ended')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists billing.payments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  invoice_id uuid references billing.invoices(id) on delete set null,
  subscription_id uuid references billing.subscriptions(id) on delete set null,
  asaas_payment_id text,
  amount numeric(12,2) not null,
  paid_at timestamptz,
  status text not null default 'pending' check (status in ('pending','confirmed','failed','refunded','chargeback')),
  payment_method text,
  created_at timestamptz not null default now()
);

create table if not exists billing.splits (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  invoice_id uuid references billing.invoices(id) on delete cascade,
  subscription_id uuid references billing.subscriptions(id) on delete cascade,
  recipient_wallet_id text not null,
  fixed_value numeric(12,2),
  percent_value numeric(5,2),
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  check (fixed_value is not null or percent_value is not null)
);

create table if not exists billing.asaas_events (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references core.tenants(id) on delete set null,
  external_event_id text not null,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'received' check (status in ('received','processed','failed')),
  created_at timestamptz not null default now(),
  unique (external_event_id)
);

-- ============================================================
-- INTEGRATIONS / SECURITY / AUDIT
-- ============================================================
create table if not exists integrations.integration_secrets_metadata (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references core.tenants(id) on delete cascade,
  provider text not null,
  secret_ref text not null,
  key_fingerprint text,
  status text not null default 'active' check (status in ('active','rotated','revoked')),
  last_rotated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, provider, secret_ref)
);

create table if not exists audit.audit_logs (
  id bigserial primary key,
  tenant_id uuid,
  actor_id uuid,
  table_name text not null,
  record_id uuid,
  action text not null check (action in ('INSERT','UPDATE','DELETE')),
  old_data jsonb,
  new_data jsonb,
  request_id text,
  created_at timestamptz not null default now()
);

create table if not exists audit.access_logs (
  id bigserial primary key,
  tenant_id uuid,
  actor_id uuid,
  resource_type text not null,
  resource_id uuid,
  access_type text not null check (access_type in ('READ','EXPORT','DOWNLOAD')),
  request_id text,
  created_at timestamptz not null default now()
);

create table if not exists security.webhook_events (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references core.tenants(id) on delete set null,
  provider text not null,
  event_type text not null,
  external_event_id text,
  idempotency_key text not null,
  signature_valid boolean not null default false,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'received' check (status in ('received','processed','failed','ignored')),
  processed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (provider, idempotency_key)
);

-- ============================================================
-- Indexes: tenant_id, patient_id, status, created_at
-- ============================================================
create index if not exists idx_patients_tenant on clinical.patients(tenant_id);
create index if not exists idx_patients_status on clinical.patients(status);
create index if not exists idx_patients_created_at on clinical.patients(created_at desc);

create index if not exists idx_patient_pii_tenant on clinical.patient_pii(tenant_id);
create index if not exists idx_appointments_tenant on clinical.appointments(tenant_id);
create index if not exists idx_appointments_patient on clinical.appointments(patient_id);
create index if not exists idx_appointments_status on clinical.appointments(status);
create index if not exists idx_appointments_created_at on clinical.appointments(created_at desc);

create index if not exists idx_queue_events_tenant on clinical.queue_events(tenant_id);
create index if not exists idx_queue_events_patient on clinical.queue_events(patient_id);
create index if not exists idx_queue_events_status on clinical.queue_events(status);
create index if not exists idx_queue_events_created_at on clinical.queue_events(created_at desc);

create index if not exists idx_encounters_tenant on clinical.encounters(tenant_id);
create index if not exists idx_encounters_patient on clinical.encounters(patient_id);
create index if not exists idx_encounters_status on clinical.encounters(status);
create index if not exists idx_encounters_created_at on clinical.encounters(created_at desc);

create index if not exists idx_measurements_tenant on clinical.measurements(tenant_id);
create index if not exists idx_measurements_patient on clinical.measurements(patient_id);
create index if not exists idx_measurements_status on clinical.measurements(status);
create index if not exists idx_measurements_created_at on clinical.measurements(created_at desc);

create index if not exists idx_bioimp_tenant on clinical.bioimpedance_results(tenant_id);
create index if not exists idx_bioimp_patient on clinical.bioimpedance_results(patient_id);
create index if not exists idx_bioimp_status on clinical.bioimpedance_results(status);
create index if not exists idx_bioimp_created_at on clinical.bioimpedance_results(created_at desc);

create index if not exists idx_protocol_instances_tenant on protocols.protocol_instances(tenant_id);
create index if not exists idx_protocol_instances_patient on protocols.protocol_instances(patient_id);
create index if not exists idx_protocol_instances_status on protocols.protocol_instances(status);
create index if not exists idx_protocol_instances_created_at on protocols.protocol_instances(created_at desc);

create index if not exists idx_protocol_tasks_tenant on protocols.protocol_tasks(tenant_id);
create index if not exists idx_protocol_tasks_status on protocols.protocol_tasks(status);
create index if not exists idx_protocol_tasks_created_at on protocols.protocol_tasks(created_at desc);

create index if not exists idx_documents_tenant on documents.documents(tenant_id);
create index if not exists idx_documents_patient on documents.documents(patient_id);
create index if not exists idx_documents_status on documents.documents(status);
create index if not exists idx_documents_created_at on documents.documents(created_at desc);

create index if not exists idx_signature_requests_tenant on documents.signature_requests(tenant_id);
create index if not exists idx_signature_requests_status on documents.signature_requests(status);
create index if not exists idx_signature_requests_created_at on documents.signature_requests(created_at desc);

create index if not exists idx_invoices_tenant on billing.invoices(tenant_id);
create index if not exists idx_invoices_patient on billing.invoices(patient_id);
create index if not exists idx_invoices_status on billing.invoices(status);
create index if not exists idx_invoices_created_at on billing.invoices(created_at desc);

create index if not exists idx_subscriptions_tenant on billing.subscriptions(tenant_id);
create index if not exists idx_subscriptions_patient on billing.subscriptions(patient_id);
create index if not exists idx_subscriptions_status on billing.subscriptions(status);
create index if not exists idx_subscriptions_created_at on billing.subscriptions(created_at desc);

create index if not exists idx_payments_tenant on billing.payments(tenant_id);
create index if not exists idx_payments_status on billing.payments(status);
create index if not exists idx_payments_created_at on billing.payments(created_at desc);

create index if not exists idx_splits_tenant on billing.splits(tenant_id);
create index if not exists idx_splits_status on billing.splits(status);
create index if not exists idx_splits_created_at on billing.splits(created_at desc);

create index if not exists idx_webhook_events_tenant on security.webhook_events(tenant_id);
create index if not exists idx_webhook_events_status on security.webhook_events(status);
create index if not exists idx_webhook_events_created_at on security.webhook_events(created_at desc);

create index if not exists idx_audit_logs_tenant on audit.audit_logs(tenant_id);
create index if not exists idx_audit_logs_created_at on audit.audit_logs(created_at desc);
create index if not exists idx_access_logs_tenant on audit.access_logs(tenant_id);
create index if not exists idx_access_logs_created_at on audit.access_logs(created_at desc);

-- ============================================================
-- updated_at triggers
-- ============================================================
create trigger trg_tenants_updated_at before update on core.tenants for each row execute function core.set_updated_at();
create trigger trg_profiles_updated_at before update on core.profiles for each row execute function core.set_updated_at();
create trigger trg_tenant_memberships_updated_at before update on core.tenant_memberships for each row execute function core.set_updated_at();
create trigger trg_tenant_roles_updated_at before update on core.tenant_roles for each row execute function core.set_updated_at();
create trigger trg_patients_updated_at before update on clinical.patients for each row execute function core.set_updated_at();
create trigger trg_patient_pii_updated_at before update on clinical.patient_pii for each row execute function core.set_updated_at();
create trigger trg_appointments_updated_at before update on clinical.appointments for each row execute function core.set_updated_at();
create trigger trg_encounters_updated_at before update on clinical.encounters for each row execute function core.set_updated_at();
create trigger trg_soap_notes_updated_at before update on clinical.soap_notes for each row execute function core.set_updated_at();
create trigger trg_lab_orders_updated_at before update on clinical.lab_orders for each row execute function core.set_updated_at();
create trigger trg_prescriptions_placeholder_updated_at before update on clinical.prescriptions_placeholder for each row execute function core.set_updated_at();
create trigger trg_protocol_templates_updated_at before update on protocols.protocol_templates for each row execute function core.set_updated_at();
create trigger trg_protocol_instances_updated_at before update on protocols.protocol_instances for each row execute function core.set_updated_at();
create trigger trg_protocol_tasks_updated_at before update on protocols.protocol_tasks for each row execute function core.set_updated_at();
create trigger trg_nutrition_plans_updated_at before update on engagement.nutrition_plans for each row execute function core.set_updated_at();
create trigger trg_training_plans_updated_at before update on engagement.training_plans for each row execute function core.set_updated_at();
create trigger trg_document_templates_updated_at before update on documents.document_templates for each row execute function core.set_updated_at();
create trigger trg_documents_updated_at before update on documents.documents for each row execute function core.set_updated_at();
create trigger trg_signature_requests_updated_at before update on documents.signature_requests for each row execute function core.set_updated_at();
create trigger trg_platform_accounts_updated_at before update on billing.platform_accounts for each row execute function core.set_updated_at();
create trigger trg_tenant_billing_accounts_updated_at before update on billing.tenant_billing_accounts for each row execute function core.set_updated_at();
create trigger trg_invoices_updated_at before update on billing.invoices for each row execute function core.set_updated_at();
create trigger trg_subscriptions_updated_at before update on billing.subscriptions for each row execute function core.set_updated_at();
create trigger trg_integration_secrets_metadata_updated_at before update on integrations.integration_secrets_metadata for each row execute function core.set_updated_at();

-- ============================================================
-- RLS enablement (sensitive tables)
-- ============================================================
alter table core.tenants enable row level security;
alter table core.tenant_memberships enable row level security;
alter table core.tenant_roles enable row level security;
alter table core.tenant_role_permissions enable row level security;

alter table clinical.patients enable row level security;
alter table clinical.patient_pii enable row level security;
alter table clinical.appointments enable row level security;
alter table clinical.queue_events enable row level security;
alter table clinical.encounters enable row level security;
alter table clinical.soap_notes enable row level security;
alter table clinical.measurements enable row level security;
alter table clinical.bioimpedance_results enable row level security;
alter table clinical.lab_orders enable row level security;
alter table clinical.lab_results enable row level security;
alter table clinical.prescriptions_placeholder enable row level security;

alter table protocols.protocol_templates enable row level security;
alter table protocols.protocol_instances enable row level security;
alter table protocols.care_team_assignments enable row level security;
alter table protocols.protocol_tasks enable row level security;
alter table protocols.protocol_events enable row level security;

alter table engagement.nutrition_plans enable row level security;
alter table engagement.food_diary_entries enable row level security;
alter table engagement.training_plans enable row level security;
alter table engagement.workout_logs enable row level security;

alter table documents.document_templates enable row level security;
alter table documents.documents enable row level security;
alter table documents.signature_requests enable row level security;
alter table documents.d4sign_events enable row level security;

alter table billing.tenant_billing_accounts enable row level security;
alter table billing.patient_customers enable row level security;
alter table billing.invoices enable row level security;
alter table billing.subscriptions enable row level security;
alter table billing.payments enable row level security;
alter table billing.splits enable row level security;
alter table billing.asaas_events enable row level security;

alter table integrations.integration_secrets_metadata enable row level security;
alter table audit.audit_logs enable row level security;
alter table audit.access_logs enable row level security;
alter table security.webhook_events enable row level security;

-- baseline tenant policy (to be refined with RBAC helpers)
create policy tenant_isolation_select on clinical.patients
for select to authenticated
using (tenant_id = core.current_tenant_id());

create policy tenant_isolation_mod on clinical.patients
for all to authenticated
using (tenant_id = core.current_tenant_id())
with check (tenant_id = core.current_tenant_id());

commit;
