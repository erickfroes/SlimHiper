# Contrato de Supabase Edge Functions para Bubble (SlimHiper)

Este documento define o contrato completo das Edge Functions que o Bubble pode chamar via API Connector.

## 1) Padrões obrigatórios (todos os endpoints)

- **Base URL**: `https://<project-ref>.supabase.co/functions/v1`
- **Autenticação padrão**: `Authorization: Bearer <supabase_access_token>` (exceto webhooks públicos).
- **Bubble nunca envia nem define tenant efetivo**.
  - Se `tenant_id` vier no payload, deve ser ignorado para autorização.
  - Tenant é sempre derivado de `auth.uid()` + vínculo em `core.user_tenants`.
- **Validação**: payload validado por schema (Zod/Valibot) em cada função.
- **Erros seguros**: nunca retornar stack trace ou segredo.
- **Auditoria**: registrar `audit_log` para toda escrita e leitura sensível.
- **PII/PHI**: logs de integração e erro devem mascarar dados clínicos sensíveis.
- **Idempotência (escritas críticas e webhooks)**:
  - Header: `Idempotency-Key` obrigatório quando indicado.
  - Persistir em `ops.idempotency_keys` com hash da requisição.

## 2) Envelope de resposta padrão

### 2.1 Sucesso

```json
{
  "ok": true,
  "data": {},
  "meta": {
    "request_id": "uuid",
    "timestamp": "2026-05-06T12:00:00Z"
  }
}
```

### 2.2 Erro

```json
{
  "ok": false,
  "error": {
    "code": "FORBIDDEN",
    "message": "Você não possui permissão para esta ação.",
    "details": null
  },
  "meta": {
    "request_id": "uuid",
    "timestamp": "2026-05-06T12:00:00Z"
  }
}
```

## 3) Matriz de permissões (chaves RBAC)

- `auth.session.read|write`
- `tenant.read|users.read|users.invite|users.role.update|settings.read|settings.write|feature_flags.read`
- `clinical.patients.read|write|timeline.read|appointments.read|appointments.write|queue.read|soap.write|metrics.write|labs.write|prescriptions.write`
- `protocols.templates.read|write|builder.write|enroll.write|active.read|care_team.write|tasks.write`
- `nutrition.plan.read|write|diary.review|adjustment.request`
- `training.plan.read|write|library.read|workout.log|pain_alert.write`
- `documents.templates.read|write|generate|send|status.read|webhook.process`
- `billing.platform.write|tenant_account.write|customers.write|invoice.write|payment_link.write|subscription.write|split.write|status.read|webhook.process`
- `platform.tenants.read|tenants.suspend|tenants.reactivate|usage.read|audit.read|support.session|break_glass.request`

## 4) Endpoints

> Legendas:
> - **Auth exigida**: `user_jwt`, `service_internal`, `public_hmac`
> - **Audit events**: eventos em `audit.security_events`, `audit.access_log` e/ou `audit.change_log`

---

## 4.1 Auth

### POST `/auth/login`
- Auth exigida: `anon` (credenciais do usuário)
- Permissões: N/A
- Request JSON:
```json
{ "email": "user@clinic.com", "password": "******" }
```
- Response JSON:
```json
{ "access_token": "jwt", "refresh_token": "jwt", "expires_in": 3600, "user": { "id": "uuid", "email": "user@clinic.com" } }
```
- Audit events: `auth.login.success|failed`
- Erros: `INVALID_CREDENTIALS`, `USER_SUSPENDED`, `RATE_LIMITED`

### POST `/auth/logout`
- Auth exigida: `user_jwt`
- Permissões: `auth.session.write`
- Request JSON: `{ "all_devices": false }`
- Response JSON: `{ "revoked": true }`
- Audit events: `auth.logout`
- Erros: `UNAUTHORIZED`

### GET `/auth/me`
- Auth exigida: `user_jwt`
- Permissões: `auth.session.read`
- Request JSON: none
- Response JSON:
```json
{ "user": { "id": "uuid", "email": "user@clinic.com", "full_name": "Nome" }, "tenants": [{ "tenant_id": "uuid", "role": "doctor", "is_default": true }], "permissions": ["clinical.patients.read"] }
```
- Audit events: `auth.me.read`
- Erros: `UNAUTHORIZED`

### POST `/auth/refresh-session`
- Auth exigida: `anon` com `refresh_token`
- Permissões: N/A
- Request JSON: `{ "refresh_token": "jwt" }`
- Response JSON: `{ "access_token": "jwt", "refresh_token": "jwt", "expires_in": 3600 }`
- Audit events: `auth.refresh.success|failed`
- Erros: `INVALID_REFRESH_TOKEN`, `SESSION_EXPIRED`

---

## 4.2 Tenant

### GET `/tenant/current`
- Auth exigida: `user_jwt`
- Permissões: `tenant.read`
- Response: `{ "tenant": { "id": "uuid", "trade_name": "Clínica X", "status": "active" } }`
- Audit: `tenant.current.read`
- Erros: `NO_TENANT_CONTEXT`, `FORBIDDEN`

### GET `/tenant/users`
- Permissões: `tenant.users.read`
- Response: `{ "items": [{ "user_id": "uuid", "email": "a@b.com", "role": "manager" }] }`
- Audit: `tenant.users.read`
- Erros: `FORBIDDEN`

### POST `/tenant/invite-user`
- Permissões: `tenant.users.invite`
- Request: `{ "email": "new@clinic.com", "role": "nutritionist" }`
- Response: `{ "invite_id": "uuid", "status": "pending" }`
- Audit: `tenant.user.invite.created`
- Erros: `ROLE_INVALID`, `USER_ALREADY_IN_TENANT`, `FORBIDDEN`

### PATCH `/tenant/update-role`
- Permissões: `tenant.users.role.update`
- Request: `{ "user_id": "uuid", "role": "doctor" }`
- Response: `{ "updated": true }`
- Audit: `tenant.user.role.updated`
- Erros: `TARGET_NOT_FOUND`, `ROLE_INVALID`, `FORBIDDEN`

### GET `/tenant/feature-flags`
- Permissões: `tenant.feature_flags.read`
- Response: `{ "flags": { "d4sign_enabled": true, "training_enabled": true } }`
- Audit: `tenant.feature_flags.read`
- Erros: `FORBIDDEN`

### PATCH `/tenant/clinic-settings`
- Permissões: `tenant.settings.write`
- Request: `{ "timezone": "America/Sao_Paulo", "locale": "pt-BR", "branding": { "primary_color": "#0EA5E9" } }
`
- Response: `{ "updated": true, "settings": {} }`
- Audit: `tenant.settings.updated`
- Erros: `VALIDATION_ERROR`, `FORBIDDEN`

---

## 4.3 Clinical

### GET `/clinical/patients`
- Permissões: `clinical.patients.read`
- Query: `?q=&page=1&page_size=20`
- Response: `{ "items": [{ "id": "uuid", "full_name": "Paciente", "asaas_customer_id": "cus_123" }], "page": 1 }`
- Audit: `clinical.patients.list`
- Erros: `FORBIDDEN`

### POST `/clinical/patient`
- Permissões: `clinical.patients.write`
- Headers: `Idempotency-Key`
- Request: `{ "full_name": "Paciente", "birth_date": "1990-01-01", "email": "p@x.com", "phone": "+55..." }`
- Response: `{ "id": "uuid", "created": true }`
- Audit: `clinical.patient.created`
- Erros: `VALIDATION_ERROR`, `CONFLICT_DUPLICATE`, `FORBIDDEN`

### GET `/clinical/patient/:patient_id/profile`
- Permissões: `clinical.patients.read`
- Response: `{ "patient": {}, "sensitive": { "masked": true } }
`
- Audit: `clinical.patient.profile.read` + `audit.access_log`
- Erros: `NOT_FOUND`, `FORBIDDEN`

### GET `/clinical/patient/:patient_id/timeline`
- Permissões: `clinical.timeline.read`
- Response: `{ "events": [{ "type": "appointment", "at": "..." }] }`
- Audit: `clinical.patient.timeline.read`
- Erros: `NOT_FOUND`, `FORBIDDEN`

### GET|POST `/clinical/appointments`
- GET permissão: `clinical.appointments.read`
- POST permissão: `clinical.appointments.write`
- POST request: `{ "patient_id": "uuid", "scheduled_at": "...", "type": "return" }`
- Response: `{ "items": [] }` / `{ "id": "uuid" }`
- Audit: `clinical.appointments.read|created`
- Erros: `VALIDATION_ERROR`, `NOT_FOUND`, `FORBIDDEN`

### GET `/clinical/queue`
- Permissões: `clinical.queue.read`
- Response: `{ "items": [{ "patient_id": "uuid", "status": "waiting" }] }`
- Audit: `clinical.queue.read`
- Erros: `FORBIDDEN`

### POST `/clinical/soap-encounter`
- Permissões: `clinical.soap.write`
- Request: `{ "patient_id": "uuid", "subjective": "...", "objective": "...", "assessment": "...", "plan": "..." }`
- Response: `{ "encounter_id": "uuid" }`
- Audit: `clinical.soap.created` (sem texto clínico integral no log)
- Erros: `VALIDATION_ERROR`, `FORBIDDEN`

### POST `/clinical/measurements`
- Permissões: `clinical.metrics.write`
- Request: `{ "patient_id": "uuid", "metrics": [{ "code": "weight", "value": 82.4, "unit": "kg" }] }`
- Response: `{ "saved": 1 }`
- Audit: `clinical.measurements.created`
- Erros: `VALIDATION_ERROR`, `FORBIDDEN`

### POST `/clinical/bioimpedance`
- Permissões: `clinical.metrics.write`
- Request: `{ "patient_id": "uuid", "body_fat_pct": 21.3, "lean_mass_kg": 61.2 }
`
- Response: `{ "record_id": "uuid" }`
- Audit: `clinical.bioimpedance.created`
- Erros: `VALIDATION_ERROR`, `FORBIDDEN`

### POST `/clinical/lab-orders`
- Permissões: `clinical.labs.write`
- Request: `{ "patient_id": "uuid", "exam_codes": ["CBC", "TSH"], "notes": "..." }`
- Response: `{ "order_id": "uuid" }`
- Audit: `clinical.lab_order.created`
- Erros: `VALIDATION_ERROR`, `FORBIDDEN`

### POST `/clinical/lab-uploads`
- Permissões: `clinical.labs.write`
- Request: `{ "patient_id": "uuid", "file_name": "exame.pdf", "content_type": "application/pdf" }
`
- Response: `{ "upload_url": "signed-url", "file_id": "uuid", "expires_in": 120 }
`
- Audit: `clinical.lab_upload.url_issued`
- Erros: `FORBIDDEN`, `VALIDATION_ERROR`

### POST `/clinical/prescriptions-placeholder`
- Permissões: `clinical.prescriptions.write`
- Request: `{ "patient_id": "uuid", "provider_key": "future_provider", "payload_ref": "opaque-ref" }`
- Response: `{ "prescription_id": "uuid", "status": "draft" }`
- Audit: `clinical.prescription.placeholder.created`
- Erros: `VALIDATION_ERROR`, `FORBIDDEN`

---

## 4.4 Protocols

### GET `/protocols/templates`
- Permissões: `protocols.templates.read`
- Response: `{ "items": [{ "id": "uuid", "name": "Emagrecimento 90d" }] }`
- Audit: `protocols.templates.read`

### POST `/protocols/builder`
- Permissões: `protocols.builder.write`
- Request: `{ "name": "Hipertrofia 120d", "modules": [{ "discipline": "training", "order": 1 }] }`
- Response: `{ "protocol_id": "uuid" }`
- Audit: `protocols.builder.saved`

### POST `/protocols/enroll-patient`
- Permissões: `protocols.enroll.write`
- Headers: `Idempotency-Key`
- Request: `{ "patient_id": "uuid", "protocol_id": "uuid", "start_date": "2026-05-06" }`
- Response: `{ "enrollment_id": "uuid", "status": "active" }`
- Audit: `protocols.enrollment.created`

### GET `/protocols/patient/:patient_id/active`
- Permissões: `protocols.active.read`
- Response: `{ "active_protocol": { "enrollment_id": "uuid" } }`
- Audit: `protocols.active.read`

### POST `/protocols/care-team-assignment`
- Permissões: `protocols.care_team.write`
- Request: `{ "enrollment_id": "uuid", "assignments": [{ "user_id": "uuid", "discipline": "nutrition" }] }`
- Response: `{ "updated": true }`
- Audit: `protocols.care_team.assigned`

### POST `/protocols/tasks`
- Permissões: `protocols.tasks.write`
- Request: `{ "enrollment_id": "uuid", "task_type": "checkin", "due_at": "..." }`
- Response: `{ "task_id": "uuid" }`
- Audit: `protocols.task.created`

---

## 4.5 Nutrition

### GET|PUT `/nutrition/plan/:patient_id`
- Permissões: GET `nutrition.plan.read`, PUT `nutrition.plan.write`
- PUT Request: `{ "calories": 2200, "macros": { "protein_g": 180, "carb_g": 220, "fat_g": 70 } }
`
- Response: `{ "plan_id": "uuid", "version": 3 }`
- Audit: `nutrition.plan.read|updated`

### POST `/nutrition/food-diary-review`
- Permissões: `nutrition.diary.review`
- Request: `{ "patient_id": "uuid", "period": { "from": "2026-05-01", "to": "2026-05-06" }, "notes": "..." }`
- Response: `{ "review_id": "uuid" }`
- Audit: `nutrition.diary.reviewed`

### POST `/nutrition/adjustment-request`
- Permissões: `nutrition.adjustment.request`
- Request: `{ "patient_id": "uuid", "reason": "plateau", "priority": "medium" }
`
- Response: `{ "request_id": "uuid", "status": "open" }`
- Audit: `nutrition.adjustment.requested`

---

## 4.6 Training

### GET|PUT `/training/plan/:patient_id`
- Permissões: GET `training.plan.read`, PUT `training.plan.write`
- Request PUT: `{ "split": "ABCD", "weeks": 8, "sessions": [] }`
- Response: `{ "plan_id": "uuid" }`
- Audit: `training.plan.read|updated`

### GET `/training/exercise-library`
- Permissões: `training.library.read`
- Response: `{ "items": [{ "code": "squat", "name": "Agachamento" }] }`
- Audit: `training.library.read`

### POST `/training/workout-log`
- Permissões: `training.workout.log`
- Request: `{ "patient_id": "uuid", "session_date": "2026-05-06", "entries": [{ "exercise": "squat", "sets": 4 }] }
`
- Response: `{ "log_id": "uuid" }`
- Audit: `training.workout.logged`

### POST `/training/pain-alert`
- Permissões: `training.pain_alert.write`
- Request: `{ "patient_id": "uuid", "pain_scale": 8, "region": "knee", "note": "..." }`
- Response: `{ "alert_id": "uuid", "triage": "high" }`
- Audit: `training.pain_alert.created`

---

## 4.7 Documents (D4Sign)

### GET `/documents/templates`
- Permissões: `documents.templates.read`
- Response: `{ "items": [{ "id": "uuid", "name": "Consentimento" }] }`
- Audit: `documents.templates.read`

### POST `/documents/generate`
- Permissões: `documents.generate`
- Headers: `Idempotency-Key`
- Request: `{ "patient_id": "uuid", "template_id": "uuid", "variables": { "patient_name": "..." } }
`
- Response: `{ "document_id": "uuid", "hash": "sha256..." }`
- Audit: `documents.generated`

### POST `/documents/send-d4sign`
- Permissões: `documents.send`
- Request: `{ "document_id": "uuid", "signers": [{ "name": "Paciente", "email": "p@x.com" }] }
`
- Response: `{ "signature_request_id": "uuid", "provider": "d4sign" }`
- Audit: `documents.d4sign.sent`

### GET `/documents/d4sign-status/:signature_request_id`
- Permissões: `documents.status.read`
- Response: `{ "status": "signed", "events": [{ "at": "...", "type": "viewed" }] }`
- Audit: `documents.d4sign.status.read`

### POST `/webhooks/d4sign`
- Auth exigida: `public_hmac`
- Permissões: `documents.webhook.process` (contexto interno)
- Headers: `X-D4Sign-Signature`, `X-Webhook-Id`
- Request: payload bruto do D4Sign
- Response: `{ "accepted": true, "idempotent_replay": false }`
- Audit: `webhook.d4sign.received|validated|processed|replayed|failed`
- Erros: `INVALID_SIGNATURE`, `DUPLICATE_EVENT`, `PROCESSING_ERROR`

---

## 4.8 Billing / Asaas

### POST `/billing/platform-customer`
- Permissões: `billing.platform.write`
- Request: `{ "tenant_id_external_ref": "optional", "name": "Clínica X", "email": "financeiro@x.com" }`
- Response: `{ "platform_customer_id": "cus_..." }`
- Audit: `billing.platform_customer.created`

### POST `/billing/platform-subscription`
- Permissões: `billing.platform.write`
- Request: `{ "plan_code": "pro", "billing_cycle": "monthly" }`
- Response: `{ "subscription_id": "sub_...", "status": "active" }`
- Audit: `billing.platform_subscription.created`

### POST `/billing/tenant-asaas-subaccount`
- Permissões: `billing.tenant_account.write`
- Headers: `Idempotency-Key`
- Request: `{ "legal_name": "Clínica X LTDA", "cnpj": "***", "email": "financeiro@x.com" }`
- Response: `{ "asaas_account_id": "acc_...", "status": "pending_validation" }`
- Audit: `billing.tenant_subaccount.created`

### POST `/billing/patient-customer`
- Permissões: `billing.customers.write`
- Headers: `Idempotency-Key`
- Request: `{ "patient_id": "uuid", "name": "Paciente", "cpf": "***", "email": "p@x.com" }`
- Response: `{ "customer_id": "cus_..." }`
- Audit: `billing.patient_customer.created`

### POST `/billing/invoice`
- Permissões: `billing.invoice.write`
- Headers: `Idempotency-Key`
- Request: `{ "patient_id": "uuid", "amount": 1200.5, "due_date": "2026-05-10", "description": "Protocolo" }
`
- Response: `{ "invoice_id": "inv_...", "status": "pending" }`
- Audit: `billing.invoice.created`

### POST `/billing/payment-link`
- Permissões: `billing.payment_link.write`
- Request: `{ "patient_id": "uuid", "amount": 299.9, "expires_at": "2026-05-20T00:00:00Z" }`
- Response: `{ "payment_link_id": "plink_...", "url": "https://..." }`
- Audit: `billing.payment_link.created`

### POST `/billing/subscription`
- Permissões: `billing.subscription.write`
- Headers: `Idempotency-Key`
- Request: `{ "patient_id": "uuid", "amount": 399.9, "cycle": "MONTHLY" }`
- Response: `{ "subscription_id": "sub_..." }`
- Audit: `billing.subscription.created`

### POST `/billing/split-charge`
- Permissões: `billing.split.write`
- Request: `{ "charge_id": "ch_...", "splits": [{ "wallet_id": "w_...", "percent": 10 }] }`
- Response: `{ "split_id": "uuid" }`
- Audit: `billing.split.created`

### POST `/billing/cancel-subscription`
- Permissões: `billing.subscription.write`
- Request: `{ "subscription_id": "sub_...", "effective_immediately": false }`
- Response: `{ "cancelled": true }
`
- Audit: `billing.subscription.cancelled`

### GET `/billing/payment-status/:payment_id`
- Permissões: `billing.status.read`
- Response: `{ "payment_id": "pay_...", "status": "RECEIVED", "paid_at": "..." }`
- Audit: `billing.payment_status.read`

### POST `/webhooks/asaas`
- Auth exigida: `public_hmac`
- Permissões: `billing.webhook.process` (interno)
- Headers: `X-Asaas-Signature`, `X-Event-Id`
- Request: payload bruto Asaas
- Response: `{ "accepted": true, "idempotent_replay": false }`
- Audit: `webhook.asaas.received|validated|processed|replayed|failed`
- Erros: `INVALID_SIGNATURE`, `DUPLICATE_EVENT`, `PROCESSING_ERROR`

---

## 4.9 Platform Admin

### GET `/admin/tenants`
- Auth exigida: `user_jwt`
- Permissões: `platform.tenants.read`
- Response: `{ "items": [{ "tenant_id": "uuid", "trade_name": "Clínica X", "status": "active" }] }`
- Audit: `platform.tenants.read`

### GET `/admin/tenant/:tenant_id`
- Permissões: `platform.tenants.read`
- Response: `{ "tenant": {}, "usage": {}, "billing": {} }`
- Audit: `platform.tenant.detail.read`

### POST `/admin/tenant/:tenant_id/suspend`
- Permissões: `platform.tenants.suspend`
- Request: `{ "reason": "inadimplencia" }`
- Response: `{ "suspended": true }`
- Audit: `platform.tenant.suspended`

### POST `/admin/tenant/:tenant_id/reactivate`
- Permissões: `platform.tenants.reactivate`
- Request: `{ "reason": "pagamento_confirmado" }`
- Response: `{ "reactivated": true }`
- Audit: `platform.tenant.reactivated`

### GET `/admin/usage`
- Permissões: `platform.usage.read`
- Query: `?from=2026-05-01&to=2026-05-31`
- Response: `{ "totals": { "tenants": 10, "patients": 1200, "api_calls": 35000 } }`
- Audit: `platform.usage.read`

### GET `/admin/audit-logs`
- Permissões: `platform.audit.read`
- Query: `?tenant_id=&actor_id=&event=&from=&to=`
- Response: `{ "items": [{ "event": "clinical.patient.created", "at": "..." }] }`
- Audit: `platform.audit.read`

### POST `/admin/support-session`
- Permissões: `platform.support.session`
- Request: `{ "tenant_id": "uuid", "duration_minutes": 30, "reason": "ticket-123" }`
- Response: `{ "session_id": "uuid", "expires_at": "..." }`
- Audit: `platform.support_session.created`

### POST `/admin/break-glass-request`
- Permissões: `platform.break_glass.request`
- Request: `{ "tenant_id": "uuid", "patient_id": "uuid", "reason": "emergency", "ttl_minutes": 15 }`
- Response: `{ "request_id": "uuid", "status": "pending_approval" }`
- Audit: `platform.break_glass.requested|approved|denied|expired`

---

## 5) Regras extras para webhooks públicos (Asaas e D4Sign)

1. Validar assinatura HMAC/token com segredo no ambiente da Edge Function.
2. Persistir payload bruto em `ops.webhook_inbox` (com redaction quando necessário).
3. Verificar idempotência por `provider + event_id`.
4. Processar em transação com registro em `ops.webhook_events`.
5. Em erro transitório, enviar para `ops.retry_queue`.
6. Sempre responder `2xx` somente após persistir recebimento; processamento pode ser assíncrono.

## 6) Regras de segurança de implementação

- Edge Functions usam `supabase.auth.getUser()` e consultas em `core.user_tenants` para contexto.
- Nunca confiar em role/permission vindo do cliente.
- Service role apenas no servidor (variável de ambiente), nunca em Bubble/API Connector.
- Storage sempre privado com signed URL curta.
- Campos clínicos sensíveis não retornam completos para perfis sem permissão.
- Toda mutação relevante inclui `request_id` e `actor_user_id` no log de auditoria.
