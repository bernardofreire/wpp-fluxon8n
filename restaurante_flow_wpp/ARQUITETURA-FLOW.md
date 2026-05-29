# Arquitetura: WhatsApp Flow Restaurante (Dinamico)

## Visao Geral

O WhatsApp Flow substitui o catalogo nativo do WhatsApp e assume toda a jornada do pedido:
cardapio, carrinho, entrega e pagamento. O Odoo e o backend de dados.

**Workflow unico**: um unico fluxo n8n contem TUDO — webhook, logica de conversa, chamadas
ao Odoo, envio de Flow, processamento de resposta e envio de mensagens WhatsApp.
Nao ha sub-workflows ou data.api.call separado. Para cada cliente (restaurante), o workflow
e duplicado e apenas as configs no inicio sao alteradas.

```
 Cliente                n8n (workflow unico)           Odoo
   |                     |                              |
   |-- msg "oi" -------->|                              |
   |                     |-- [CONFIG do cliente] ------>|
   |                     |-- GET /customers/search ---->|
   |                     |-- GET /companies/pos ------->|
   |                     |-- GET /companies/products -->|
   |                     |                              |
   |<-- Flow msg --------|                              |
   |                     |                              |
   |   (WhatsApp Flow - cardapio+entrega+pagamento)     |
   |                     |                              |
   |-- action=complete ->|                              |
   |                     |-- POST /orders/quote ------->|
   |                     |-- POST /orders ------------->|
   |                     |-- POST conversations ------->|  (Supabase)
   |<-- confirmacao -----|                              |
```

## Principio Central

1. **Flow 100% dinamico.** Nenhum item, categoria, endereco ou metodo de pagamento
   hardcoded no JSON. Tudo vem via `initial_data` injetado pelo n8n com dados do Odoo.

2. **Workflow unico, duplicado por cliente.** Cada restaurante tem sua copia do workflow.
   A unica diferenca entre copias sao as configs no no "Config" no inicio do fluxo.

3. **Sem sub-workflows.** Todas as chamadas HTTP (Odoo, Supabase, Meta) estao dentro
   do mesmo workflow. Isso simplifica deploy e debug.

## Config por Cliente

No inicio do workflow, um no Set chamado **"Config"** define todas as variaveis do cliente.
Este e o UNICO no que muda ao duplicar o workflow para um novo cliente.

```json
{
  "display_name": "Restaurante Fino",
  "phone_number_id": "123456789",
  "wa_token": "EAAG...",
  "flow_id": "1234567890",

  "odoo_base_url": "https://cliente.odoo.com",
  "odoo_database": "cliente_db",
  "odoo_api_key": "key_xxx",
  "odoo_api_secret": "secret_xxx",
  "company_id": 1,
  "pos_config_id": 2,

  "supabase_url": "https://xxx.supabase.co",
  "supabase_key": "eyJ...",

  "timezone_offset": -3,
  "session_timeout_min": 30,

  "msg_closed": "Estamos fechados. Horario: Seg-Sab 11h-23h",
  "msg_welcome": "Ola {nome}! Toque abaixo para montar seu pedido",
  "msg_welcome_new": "Bem-vindo ao {display_name}! Toque abaixo para montar seu pedido",
  "msg_aguardando_flow": "Toque no botao acima para abrir o cardapio!",
  "msg_pedido_confirmado": "Pedido #{order_name} confirmado! Previsao: {tempo} min",
  "msg_erro_generico": "Tivemos um problema. Tente novamente ou fale com atendente.",
  "msg_escape": "Ok, cancelado. Quando quiser, mande um oi!",
  "msg_timeout": "Sua sessao expirou. Mande qualquer mensagem para comecar de novo."
}
```

### Ao duplicar para novo cliente:
1. Duplicar o workflow no n8n
2. Alterar o no **"Config"** com dados do novo cliente
3. Alterar o **Webhook path** (ex: `restaurante_fino`, `restaurante_bk_centro`)
4. Renomear o workflow

## 3 Momentos do n8n

### 1. PRE-FLOW (conversa)
Recebe mensagem do cliente, identifica quem e, verifica estado.

```
Webhook -> ACK 200 -> Filter & Dedup -> Config
  -> Odoo Auth (JWT)
  -> GET /customers/search (busca cliente por telefone)
  -> GET conversations (Supabase - estado da sessao)
  -> Roteador Principal (switch por etapa)
```

Roteador:
- `etapa=''` (livre) -> verifica pedido aberto -> verifica loja aberta -> busca catalogo -> envia Flow
- `etapa='aguardando_flow'` -> msg "toque no botao" + opcao reenviar
- `etapa='pedido_ativo'` -> busca status do pedido -> mostra + botoes

### 2. FLOW (WhatsApp Flow - fora do n8n)
5 telas client-side, dados injetados via initial_data:

| Tela | Conteudo | Dados dinamicos |
|------|----------|-----------------|
| CARDAPIO | Categorias + itens + precos | GET /companies/{id}/products |
| CARRINHO | Revisao, qtd, obs, subtotal | calculado client-side |
| ENTREGA | Endereco salvo ou novo | delivery_addresses[] do cliente |
| PAGAMENTO | PIX / Cartao / Dinheiro | definido na config |
| RESUMO | Consolidado + Finalizar | tudo acima |

O Flow retorna `action=complete` com payload completo:
```json
{
  "itens": [{"id": 1, "qtd": 2, "preco": 22.50, "obs": "sem cebola"}],
  "endereco": {"id": 5},
  "pagamento": {"metodo": "pix", "troco": null},
  "subtotal": 54.00,
  "taxa_entrega": 7.00,
  "total": 61.00
}
```

Ou com endereco novo:
```json
{
  "endereco": {
    "novo": {
      "rua": "Rua das Flores",
      "numero": "123",
      "complemento": "Apto 4",
      "bairro": "Centro",
      "cep": "01001-000"
    }
  }
}
```

### 3. POS-FLOW (conversa)
Recebe o payload do Flow, valida, cria pedido no Odoo, confirma pro cliente.

```
Webhook (nfm_reply) -> Parse response_json
  -> Validar flow_token (anti-replay)
  -> Validar itens vs Odoo (precos, disponibilidade)
  -> POST /orders/quote (confirmar totais server-side)
  -> POST /orders (persistir pedido)
  -> POST conversations (Supabase: etapa='pedido_ativo')
  -> Enviar confirmacao ao cliente (API Meta)
  -> (se PIX) Enviar QR code / chave
```

## Estados da Sessao

Apenas 3 estados possiveis (tabela conversations_restaurante no Supabase):

| etapa | contexto | significado |
|-------|----------|-------------|
| `''` | `{}` | livre - qualquer msg inicia jornada |
| `aguardando_flow` | `{flow_token, sent_at}` | Flow enviado, esperando resposta |
| `pedido_ativo` | `{order_id, order_name}` | pedido criado, esperando conclusao |

## Fluxo Detalhado: Interacao Cliente x Sistema

### Entrada (qualquer mensagem)

```
CLIENTE                                  SISTEMA (n8n workflow unico)
  |                                        |
  |-- "oi" ------------------------------>|
  |                                        |-- ACK 200
  |                                        |-- Filter (so message + interactive)
  |                                        |-- Dedup (message.id via Supabase)
  |                                        |-- Config (Set node - dados do cliente)
  |                                        |-- Odoo Auth (POST /lym-auth/auth/token)
  |                                        |-- GET /customers/search?phone={tel}
  |                                        |   -> partner_id, nome, enderecos[]
  |                                        |-- GET conversations (Supabase)
  |                                        |   -> etapa, contexto
  |                                        |
  |                                        |-- Session Timeout?
  |                                        |   (updated_at > session_timeout_min)
  |                                        |   SIM -> reset etapa='', ctx={}
  |                                        |
  |                                        |-- ROTEADOR (switch etapa)
```

### Ramo A: Pedido Ativo (etapa='pedido_ativo')

```
CLIENTE                                  SISTEMA
  |                                        |
  |                                        |-- GET /orders/{order_id}
  |                                        |
  |<-- "Oi Joao! Pedido em andamento:  ---|
  |     #847 - 2x X-Burguer...            |
  |     Em preparo - ~25 min"             |
  |                                        |
  |    [Novo pedido]                       |
  |    [Cancelar pedido #847]              |
  |    [Falar com atendente]               |
  |                                        |
  |-- "Cancelar pedido" ----------------->|
  |                                        |-- Confirma?
  |<-- "Tem certeza?" [Sim] [Nao] --------|
  |-- "Sim" ----------------------------->|
  |                                        |-- (cancelamento - futuro)
  |                                        |-- POST conversations (etapa='')
  |<-- "Pedido cancelado."  --------------|
  |    [Ver cardapio] [Ate mais]           |
```

### Ramo B: Sem Pedido -> Abrir Flow (etapa='')

```
CLIENTE                                  SISTEMA
  |                                        |
  |                                        |-- GET /orders?status=pending,draft
  |                                        |   (verifica pedido em aberto)
  |                                        |   TEM ABERTO? -> vai pro Ramo A
  |                                        |
  |                                        |-- GET /companies/{id}/pos
  |                                        |   (can_receive_orders?)
  |                                        |
  |                                        |-- FECHADO?
  |<-- "Estamos fechados. Horario: ..." ---|   [FIM - nao salva sessao]
  |                                        |
  |                                        |-- ABERTO
  |                                        |-- GET /companies/{id}/products
  |                                        |   -> categorias, itens, precos
  |                                        |
  |                                        |-- Monta initial_data:
  |                                        |   { categorias, itens, precos,
  |                                        |     enderecos_salvos,
  |                                        |     nome_cliente,
  |                                        |     metodos_pagamento }
  |                                        |
  |                                        |-- POST Meta API (Send Flow Message)
  |                                        |   flow_id (da Config), flow_token,
  |                                        |   initial_data
  |                                        |
  |<-- "Ola Joao! Toque abaixo para    ---|
  |     montar seu pedido"                 |
  |    [Abrir Cardapio]                    |
  |                                        |
  |                                        |-- POST conversations (Supabase)
  |                                        |   etapa='aguardando_flow'
  |                                        |   contexto={flow_token, sent_at}
```

### Ramo C: Aguardando Flow (etapa='aguardando_flow')

```
CLIENTE                                  SISTEMA
  |                                        |
  |-- "como funciona?" ------------------>|
  |                                        |-- Detecta etapa='aguardando_flow'
  |<-- "Toque no botao acima para      ---|
  |     abrir o cardapio!"                 |
  |    [Reenviar cardapio]                 |
  |    [Falar com atendente]               |
```

### Flow Response (action=complete)

```
CLIENTE                                  SISTEMA
  |                                        |
  |-- [Finalizar Pedido no Flow] -------->|
  |   payload = {itens, endereco,          |-- Webhook: type=interactive
  |              pagamento, totais}        |   nfm_reply.response_json
  |                                        |
  |                                        |-- Parse response_json
  |                                        |-- Validar flow_token
  |                                        |   (bate com contexto salvo?)
  |                                        |   INVALIDO? -> msg erro + reenviar
  |                                        |
  |                                        |-- Validar itens (ids, precos)
  |                                        |   FALHA? -> msg + reenviar Flow
  |                                        |
  |                                        |-- POST /orders/quote
  |                                        |   confirma totais server-side
  |                                        |   DIVERGENCIA? -> msg + reenviar
  |                                        |
  |                                        |-- POST /orders
  |                                        |   {partner_id, items[],
  |                                        |    delivery_address: {id} ou
  |                                        |    {new:{...}, add_new_address:true},
  |                                        |    payment_method, notes}
  |                                        |   FALHA? -> retry 1x -> msg suporte
  |                                        |
  |                                        |-- POST conversations (Supabase)
  |                                        |   etapa='pedido_ativo'
  |                                        |   contexto={order_id, order_name}
  |                                        |
  |<-- "Pedido #847 confirmado!         ---|
  |     2x X-Burguer R$45 ...             |
  |     Total: R$61 - PIX                 |
  |     Previsao: 30-40 min"              |
  |                                        |
  |                                        |-- (se PIX) Envia QR/chave
  |<-- "Pague via PIX: chave XX..."  -----|
```

## Tratamento de Erros

| Situacao | Resposta ao cliente | Acao sistema |
|----------|---------------------|--------------|
| Loja fechada | Horario de funcionamento | Nao salva sessao |
| Flow timeout (nao abre) | Msg lembrete + reenviar | Mantem etapa |
| Flow token invalido | "Tente novamente" | Log erro, reenviar Flow |
| Item indisponivel pos-flow | "Itens mudaram, reabra" | Reenviar Flow |
| order.quote diverge | "Precos atualizaram" | Reenviar Flow |
| order.create falha | "Tentando novamente..." | 1 retry, depois suporte |
| Msg invalida durante espera | Status do pedido atual | Mostra botoes |
| Midia (imagem/audio/video) | "So processamos texto" | Ignora |
| Odoo Auth falha | Msg erro generico | Log + nao continua |
| Supabase falha | Msg erro generico | Log + continua sem estado |
| Session timeout | Msg "sessao expirou" | Reset etapa='', ctx={} |

## Escape (qualquer momento)

Keywords: "sair", "cancelar", "0"

| etapa atual | acao |
|-------------|------|
| `''` | msg despedida |
| `aguardando_flow` | cancela, POST conversations(etapa=''), msg escape |
| `pedido_ativo` | pergunta "cancelar pedido #X?" [Sim] [Nao] |

## Dados Dinamicos do Flow (initial_data)

Payload montado pelo n8n e injetado no envio do Flow Message:

```json
{
  "categorias": [
    {"id": "hamburgueres", "label": "Hamburgueres"},
    {"id": "pizzas", "label": "Pizzas"},
    {"id": "bebidas", "label": "Bebidas"}
  ],
  "itens": [
    {
      "id": 101,
      "categoria": "hamburgueres",
      "nome": "X-Burguer",
      "descricao": "Pao, hamburguer, queijo, alface, tomate",
      "preco": 22.50,
      "disponivel": true
    }
  ],
  "enderecos_salvos": [
    {"id": 5, "label": "Rua das Flores, 123 - Centro"},
    {"id": 8, "label": "Av. Brasil, 456 - Jardim"}
  ],
  "metodos_pagamento": ["pix", "cartao_entrega", "dinheiro"],
  "nome_cliente": "Joao",
  "taxa_entrega_base": 7.00
}
```

## Nos n8n (visao macro do workflow unico)

```
Webhook (/webhook/restaurante_{cliente})
  |
  -> Respond 200 (ACK imediato)
  -> Filter (so message + interactive, ignora status/read)
  -> Dedup (POST processed_messages - Supabase)
  -> Config (Set node - UNICO NO QUE MUDA POR CLIENTE)
  -> Odoo Auth (POST /lym-auth/auth/token -> JWT)
  -> Busca Cliente (GET /customers/search?phone=)
  -> Busca Sessao (GET conversations - Supabase)
  -> Session Timeout? (updated_at check)
  |
  -> E nfm_reply (flow response)? -----> RAMO FLOW-RESPONSE
  |    Parse payload
  |    Validar flow_token
  |    Validar itens
  |    POST /orders/quote
  |    POST /orders
  |    POST conversations (etapa='pedido_ativo')
  |    Send confirmacao (POST Meta API)
  |    (se PIX) Send QR
  |
  -> E escape keyword? ----------------> RAMO ESCAPE
  |    Switch(etapa) -> trata + POST conversations
  |
  -> E mensagem normal? ---------------> RAMO CONVERSA
       Switch(etapa):
         ''  -> GET /orders (pedido aberto?)
              -> GET /companies/pos (aberto?)
              -> GET /companies/products (catalogo)
              -> Send Flow Message (POST Meta API)
              -> POST conversations (etapa='aguardando_flow')
         'aguardando_flow'
              -> Send msg "toque no botao" + botao reenviar
         'pedido_ativo'
              -> GET /orders/{id} (status)
              -> Send msg status + botoes
```

## Chamadas HTTP no Workflow

### Odoo (lym_pos API)
| Metodo | Endpoint | Quando |
|--------|----------|--------|
| POST | /lym-auth/auth/token | inicio (auth JWT) |
| GET | /customers/search?phone={tel} | pre-flow (busca cliente) |
| GET | /customers/{id} | pre-flow (enderecos entrega) |
| GET | /companies/{id}/pos | pre-flow (loja aberta?) |
| GET | /companies/{id}/products | pre-flow (catalogo) |
| GET | /orders?status=pending,draft | pre-flow (pedido aberto?) |
| GET | /orders/{id} | pedido_ativo (status) |
| POST | /orders/quote | pos-flow (validar totais) |
| POST | /orders | pos-flow (criar pedido) |

Base URL: `config.odoo_base_url + /lym/pos/pointofsales`
Headers: `Authorization: Bearer {jwt}`, `X-Odoo-Database: {config.odoo_database}`

### Supabase
| Metodo | Endpoint | Quando |
|--------|----------|--------|
| POST | processed_messages_restaurante | dedup (insert message.id) |
| GET | conversations_restaurante?store_phone_id=eq.X&customer_phone=eq.Y | pre-flow (sessao) |
| POST | conversations_restaurante (upsert) | pre/pos-flow (salvar estado) |

Headers: `apikey: {config.supabase_key}`, `Authorization: Bearer {config.supabase_key}`
Upsert: `?on_conflict=store_phone_id,customer_phone` + `Prefer: resolution=merge-duplicates`

### Meta (WhatsApp Business API)
| Metodo | Endpoint | Quando |
|--------|----------|--------|
| POST | /{phone_number_id}/messages | enviar Flow, confirmacao, status, erros |

Headers: `Authorization: Bearer {config.wa_token}`

## Onboarding de Novo Cliente

```
1. Duplicar workflow no n8n
2. No no "Config" (Set), preencher:
   - display_name, phone_number_id, wa_token, flow_id
   - odoo_base_url, odoo_database, odoo_api_key, odoo_api_secret
   - company_id, pos_config_id
   - supabase_url, supabase_key
   - mensagens personalizadas (opcional)
3. Alterar Webhook path: /webhook/restaurante_{nome_cliente}
4. Renomear workflow: "Restaurante - {Nome Cliente}"
5. Ativar workflow
```

## Dependencias

- **WhatsApp Flow JSON**: precisa ser refeito para aceitar dados via initial_data (100% dinamico)
- **Workflow n8n**: criar do zero (workflow unico com tudo dentro)
- **Supabase**: conversations_restaurante + processed_messages_restaurante (sem mudancas)
- **Odoo**: API lym_pos ja pronta (endpoints listados acima)
- **Meta**: Flow precisa ser registrado na WABA do cliente (flow_id na Config)
