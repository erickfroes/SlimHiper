# Integração D4Sign completa — SlimHiper (Bubble + Supabase)

## Objetivo
Desenhar a integração completa de assinatura eletrônica entre SlimHiper e D4Sign, mantendo Bubble como interface operacional e Supabase como backend sensível (Auth, Postgres, RLS, Edge Functions, Storage privado, auditoria).

## Escopo permitido no SlimHiper
Usar D4Sign para:
- contratos de prestação de serviço;
- termos de consentimento;
- termos de privacidade;
- termos de tratamento de dados;
- termos de protocolo;
- autorização de compartilhamento com nutricionista/educador físico;
- termos de teleatendimento.

**Fora de escopo D4Sign**: prescrições médicas. Prescrição deve continuar em provedor dedicado (placeholder já previsto na arquitetura).

---

## 1) Fluxo completo (template → assinatura → timeline)

1. **Configuração do template por tenant**
   - Operador da clínica escolhe tipo documental (`service_contract`, `consent_term`, etc.) no Bubble.
   - Bubble chama `POST /legal/templates/upsert`.
   - Edge Function valida permissão, salva metadados do template em `legal.document_templates` e arquivo-base em Storage privado.

2. **Geração do documento para assinatura**
   - Bubble chama `POST /legal/documents/generate` informando `template_id`, `patient_id` (quando aplicável), `protocol_id` (quando aplicável) e variáveis.
   - Edge Function renderiza placeholders, gera PDF final, calcula hash SHA-256, grava em `storage/private/legal-documents/...` e cria registro em `legal.documents` com status `generated`.

3. **Envio para D4Sign**
   - Bubble chama `POST /legal/signatures/send` com `document_id`.
   - Edge Function busca token/cryptKey do tenant, cria envelope/documento no D4Sign, sobe o PDF, persiste `d4sign_document_uuid` e status `sent`.

4. **Adição de signatários**
   - Bubble chama `POST /legal/signatures/signer/add` (1..N vezes).
   - Edge Function adiciona paciente/responsável/profissional/testemunha conforme regra do tipo de documento.
   - Dados de signatários ficam em `legal.document_signers`.

5. **Acompanhar status**
   - Bubble consulta `GET /legal/signatures/status?document_id=...`.
   - Edge Function retorna status local e, se necessário, sincroniza com D4Sign (`queued`, `sent`, `viewed`, `signed`, `rejected`, `expired`, `canceled`).

6. **Webhook D4Sign**
   - D4Sign chama `POST /webhooks/d4sign`.
   - Edge Function valida assinatura/token/HMAC, aplica idempotência, registra evento em `ops.webhook_events` e atualiza `legal.documents` + `legal.document_signers`.

7. **Download do assinado e versionamento**
   - Quando status final = `signed`, job/edge function baixa PDF assinado do D4Sign, armazena versão final em Storage privado, atualiza `signed_file_path`, `signed_file_hash` e `signed_at`.

8. **Timeline operacional/clínica**
   - Cada transição gera eventos em `audit.change_log` e `clinical.care_events` (quando há paciente), exibindo trilha completa no Bubble.

---

## 2) Tabelas necessárias (Postgres/Supabase)

## 2.1 `legal.document_templates`
- `id` (uuid, pk)
- `tenant_id` (uuid, obrigatório)
- `doc_type` (`service_contract|consent_term|privacy_term|data_processing_term|protocol_term|sharing_auth|telehealth_term`)
- `name`
- `version` (int)
- `is_active` (bool)
- `storage_path_template` (arquivo-base no Storage privado)
- `placeholders_schema` (jsonb)
- `locale` (ex: `pt-BR`)
- `created_by`, `created_at`, `updated_at`

## 2.2 `legal.documents`
- `id` (uuid, pk)
- `tenant_id`
- `patient_id` (nullable)
- `protocol_id` (nullable)
- `template_id`
- `doc_type`
- `title`
- `status` (`generated|sent|viewed|partially_signed|signed|rejected|expired|canceled|failed`)
- `file_path_generated`
- `file_hash_generated`
- `signed_file_path` (nullable)
- `signed_file_hash` (nullable)
- `d4sign_document_uuid` (nullable)
- `d4sign_safe_key` (nullable)
- `external_ref` (id interno Bubble, opcional)
- `expires_at` (nullable)
- `rejection_reason` (nullable)
- `canceled_reason` (nullable)
- `created_by`, `created_at`, `updated_at`, `signed_at`

## 2.3 `legal.document_signers`
- `id` (uuid, pk)
- `tenant_id`
- `document_id`
- `role` (`patient|guardian|provider|witness|clinic_representative`)
- `name`
- `email`
- `phone` (nullable)
- `tax_id` (nullable)
- `d4sign_signer_uuid` (nullable)
- `status` (`pending|sent|viewed|signed|rejected|failed`)
- `signed_at` (nullable)
- `rejected_reason` (nullable)
- `auth_method` (`email|sms|whatsapp|certificate`, conforme política)
- `created_at`, `updated_at`

## 2.4 `legal.d4sign_tenant_credentials`
- `tenant_id` (pk)
- `secret_ref_token_api` **ou** `token_api_ciphertext`
- `secret_ref_crypt_key` **ou** `crypt_key_ciphertext`
- `key_version`
- `active`
- `rotated_at`, `created_at`, `updated_at`

## 2.5 `legal.document_events`
- `id` (bigint, pk)
- `tenant_id`
- `document_id`
- `event_type` (`generated|sent|signer_added|viewed|signed|rejected|expired|canceled|resent|webhook_received|downloaded_signed`)
- `event_source` (`edge|webhook|system|manual`)
- `payload` (jsonb)
- `created_at`

## 2.6 `ops.webhook_events` (genérica, reaproveitável)
- `id` (uuid, pk)
- `provider` (`d4sign|asaas|...`)
- `tenant_id` (nullable no início)
- `idempotency_key` (unique por provider)
- `signature_valid` (bool)
- `headers` (jsonb)
- `payload` (jsonb)
- `status` (`received|processed|ignored|failed`)
- `error_message` (nullable)
- `received_at`, `processed_at`

> Todas as tabelas com `tenant_id`, RLS obrigatória e índices por `(tenant_id, created_at desc)`.

---

## 3) Edge Functions necessárias

1. `legal-templates-upsert`
2. `legal-documents-generate`
3. `legal-signatures-send`
4. `legal-signatures-signer-add`
5. `legal-signatures-status`
6. `legal-signatures-resend`
7. `legal-signatures-cancel`
8. `legal-signed-download-sync`
9. `webhook-d4sign`
10. `legal-patient-document-access` (gera URL assinada curta para portal paciente)
11. `legal-document-audit-log` (consulta trilha para painel)

Todas devem:
- validar JWT Supabase;
- derivar tenant pelo vínculo usuário↔tenant (nunca confiar tenant no body);
- validar permissões por papel;
- registrar auditoria.

---

## 4) Como guardar `tokenAPI` e `cryptKey` com segurança

- Nunca no Bubble.
- Preferência: Secret Manager externo (AWS/GCP/Vault), guardando apenas `secret_ref_*` no Postgres.
- Fallback: cifrar no backend (AES-256-GCM envelope), chave mestra em env da Edge Function.
- Rotação:
  - campo `key_version`;
  - `active=true` somente na versão atual;
  - job de rotação com teste de conectividade D4Sign antes do cutover.
- Logs: mascarar qualquer trecho de token/chave.

---

## 5) Como o Bubble chama geração/envio

## 5.1 Gerar documento
`POST /legal/documents/generate`

Headers:
- `Authorization: Bearer <jwt_usuario>`
- `Idempotency-Key: <uuid-v4>`

Payload exemplo:
```json
{
  "template_id": "uuid-template",
  "patient_id": "uuid-patient",
  "protocol_id": "uuid-protocol",
  "title": "Termo de Consentimento - Protocolo Metabólico",
  "variables": {
    "paciente_nome": "Ana Souza",
    "cpf": "***",
    "data_inicio": "2026-05-06"
  }
}
```

## 5.2 Enviar para assinatura
`POST /legal/signatures/send`

Payload:
```json
{
  "document_id": "uuid-document"
}
```

## 5.3 Adicionar signatário
`POST /legal/signatures/signer/add`

Payload:
```json
{
  "document_id": "uuid-document",
  "role": "patient",
  "name": "Ana Souza",
  "email": "ana@email.com",
  "auth_method": "email"
}
```

---

## 6) Configurar templates por tenant

- Cada tenant mantém seus templates ativos em `legal.document_templates`.
- Estratégia de versionamento:
  - Novo ajuste textual gera `version+1`.
  - Template anterior permanece para documentos históricos.
- Regras:
  - Um template ativo por `tenant_id + doc_type` (opcionalmente por unidade).
  - Placeholders obrigatórios validados por `placeholders_schema`.
- Bubble deve oferecer:
  - tela de upload/template;
  - pré-visualização com dados mock;
  - publicação/desativação.

---

## 7) Associação do documento a paciente, protocolo ou tenant

No `legal.documents`:
- Documento institucional (ex.: política interna): apenas `tenant_id`.
- Documento de paciente: `tenant_id + patient_id`.
- Documento de protocolo: `tenant_id + patient_id + protocol_id`.

Regra de integridade:
- `patient_id` e `protocol_id` devem pertencer ao mesmo `tenant_id`.
- `protocol_id` não pode existir sem `patient_id`.

---

## 8) Validação de webhook com token/HMAC

No endpoint `webhook-d4sign`:
1. Capturar body bruto (`raw_body`) + headers.
2. Validar header de autenticação/token compartilhado cadastrado por ambiente.
3. Quando disponível assinatura HMAC:
   - `expected = HMAC_SHA256(raw_body, webhook_secret)`
   - comparar em tempo constante com header recebido.
4. Se inválido:
   - registrar `ops.webhook_events.signature_valid=false`
   - retornar `401`.
5. Se válido: continuar processamento.

---

## 9) Idempotência (obrigatória)

Camadas:
1. **Entrada Bubble → Edge**: exigir `Idempotency-Key` em operações mutáveis.
2. **Webhook**: `idempotency_key = provider + event_id` (ou hash determinístico do payload).
3. **Banco**:
   - unique em `ops.webhook_events(provider, idempotency_key)`;
   - upsert transacional de status de documento.
4. **Processador**:
   - se evento já `processed`, retornar `200` sem reprocessar.

---

## 10) Como exibir status no Bubble

Criar endpoint de leitura `GET /legal/documents/list` com filtros:
- `patient_id`
- `protocol_id`
- `doc_type`
- `status`
- paginação

Campos exibidos:
- `title`, `doc_type`, `status`, `created_at`, `signed_at`, `expires_at`
- `sign_progress` (ex: `1/2 assinaturas`)
- ação disponível (`reenviar`, `cancelar`, `baixar assinado`, `ver motivo rejeição`)

Atualização:
- polling curto (30-60s) ou webhook interno para atualizar estado no Bubble.

---

## 11) Liberação do documento assinado no portal do paciente

1. Documento em `status=signed` e `signed_file_path` preenchido.
2. Portal chama `POST /legal/patient/document-access` com `document_id`.
3. Edge Function valida:
   - paciente dono do documento (via JWT + relação com tenant);
   - documento assinado e ativo.
4. Retorna URL assinada curta (ex: 60-120s) do Storage privado.
5. Registrar evento de visualização/download em `legal.document_events` e `audit.change_log`.

---

## 12) Auditoria de visualização/download

Registrar sempre:
- `actor_user_id` (ou `patient_auth_id`);
- `tenant_id`, `document_id`;
- `action` (`view`, `download`, `share_link_generated`);
- `ip`, `user_agent`, `timestamp`;
- `origin` (`backoffice_bubble|patient_portal|api`).

Tabelas:
- `audit.change_log` (trilha geral)
- `legal.document_events` (trilha documental)

---

## 13) Rejeitado, expirado, cancelado e reenviado

- **Rejeitado**:
  - webhook atualiza `legal.documents.status=rejected` e `rejection_reason`.
  - Bubble exibe motivo + ação “corrigir e reenviar”.

- **Expirado**:
  - job diário marca `expired` conforme regra do D4Sign/tenant.
  - operador pode clicar “reenviar” (novo ciclo de envio).

- **Cancelado**:
  - endpoint `POST /legal/signatures/cancel` solicita cancelamento no D4Sign e fecha ciclo local com justificativa.

- **Reenviado**:
  - endpoint `POST /legal/signatures/resend`.
  - manter histórico no mesmo `document_id` via `document_events` ou criar nova revisão (`parent_document_id`) conforme governança jurídica.

---

## 14) Testes sandbox (obrigatórios antes de produção)

1. **Template válido**: gerar PDF com placeholders completos.
2. **Template inválido**: placeholder ausente deve bloquear geração.
3. **Envio e assinatura happy path**: `generated → sent → signed`.
4. **Múltiplos signatários**: validar ordem e conclusão parcial.
5. **Webhook inválido**: token/HMAC incorreto deve retornar 401.
6. **Webhook duplicado**: processar uma vez (idempotência).
7. **Expiração**: simular timeout e transição para `expired`.
8. **Rejeição**: capturar `rejection_reason`.
9. **Cancelamento manual**: status consistente local + D4Sign.
10. **Download assinado**: somente com autorização correta (RLS + regras portal).
11. **Multi-tenant**: impedir acesso cruzado entre clínicas.

---

## 15) Falhas comuns e recuperação

1. **Credencial D4Sign inválida/expirada**
   - Sintoma: erro 401/403 no envio.
   - Ação: marcar integração `degraded`, alertar owner, bloquear novos envios até rotação de credencial.

2. **Webhook não chega**
   - Sintoma: documento assinado no provedor, mas não no SlimHiper.
   - Ação: rotina de reconciliação (`legal-signatures-status` em lote) e `legal-signed-download-sync`.

3. **PDF corrompido/incompatível**
   - Sintoma: D4Sign rejeita upload.
   - Ação: validar PDF/A e tamanho antes de envio; regenerar arquivo.

4. **Duplicidade por retry de rede**
   - Sintoma: documentos repetidos.
   - Ação: idempotency key + unique constraints + detecção por hash do conteúdo.

5. **Assinante com e-mail inválido**
   - Sintoma: envio falha para signatário específico.
   - Ação: status `failed` no signer, permitir correção e reenvio sem recriar todo documento.

6. **Acesso indevido a documento assinado**
   - Sintoma: tentativa cross-tenant/paciente errado.
   - Ação: negar por RLS, registrar tentativa em auditoria de segurança.

---

## Regras de segurança finais (checklist)

- Bubble sem segredo e sem dado clínico sensível.
- Somente Edge Functions chamam D4Sign.
- Storage privado para PDFs (gerados e assinados).
- RLS em todas as tabelas com `tenant_id`.
- Auditoria completa de criação, envio, assinatura, visualização e download.
- Webhook autenticado + idempotente + logado.
- Reconciliação periódica para evitar divergência de status.
