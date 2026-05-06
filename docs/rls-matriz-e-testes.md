# SlimHiper - Matriz de Acesso (RLS)

## Matriz papel x recurso x ação

Legenda: ✅ permitido · 👁️ leitura · ❌ negado · BG = somente break-glass auditado.

| Papel | Pacientes | SOAP | Prescrição | Plano alimentar | Audit logs |
|---|---|---|---|---|---|
| platform_owner | BG | BG | BG | BG | ✅ |
| platform_admin | ❌ por padrão | ❌ | ❌ | ❌ | metadados somente |
| platform_support | ❌ (BG somente) | ❌ | ❌ | ❌ | administrativo; clínico só BG |
| tenant_owner | ✅ CRUD | ✅ CRUD | ✅ CRUD | ✅ CRUD | ✅ |
| clinic_admin | ✅ CRUD | ✅ CRUD | ✅ CRUD | ✅ CRUD | ✅ |
| receptionist | ✅ CRUD operacional | ❌ SOAP completo | ❌ | 👁️ restrito | 👁️ administrativo |
| physician | ✅ | ✅ CRUD | ✅ CRUD | ✅ CRUD | 👁️ |
| nutritionist | ✅ | ✅ CRUD | ❌ alterar prescrição médica | ✅ CRUD | 👁️ |
| fitness_professional | ✅ pacientes atribuídos | ❌ | ❌ | 👁️ | 👁️ mínimo |
| external_professional | 👁️ paciente/protocolo atribuído e válido | ❌/restrito | ❌ | 👁️ conforme consentimento | ❌ |
| patient | 👁️ próprio | 👁️ próprio liberado | 👁️ próprio liberado | 👁️ próprio | ❌ |
| guardian | 👁️ paciente autorizado | 👁️ conforme autorização | 👁️ conforme autorização | 👁️ conforme autorização | ❌ |

## Funções auxiliares SQL implementadas

- `security.current_role()`
- `security.is_platform_role()`
- `security.has_tenant_role(text[])`
- `security.current_patient_id()`
- `security.can_access_patient(uuid, uuid)`
- `security.is_break_glass_enabled()`

## Policies implementadas (resumo)

- `clinical.patients`
  - `patients_select`
  - `patients_write_staff`
- `clinical.soap_notes`
  - `soap_select`
  - `soap_write_clinical`
- `clinical.prescriptions_placeholder`
  - `prescriptions_select`
  - `prescriptions_write_physician`
- `engagement.nutrition_plans`
  - `nutrition_select`
  - `nutrition_write`
- `protocols.care_team_assignments`
  - `care_team_select`
- `audit.audit_logs`
  - `audit_logs_select`

## Testes SQL (anti-vazamento)

Os cenários abaixo também foram registrados na migration de RLS como bloco de referência:

1. Vazamento entre tenants
2. Paciente tentando acessar outro paciente
3. Profissional externo com vínculo expirado
4. `platform_support` sem break-glass

