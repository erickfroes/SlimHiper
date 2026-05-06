# Integração Asaas completa — SlimHiper (Bubble + Supabase)

## Objetivo
Desenhar a integração financeira completa entre SlimHiper e Asaas, com Bubble apenas como interface e Supabase (Edge Functions + Postgres + RLS + auditoria) como backend real.

## Premissas de segurança (obrigatórias)

1. **Bubble nunca recebe API key da conta raiz nem da subconta da clínica**.
2. **Toda chamada Asaas é feita apenas por Supabase Edge Functions**.
3. **Tenant é derivado do JWT do usuário** (`auth.uid()` + `core.user_tenants`), nunca confiado do payload.
4. **Segredos ficam fora do Bubble** e criptografados em backend.
5. **Todos os eventos de pagamento atualizam Supabase** e, quando ligados a paciente, geram evento em `clinical.care_events`.

---

## 1) Fluxo de onboarding financeiro da clínica

1. Usuário `owner/finance` da clínica conclui cadastro interno no SlimHiper.
2. Bubble chama `POST /billing/onboarding/start` (Edge Function).
3. Edge Function valida permissão e cria/atualiza `billing.tenant_financial_profiles` com status `pending_documents`.
4. Bubble envia formulário financeiro (PJ/PF) para `POST /billing/onboarding/submit`.
5. Edge Function valida payload, cria subconta Asaas (ou marca para revisão manual), salva vínculo no Supabase.
6. Edge Function retorna status de onboarding (`pending_validation`, `active`, `rejected`).
7. Se `active`, habilita feature flag financeira no tenant.

**Status internos sugeridos**:
- `draft`
- `pending_documents`
- `pending_asaas_validation`
- `active`
- `restricted`
- `rejected`

---

## 2) Fluxo de criação de subconta Asaas

1. Bubble → `POST /billing/tenant-asaas-subaccount`.
2. Edge Function:
   - autentica usuário;
   - verifica `billing.tenant_account.write`;
   - carrega perfil financeiro do tenant;
   - chama Asaas com **API key da conta raiz**;
   - grava `billing.tenant_asaas_accounts`;
   - grava auditoria.
3. Após retorno Asaas, salva:
   - `asaas_account_id`;
   - `wallet_id` (quando disponível);
   - status de verificação.
4. Pode disparar sincronização assíncrona para complementar campos pendentes.

---

## 3) Campos necessários para subconta PF/PJ (validação posterior)

## 3.1 Comuns
- `tenant_id`
- `account_type` (`PF` ou `PJ`)
- `name`
- `email`
- `mobile_phone`
- `address`, `address_number`, `province`, `postal_code`
- `birth_date` (PF) / `company_foundation_date` (PJ, opcional)

## 3.2 PF
- `cpf`
- `income_value` (opcional, conforme regra Asaas)

## 3.3 PJ
- `cnpj`
- `company_type` (MEI, LTDA, etc. conforme enum interno)
- `state_inscription` (opcional)
- `municipal_inscription` (opcional)
- `responsible_name`
- `responsible_cpf`

## 3.4 Bancário (quando exigido)
- `bank_code`
- `agency`
- `account`
- `account_digit`
- `account_type`

> Estratégia: aceitar mínimo para criação inicial + status `pending_asaas_validation`, e completar dados por update posterior.

---

## 4) Onde armazenar `apiKey` e `walletId` da subconta

- `wallet_id`: tabela `billing.tenant_asaas_accounts` (dado não secreto operacional).
- `api_key` da subconta: **não guardar em texto puro**.
  - Guardar em `billing.tenant_asaas_secrets` com:
    - `tenant_id`
    - `secret_ref` (id externo de secret manager) **ou** `api_key_ciphertext`
    - `key_version`
    - `rotated_at`
    - `active`

---

## 5) Como criptografar/guardar segredos fora do Bubble

Ordem de preferência:
1. **Secret Manager externo** (AWS Secrets Manager/GCP Secret Manager/Vault).
2. Supabase Edge Functions guardam apenas `secret_ref`.
3. Em fallback, criptografia envelope no Postgres:
   - chave mestra em env da Edge Function (`KMS_DEK_WRAPPER_KEY`),
   - `api_key` cifrada com AES-GCM,
   - nonce/tag armazenados junto,
   - rotação periódica.

Nunca:
- colocar segredo no Bubble DB;
- retornar segredo em response;
- logar segredo em `ops.integration_logs`.

---

## 6) Como o Bubble inicia criação da subconta via Edge Function

**Endpoint**: `POST /billing/tenant-asaas-subaccount`

Headers:
- `Authorization: Bearer <jwt_usuario>`
- `Content-Type: application/json`
- `Idempotency-Key: <uuid-v4>`

Payload mínimo:
```json
{
  "account_type": "PJ",
  "name": "Clinica ABC LTDA",
  "email": "financeiro@clinica.com",
  "mobile_phone": "+5511999999999",
  "cnpj": "12345678000199",
  "responsible_name": "Maria Silva",
  "responsible_cpf": "12345678901",
  "postal_code": "01310930",
  "address": "Av Paulista",
  "address_number": "1000",
  "province": "Bela Vista"
}
```

Retorno:
```json
{
  "ok": true,
  "data": {
    "asaas_account_id": "acc_123",
    "status": "pending_asaas_validation"
  }
}
```

---

## 7) Como criar customer do paciente na subconta da clínica

**Endpoint**: `POST /billing/patient-customer`

Fluxo:
1. Bubble envia `patient_id`.
2. Edge Function busca paciente por `tenant_id` derivado.
3. Carrega credencial/secret da subconta da clínica.
4. Chama Asaas Customers API na subconta.
5. Salva em `billing.customers`:
   - `tenant_id`, `patient_id`, `asaas_customer_id`, `status`, `raw_snapshot`.
6. Gera `audit.change_log` + evento `clinical.care_events` (`billing_customer_created`).

---

## 8) Como criar cobrança avulsa para paciente

**Endpoint**: `POST /billing/invoice`

Campos recomendados:
- `patient_id`
- `amount`
- `due_date`
- `description`
- `billing_type` (`PIX`, `BOLETO`, `CREDIT_CARD`, `UNDEFINED`)
- `external_reference` (id interno SlimHiper)

Persistir em:
- `billing.charges`
- `billing.charge_events` (evento inicial `created`)
- `clinical.care_events` (`billing_charge_created`)

---

## 9) Como criar assinatura recorrente para paciente

**Endpoint**: `POST /billing/subscription`

Campos:
- `patient_id`
- `amount`
- `cycle` (`WEEKLY|BIWEEKLY|MONTHLY|QUARTERLY|SEMIANNUALLY|YEARLY`)
- `next_due_date`
- `description`
- `max_payments` (opcional)

Persistência:
- `billing.subscriptions`
- `billing.subscription_items` (quando parcelamento/itens)
- timeline paciente: `billing_subscription_created`

---

## 10) Como criar link de pagamento

**Endpoint**: `POST /billing/payment-link`

Campos:
- `patient_id` (opcional para checkout aberto, mas recomendado)
- `name`
- `description`
- `amount`
- `due_date_limit_days` ou `expires_at`

Salvar:
- `billing.payment_links`
- relacionamento opcional com `billing.charges`
- timeline quando associado ao paciente

---

## 11) Como criar cobrança com split

**Endpoint**: `POST /billing/split-charge`

Regras:
1. Split só permitido se tenant tiver `platform_fee_enabled=true`.
2. Percentual fixo do SlimHiper em `core.tenant_settings.billing.platform_fee_percent`.
3. Edge Function monta `split` no payload Asaas usando wallet da conta raiz/plataforma.
4. Persistir configuração aplicada em `billing.splits`:
   - `charge_id`
   - `receiver_wallet_id`
   - `fixed_value`/`percentual_value`
   - `status`

---

## 12) Como cobrar assinatura da clínica pelo SaaS

Modelo:
- Cobrança ocorre na **conta raiz Asaas** (não subconta).
- Tenant possui `billing.saas_subscriptions`.

Fluxo:
1. `POST /billing/platform-subscription` cria assinatura SaaS da clínica.
2. Webhooks Asaas da conta raiz atualizam `billing.saas_invoices` e `billing.saas_subscription_events`.
3. Status da assinatura controla `core.tenants.status` e feature flags.

---

## 13) Como tratar inadimplência da clínica

Política sugerida:
- D+1 atraso: notificação financeira.
- D+3: bloqueio de novos faturamentos ao paciente (mantém leitura).
- D+7: `tenant.status=restricted` (login permitido só para owner/finance + tela cobrança).
- D+15: `tenant.status=suspended`.

Automação:
- job diário (`ops.retry_queue` / cron Edge Function) avalia faturas SaaS vencidas;
- gera `audit.security_events` e `core.tenant_events`.

---

## 14) Como tratar inadimplência do paciente

- `charge.overdue` recebido via webhook:
  - atualizar `billing.charges.status='overdue'`;
  - criar tarefa operacional em `clinical`/`ops`;
  - registrar timeline paciente (`billing_overdue`).
- Regras de negócio opcionais:
  - bloquear agendamento futuro;
  - alertar equipe financeira;
  - disparar régua de cobrança.

---

## 15) Como processar webhooks Asaas com `asaas-access-token`

**Endpoint público**: `POST /webhooks/asaas`

Validações:
1. Ler header `asaas-access-token`.
2. Comparar com segredo esperado (constante de ambiente, comparação em tempo constante).
3. Rejeitar (`401`) se inválido.
4. Persistir recebimento em `ops.webhook_inbox` antes de processar.
5. Normalizar evento em `ops.webhook_events`.

Boas práticas:
- permitir rotação com token primário/secundário;
- não logar token;
- registrar apenas hash parcial para troubleshooting.

---

## 16) Como garantir idempotência

Duas camadas:

1. **Idempotência ativa (requisições Bubble)**
   - Header `Idempotency-Key` obrigatório em criação/alteração financeira.
   - Tabela `ops.idempotency_keys(scope, key, request_hash, response_snapshot, expires_at)`.

2. **Idempotência passiva (webhooks)**
   - Chave única: `provider + event_id` (ou hash payload + timestamp se event_id ausente).
   - Reprocessamento retorna `200` com `idempotent_replay=true`.

---

## 17) Mapeamento de status Asaas → status interno

## 17.1 Cobranças (`billing.charges`)
- `PENDING` -> `pending`
- `RECEIVED` -> `paid`
- `CONFIRMED` -> `paid_confirmed`
- `OVERDUE` -> `overdue`
- `REFUNDED` -> `refunded`
- `RECEIVED_IN_CASH` -> `paid_cash`
- `CHARGEBACK_REQUESTED` -> `chargeback_requested`
- `CHARGEBACK_DISPUTE` -> `chargeback_dispute`
- `AWAITING_CHARGEBACK_REVERSAL` -> `chargeback_pending_reversal`
- `DUNNING_REQUESTED` -> `dunning_requested`
- `DUNNING_RECEIVED` -> `dunning_paid`

## 17.2 Assinaturas (`billing.subscriptions`)
- `ACTIVE` -> `active`
- `EXPIRED` -> `expired`
- `INACTIVE` -> `inactive`

## 17.3 Assinatura SaaS da clínica (`billing.saas_subscriptions`)
- `ACTIVE` -> `active`
- `OVERDUE` -> `overdue`
- `CANCELED` -> `canceled`
- `SUSPENDED` -> `suspended`

---

## 18) Tabelas billing necessárias

Mínimo recomendado:
- `billing.tenant_financial_profiles`
- `billing.tenant_asaas_accounts`
- `billing.tenant_asaas_secrets`
- `billing.customers`
- `billing.charges`
- `billing.charge_events`
- `billing.subscriptions`
- `billing.subscription_items`
- `billing.subscription_events`
- `billing.payment_links`
- `billing.splits`
- `billing.transactions`
- `billing.saas_subscriptions`
- `billing.saas_invoices`
- `billing.saas_subscription_events`

Apoio operacional:
- `ops.idempotency_keys`
- `ops.webhook_inbox`
- `ops.webhook_events`
- `ops.integration_logs`

---

## 19) Edge Functions necessárias

- `billing-onboarding-start`
- `billing-onboarding-submit`
- `billing-tenant-asaas-subaccount-create`
- `billing-tenant-asaas-subaccount-sync`
- `billing-patient-customer-create`
- `billing-invoice-create`
- `billing-subscription-create`
- `billing-subscription-cancel`
- `billing-payment-link-create`
- `billing-split-charge-create`
- `billing-payment-status-get`
- `billing-platform-subscription-create`
- `billing-delinquency-run`
- `webhook-asaas-receive`

Todas devem:
- validar JWT (exceto webhook público);
- derivar tenant no backend;
- checar RBAC;
- registrar auditoria;
- mascarar PII em logs.

---

## 20) Telas Bubble necessárias

Por tenant (clínica):
1. **Configuração Financeira**
   - status onboarding
   - dados PF/PJ
   - status subconta Asaas
2. **Pacientes > Cobrança**
   - customer Asaas
   - cobranças avulsas
   - assinaturas recorrentes
   - links de pagamento
3. **Recebíveis e Inadimplência**
   - listagem de atrasos
   - ações de cobrança
4. **Configuração de Split/Taxa de Plataforma**
5. **Timeline do Paciente** (com eventos financeiros)

Plataforma (admin SlimHiper):
6. **Assinaturas SaaS das Clínicas**
7. **Monitor de Webhooks/Conciliação**
8. **Falhas e Retentativas**

---

## 21) Testes sandbox (roteiro)

1. Criar tenant de teste.
2. Criar subconta Asaas sandbox.
3. Criar paciente e customer na subconta.
4. Emitir cobrança avulsa (`PIX` e `BOLETO`).
5. Criar assinatura recorrente e validar próxima cobrança.
6. Criar link de pagamento e simular pagamento.
7. Criar cobrança com split e validar repasse.
8. Simular webhook de `RECEIVED`, `OVERDUE`, `REFUNDED`.
9. Verificar:
   - atualização em `billing.*`;
   - evento em `clinical.care_events`;
   - idempotência em replay do webhook.
10. Simular token webhook inválido e conferir rejeição + log de segurança.

---

## 22) Falhas comuns e recuperação

1. **Token webhook inválido**
   - ação: `401`, grava `audit.security_events`, alerta observabilidade.
2. **Timeout na API Asaas**
   - ação: retry exponencial + circuito aberto temporário.
3. **Webhook duplicado**
   - ação: detectar chave idempotente e ignorar efeito colateral.
4. **Divergência de status (Asaas vs banco)**
   - ação: job de reconciliação (`billing-tenant-asaas-subaccount-sync` + `billing-payment-status-get`).
5. **Subconta sem wallet/split indisponível**
   - ação: bloquear split, permitir cobrança sem split, abrir pendência operacional.
6. **Rotação de segredo quebrada**
   - ação: manter chave anterior por janela de transição, executar healthcheck de credenciais.

---

## Observabilidade mínima

- `request_id` por chamada.
- Métricas por função: sucesso, erro, latência, retries.
- Dead-letter para eventos webhook não processados.
- Dashboard por tenant: volume, conversão, atraso, chargeback.
