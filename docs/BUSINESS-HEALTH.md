# Observabilidade orientada a negócio — FIAP OTEL Bank

Como olhar as seis funcionalidades de negócio do banco usando o que o
Splunk Observability Cloud **já oferece pronto**, sem construir nada do zero.

---

## A topologia real — e ela não é uniforme

Há **dois caminhos** no FIAP OTEL Bank, e confundi-los faz a regra do APM
capturar zero tráfego.

**Quatro jornadas passam pelo BFF.** O serviço `dashboard` (porta 5000) recebe
a chamada e repassa ao serviço de domínio:

```
navegador  →  dashboard (BFF)  →  accounts | transactions | loan  →  MongoDB
```

**Duas jornadas não passam.** O navegador chama os serviços Node
**diretamente**, e o `dashboard` não participa:

```
navegador  →  customer-auth (:8000)  →  MongoDB
navegador  →  atm-locator   (:8001)  →  MongoDB
```

Isso está em `ui/src/slices/apiUrls.js`: `VITE_USERS_URL` aponta para `:8000` e
`VITE_ATM_URL` para `:8001`, enquanto contas, transferências e empréstimos vão
para `:5000`. É por isso que, no Service Map, `customer-auth` e `atm-locator`
aparecem como ilhas, sem aresta vindo do `dashboard`.

**Não é defeito de configuração, e não vale "consertar".** O `dashboard` até
tem rotas de proxy para `/api/users/auth` e `/api/atm/`, mas elas devolvem
apenas o JSON: **descartam o `Set-Cookie`**. Como o `customer-auth` entrega o
JWT num cookie httpOnly, rotear o login pelo BFF quebraria a autenticação.
Uniformizar exigiria repassar cabeçalhos no `dashboard.py` — mudança de código
que o lab não precisa.

O que muda, na prática: a **âncora da regra** é o serviço que de fato recebe a
chamada do navegador. Em cada caso continua havendo relação 1:1 entre rota e
função de negócio, que é a condição para usar as *Business Transactions* sem
tocar em código.

---

## Mapa das seis funcionalidades

| Funcionalidade de negócio | Tela (RUM) | Quem o navegador chama | Serviço que responde | Rota |
|---|---|---|---|---|
| **AUTENTICAÇÃO** | `/login` | `customer-auth:8000` | `customer-auth` | `POST /api/users/auth` |
| *(cadastro de cliente)* | `/register` | `customer-auth:8000` | `customer-auth` | `POST /api/users` |
| **ABRIR CONTAS** | `/new-account` | `dashboard:5000` `POST /account/create` | `accounts` | `POST /create-account` |
| *(consultar contas)* | `/acc-info` | `dashboard:5000` `POST /account/allaccounts` | `accounts` | `POST /get-all-accounts` |
| **TRANSFERIR ENTRE CONTAS** | `/transfer` | `dashboard:5000` `POST /transaction/` | `transactions` | `POST /transfer` |
| *(transferência Zelle)* | `/transfer` | `dashboard:5000` `POST /transaction/zelle/` | `transactions` | `POST /zelle` |
| **EXTRATO DA CONTA** | `/transactions` | `dashboard:5000` `POST /transaction/history` | `transactions` | `POST /transaction-history` |
| **SOLICITAR EMPRÉSTIMO** | `/new-loan` | `dashboard:5000` `POST /loan/` | `loan` | `POST /loan/request` |
| *(histórico de empréstimos)* | `/loan` | `dashboard:5000` `POST /loan/history` | `loan` | `POST /loan/history` |
| **LOCALIZAR CAIXAS ELETRÔNICOS** | `/find-atm` | `atm-locator:8001` | `atm-locator` | `POST /api/atm` |

---

## Onde isso aparece nos dashboards que você já tem

### 1. APM → Business Transactions — *o mais próximo do negócio*

Este é o recurso feito exatamente para isto. Ele agrupa traços inteiros sob um
nome que **você** escolhe, e produz taxa de erro, latência e volume por nome.

**Como criar** — `Settings > APM Configuration > Business transaction rule`,
uma regra por funcionalidade:

Em todas: **Rule type** `Service`, **Environments** `lab-fiap`. O **Service**
muda conforme o caminho — é o detalhe que decide se a regra captura algo.

| Business transaction name | Service | Endpoints | Valor |
|---|---|---|---|
| `Autenticação` | **`customer-auth`** | That contain | `/api/users/auth` |
| `Abertura de conta` | `dashboard` | That contain | `/account/create` |
| `Transferência entre contas` | `dashboard` | **Specific endpoints** | `POST /transaction/` |
| `Extrato da conta` | `dashboard` | That contain | `/transaction/history` |
| `Solicitação de empréstimo` | `dashboard` | **Specific endpoints** | `POST /loan/` |
| `Localizar caixa eletrônico` | **`atm-locator`** | **Specific endpoints** | `POST /api/atm/` |

Ancorar as duas primeiras em `dashboard` produz uma Business Transaction que
existe, aparece na lista e **nunca registra um traço** — o tipo de erro que só
se descobre quando alguém repara que o gráfico está vazio.

**Por que três delas não podem usar *That contain*.** A opção casa por
substring, e no BFF há rotas que são prefixo de outras do mesmo serviço:

- `/transaction/` também casaria com `/transaction/history` e
  `/transaction/zelle/` — três jornadas distintas sob um nome só;
- `/loan/` também casaria com `/loan/history`, que é consulta, não solicitação;
- `/api/atm/` também casaria com o `GET` de um caixa específico.

O erro é silencioso: a workflow aparece, com números — só que errados, porque
misturam jornadas. Vale como exemplo em aula de indicador que parece saudável
e não mede o que diz medir.

Nas quatro que passam pelo BFF, ancore no `dashboard` e não no serviço de
domínio: com o RUM ligado a raiz do traço é o navegador, e prender a regra ao
ponto de entrada mantém o nome estável.

**Onde ver depois de criadas:**
- `APM > Business Workflows` — lista com RED por funcionalidade (o menu
  ainda usa o nome antigo; a regra que a alimenta chama-se transaction).
- Dashboard pronto **`APM business transactions`** (grupo *Built-in*, que já
  aparece na sua tela de Dashboards) — é a visão de negócio já montada.

### 1b. A regra Default já não basta? — análise

O APM vem com uma regra **Default** ligada, que nomeia cada transação pelo
*endpoint que iniciou o traço*. Sem configurar nada, o lab já produz nove
transações:

```
atm-locator:GET /api      customer-auth:GET         dashboard:GET /account
atm-locator:POST /api     customer-auth:POST /api   dashboard:POST /account
                          customer-auth:PUT /api    dashboard:POST /loan
                                                    dashboard:POST /transaction
```

É tentador parar por aqui. Duas coisas impedem.

#### O corte por 1 segmento funde jornadas diferentes

Com `Use the first 1 URI segments`, tudo que começa igual vira o mesmo nome:

| Transação Default | O que ela está somando |
|---|---|
| `dashboard:POST /transaction` | `/transaction/` (**transferir**), `/transaction/history` (**extrato**), `/transaction/zelle/`, `/transaction/transaction-with-id` |
| `dashboard:POST /account` | `/account/create` (**abrir conta**), `/account/allaccounts`, `/account/detail` |
| `dashboard:POST /loan` | `/loan/` (**solicitar**), `/loan/history` (consultar) |
| `customer-auth:POST /api` | `/api/users` (**cadastrar**), `/api/users/auth` (**login**), `/api/users/logout` |

Isso não é detalhe. **Transferir** e **Extrato** são duas jornadas com SLOs
deliberadamente diferentes — 99,9 % e 1,5 s contra 99,5 % e 1 s. Somadas num
indicador só, nenhuma das duas é mensurável: a latência da consulta dilui a
da transferência, e um erro na movimentação some na média das quatro rotas.

**E isso tem conserto sem criar regra nenhuma.** Mudando a Default para
`the first 3 URI segments`, cada rota real vira uma transação distinta —
`/api/users/auth` separa de `/api/users`, `/transaction/history` separa de
`/transaction/`, e as rotas do BFF (no máximo 2 segmentos) não são afetadas.
Vale fazer: é um clique e melhora o padrão para todo mundo.

#### O que continua faltando: o nome

Mesmo com a granularidade certa, `dashboard:POST /transaction/history` é o
nome de uma rota, não de uma função de negócio. Quem lê um painel chamado
**Extrato da conta** não precisa saber o que é um BFF.

Daí a divisão de trabalho que faz sentido:

| | Regra Default | Regra explícita |
|---|---|---|
| Custo | zero | uma por jornada |
| Cobertura | todo o tráfego, inclusive o que ninguém previu | só o que você declarou |
| Nome | técnico | de negócio |
| Serve para | **descobrir** o que existe | **comprometer-se** com um SLO |

Ou seja: deixe a Default ligada em 3 segmentos como rede de segurança e mapa
do tráfego real, e escreva regra explícita só para as jornadas que vão ter
SLO e alerta — que no exercício é uma por grupo.

#### "Por que separa GET de POST se é a mesma jornada?"

A pergunta é boa, e a resposta é que **o Splunk está certo — e é justamente
por não saber nada do seu negócio.**

Em HTTP, um endpoint é o par *(método, caminho)*. `GET /account` e
`POST /account` são operações diferentes por definição, e com frequência são
jornadas diferentes de verdade: consultar contas não é abrir uma conta. Uma
ferramenta que fundisse as duas estaria tomando uma decisão de domínio que
não tem como sustentar — e erraria nesses casos.

O que ela não tem como saber é o inverso: que `POST /api/users/auth` seguido
de `GET /api/users/profile` é **uma** jornada chamada "entrar na conta", do
ponto de vista de quem usa o banco. Essa junção exige conhecer o domínio.

A conclusão vale para a aula inteira: a regra Default entrega o **agrupamento
técnico correto**; a distância entre ele e o negócio não é um defeito da
ferramenta, é exatamente o trabalho que sobra para as pessoas. Nomear jornada,
escolher granularidade e decidir o que conta como sucesso são decisões de
negócio — e é por isso que observabilidade orientada a negócio não sai de
instrumentação automática.

#### A terceira via: `workflow.name`

Acima da Default há uma regra de prioridade 1 já ligada: **Global Tag
`workflow.name`**. Se um span carregar essa tag, o valor dela vira o nome da
transação. É o caminho por código — uma linha na aplicação
(`span.set_attribute("workflow.name", "Transferência entre contas")`) e o nome
de negócio nasce junto do traço, sem regra nenhuma no console.

Não usamos no lab porque a proposta é não tocar no código da aplicação. Mas é
o mais robusto dos três: o nome acompanha a jornada mesmo que a rota mude.

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
