cat > ~/diagnostico_otel.sh <<'EOF'
#!/bin/bash

set +e

# ==================================================
# DIAGNOSTICO DA TELEMETRIA
#
# Responde, com dados e nao com achismo:
#   - o collector esta RECEBENDO spans das aplicacoes?
#   - o collector esta CONSEGUINDO ENVIAR ao Splunk?
#   - as aplicacoes estao configuradas corretamente?
#   - metricas de container estao configuradas?
# ==================================================

COLLECTOR_CONF="/etc/otel/collector/splunk-otel-collector.conf"
AGENT_CONF="/etc/otel/collector/agent_config.yaml"
INTERNAL="http://localhost:8888/metrics"

echo "=================================================="
echo " DIAGNOSTICO DA TELEMETRIA - $(date '+%H:%M:%S')"
echo "=================================================="


# ==================================================
# 1. COLLECTOR
# ==================================================

echo
echo "1. COLLECTOR"
echo "=================================================="

systemctl is-active --quiet splunk-otel-collector \
    && echo "✅ splunk-otel-collector ativo" \
    || { echo "❌ collector NAO esta ativo"; exit 1; }

echo
echo "Portas em escuta:"
sudo ss -lntp 2>/dev/null | grep -E ':4317|:4318|:8006|:8888' \
    || echo "⚠️ nenhuma porta do collector encontrada"

echo
echo "Realm / endpoints:"
sudo grep -E '^SPLUNK_(REALM|INGEST_URL|HEC_URL|LISTEN_INTERFACE)=' "$COLLECTOR_CONF" 2>/dev/null

echo
echo "Token de acesso configurado:"
sudo grep -qE '^SPLUNK_ACCESS_TOKEN=.+' "$COLLECTOR_CONF" 2>/dev/null \
    && echo "✅ SPLUNK_ACCESS_TOKEN preenchido" \
    || echo "❌ SPLUNK_ACCESS_TOKEN VAZIO - nada chega ao Splunk"


# ==================================================
# 2. O COLLECTOR ESTA RECEBENDO E ENVIANDO SPANS?
# ==================================================

echo
echo "=================================================="
echo "2. FLUXO DE SPANS (metricas internas do collector)"
echo "=================================================="
echo
echo "Esta e' a pergunta decisiva: se 'accepted' sobe e 'sent' acompanha,"
echo "os spans chegaram ao Splunk e o problema e' de visualizacao (janela de"
echo "tempo, filtro de ambiente). Se 'accepted' fica em zero, o problema esta"
echo "entre a aplicacao e o collector."
echo

ler_spans() {
    curl -s --max-time 5 "$INTERNAL" 2>/dev/null \
        | grep -E '^otelcol_(receiver_accepted_spans|receiver_refused_spans|exporter_sent_spans|exporter_send_failed_spans|processor_dropped_spans)' \
        | grep -v '^#'
}

# Duas coisas diferentes que antes eu tratava como uma so': o endpoint estar
# inacessivel, e o endpoint responder sem nenhuma metrica de span. A segunda e'
# o estado NORMAL de uma maquina onde a aplicacao ainda nao subiu -- o
# Prometheus so' cria a serie depois do primeiro span. Dizer "nao consegui ler"
# nesse caso manda procurar problema no lugar errado.
BRUTO=$(curl -s --max-time 5 "$INTERNAL" 2>/dev/null)

APPS_NO_AR=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -cE 'fiapbank-otel|martianbank-otel')

if [ -z "$BRUTO" ] || ! echo "$BRUTO" | grep -q '^otelcol_'; then

    echo "⚠️ Nao consegui ler $INTERNAL"
    echo "   (a telemetria interna escuta em 127.0.0.1:8888 - rode na propria maquina)"

elif [ -z "$(ler_spans)" ]; then

    echo "ℹ️ O endpoint responde, mas ainda NAO existe nenhuma metrica de span."
    echo

    if [ "$APPS_NO_AR" -eq 0 ]; then
        echo "   Motivo: nenhum container da aplicacao esta rodando, entao nada"
        echo "   enviou span algum ainda. Isso nao e' defeito."
        echo
        echo "   Suba a aplicacao e rode este diagnostico de novo:"
        echo "     cd ~/splunk && bash docker-run-demo-bank.sh host"
    else
        echo "   Os containers estao no ar, mas nenhum span chegou ao collector."
        echo "   Gere trafego e repita:"
        echo "     cd ~/splunk && bash carga-locust.sh --usuarios 5"
    fi

else

    echo "--- leitura 1 ---"
    echo "$ANTES" | sed 's/{/ {/' | awk '{printf "  %s\n", $0}'

    echo
    echo "Gerando trafego (dashboard -> accounts -> mongo)..."

    for i in 1 2 3 4 5; do
        curl -s --max-time 10 -X POST "http://localhost:5000/account/allaccounts" \
            -F "email_id=teste@teste.com" -o /dev/null
    done

    echo "Aguardando o batch do collector (15s)..."
    sleep 15

    DEPOIS=$(ler_spans)

    echo
    echo "--- leitura 2 (depois do trafego) ---"
    echo "$DEPOIS" | sed 's/{/ {/' | awk '{printf "  %s\n", $0}'

    echo
    echo "--- veredito ---"

    A_ACC=$(echo "$ANTES"  | grep 'receiver_accepted_spans' | awk '{s+=$NF} END {printf "%.0f", s+0}')
    D_ACC=$(echo "$DEPOIS" | grep 'receiver_accepted_spans' | awk '{s+=$NF} END {printf "%.0f", s+0}')
    A_SNT=$(echo "$ANTES"  | grep 'exporter_sent_spans'     | awk '{s+=$NF} END {printf "%.0f", s+0}')
    D_SNT=$(echo "$DEPOIS" | grep 'exporter_sent_spans'     | awk '{s+=$NF} END {printf "%.0f", s+0}')
    FAIL=$(echo  "$DEPOIS" | grep 'send_failed_spans'       | awk '{s+=$NF} END {printf "%.0f", s+0}')

    echo "  spans recebidos no periodo: $((D_ACC - A_ACC))"
    echo "  spans enviados no periodo:  $((D_SNT - A_SNT))"
    echo "  falhas de envio (total):    ${FAIL:-0}"
    echo

    if [ "$((D_ACC - A_ACC))" -eq 0 ]; then
        echo "  ❌ O collector NAO recebeu spans."
        echo "     Olhe a secao 3: as apps estao apontando para o endpoint certo?"
    elif [ "$((D_SNT - A_SNT))" -eq 0 ]; then
        echo "  ❌ Recebeu mas NAO enviou - problema de exporter/token/rede."
    else
        echo "  ✅ Spans chegaram ao collector E foram enviados ao Splunk."
        echo "     Se o APM nao mostra os servicos, o problema e' de visualizacao:"
        echo "     confira a JANELA DE TEMPO (use -1h) e o filtro Environment."
    fi

fi


# ==================================================
# 3. AS APLICACOES
# ==================================================

echo
echo "=================================================="
echo "3. CONFIGURACAO DAS APLICACOES"
echo "=================================================="
echo

printf "%-16s %-22s %-34s\n" "CONTAINER" "OTEL_SERVICE_NAME" "OTEL_EXPORTER_OTLP_ENDPOINT"
printf "%-16s %-22s %-34s\n" "---------" "-----------------" "---------------------------"

if [ "$(docker ps --format '{{.Names}}' | grep -cE 'fiapbank|martianbank')" -eq 0 ]; then
    echo "  (nenhum container da aplicacao rodando)"
    echo
    echo "  Suba com: cd ~/splunk && bash docker-run-demo-bank.sh host"
fi

for C in $(docker ps --format '{{.Names}}' | grep -E 'fiapbank|martianbank'); do

    SVC=$(docker inspect "$C" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | grep '^OTEL_SERVICE_NAME=' | cut -d= -f2-)

    EP=$(docker inspect "$C" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | grep '^OTEL_EXPORTER_OTLP_ENDPOINT=' | cut -d= -f2-)

    printf "%-16s %-22s %-34s\n" \
        "$(echo "$C" | sed 's/.*-\(.*\)-1/\1/')" "${SVC:-<VAZIO>}" "${EP:-<VAZIO>}"

done

echo
echo "Lembrete: os servicos Node usam a porta 4318 (OTLP/HTTP) e os Python"
echo "a 4317 (gRPC). Node apontado para 4317 instrumenta tudo e falha calado."


# ==================================================
# 4. CONECTIVIDADE ATE O COLLECTOR
# ==================================================

echo
echo "=================================================="
echo "4. CONECTIVIDADE CONTAINER -> COLLECTOR"
echo "=================================================="
echo

for ALVO in "localhost 4317" "localhost 4318"; do

    set -- $ALVO

    if docker run --rm --network host busybox:latest \
        timeout 3 nc -z "$1" "$2" >/dev/null 2>&1; then

        echo "✅ modo host:   $1:$2 alcancavel"

    else

        echo "❌ modo host:   $1:$2 NAO alcancavel"

    fi

done

GATEWAY=$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)

if [ -n "$GATEWAY" ]; then

    for PORTA in 4317 4318; do

        if docker run --rm busybox:latest \
            timeout 3 nc -z "$GATEWAY" "$PORTA" >/dev/null 2>&1; then

            echo "✅ modo bridge: $GATEWAY:$PORTA alcancavel"

        else

            echo "❌ modo bridge: $GATEWAY:$PORTA NAO alcancavel"
            echo "   (esperado se SPLUNK_LISTEN_INTERFACE ainda for 127.0.0.1)"

        fi

    done

fi


# ==================================================
# 5. METRICAS DE INFRAESTRUTURA
# ==================================================

echo
echo "=================================================="
echo "5. METRICAS DE INFRAESTRUTURA"
echo "=================================================="
echo

sudo grep -q "host_metrics" "$AGENT_CONF" 2>/dev/null \
    && echo "✅ host_metrics configurado - CPU/memoria da EC2 vao para o Splunk" \
    || echo "❌ host_metrics ausente"

echo

if sudo grep -q "docker_stats" "$AGENT_CONF" 2>/dev/null; then

    echo "✅ docker_stats configurado (receiver NATIVO do OpenTelemetry)"
    echo "   Metricas: container.cpu.utilization, container.memory.usage.total,"
    echo "             container.memory.percent, container.network.io.usage.*"
    echo "   Dimensoes: container.name, container.id, container.image.name"
    echo "   Sem dashboard pronto - monte os graficos no Metric Finder."

elif sudo grep -q "smartagent/docker-container-stats" "$AGENT_CONF" 2>/dev/null; then

    echo "⚠️ smartagent/docker-container-stats configurado (caminho LEGADO)"
    echo "   Acende os dashboards prontos de Docker, mas o Smart Agent esta"
    echo "   descontinuado e esses dashboards estao depreciados."

else

    echo "❌ NENHUM receiver de metricas de container configurado."
    echo "   E' por isso que os containers nao aparecem na Infraestrutura."
    echo "   Rode: sudo ./config_docker_otel.sh"

fi

echo
echo "Usuario do collector no grupo docker (necessario p/ ler o socket):"
id -nG splunk-otel-collector 2>/dev/null | grep -qw docker \
    && echo "✅ sim" \
    || echo "❌ nao - o docker_stats nao consegue ler /var/run/docker.sock"


# ==================================================
# 6. ERROS RECENTES
# ==================================================

echo
echo "=================================================="
echo "6. ERROS RECENTES DO COLLECTOR"
echo "=================================================="
echo

sudo journalctl -u splunk-otel-collector --since "5 minutes ago" 2>/dev/null \
    | grep -iE 'error|refused|failed|permanent' \
    | sed -E 's/.*"otelcol.component.id": "([^"]+)".*"error": "([^"]+)".*/  [\1] \2/' \
    | sort | uniq -c | sort -rn | head -8

echo
echo "  (erros do splunk_hec/logs sao esperados: o Splunk Observability nao"
echo "   aceita mais ingestao direta de logs)"

echo
echo "=================================================="
echo " FIM DO DIAGNOSTICO"
echo "=================================================="

EOF

chmod +x ~/diagnostico_otel.sh

echo
echo "=================================================="
echo " DIAGNOSTICO CRIADO"
echo "=================================================="
echo
echo "~/diagnostico_otel.sh"
echo
echo "Executando"
~/diagnostico_otel.sh
