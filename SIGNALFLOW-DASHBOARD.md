# Dashboard de containers — SignalFlow

O receiver `docker_stats` é nativo do OpenTelemetry e, por isso, **não acende os
dashboards prontos de Docker** do Splunk (aqueles são construídos sobre os nomes
de métrica do Smart Agent, que está descontinuado). Em compensação, montar os
gráficos leva uns 10 minutos e o resultado não fica preso a um caminho legado.

**Como usar:** Dashboards → novo dashboard → **New chart** → aba **SignalFlow**
(o editor de plot tem um botão "Switch to SignalFlow"/"Show SignalFlow"), cole o
programa e salve.

Os nomes de métrica abaixo são os que o `docker_stats` emite — medidos rodando o
receiver, não de memória. Se algum gráfico vier vazio, confirme o nome exato em
**Metrics → Metric Finder** buscando por `container.`.

Os filtros cobrem os dois prefixos de projeto (`fiapbank-otel-*` é o atual,
`martianbank-otel-*` é o antigo), então funcionam antes e depois do rename.

## Atalho: importar o dashboard pronto

Em vez de montar os oito gráficos na mão, importe
[`dashboard_FIAP_Bank_Containers.json`](dashboard_FIAP_Bank_Containers.json):

**Dashboards → ⋮ → Import dashboard → Select file →** dê um nome **→ Import**

O arquivo foi gerado a partir de um export real da própria org (o
`dashboard_Conteineres.json`), então o schema é o que o Splunk espera — e não um
palpite. Os ids internos foram trocados por novos de propósito, para o import
criar objetos novos em vez de arriscar sobrescrever um dashboard existente.

Se preferir entender o que cada gráfico faz antes de importar, o SignalFlow de
cada um está abaixo.

---

## 1. CPU por container (%)

O gráfico principal. Mostra qual serviço está consumindo processador — em carga,
`dashboard` e `accounts` sobem primeiro, porque todo o tráfego passa por eles.

```
A = data('container.cpu.utilization',
         filter=filter('container.name', 'fiapbank-otel-*', 'martianbank-otel-*'))
    .mean(by=['container.name'])
    .publish(label='CPU %')
```

> Tipo de gráfico: Line. Eixo Y: 0 a 100.

---

## 2. Memória por container (%)

```
A = data('container.memory.percent',
         filter=filter('container.name', 'fiapbank-otel-*', 'martianbank-otel-*'))
    .mean(by=['container.name'])
    .publish(label='Memória %')
```

---

## 3. Memória por container (MB)

Útil para ver o custo real de cada runtime: os serviços Python com o agente OTel
costumam ficar bem acima dos Node.

```
A = data('container.memory.usage.total',
         filter=filter('container.name', 'fiapbank-otel-*', 'martianbank-otel-*'))
    .mean(by=['container.name'])
    .scale(1/1048576)
    .publish(label='Memória (MB)')
```

---

## 4. Memória usada x limite

```
A = data('container.memory.usage.total',
         filter=filter('container.name', 'fiapbank-otel-*', 'martianbank-otel-*'))
    .mean(by=['container.name']).scale(1/1048576).publish(label='Usada (MB)')

B = data('container.memory.usage.limit',
         filter=filter('container.name', 'fiapbank-otel-*', 'martianbank-otel-*'))
    .mean(by=['container.name']).scale(1/1048576).publish(label='Limite (MB)')
```

---

## 5. Rede — recebido e enviado (bytes/s)

Estas são contadores cumulativos, então precisam de `rollup='rate'` para virar
taxa por segundo.

```
A = data('container.network.io.usage.rx_bytes', rollup='rate',
         filter=filter('container.name', 'fiapbank-otel-*', 'martianbank-otel-*'))
    .sum(by=['container.name']).publish(label='RX B/s')

B = data('container.network.io.usage.tx_bytes', rollup='rate',
         filter=filter('container.name', 'fiapbank-otel-*', 'martianbank-otel-*'))
    .sum(by=['container.name']).publish(label='TX B/s')
```

> **Atenção no modo `network_mode: host`:** os containers compartilham a pilha de
> rede da EC2, então esta métrica **não separa por container** — todos mostram o
> tráfego do host. Ela só faz sentido na variante bridge. CPU e memória
> continuam corretas nos dois modos.

---

## 6. Disco — I/O por container (bytes/s)

```
A = data('container.blockio.io_service_bytes_recursive', rollup='rate',
         filter=filter('container.name', 'fiapbank-otel-*', 'martianbank-otel-*'))
    .sum(by=['container.name']).publish(label='Disco B/s')
```

---

## 7. CPU da EC2 (host)

Vem do receiver `host_metrics`, que já está na configuração padrão do collector
— não depende do `docker_stats`. Aqui os nomes passam pelas regras de tradução
do exporter `signalfx` e ficam no padrão clássico (sem o prefixo `container.`).

```
A = data('cpu.utilization').mean(by=['host.name']).publish(label='CPU do host %')
```

---

## 8. Memória da EC2 (host)

```
A = data('memory.utilization').mean(by=['host.name']).publish(label='Memória do host %')
```

---

## Como conferir rapidamente se o dado está chegando

Antes de montar tudo, vale um teste de um gráfico só. Se este vier vazio, o
problema é de ingestão e não de SignalFlow:

```
A = data('container.cpu.utilization').publish(label='teste')
```

Sem filtro nenhum, ele mostra **todos** os containers da EC2 — incluindo o
`martian-mongodb`. Se aparecer, a coleta está funcionando e é só ajustar os
filtros.

E para gerar carga e ver os gráficos se mexerem:

```bash
~/carga_locust.sh --usuarios 20 --continuo
```

---

## Dimensões disponíveis para filtrar e agrupar

Medidas na saída real do receiver:

| Dimensão | Exemplo |
|---|---|
| `container.name` | `fiapbank-otel-host-accounts-1` |
| `container.id` | `010a272e63c6b2b4...` |
| `container.image.name` | `martian-bank-accounts-otel` |
| `container.hostname` | `010a272e63c6` |

Agrupar por `container.image.name` em vez de `container.name` é útil quando você
sobe e derruba a stack várias vezes: o nome do container muda, o da imagem não.
