# Guia do Projeto - Bot WhatsApp Pizzaria (n8n)

## Arquivos do Projeto
| Arquivo | O que e |
|---------|---------|
| `fluxon8n-wpp.json` | Workflow principal do n8n (logica do bot) |
| `data.api.call (1).json` | Workflow auxiliar (leitura/escrita de dados) |
| `sync-sheets.sh` | Script para baixar planilhas atualizadas |
| `sheets-data/` | Pasta com CSVs das planilhas (gerada pelo script) |

## Comandos Uteis

### Atualizar dados das planilhas
```bash
bash sync-sheets.sh
```
Baixa todas as abas do Google Sheets como CSV para `./sheets-data/`. Rode antes de pedir ajustes ao Claude para garantir que ele tem os dados atualizados.

## Planilha Google Sheets
- **Link:** https://docs.google.com/spreadsheets/d/1FrLFvKhZQpyniQa4qMKfsgLJyrKXMDjpBPK8xw_JVn8/edit?usp=sharing
- **Nome:** N8N_Pizzaria

### Abas
| Aba | Funcao |
|-----|--------|
| `tenants_config` | Configuracao do tenant (pizza_a) |
| `Clients` | Clientes, estado do bot, contexto JSON |
| `pizza_sizes` | Tamanhos: P(35), M(45), G(59), F(75) |
| `pizza_flavors` | Sabores (5): Marguerita, Calabresa, Portuguesa, 4 Queijos, Frango c/ Catupiry |
| `pizza_borders` | Bordas (5): Sem borda, Catupiry, Cheddar, Cream Cheese, Chocolate |
| `Order List` | Pedidos realizados |
| `horario_funcionamento` | Horarios de abertura por dia da semana |
| `Worksheet` | Catalogo de produtos que a Meta puxa para o WhatsApp |

## Fluxo Resumido do Bot
1. Cliente envia msg no WhatsApp -> webhook recebe
2. Verifica se esta aberto (horario_funcionamento)
3. Exibe catalogo do WhatsApp (Worksheet)
4. Cliente escolhe pizzas pelo catalogo
5. Bot pergunta: borda -> sabor 1 -> sabor 2 (se meio a meio) -> confirma pizza
6. Repete para cada pizza do pedido
7. Pergunta talheres -> endereco (se nao tem) -> resumo -> pagamento
8. Finaliza pedido (salva na Order List)

## Importacao no n8n
- O JSON exportado pelo Claude sempre mantem o node `Whatsapp Bot Webhook1` intacto
- Basta importar e tudo ja aponta para o webhook correto
