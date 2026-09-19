# Observabilidade orientada a negócio — FIAP OTEL Bank

Como olhar as seis funcionalidades de negócio do banco usando o que o
Splunk Observability Cloud **já oferece pronto**, sem construir nada do zero.

---

## O fato que torna isso simples

O serviço `dashboard` é um **BFF** (Backend for Frontend): toda funcionalidade
de negócio entra por **exatamente um endpoint dele**, que por sua vez chama um
único serviço de domínio.

```
navegador  →  dashboard (BFF)  →  serviço de domínio  →  MongoDB
  (RUM)         1 rota = 1                (APM)
             função de negócio
```

Isso dá uma relação **1:1 entre rota e função de negócio**. É a condição que
torna as *Business Workflows* do APM utilizáveis sem tocar em código: cada
regra vira uma funcionalidade, com nome de negócio em vez de nome técnico.

---

## Mapa das seis funcionalidades

| Funcionalidade de negócio | Tela (RUM) | Entrada no BFF `dashboard` (APM) | Serviço de domínio | Rota do domínio |
|---|---|---|---|---|
| **AUTENTICAÇÃO** | `/login` | `POST /api/users/auth` | `customer-auth` | `POST /api/users/auth` |
| *(cadastro de cliente)* | `/register` | `POST /api/users` | `customer-auth` | `POST /api/users` |
| **ABRIR CONTAS** | `/new-account` | `POST /account/create` | `accounts` | `POST /create-account` |
| *(consultar contas)* | `/acc-info` | `POST /account/allaccounts` | `accounts` | `POST /get-all-accounts` |
| **TRANSFERIR ENTRE CONTAS** | `/transfer` | `POST /transaction/` | `transactions` | `POST /transfer` |
| *(transferência Zelle)* | `/transfer` | `POST /transaction/zelle/` | `transactions` | `POST /zelle` |
| **EXTRATO DA CONTA** | `/transactions` | `POST /transaction/history` | `transactions` | `POST /transaction-history` |
| **SOLICITAR EMPRÉSTIMO** | `/new-loan` | `POST /loan/` | `loan` | `POST /loan/request` |
| *(histórico de empréstimos)* | `/loan` | `POST /loan/history` | `loan` | `POST /loan/history` |
| **LOCALIZAR CAIXAS ELETRÔNICOS** | `/find-atm` | `POST /api/atm/` | `atm-locator` | `POST /api/atm` |

---

## Onde isso aparece nos dashboards que você já tem

### 1. APM → Business Workflows — *o mais próximo do negócio*

Este é o recurso feito exatamente para isto. Ele agrupa traços inteiros sob um
nome que **você** escolhe, e produz taxa de erro, latência e volume por nome.

**Como criar** — `Settings > APM Configuration > Business Workflow Rules`,
uma regra por funcionalidade:

| Nome da workflow | Condição (span do serviço `dashboard`) |
|---|---|
| `Autenticação` | `service = dashboard` e `operation = POST /api/users/auth` |
| `Abertura de conta` | `service = dashboard` e `operation = POST /account/create` |
| `Transferência entre contas` | `service = dashboard` e `operation = POST /transaction/` |
| `Extrato da conta` | `service = dashboard` e `operation = POST /transaction/history` |
| `Solicitação de empréstimo` | `service = dashboard` e `operation = POST /loan/` |
| `Localizar caixa eletrônico` | `service = dashboard` e `operation = POST /api/atm/` |

Ancore no `dashboard`, não no serviço de domínio: com o RUM ligado a raiz do
traço é o navegador, e prender a regra ao BFF mantém o nome estável.

**Onde ver depois de criadas:**
- `APM > Business Workflows` — lista com RED por funcionalidade.
- Dashboard pronto **`APM business transactions`** (grupo *Built-in*, que já
  aparece na sua tela de Dashboards) — é a visão de negócio já montada.

### 2. RUM → `Browser page health` — *a saúde vista pelo cliente*

Você já tem dados aqui (a aplicação `bank-ui` já aparece no RUM). Filtrando por
URL, cada tela da tabela acima vira uma linha de negócio: quanto tempo o cliente
esperou para abrir a conta, quantos erros de JavaScript quebraram a transferência.

Dashboards prontos, no grupo *Built-in* → **RUM applications**:
- **`Browser app health`** — visão geral da aplicação.
- **`Browser page health`** — por página, que é o nível da funcionalidade.

Já há sinal real para explorar: os erros `TypeError: can't access property
"email", userInfo is null` que aparecem no seu RUM são falha de negócio na
**AUTENTICAÇÃO** — sessão sem usuário carregado.

### 3. APM → Tag Spotlight — *por que a funcionalidade piorou*

Escolhida uma workflow, o Tag Spotlight quebra o mesmo indicador por qualquer
tag (`http.status_code`, `deployment.environment`, `container.name`). Responde
"a abertura de conta piorou para quem?" sem sair da visão de negócio.

### 4. Detectores — *quando avisar*

`Alerts > Detectors`, um por funcionalidade crítica, sobre a métrica da
workflow. Sugestão para a aula: erro > 5% em 5 min para *Autenticação* e
*Transferência*; latência p90 acima de 2s para *Abertura de conta*.

---

## SignalFlow para um dashboard "Saúde do Negócio"

Depois de criar as workflows, estas consultas montam um painel só de negócio.

**Volume por funcionalidade** (quantas operações de negócio por minuto):

```
A = data('workflows.count', filter=filter('sf_workflow', '*'))
    .sum(by=['sf_workflow']).publish(label='Operações/min')
```

**Taxa de sucesso por funcionalidade** — o indicador mais próximo do negócio:

```
ERRO = data('workflows.errors', filter=filter('sf_workflow', '*')).sum(by=['sf_workflow'])
TUDO = data('workflows.count',  filter=filter('sf_workflow', '*')).sum(by=['sf_workflow'])
SUCESSO = ((TUDO - ERRO) / TUDO * 100).publish(label='% sucesso')
```

**Tempo de espera do cliente (p90)**:

```
A = data('workflows.duration.ns.p90', filter=filter('sf_workflow', '*'))
    .mean(by=['sf_workflow']).scale(0.000001).publish(label='p90 (ms)')
```

**Experiência no navegador, por tela de negócio**:

```
A = data('rum.page_view.count', filter=filter('sf_operation', '*'))
    .sum(by=['sf_operation']).publish(label='Page views')
```

---

## O que este mapeamento NÃO entrega — e o que fazer

Seja explícito com a turma sobre o limite, porque ele é o ponto didático mais
interessante:

Tudo acima mede se a funcionalidade **respondeu**, não se ela **deu certo para
o negócio**. Um `POST /transaction/` que retorna HTTP 200 dizendo "saldo
insuficiente" conta como sucesso técnico e é uma transferência que não
aconteceu. As perguntas que um gerente faria continuam sem resposta:

- Quanto foi transferido em reais na última hora?
- Qual o percentual de empréstimos aprovados vs. recusados?
- Quantas contas foram abertas hoje?

Nenhuma dessas sai da instrumentação automática, porque ela não conhece o
domínio. Três caminhos, do mais barato ao mais correto:

1. **Métricas derivadas de log** — os serviços já logam as operações, e os
   logs já estão indexados. Sem tocar em código.
2. **Atributos de span** (`span.set_attribute("valor.transferido", v)`) — uma
   linha por endpoint, e o valor vira dimensão pesquisável no Tag Spotlight.
3. **Métricas de negócio explícitas** via OTel Metrics — o correto para
   produção, e o mais invasivo.

A conversa "por que a instrumentação automática não sabe quanto dinheiro foi
transferido" costuma ensinar mais sobre observabilidade do que qualquer
dashboard pronto.
