# Arquitetura: WhatsApp Flow Restaurante (Dinamico)

## Visao Geral

O WhatsApp Flow substitui o catalogo nativo do WhatsApp e assume toda a jornada do pedido:
cardapio, carrinho, entrega e pagamento. O n8n orquestra apenas 3 momentos (pre-flow,
flow-response, pos-flow). O Odoo e o backend de dados.

```
 Cliente                n8n                    Odoo              WhatsApp Flow
   |                     |                      |                     |
   |-- msg "oi" -------->|                      |                     |
   |                     |-- client.get ------->|                     |
   |                     |-- is_open_now ------>|                     |
   |                     |-- catalog.get_items ->|                     |
   |                     |                      |                     |
   |<-- Flow msg --------|                      |                     |
   |                     |                      |                     |
   |-- abre Flow --------|------------------------------------->|
   |   (cardapio,        |                      |              |
   |    carrinho,        |                      |              |
   |    entrega,         |                      |              |
   |    pagamento)       |                      |              |
   |<-- action=complete -|------------------------------------->|
   |                     |                      |                     |
   |                     |-- order.quote ------>|                     |
   |                     |-- order.create ----->|                     |
   |                     |-- client.save ------>|  (Supabase)         |
   |<-- confirmacao -----|                      |                     |
```

## Principio Central

**O Flow e 100% dinamico.** Nao ha itens, categorias, enderecos ou metodos de pagamento
hardcoded no JSON do Flow. Tudo vem via `initial_data` injetado pelo n8n no momento do envio,
com dados vindos do Odoo (catalog.get_items, customer.get_detail).

## 3 Momentos do n8n

### 1. PRE-FLOW (conversa)
Recebe mensagem do cliente, identifica quem e, verifica estado.

```
Webhook -> ACK 200 -> Filter & Dedup -> Resolve Tenant
  -> client.get (Odoo + Supabase)
  -> Roteador Principal (switch por etapa)
```

Roteador:
- `etapa=''` (livre) -> verifica loja aberta -> busca catalogo -> envia Flow
- `etapa='aguardando_flow'` -> msg "toque no botao" + opcao reenviar
- `etapa='pedido_ativo'` -> busca status do pedido -> mostra + botoes

### 2. FLOW (WhatsApp Flow - fora do n8n)
5 telas client-side, dados injetados via initial_data:

| Tela | Conteudo | Dados dinamicos |
|------|----------|-----------------|
| CARDAPIO | Categorias + itens + precos | catalog.get_items |
| CARRINHO | Revisao, qtd, obs, subtotal | calculado client-side |
| ENTREGA | Endereco salvo ou novo | delivery_addresses[] |
| PAGAMENTO | PIX / Cartao / Dinheiro | metodos_pagamento do tenant |
| RESUMO | Consolidado + Finalizar | tudo acima |

O Flow retorna `action=complete` com payload completo:
```json
{
  "itens": [{"id": 1, "qtd": 2, "preco": 22.50, "obs": "sem cebola"}],
  "endereco": {"id": 5} ou {"novo": {"rua": "...", "bairro": "...", "cep": "..."}},
  "pagamento": {"metodo": "pix", "troco": null},
  "subtotal": 54.00,
  "taxa_entrega": 7.00,
  "total": 61.00
}
```

### 3. POS-FLOW (conversa)
Recebe o payload do Flow, valida, cria pedido no Odoo, confirma pro cliente.

```
Webhook (nfm_reply) -> Parse response_json
  -> Validar flow_token (anti-replay)
  -> Validar itens vs Odoo (precos, disponibilidade)
  -> order.quote (confirmar totais server-side)
  -> order.create (persistir pedido)
  -> client.save (etapa='pedido_ativo')
  -> Enviar confirmacao ao cliente
  -> (se PIX) Enviar QR code / chave
```

## Estados da Sessao

Apenas 3 estados possiveis:

| etapa | contexto | significado |
|-------|----------|-------------|
| `''` | `{}` | livre - qualquer msg inicia jornada |
| `aguardando_flow` | `{flow_token, sent_at}` | Flow enviado, esperando resposta |
| `pedido_ativo` | `{order_id, order_name}` | pedido criado, esperando conclusao |

## Fluxo Detalhado: Interacao Cliente x Sistema

### Entrada (qualquer mensagem)

```
CLIENTE                                  SISTEMA
  |                                        |
  |-- "oi" ------------------------------>|
  |                                        |-- ACK 200
  |                                        |-- Filter (so message + interactive)
  |                                        |-- Dedup (message.id)
  |                                        |-- Resolve Tenant (phone_number_id)
  |                                        |-- client.get (Odoo + Supabase)
  |                                        |   -> partner_id, nome, enderecos[],
  |                                        |      conversation {etapa, contexto}
  |                                        |
  |                                        |-- ROTEADOR (switch etapa)
```

### Ramo A: Pedido Ativo (etapa='pedido_ativo')

```
CLIENTE                                  SISTEMA
  |                                        |
  |                                        |-- order.get_detail(order_id)
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
  |                                        |-- order.cancel (Odoo)  [FUTURO]
  |                                        |-- client.save(etapa='')
  |<-- "Pedido cancelado."  --------------|
  |    [Ver cardapio] [Ate mais]           |
```

### Ramo B: Sem Pedido -> Abrir Flow (etapa='')

```
CLIENTE                                  SISTEMA
  |                                        |
  |                                        |-- catalog.is_open_now (Odoo)
  |                                        |
  |                                        |-- FECHADO?
  |<-- "Estamos fechados. Horario: ..." ---|   [FIM - nao salva sessao]
  |                                        |
  |                                        |-- ABERTO
  |                                        |-- catalog.get_items (Odoo)
  |                                        |   -> categorias, itens, precos
  |                                        |
  |                                        |-- Monta initial_data:
  |                                        |   { categorias, itens, precos,
  |                                        |     enderecos_salvos,
  |                                        |     nome_cliente,
  |                                        |     metodos_pagamento }
  |                                        |
  |                                        |-- Envia Flow Message (API Meta)
  |                                        |   flow_id, flow_token, initial_data
  |                                        |
  |<-- "Ola Joao! Toque abaixo para    ---|
  |     montar seu pedido"                 |
  |    [Abrir Cardapio]                    |
  |                                        |
  |                                        |-- client.save
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
  |                                        |   INVALIDO? -> msg erro + reenviar
  |                                        |
  |                                        |-- Validar itens (ids, precos)
  |                                        |   FALHA? -> msg + reenviar Flow
  |                                        |
  |                                        |-- order.quote (Odoo)
  |                                        |   confirma totais server-side
  |                                        |   DIVERGENCIA? -> msg + reenviar
  |                                        |
  |                                        |-- order.create (Odoo)
  |                                        |   partner_id, items, delivery_address,
  |                                        |   payment_method, notes
  |                                        |   FALHA? -> retry 1x -> msg suporte
  |                                        |
  |                                        |-- client.save (Supabase)
  |                                        |   etapa='pedido_ativo'
  |                                        |   contexto={order_id, order_name}
  |                                        |
  |<-- "Pedido #847 confirmado!         ---|
  |     2x X-Burguer R$45 ...             |
  |     Total: R$61  - PIX               |
  |     Previsao: 30-40 min"              |
  |                                        |
  |                                        |-- (se PIX) Envia QR/chave
  |<-- "Pague via PIX: chave XX..."  -----|
```

## Tratamento de Erros

| Situacao | Resposta ao cliente | Acao sistema |
|----------|---------------------|--------------|
| Loja fechada | Horario de funcionamento | Nao salva sessao |
| Flow timeout (nao abre) | Msg lembrete + reenviar | Mantém etapa |
| Flow token invalido | "Tente novamente" | Log erro, reenviar Flow |
| Item indisponivel pos-flow | "Itens mudaram, reabra" | Reenviar Flow |
| order.quote diverge | "Precos atualizaram" | Reenviar Flow |
| order.create falha | "Tentando novamente..." | 1 retry, depois suporte |
| Msg invalida durante espera | Status do pedido atual | Mostra botoes |
| Midia (imagem/audio/video) | "So processamos texto" | Ignora |

## Escape (qualquer momento)

Keywords: "sair", "cancelar", "0"

| etapa atual | acao |
|-------------|------|
| `''` | msg despedida |
| `aguardando_flow` | cancela, client.save(etapa=''), msg "quando quiser, mande oi" |
| `pedido_ativo` | pergunta "cancelar pedido #X?" [Sim] [Nao] |

## Dados Dinamicos do Flow (initial_data)

Payload injetado no envio do Flow Message:

```json
{
  "categorias": [
    {"id": "hamburgueres", "label": "Hamburgueres", "icon": "emoji_burger"},
    {"id": "pizzas", "label": "Pizzas", "icon": "emoji_pizza"},
    {"id": "bebidas", "label": "Bebidas", "icon": "emoji_drink"}
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

## Nos n8n (visao macro)

```
Webhook
  -> ACK 200
  -> Filter (so message + interactive)
  -> Dedup (message.id)
  -> Resolve Tenant
  -> client.get (Odoo + Supabase)
  -> E nfm_reply (flow response)? -----> RAMO FLOW-RESPONSE
  |    Parse payload -> Validar -> Quote -> Create -> Confirmar
  |
  -> E escape keyword? ----------------> RAMO ESCAPE
  |    Trata por etapa
  |
  -> E mensagem normal? ---------------> RAMO CONVERSA
       Switch(etapa):
         '' -> is_open? -> catalog.get_items -> Enviar Flow
         'aguardando_flow' -> "toque no botao" + reenviar?
         'pedido_ativo' -> order.get_detail -> status + botoes
```

## Operations data.api.call Utilizadas

| Operation | Momento | Descricao |
|-----------|---------|-----------|
| `client.get` | pre-flow | Busca cliente + conversa |
| `client.save` | pre/pos-flow | Salva estado da sessao |
| `catalog.is_open_now` | pre-flow | Verifica se loja aceita pedidos |
| `catalog.get_items` | pre-flow | Busca categorias + itens + precos |
| `order.quote` | pos-flow | Valida totais server-side |
| `order.create` | pos-flow | Cria pedido no Odoo |
| `order.get_detail` | pedido_ativo | Status do pedido |
| `order.get_history` | pre-flow | Verifica pedido em aberto |
| `customer.get_detail` | pre-flow | Enderecos de entrega salvos |

## Dependencias

- **WhatsApp Flow JSON**: precisa ser refeito para aceitar dados via initial_data (100% dinamico)
- **n8n template**: precisa ser adaptado (remover etapas de catalogo msg-a-msg, adicionar envio de Flow)
- **data.api.call**: ja tem todas as operations necessarias (10 total)
- **Supabase**: conversations_restaurante + processed_messages_restaurante (sem mudancas)
