begin;

-- Helper functions for role/tenant/patient context
create or replace function security.current_role()
returns text language sql stable as $$
  select nullif(current_setting('request.jwt.claim.role', true), '');
$$;

create or replace function security.is_platform_role()
returns boolean language sql stable as $$
  select security.current_role() in ('platform_owner','platform_admin','platform_support');
$$;

create or replace function security.has_tenant_role(_roles text[])
returns boolean language sql stable as $$
  select exists (
    select 1
    from core.tenant_memberships tm
    where tm.tenant_id = core.current_tenant_id()
      and tm.profile_id = auth.uid()
      and tm.role = any(_roles)
  );
$$;

create or replace function security.current_patient_id()
returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.patient_id', true), '')::uuid;
$$;

create or replace function security.can_access_patient(_tenant_id uuid, _patient_id uuid)
returns boolean language sql stable as $$
  select
    (_tenant_id = core.current_tenant_id())
    and (
      security.has_tenant_role(array['tenant_owner','clinic_admin','receptionist','physician','nutritionist','fitness_professional'])
      or (security.current_role() = 'patient' and security.current_patient_id() = _patient_id)
      or (security.current_role() = 'guardian' and exists (
        select 1 from protocols.care_team_assignments cta
        where cta.tenant_id = _tenant_id and cta.patient_id = _patient_id and cta.professional_profile_id = auth.uid() and cta.status = 'active'
      ))
      or (security.current_role() = 'external_professional' and exists (
        select 1 from protocols.care_team_assignments cta
        where cta.tenant_id = _tenant_id and cta.patient_id = _patient_id and cta.professional_profile_id = auth.uid()
          and cta.status = 'active' and (cta.ends_at is null or cta.ends_at >= now())
      ))
    );
$$;

create or replace function security.is_break_glass_enabled()
returns boolean language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.break_glass', true), ''), 'false')::boolean;
$$;

-- Enable RLS on tenant-scoped tables
alter table clinical.patients enable row level security;
alter table clinical.soap_notes enable row level security;
alter table clinical.prescriptions_placeholder enable row level security;
alter table engagement.nutrition_plans enable row level security;
alter table protocols.care_team_assignments enable row level security;
alter table audit.audit_logs enable row level security;

-- Patients table policies
create policy patients_select on clinical.patients for select
using (
  security.can_access_patient(tenant_id, id)
  and security.current_role() <> 'platform_admin'
  and (security.current_role() <> 'platform_support' or security.is_break_glass_enabled())
);

create policy patients_write_staff on clinical.patients for all
using (tenant_id = core.current_tenant_id() and security.has_tenant_role(array['tenant_owner','clinic_admin','receptionist']))
with check (tenant_id = core.current_tenant_id() and security.has_tenant_role(array['tenant_owner','clinic_admin','receptionist']));

-- SOAP: reception denied
create policy soap_select on clinical.soap_notes for select
using (
  tenant_id = core.current_tenant_id()
  and (
    security.has_tenant_role(array['tenant_owner','clinic_admin','physician','nutritionist'])
    or (security.current_role() = 'patient' and patient_id = security.current_patient_id())
  )
);

create policy soap_write_clinical on clinical.soap_notes for all
using (tenant_id = core.current_tenant_id() and security.has_tenant_role(array['tenant_owner','clinic_admin','physician','nutritionist']))
with check (tenant_id = core.current_tenant_id() and security.has_tenant_role(array['tenant_owner','clinic_admin','physician','nutritionist']));

-- Prescription placeholder: nutritionist/fitness can't alter medical prescription
create policy prescriptions_select on clinical.prescriptions_placeholder for select
using (security.can_access_patient(tenant_id, patient_id));

create policy prescriptions_write_physician on clinical.prescriptions_placeholder for all
using (tenant_id = core.current_tenant_id() and security.has_tenant_role(array['tenant_owner','clinic_admin','physician']))
with check (tenant_id = core.current_tenant_id() and security.has_tenant_role(array['tenant_owner','clinic_admin','physician']));

-- Nutrition plans: physician/nutritionist manage; fitness read only via patient access
create policy nutrition_select on engagement.nutrition_plans for select
using (security.can_access_patient(tenant_id, patient_id));

create policy nutrition_write on engagement.nutrition_plans for all
using (tenant_id = core.current_tenant_id() and security.has_tenant_role(array['tenant_owner','clinic_admin','nutritionist','physician']))
with check (tenant_id = core.current_tenant_id() and security.has_tenant_role(array['tenant_owner','clinic_admin','nutritionist','physician']));

-- External professional / guardian assignment visibility
create policy care_team_select on protocols.care_team_assignments for select
using (
  tenant_id = core.current_tenant_id()
  and (
    security.has_tenant_role(array['tenant_owner','clinic_admin','physician','nutritionist'])
    or professional_profile_id = auth.uid()
  )
);

-- Audit logs: support only administrative unless break-glass
create policy audit_logs_select on audit.audit_logs for select
using (
  tenant_id = core.current_tenant_id()
  and (
    security.has_tenant_role(array['tenant_owner','clinic_admin'])
    or security.current_role() = 'platform_owner'
    or (security.current_role() = 'platform_support' and security.is_break_glass_enabled() and action ilike 'break_glass:%')
  )
);

-- Tests (manual execution snippets)
comment on schema security is $$
RLS TESTS:
1) Tenant leakage
   set local request.jwt.claim.tenant_id = '<tenant_a>';
   set local request.jwt.claim.role = 'clinic_admin';
   select count(*) from clinical.patients where tenant_id = '<tenant_b>'; -- expect 0

2) Patient crossing
   set local request.jwt.claim.role = 'patient';
   set local request.jwt.claim.patient_id = '<patient_a>';
   select * from clinical.patients where id = '<patient_b>'; -- expect 0 rows

3) Expired external professional
   set local request.jwt.claim.role = 'external_professional';
   set local request.jwt.claim.sub = '<profile_external>';
   select * from clinical.patients where id = '<patient_with_expired_assignment>'; -- expect 0

4) platform_support without break-glass
   set local request.jwt.claim.role = 'platform_support';
   set local request.jwt.claim.break_glass = 'false';
   select * from clinical.patients; -- expect 0
$$;

commit;
