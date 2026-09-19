# Exercício final — transforme uma jornada em SLIs e SLOs

Atividade prática sobre o FIAP OTEL Bank instrumentado com OpenTelemetry.
Duração sugerida: **60 a 75 minutos**. Grupos de 3 a 5 alunos.

> "Se não sabemos exatamente qual jornada estamos protegendo e quais
> dependências a sustentam, como podemos definir o que significa
> confiabilidade?"

---

## Antes da aula — preparo do ambiente (instrutor)

O Service Map só é útil com tráfego. Gere carga **antes** de distribuir os grupos:

```bash
bash ~/splunk/carga-locust.sh --usuarios 10 --tempo 15m
```

Confirme em `APM > Service Map` que os 8 serviços aparecem com números.
Sem isso, os alunos desenham uma arquitetura em vez de observá-la.

---

## Distribuição — uma jornada por grupo

| Grupo | Jornada de negócio | Tela | Entrada no BFF |
|---|---|---|---|
| 1 | **Autenticação** | `/login` | `POST /api/users/auth` |
| 2 | **Abrir conta** | `/new-account` | `POST /account/create` |
| 3 | **Transferir entre contas** | `/transfer` | `POST /transaction/` |
| 4 | **Extrato da conta** | `/transactions` | `POST /transaction/history` |
| 5 | **Solicitar empréstimo** | `/new-loan` | `POST /loan/` |
| 6 | **Localizar caixas eletrônicos** | `/find-atm` | `POST /api/atm/` |

Mapeamento completo em [BUSINESS-HEALTH.md](BUSINESS-HEALTH.md).

---

## Passo 1 — Viva a jornada como cliente (10 min)

**Antes de abrir qualquer dashboard**, execute a jornada no navegador.

1. Acesse o FIAP OTEL Bank e faça a jornada do grupo de ponta a ponta.
2. Anote: o que você esperava que acontecesse? O que indicou que deu certo?
3. Faça de novo, **de propósito errado** (senha errada, valor maior que o
   saldo, campo vazio). Anote o que o sistema respondeu.

> **Responde às perguntas 1 e 2 do enunciado.**
> A ordem importa: quem começa pelo dashboard descreve a tecnologia; quem
> começa pela tela descreve o negócio.

## Passo 2 — Encontre a jornada no Service Map (10 min)

`APM > Service Map`, filtro `Environment: lab-fiap`, janela `-15m`.

1. Localize os serviços que a sua jornada atravessa.
2. Desenhe a cadeia, com a latência que o mapa mostra em cada nó.
3. Abra um traço real em `APM > Traces` e confira se bate com o desenho.

**Pergunta-chave:** algum nó aparece com **borda tracejada**? Descubra o que
isso significa — e o que você *não* consegue ver nele.

## Passo 3 — Os dois pontos de falha (10 min)

Gere carga antes de abrir o APM — sem tráfego o Service Map vem vazio e o
grupo acaba desenhando a arquitetura em vez de observá-la:

```bash
bash ~/splunk/carga-locust.sh --cenario <auth|account|transaction|loan|atm> --usuarios 10 --continuo
```

Os **quatro Golden Signals** (latência, tráfego, erros, saturação) respondem à
coluna "como eu detectaria". Dois limites que valem a discussão: saturação não
vira SLI de confiabilidade, é indicador de capacidade; e nenhum dos quatro
detecta uma jornada que falhou sem erro nenhum — que é a razão de existir o
SLI de falha relevante.

Escolha então os **dois** pontos cuja falha mais dói para o cliente:

| Ponto de falha | O que o cliente vê | Como eu detectaria hoje |
|---|---|---|

Critério: não é "o que tem mais chance de quebrar", é **"o que, quebrando,
impede o resultado de negócio"**.

## Passo 4 — Defina os três SLIs (15 min)

Um de cada tipo. Escreva como frase mensurável, não como nome de métrica.

| Tipo | Formato esperado |
|---|---|
| **Disponibilidade** | % de tentativas de \<jornada\> que retornam sem erro |
| **Latência** | % de tentativas que completam em menos de \<X\> ms |
| **Falha relevante** | % de tentativas que atingem o resultado de negócio |

O terceiro é o difícil e o mais importante: **falha relevante ≠ erro HTTP.**
Uma transferência recusada por saldo insuficiente devolve HTTP 200.

> **Responde às perguntas 3, 4 e 5.**

## Passo 5 — Proponha os SLOs e justifique (10 min)

Para cada SLI, um alvo e **uma frase de justificativa**. Alvo sem justificativa
não vale — o número tem que vir de uma consequência de negócio.

Use as latências reais do Service Map como piso. Orçamento de erro mensal:

| SLO | Orçamento de erro em 30 dias |
|---|---|
| 99,0 % | 7 h 12 min |
| 99,5 % | 3 h 36 min |
| 99,9 % | 43 min |
| 99,95 % | 21 min |

**Pergunta de controle:** sua equipe aguentaria ser acordada de madrugada para
proteger esse número? Se não, o SLO está apertado demais.

> **Responde à pergunta 6.**

## Passo 6 — Implemente no Splunk (10 min)

1. `Settings > APM Configuration > Business transaction rule` — crie a Business Transaction
   da sua jornada, com **nome de negócio** (ex.: `Transferência entre contas`),
   ancorada em `service = dashboard` e a operação da tabela.
2. `Alerts > Detectors` — crie **um** detector sobre o SLI de disponibilidade,
   no alvo que você definiu.

## Passo 7 — Quebre de propósito (10 min)

O SLO só é real quando você vê o orçamento queimar.

```bash
docker stop fiap-mongodb        # derruba a persistência
```

Rode a jornada no navegador, observe o que acontece no seu SLI e no detector.
Depois:

```bash
docker start fiap-mongodb
```

Discuta: o seu SLI capturou a falha? Em quanto tempo? O que o **cliente** viu
antes de o alerta disparar?

## Passo 8 — Cliente e mercado (5 min)

Feche o entregável com duas frases:

- **Cliente:** quando este SLO é violado, o cliente ______.
- **Mercado:** se isso acontecer repetidamente, o banco ______.

> **Responde à pergunta 7.**

---

## Entregável do grupo

Página para preencher em aula, com cálculo do orçamento de erro e exportação
da entrega em `.xlsx`:

**https://claude.ai/artifact/PnSnibUtNm4ESzXtir3vn4**

O preenchimento fica salvo no navegador do grupo enquanto ele trabalha. A
planilha sai com três abas — entregável, pontos de falha e SLIs. Fonte da
página: [app/index.html](../app/index.html).

Para servir a página do próprio lab, sem depender do claude.ai:

```bash
bash ~/splunk/app/atividade-sli-slo.sh
```

É o mesmo arquivo nos dois casos. A única diferença é o download da
planilha: no artifact quem salva é a capability do claude.ai, e servida
pelo nginx é o download normal do navegador — a página detecta onde está.

### Campos (caso o grupo prefira papel)

| Item | |
|---|---|
| Integrantes do grupo | |
| Jornada e resultado de negócio | |
| 2 pontos de falha do Service Map | |
| SLI de disponibilidade | |
| SLI de latência | |
| SLI de falha relevante | |
| SLOs propostos + justificativa | |
| O SLI capturou a falha do `docker stop`? Em quanto tempo? | |
| O que o cliente viu antes de o alerta disparar | |
| Impacto no cliente | |
| Impacto no mercado | |
| Print da Business Transaction criada | |

---
---

# GABARITO

Para o instrutor. Os alvos de latência partem das medições reais do Service Map
do ambiente de lab (`dashboard 19ms`, `accounts 5ms`, `loan 23ms`,
`transactions 3ms`, `atm-locator 8ms`, `customer-auth 101ms`, `mongodb 3ms`) com
folga para carga de aula.

## O que vale ponto em qualquer jornada

**Obrigatório:**
- O SLI de falha relevante **não** é taxa de erro HTTP. Se o grupo escreveu
  "% de requisições sem erro 5xx" nos três campos, não entendeu o exercício.
- Os dois pontos de falha incluem um que **não é um serviço**:
  o BFF como ponto único de entrada, o MongoDB compartilhado, ou o próprio
  navegador do cliente.
- O SLO de latência é maior que a latência medida — se alguém propôs p90 < 5ms
  para autenticação, não olhou o Service Map.

**Ponto extra:**
- Percebeu que `mongodb:bank` e `mongodb:martianbank` aparecem **tracejados**
  no Service Map: são *Inferred Services*. Não há agente dentro do Mongo; só
  enxergamos o que o chamador reporta. É um ponto cego real — se o banco
  estiver lento por causa de um índice faltando, a jornada vê "lentidão", não
  a causa.
- Notou que **duas bases diferentes** aparecem (`bank` e `martianbank`).
- Propôs um SLI medido no **navegador** (RUM) e não só no servidor. Só o RUM
  responde "o cliente conseguiu?".

**Erro clássico a corrigir em sala:**
Definir SLO de 99,99% "porque banco não pode cair". Peça para calcular o
orçamento: 4 minutos por mês. Pergunte quem vai ficar de plantão.

---

## Jornada 1 — AUTENTICAÇÃO

**Resultado esperado:** o cliente entra na conta e vê o próprio nome e saldo.
**Evento de sucesso:** sessão criada e a tela `/acc-info` renderizada com dados.

**Pontos de falha** (o gabarito lista três; o grupo entrega dois):
1. `customer-auth` indisponível → ninguém entra. Bloqueia **todas** as outras
   jornadas: é o gargalo de maior alcance do sistema.
2. `mongodb:martianbank` (tracejado) → credenciais não conferem.
3. O navegador: o erro `TypeError: can't access property "email", userInfo is
   null`, **já visível no RUM do ambiente**, é login que tecnicamente passou e
   entregou uma tela quebrada.

**SLIs:**
- Disponibilidade: % de tentativas de login que retornam sem erro.
- Latência: % de logins que completam em < **800 ms**.
- Falha relevante: % de sessões em que a tela seguinte renderiza **sem erro de
  JavaScript** (medido no RUM).

**SLOs e justificativa:**
| SLI | Alvo | Justificativa |
|---|---|---|
| Disponibilidade | 99,9 % | Porta de entrada: sem login, nenhuma outra jornada existe. 43 min/mês. |
| Latência p90 | < 800 ms | O serviço mede **101 ms** no mapa, muito acima dos outros — é hashing de senha, que é lento **por projeto**. Apertar aqui empurraria para enfraquecer a criptografia. |
| Falha relevante | 99,5 % | Tela quebrada pós-login é indistinguível de indisponibilidade para o cliente. |

**Cliente:** não consegue usar o banco — nem consultar saldo.
**Mercado:** login instável é a falha mais visível publicamente; vira print em
rede social e abre reclamação em órgão regulador.

> **Discussão dirigida:** por que o único serviço "lento" do mapa é o de
> autenticação? Lentidão nem sempre é defeito — às vezes é segurança.

---

## Jornada 2 — ABRIR CONTA

**Resultado esperado:** conta criada, com número e saldo inicial visíveis.
**Evento de sucesso:** a conta aparece em `/acc-info` com número gerado.

**Pontos de falha:** `accounts` indisponível; `mongodb:bank` (tracejado);
o BFF `dashboard`, por onde a jornada obrigatoriamente passa.

**SLIs:**
- Disponibilidade: % de solicitações de abertura que retornam sem erro.
- Latência: % que completa em < **2 s**.
- Falha relevante: % de solicitações que resultam em **conta efetivamente
  persistida e listável** — não apenas HTTP 200.

**SLOs:**
| SLI | Alvo | Justificativa |
|---|---|---|
| Disponibilidade | 99,5 % | Aquisição de cliente. Falhar aqui é perder receita futura, mas não trava quem já é cliente. 3h36/mês é tolerável. |
| Latência p90 | < 2 s | Formulário de cadastro: acima de 2 s o abandono cresce. O serviço mede 5 ms — há folga enorme. |
| Falha relevante | 99,9 % | Conta "criada" que não existe é o pior defeito possível: o cliente acredita que tem uma conta. |

**Cliente:** desiste e abre conta em outro banco.
**Mercado:** custo de aquisição pago sem conversão; funil de crescimento vaza.

---

## Jornada 3 — TRANSFERIR ENTRE CONTAS *(a mais rica — recomendada para a demo)*

**Resultado esperado:** valor sai de uma conta e entra na outra.
**Evento de sucesso:** **ambos** os saldos atualizados e a transação no extrato.

**Pontos de falha** (o gabarito lista três; o grupo entrega dois):
1. `transactions` indisponível → transferência não ocorre.
2. `mongodb:bank` → **falha parcial**: debita e não credita. O pior caso.
3. `dashboard` (BFF) → timeout deixa o cliente sem saber se enviou. O risco
   real vem daí: ele tenta de novo e duplica.

**SLIs:**
- Disponibilidade: % de transferências que retornam sem erro.
- Latência: % que completa em < **1,5 s**.
- Falha relevante: % de transferências **solicitadas** que resultam em saldos
  consistentes nas duas contas.

**SLOs:**
| SLI | Alvo | Justificativa |
|---|---|---|
| Disponibilidade | 99,9 % | Movimentação de dinheiro é a função central do banco. 43 min/mês. |
| Latência p90 | < 1,5 s | Acima disso o cliente clica de novo, e clique repetido em transferência gera duplicidade. O alvo protege contra um risco de negócio, não contra desconforto. |
| Falha relevante | 99,99 % | Inconsistência de saldo não tem orçamento de erro aceitável: é perda financeira direta e risco regulatório. |

**Cliente:** perde dinheiro ou fica sem saber se perdeu — e isso é pior.
**Mercado:** falha de integridade financeira gera multa do Banco Central,
ressarcimento e dano reputacional duradouro.

> **Discussão dirigida:** por que a disponibilidade pode ser 99,9% mas a falha
> relevante precisa ser 99,99%? Porque *estar fora do ar* é visível e
> recuperável; *dinheiro sumir* não é.

---

## Jornada 4 — EXTRATO DA CONTA

**Resultado esperado:** o cliente vê o histórico correto e completo.
**Evento de sucesso:** lista renderizada com as transações do período.

**Pontos de falha:** `transactions`; `mongodb:bank`; o BFF.

**SLIs:**
- Disponibilidade: % de consultas de extrato sem erro.
- Latência: % que completa em < **1 s**.
- Falha relevante: % de extratos que retornam **a lista completa** — extrato
  vazio por falha é indistinguível de "não há transações".

**SLOs:**
| SLI | Alvo | Justificativa |
|---|---|---|
| Disponibilidade | 99,5 % | Consulta, não movimentação: o cliente tolera tentar de novo. |
| Latência p90 | < 1 s | É a tela mais consultada; lentidão aqui define a percepção de "app lento". |
| Falha relevante | 99,9 % | Extrato incompleto leva a decisão financeira errada e gera contestação indevida. |

**Cliente:** desconfia do saldo e liga para o call center.
**Mercado:** custo de atendimento sobe; confiança nos dados cai.

> **Discussão dirigida:** extrato vazio — é sucesso ou falha? Esta jornada é a
> melhor para mostrar que o SLI precisa da semântica do negócio.

---

## Jornada 5 — SOLICITAR EMPRÉSTIMO

**Resultado esperado:** proposta submetida e decisão comunicada.
**Evento de sucesso:** solicitação registrada e visível em `/loan`.

**Pontos de falha:** `loan` (o serviço **mais lento** depois do auth, 23 ms);
`mongodb:bank`; o BFF.

**SLIs:**
- Disponibilidade: % de solicitações sem erro.
- Latência: % que completa em < **3 s**.
- Falha relevante: % de solicitações que recebem **uma decisão** (aprovada ou
  recusada) — recusa **é** sucesso operacional.

**SLOs:**
| SLI | Alvo | Justificativa |
|---|---|---|
| Disponibilidade | 99,0 % | Menor volume e o cliente retorna. 7h12/mês é aceitável. |
| Latência p90 | < 3 s | Há expectativa natural de análise; o cliente aceita esperar por uma decisão de crédito. |
| Falha relevante | 99,5 % | Solicitação sem decisão deixa o cliente em limbo e trava o funil de crédito. |

**Cliente:** não sabe se pode contar com o dinheiro.
**Mercado:** crédito é a linha de maior margem; solicitação perdida é receita
perdida com lead já qualificado.

> **Discussão dirigida:** recusar um empréstimo é falha? Não. É o melhor
> exemplo de que **resultado de negócio ≠ resultado desejado pelo cliente.**

---

## Jornada 6 — LOCALIZAR CAIXAS ELETRÔNICOS

**Resultado esperado:** o cliente vê caixas próximos e consegue chegar a um.
**Evento de sucesso:** lista com ao menos um caixa e endereço utilizável.

**Pontos de falha:** `atm-locator`; `mongodb:martianbank`; o navegador —
geolocalização negada pelo usuário é falha da jornada **sem nenhum erro no
backend**. Ponto cego clássico, só visível no RUM.

**SLIs:**
- Disponibilidade: % de buscas sem erro.
- Latência: % que completa em < **2 s**.
- Falha relevante: % de buscas que retornam **ao menos um caixa**.

**SLOs:**
| SLI | Alvo | Justificativa |
|---|---|---|
| Disponibilidade | 99,0 % | Função auxiliar; há alternativas (mapa, site). |
| Latência p90 | < 2 s | Uso tipicamente na rua, em rede móvel. |
| Falha relevante | 99,0 % | Lista vazia manda o cliente a lugar nenhum — pior que um erro visível, porque parece resposta válida. |

**Cliente:** fica sem dinheiro físico quando precisa.
**Mercado:** impacto baixo isoladamente, **mas** é a jornada mais usada em
situação de urgência — a lembrança negativa pesa mais que a frequência.

> **Discussão dirigida:** esta é a jornada de menor criticidade. Proposital:
> mostra que **nem toda jornada merece 99,9%**, e que saber priorizar é parte
> do trabalho.

---

## Fechamento — as três ideias que devem sobrar

1. **Confiabilidade se define pela jornada, não pelo serviço.** O mesmo
   `mongodb:bank` sustenta jornadas com alvos diferentes, porque o que está em
   jogo é diferente.
2. **Falha relevante é a métrica que a instrumentação automática não dá.**
   Ela exige conhecer o domínio — é exatamente por isso que SRE não é só
   infraestrutura.
3. **SLO é uma decisão de negócio com consequência operacional.** Cada nove a
   mais custa plantão, arquitetura e dinheiro. Escolher 99,9% em vez de 99,99%
   é uma escolha legítima — desde que consciente.
