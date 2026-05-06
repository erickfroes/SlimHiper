# Arquitetura Backend Supabase — SlimHiper

## 0) Princípios de segurança e desenho

1. **Supabase é o backend real**: Auth, Postgres, RLS, Edge Functions, Storage.
2. **Bubble é apenas interface operacional** (orquestração de telas/workflows), sem persistir dados clínicos sensíveis.
3. **Integrações externas (Asaas e D4Sign) somente via Edge Functions**.
4. **Todo registro operacional possui `tenant_id`** (escopo da clínica).
5. **RLS obrigatória em todas as tabelas de negócio**.
6. **Auditoria obrigatória** para escrita, leitura sensível e eventos de integração.
7. **Storage privado por tenant**, com controle por policy + URLs assinadas de curta duração.
8. **Webhooks idempotentes e autenticados** com trilha de processamento.

---

## 1) Schemas do banco (Postgres)

Separar por domínio e segurança:

- `core`: identidade de tenants, usuários internos, vínculo usuário↔tenant, configurações base.
- `clinical`: dados de protocolos, jornadas, avaliações, indicadores, prescrições (placeholder).
- `billing`: faturas, assinaturas, pagamentos, repasses/split, subcontas Asaas.
- `contracts`: templates, documentos, assinaturas e trilha D4Sign.
- `ops`: jobs, filas lógicas, integrações, retries, idempotência, webhooks recebidos/enviados.
- `audit`: trilha imutável de alterações e acessos.
- `public`: apenas views/control plane estritamente necessários para Bubble consumir via API.

**Decisão:** manter tabelas-base fora de `public` para reduzir superfície e exposição acidental.

---

## 2) Tabelas principais e campos obrigatórios

> Convenção transversal (quase todas):
> - `id` (uuid, pk)
> - `tenant_id` (uuid, not null)
> - `created_at`, `updated_at` (timestamptz)
> - `created_by`, `updated_by` (uuid, usuário auth)
> - `deleted_at` (soft delete opcional)
> - `version` (int para controle otimista)

### 2.1 `core`

1. `core.tenants`
   - `id`, `slug`, `legal_name`, `trade_name`, `status` (active/suspended/trial/cancelled)
   - `asaas_account_id` (subconta)
   - `timezone`, `locale`, `metadata` (jsonb)
2. `core.users`
   - espelho controlado de `auth.users`: `id`, `email`, `full_name`, `phone`, `status`
3. `core.user_tenants`
   - `user_id`, `tenant_id`, `role_id`, `is_default_tenant`
4. `core.roles`
   - papéis de negócio: `owner`, `manager`, `doctor`, `nutritionist`, `trainer`, `finance`, `support`, `viewer`
5. `core.permissions`
   - catálogo granular (`patients.read`, `billing.write` etc.)
6. `core.role_permissions`
   - matriz role→permission
7. `core.tenant_settings`
   - flags por tenant: recursos habilitados, políticas internas, branding

### 2.2 `clinical`

1. `clinical.patients`
   - `tenant_id`, `external_code`, `full_name`, `cpf_hash`, `birth_date`, `sex`, `email`, `phone`
   - `asaas_customer_id` (customer da subconta)
2. `clinical.patient_sensitive`
   - PII/sensíveis segregados: documento, endereço, dados de saúde críticos (criptografados em coluna)
3. `clinical.protocols`
   - definição comercial/clínica do protocolo
4. `clinical.protocol_modules`
   - módulos multidisciplinares e sequência
5. `clinical.enrollments`
   - vínculo paciente↔protocolo, status, datas
6. `clinical.assessments`
   - avaliações periódicas
7. `clinical.metrics`
   - medidas (peso, circunferência, bioimpedância etc.) com unidade
8. `clinical.prescriptions`
   - registro da prescrição, **sem acoplamento direto** ao provedor (placeholder `provider_key`, `provider_payload_ref`)
9. `clinical.care_events`
   - timeline clínica operacional

### 2.3 `billing`

1. `billing.saas_subscriptions`
   - assinatura SaaS da clínica (SlimHiper→clínica)
2. `billing.tenant_asaas_accounts`
   - credenciais referenciais não secretas da subconta (IDs, status, capabilities)
3. `billing.customers`
   - espelho de customers (pacientes) no Asaas da clínica
4. `billing.charges`
   - cobranças avulsas (PIX/boleto/cartão), status, vencimento
5. `billing.subscriptions`
   - recorrência para paciente
6. `billing.subscription_items`
   - itens/parcelas/mensalidades
7. `billing.splits`
   - regras de split por cobrança/assinatura
8. `billing.transactions`
   - eventos financeiros de liquidação/estorno/tarifa

### 2.4 `contracts`

1. `contracts.templates`
   - template lógico interno + referência D4Sign template id
2. `contracts.documents`
   - documento gerado por paciente/protocolo, hash de integridade
3. `contracts.signers`
   - signatários e ordem
4. `contracts.signature_requests`
   - envio para assinatura, canal, status
5. `contracts.signature_events`
   - trilha de status D4Sign (viewed/signed/rejected)

### 2.5 `ops`

1. `ops.idempotency_keys`
   - `scope`, `idempotency_key`, `request_hash`, `response_snapshot`, `expires_at`
2. `ops.webhook_inbox`
   - payload bruto, origem, assinatura, status validação
3. `ops.webhook_events`
   - eventos normalizados após parse
4. `ops.integration_logs`
   - requisição/resposta (redigida) Asaas/D4Sign
5. `ops.retry_queue`
   - retries com backoff e dead-letter

### 2.6 `audit`

1. `audit.change_log`
   - before/after (jsonb), tabela, registro, ator, tenant, motivo
2. `audit.access_log`
   - leitura sensível (quem viu qual paciente e quando)
3. `audit.security_events`
   - falhas de auth, RLS denied, webhook inválido

---

## 3) Relacionamentos

- `core.tenants 1:N core.user_tenants`
- `core.users 1:N core.user_tenants`
- `core.roles N:N core.permissions` (via `role_permissions`)
- `core.tenants 1:N clinical.patients`
- `clinical.patients 1:N clinical.enrollments`
- `clinical.protocols 1:N clinical.protocol_modules`
- `clinical.enrollments 1:N clinical.assessments`
- `clinical.assessments 1:N clinical.metrics`
- `clinical.patients 1:N billing.charges`
- `clinical.patients 1:N billing.subscriptions`
- `billing.charges 1:N billing.transactions`
- `contracts.documents N:1 clinical.patients`
- `contracts.signature_requests 1:N contracts.signature_events`
- `ops.webhook_inbox 1:N ops.webhook_events`

**Regra de integridade:** toda FK de domínio inclui coerência de `tenant_id` (constraint lógica + trigger de validação).

---

## 4) Estratégia multi-tenant

Modelo: **single database + shared schema + tenant discriminator**.

- `tenant_id` obrigatório em tabelas de negócio.
- Contexto do tenant carregado no JWT (`app_metadata.tenant_ids`) + `current_tenant_id` enviado pelo Bubble.
- Função SQL `core.current_tenant_id()` resolve tenant ativo com validação de vínculo.
- Índices compostos iniciando com `tenant_id` em tabelas grandes.
- Particionamento futuro por `tenant_id` para tabelas de alto volume (`audit`, `metrics`, `webhook_inbox`).

---

## 5) Roles e permissões

Camadas:
1. **Supabase roles técnicas**: `anon`, `authenticated`, `service_role`.
2. **RBAC de negócio** (tabelas `core.roles/permissions`).

Fluxo:
- Usuário autentica no Supabase Auth.
- Edge Function de sessão determina permissões efetivas por tenant.
- Bubble só invoca endpoints com JWT de usuário; ações privilegiadas usam Edge Function com validação RBAC interna.

Nunca expor `service_role` ao Bubble.

---

## 6) Estratégia de RLS

- RLS habilitada em todas as tabelas de `core` (exceto catálogos globais), `clinical`, `billing`, `contracts`, `ops`, `audit`.
- Policy base de leitura/escrita: `tenant_id = core.current_tenant_id()`.
- Policy adicional por papel/permissão via função `core.has_permission('x.y')`.
- Tabelas sensíveis (`clinical.patient_sensitive`) com policy ainda mais restritiva (somente perfis clínicos autorizados).
- Escritas críticas apenas via RPC/Edge Function para garantir regras de negócio e auditoria.

---

## 7) Storage privado

Buckets propostos:
- `private-contracts`
- `private-clinical-files`
- `private-reports`

Regras:
- Buckets privados.
- Caminho padronizado: `tenant/{tenant_id}/patient/{patient_id}/...`
- Upload/download apenas por Edge Function ou URL assinada curta (ex.: 60–300s).
- Metadados de arquivo em tabela com `tenant_id`, `owner_type`, `owner_id`, hash, classificação LGPD.

---

## 8) Estratégia de auditoria

- Triggers `AFTER INSERT/UPDATE/DELETE` nas tabelas críticas para `audit.change_log`.
- Captura de ator (`auth.uid()`), tenant, request_id, origem (Bubble/Edge/Webhook).
- `audit.access_log` preenchido em leituras de dados sensíveis via RPC controlada.
- Imutabilidade lógica: sem update/delete em logs de auditoria (apenas retenção arquivada por política).

---

## 9) Estratégia de webhooks

Pipeline:
1. Receber webhook em Edge Function dedicada por provedor.
2. Validar assinatura/HMAC + timestamp/nonce.
3. Gerar `idempotency_key` (provider + event_id).
4. Persistir bruto em `ops.webhook_inbox`.
5. Normalizar para `ops.webhook_events`.
6. Processar transacionalmente regras de negócio.
7. Logar resultado e agendar retry em falhas transitórias.

Características obrigatórias:
- Idempotência forte.
- Retry exponencial + dead-letter.
- Observabilidade (latência, falha, taxa por provedor/evento).

---

## 10) Edge Functions necessárias

### Core/Auth
1. `session-bootstrap` — resolve tenant ativo, roles, permissões e contexto UI.
2. `switch-tenant` — troca tenant ativo com validação.

### Clinical
3. `patient-upsert` — cria/atualiza paciente (com segregação sensível).
4. `enrollment-manage` — matrícula em protocolo.
5. `assessment-record` — grava avaliação/métricas.
6. `prescription-dispatch` — placeholder para provedor externo de prescrição.

### Billing/Asaas
7. `saas-tenant-subscription-create` — cobrança SaaS da clínica.
8. `asaas-subaccount-create` — cria subconta da clínica.
9. `asaas-customer-upsert` — paciente como customer da subconta.
10. `asaas-charge-create` — cobrança avulsa.
11. `asaas-subscription-create` — recorrência para paciente.
12. `asaas-split-configure` — configura split.
13. `asaas-webhook-receiver` — ingestão de eventos Asaas.

### Contracts/D4Sign
14. `d4sign-template-sync` — sincroniza templates.
15. `d4sign-document-generate` — monta documento a partir de template + dados.
16. `d4sign-signature-send` — envia para assinatura.
17. `d4sign-status-refresh` — consulta/atualiza status.
18. `d4sign-webhook-receiver` — ingestão de eventos D4Sign.

### Ops
19. `webhook-replay` — reprocessamento manual seguro.
20. `audit-export` — exportação controlada de trilhas.

---

## 11) Integração Asaas (detalhamento)

### 11.1 SaaS (SlimHiper cobrando clínica)
- Cadastro da clínica em `core.tenants`.
- Criar vínculo em `billing.saas_subscriptions`.
- Eventos de pagamento/inadimplência via webhook atualizam `tenants.status`.

### 11.2 Subconta da clínica
- `asaas-subaccount-create` cria conta e grava `asaas_account_id`.
- Capabilities e status guardados em `billing.tenant_asaas_accounts`.

### 11.3 Paciente como customer
- `asaas-customer-upsert` sincroniza paciente↔customer.
- Salvar somente IDs externos e dados mínimos operacionais.

### 11.4 Cobrança avulsa
- `asaas-charge-create` recebe payload validado do Bubble.
- Persiste `billing.charges` + `integration_logs`.

### 11.5 Assinatura recorrente
- `asaas-subscription-create` cria recorrência e espelha em `billing.subscriptions`.
- Cancelamento/pausa/reactivação via endpoint dedicado.

### 11.6 Split
- Tabela `billing.splits` com regra por charge/subscription.
- Validações para impedir split inconsistente com tenant.

### 11.7 Webhooks Asaas
- Endpoint único por ambiente (dev/stg/prd).
- Verificação de autenticidade + idempotência por `event.id`.
- Mapeamento de eventos para estado interno (`pending`, `paid`, `overdue`, `refunded`).

---

## 12) Integração D4Sign (detalhamento)

### 12.1 Templates
- `contracts.templates` mantém catálogo interno por tenant/tipo de documento.
- Sync periódico/manual via `d4sign-template-sync`.

### 12.2 Geração de documentos
- `d4sign-document-generate` compila placeholders (paciente, protocolo, consentimentos).
- Salva hash SHA-256 do payload final para não repúdio.

### 12.3 Envio para assinatura
- `d4sign-signature-send` cria envelope e signatários.
- Retorna `external_document_id` para rastreio.

### 12.4 Status
- Atualização via polling (`d4sign-status-refresh`) e webhook.
- Status internos normalizados: `draft`, `sent`, `viewed`, `signed`, `rejected`, `expired`.

### 12.5 Webhooks D4Sign
- Mesmo pipeline de segurança/idempotência.
- Eventos persistidos para auditoria jurídica.

---

## 13) API Contract para Bubble (API Connector)

Padrão:
- Base URL: Supabase Edge Functions.
- Auth: Bearer JWT do usuário Supabase.
- Headers obrigatórios:
  - `Authorization: Bearer <token>`
  - `X-Tenant-Id: <tenant_uuid>`
  - `X-Request-Id: <uuid>`
  - `Idempotency-Key` (para POST críticos)

Formato de resposta:
- `{ data, error, meta }`
- `meta` inclui `request_id`, `timestamp`, `version`

Endpoints principais (exemplo lógico):
- `POST /session-bootstrap`
- `POST /switch-tenant`
- `POST /patients/upsert`
- `POST /billing/charges`
- `POST /billing/subscriptions`
- `POST /contracts/documents/generate`
- `POST /contracts/signatures/send`
- `GET /contracts/:id/status`

**Regra:** Bubble não acessa diretamente tabelas sensíveis; prioriza Edge Functions/RPC controlado.

---

## 14) O que deve ser configurável pelo Bubble

1. Cadastro operacional de clínicas, equipes e papéis de negócio.
2. Catálogo de protocolos e módulos.
3. Réguas de comunicação e jornadas operacionais.
4. Parâmetros comerciais: preços, desconto, parcelamento permitido.
5. Templates funcionais (metadados) e mapeamento de placeholders.
6. Regras de UX/fluxo (etapas visíveis, validações de front, dashboards).
7. Acionamento manual de rotinas (reenvio assinatura, replay webhook via função segura).

---

## 15) O que nunca deve ser salvo no Bubble

1. Chaves secretas (Asaas, D4Sign, Supabase service role, JWT signing secrets).
2. Payload bruto de webhooks assinados.
3. Dados clínicos sensíveis (anamnese detalhada, documentos médicos completos, laudos confidenciais).
4. Tokens de integração, refresh tokens, credenciais de subcontas.
5. Contratos assinados em conteúdo integral (somente referências/links assinados temporários quando necessário).
6. Dados de auditoria íntegros (fonte oficial deve ser Supabase).

---

## 16) Decisões finais de governança

- **LGPD by design**: minimização, segregação e trilha de acesso.
- **Backend centrado em Edge Functions** para blindar segredos.
- **RLS + RBAC** como dupla obrigatória.
- **Integrações assíncronas resilientes** com idempotência e retries.
- **Bubble como camada de experiência**, não como repositório sensível.

Essa arquitetura atende o objetivo de ser **segura, completa e configurável pelo Bubble**, preservando o núcleo sensível no Supabase.
