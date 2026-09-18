#!/bin/bash
#
# ============================================================================
# Splunk Enterprise em container - destino para os logs do lab
# ============================================================================
#
# POR QUE ISSO E' NECESSARIO
#
# O Splunk Observability Cloud nao aceita mais ingestao direta de logs (o Log
# Observer nativo foi descontinuado em favor do Log Observer Connect, que LE
# logs de um Splunk plataforma em vez de recebe-los). O endpoint /v1/log
# responde 404 ate sem token.
#
# Entao, para os logs voltarem a funcionar no lab, e' preciso um Splunk
# Enterprise recebendo. Ele destrava DOIS caminhos de uma vez:
#
#   1. OTel Collector --HEC:8088--> Splunk Enterprise
#      (logs das apps Python, com trace_id/span_id correlacionados)
#
#   2. Universal Forwarder --:9997--> Splunk Enterprise
#      (arquivos do sistema, via config_log_splunkfwd.sh)
#
# Licenca free: 500 MB/dia, suficiente de sobra para a aula.
#
# Uso:
#   sudo ./config_splunk_enterprise.sh
#   sudo SPLUNK_ADMIN_PASS='SuaSenha@123' ./config_splunk_enterprise.sh
#   sudo PORTA_WEB=8095 ./config_splunk_enterprise.sh
# ============================================================================

set -u

CONTAINER="splunk-enterprise"
IMAGEM="splunk/splunk:latest"
VOLUME="splunk-enterprise-data"

# 8000 e' a porta padrao do Splunk Web, mas em network_mode: host ela ja e' do
# customer-auth do Martian Bank. Por isso o Web sai na 8090.
PORTA_WEB="${PORTA_WEB:-8090}"
PORTA_HEC="${PORTA_HEC:-8088}"
PORTA_S2S="${PORTA_S2S:-9997}"
PORTA_MGMT="${PORTA_MGMT:-8089}"

# Por padrao TODAS as portas saem em 0.0.0.0, para dar para acessar de fora da
# EC2 - e' um laboratorio. Para prender a porta de gerenciamento (8089, a API
# admin do Splunk) ao loopback, rode com RESTRINGIR_MGMT=sim.
if [ "${RESTRINGIR_MGMT:-nao}" = "sim" ]; then
    BIND_MGMT="127.0.0.1:"
else
    BIND_MGMT=""
fi

COLLECTOR_CONF="/etc/otel/collector/splunk-otel-collector.conf"
BASE_DOCKER="$HOME/martian-bank-demo-docker"
[ -d "$BASE_DOCKER" ] || BASE_DOCKER="/home/ec2-user/martian-bank-demo-docker"

echo "============================================================"
echo " SPLUNK ENTERPRISE EM CONTAINER"
echo "============================================================"


# ------------------------------------------------------------
# 0. Pre-requisitos
# ------------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    echo "[ERRO] Execute como root: sudo ./config_splunk_enterprise.sh"
    exit 1
fi

command -v docker >/dev/null 2>&1 || { echo "[ERRO] Docker nao encontrado."; exit 1; }

echo
echo "[1/8] Recursos da maquina"

RAM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')

if [ -n "${RAM_MB:-}" ]; then
    echo "  RAM total: ${RAM_MB} MB"
    if [ "$RAM_MB" -lt 3500 ]; then
        echo "  [ATENCAO] O Splunk Enterprise pede ~2 GB so' para ele."
        echo "            Com o Martian Bank rodando junto, pode faltar memoria."
        echo "            Continuando mesmo assim - acompanhe com 'free -m'."
    else
        echo "  [OK] memoria suficiente"
    fi
fi

# Mesma senha do usuario de teste do banco (Teste@123): uma so' para todo o
# laboratorio. O Splunk EXIGE no minimo 8 caracteres ASCII imprimiveis, entao
# um "fiap" puro nao passaria e o container nem inicializaria.
SPLUNK_ADMIN_PASS="${SPLUNK_ADMIN_PASS:-Teste@123}"

if [ ${#SPLUNK_ADMIN_PASS} -lt 8 ]; then
    echo "[ERRO] A senha precisa de no minimo 8 caracteres (regra do Splunk)."
    echo "       '$SPLUNK_ADMIN_PASS' tem ${#SPLUNK_ADMIN_PASS}."
    exit 1
fi


# ------------------------------------------------------------
# 1. Porta 8000 ocupada?
# ------------------------------------------------------------

echo
echo "[2/8] Portas"

for P in "$PORTA_WEB" "$PORTA_HEC" "$PORTA_S2S" "$PORTA_MGMT"; do
    if ss -lnt 2>/dev/null | grep -q ":$P "; then
        DONO=$(ss -lntp 2>/dev/null | grep ":$P " | grep -oE 'users:\(\("[^"]+' | cut -d'"' -f2 | head -1)
        echo "  [ATENCAO] porta $P ja ocupada por ${DONO:-algo}"
        echo "            use PORTA_WEB=, PORTA_HEC= ou PORTA_S2S= para trocar"
    else
        echo "  [OK] $P livre"
    fi
done


# ------------------------------------------------------------
# 2. Container
# ------------------------------------------------------------

echo
echo "[3/8] Container"

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then

    if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
        echo "  [OK] $CONTAINER ja esta rodando"
        JA_EXISTIA=true
    else
        echo "  iniciando container existente..."
        docker start "$CONTAINER" >/dev/null
        JA_EXISTIA=true
    fi

    echo "  [INFO] container preexistente: a senha do admin e' a que voce"
    echo "         definiu na primeira criacao, nao a deste script."

else

    JA_EXISTIA=false

    echo "  criando $CONTAINER (a imagem tem ~2,5 GB na primeira vez)..."
    echo
    echo "  [ATENCAO] Este comando aceita, em seu nome, a licenca e os Splunk"
    echo "            General Terms (SPLUNK_GENERAL_TERMS + --accept-license)."
    echo "            Sem as duas variaveis a imagem atual nem inicia."
    echo

    docker volume create "$VOLUME" >/dev/null 2>&1

    docker run -d \
        --name "$CONTAINER" \
        --restart unless-stopped \
        --hostname splunk-enterprise \
        -p "${PORTA_WEB}:8000" \
        -p "${PORTA_HEC}:8088" \
        -p "${PORTA_S2S}:9997" \
        -p "${BIND_MGMT}${PORTA_MGMT}:8089" \
        -e SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com \
        -e SPLUNK_START_ARGS=--accept-license \
        -e SPLUNK_PASSWORD="$SPLUNK_ADMIN_PASS" \
        -v "${VOLUME}:/opt/splunk/var" \
        "$IMAGEM" >/dev/null || { echo "  [ERRO] falha ao criar o container"; exit 1; }

    echo "  [OK] container criado"

fi


# ------------------------------------------------------------
# 3. Esperar ficar pronto
# ------------------------------------------------------------

echo
echo "[4/8] Aguardando o Splunk subir (leva 1 a 3 minutos na primeira vez)"

PRONTO=false

for i in $(seq 1 60); do

    # O healthcheck da propria imagem e' o sinal mais confiavel: durante o
    # Ansible de inicializacao o `splunk status` ainda reclama que nao acha o
    # splunk-launch.conf, o que nao significa falha.
    SAUDE=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null)

    if [ "$SAUDE" = "healthy" ]; then
        PRONTO=true
        echo "  [OK] container saudavel (${i}0s)"
        break
    fi

    if [ "$SAUDE" = "unhealthy" ]; then
        echo "  [ERRO] container marcado como unhealthy:"
        docker logs --tail 10 "$CONTAINER" 2>&1 | cut -c1-120
        exit 1
    fi

    # imagens sem healthcheck: cai no status do splunkd
    if [ -z "$SAUDE" ] && docker exec "$CONTAINER" /opt/splunk/bin/splunk status 2>/dev/null | grep -q "splunkd is running"; then
        PRONTO=true
        echo "  [OK] splunkd rodando (${i}0s)"
        break
    fi

    printf "  aguardando... %ds\r" $((i * 10))
    sleep 10

done

echo

if [ "$PRONTO" != "true" ]; then
    echo "  [ERRO] o Splunk nao ficou pronto. Acompanhe com:"
    echo "    docker logs -f $CONTAINER"
    exit 1
fi


# ------------------------------------------------------------
# 4. Habilitar HEC e criar o token
# ------------------------------------------------------------

echo
echo "[5/8] HTTP Event Collector (HEC)"

# Usamos a API REST via curl DENTRO do container: nao depende de a maquina
# ter curl, e o endpoint de gerenciamento nao fica exposto.
api() {
    docker exec "$CONTAINER" curl -s -k -u "admin:$SPLUNK_ADMIN_PASS" "$@"
}

# Habilita o HEC globalmente
api -X POST "https://localhost:8089/servicesNS/nobody/splunk_httpinput/data/inputs/http/http" \
    -d disabled=0 -d enableSSL=0 >/dev/null 2>&1

# Cria (ou reaproveita) um token dedicado ao lab
TOKEN=$(api "https://localhost:8089/servicesNS/nobody/splunk_httpinput/data/inputs/http/martianbank?output_mode=json" 2>/dev/null \
        | grep -oE '"token":"[^"]+' | cut -d'"' -f4 | head -1)

if [ -z "$TOKEN" ]; then

    api -X POST "https://localhost:8089/servicesNS/nobody/splunk_httpinput/data/inputs/http" \
        -d name=martianbank -d index=main -d disabled=0 >/dev/null 2>&1

    TOKEN=$(api "https://localhost:8089/servicesNS/nobody/splunk_httpinput/data/inputs/http/martianbank?output_mode=json" 2>/dev/null \
            | grep -oE '"token":"[^"]+' | cut -d'"' -f4 | head -1)
fi

if [ -n "$TOKEN" ]; then
    echo "  [OK] token 'martianbank' disponivel"
else
    echo "  [ERRO] nao foi possivel obter o token do HEC."
    echo "         Crie manualmente em Settings > Data inputs > HTTP Event Collector."
    exit 1
fi


# ------------------------------------------------------------
# 5. Provar que o HEC funciona
# ------------------------------------------------------------

echo
echo "[6/8] Testando o HEC de ponta a ponta"

RESP=$(curl -s -k --max-time 15 \
    "http://localhost:${PORTA_HEC}/services/collector" \
    -H "Authorization: Splunk $TOKEN" \
    -d '{"event":"teste de ingestao do config_splunk_enterprise.sh","sourcetype":"manual"}' 2>/dev/null)

if echo "$RESP" | grep -q '"code":0'; then
    echo "  [OK] evento aceito: $RESP"
else
    echo "  [ERRO] o HEC recusou o evento: ${RESP:-<sem resposta>}"
    echo "         Verifique se a porta $PORTA_HEC esta publicada."
    exit 1
fi


# ------------------------------------------------------------
# 6. Receber do Universal Forwarder (9997)
# ------------------------------------------------------------

echo
echo "[7/8] Recebimento na $PORTA_S2S (Universal Forwarder)"

# O `docker exec` entra como o usuario `ansible`, mas o splunkd roda como
# `splunk` - sem o -u o CLI falha com "Pid file unreadable: Permission denied".
SAIDA_LISTEN=$(docker exec -u splunk "$CONTAINER" /opt/splunk/bin/splunk enable listen 9997 \
    -auth "admin:$SPLUNK_ADMIN_PASS" 2>&1)

if echo "$SAIDA_LISTEN" | grep -qi "already exists"; then
    echo "  [OK] recebimento na 9997 ja estava configurado"
elif echo "$SAIDA_LISTEN" | grep -qi "permission denied"; then
    echo "  [ERRO] permissao negada ao configurar a 9997:"
    echo "$SAIDA_LISTEN" | grep -i "permission" | head -2
else
    echo "  [OK] recebimento habilitado na 9997"
fi

# Confirma o estado real em vez de confiar na saida do comando acima.
ESTADO=$(docker exec -u splunk "$CONTAINER" /opt/splunk/bin/splunk display listen \
    -auth "admin:$SPLUNK_ADMIN_PASS" 2>/dev/null | grep -i "9997")

[ -n "$ESTADO" ] && echo "  confirmado: $ESTADO"


# ------------------------------------------------------------
# 7. Apontar o OTel Collector para este HEC
# ------------------------------------------------------------

echo
echo "[8/8] Ligando o OTel Collector neste Splunk"

if [ ! -f "$COLLECTOR_CONF" ]; then

    echo "  [INFO] $COLLECTOR_CONF nao existe - collector nao instalado aqui."

else

    BKP="$COLLECTOR_CONF.bkp.$(date +%s)"
    cp "$COLLECTOR_CONF" "$BKP"

    NOVA_URL="http://localhost:${PORTA_HEC}/services/collector"

    sed -i "s|^SPLUNK_HEC_URL=.*|SPLUNK_HEC_URL=$NOVA_URL|" "$COLLECTOR_CONF"
    sed -i "s|^SPLUNK_HEC_TOKEN=.*|SPLUNK_HEC_TOKEN=$TOKEN|" "$COLLECTOR_CONF"

    grep -q '^SPLUNK_HEC_TOKEN=' "$COLLECTOR_CONF" || echo "SPLUNK_HEC_TOKEN=$TOKEN" >> "$COLLECTOR_CONF"

    echo "  HEC do collector -> $NOVA_URL"

    systemctl restart splunk-otel-collector
    sleep 6

    if systemctl is-active --quiet splunk-otel-collector; then

        echo "  [OK] collector reiniciado e ativo"

    else

        # Mesma protecao dos outros scripts: config quebrada derruba a
        # telemetria inteira, entao desfazemos em vez de deixar assim.
        echo "  [ERRO] o collector nao subiu. Revertendo..."
        journalctl -u splunk-otel-collector --since "1 minute ago" --no-pager 2>/dev/null \
            | grep -iE "error|invalid|required" | tail -3
        cp "$BKP" "$COLLECTOR_CONF"
        systemctl reset-failed splunk-otel-collector 2>/dev/null
        systemctl restart splunk-otel-collector
        sleep 6
        systemctl is-active --quiet splunk-otel-collector \
            && echo "  [OK] collector restaurado (mudanca desfeita)" \
            || echo "  [ERRO] collector continua fora - investigue o agent_config.yaml"
    fi

fi


# ------------------------------------------------------------
# Resumo
# ------------------------------------------------------------

IP=$(curl -s --max-time 5 checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')

echo
echo "============================================================"
echo " PRONTO"
echo "============================================================"
echo
echo "  Splunk Web:  http://${IP:-<ip-da-ec2>}:${PORTA_WEB}"
echo "  Usuario:     admin"

if [ "$JA_EXISTIA" = "false" ]; then
    echo "  Senha:       $SPLUNK_ADMIN_PASS"
else
    echo "  Senha:       (a definida quando o container foi criado)"
fi

echo
echo "  HEC (collector, na propria EC2):"
echo "               http://localhost:${PORTA_HEC}/services/collector"
echo "  HEC (de fora da EC2):"
echo "               http://${IP:-<ip-da-ec2>}:${PORTA_HEC}/services/collector"
echo "  Token:       $TOKEN"
echo "  Forwarder:   porta ${PORTA_S2S} habilitada"
echo "  API admin:   ${BIND_MGMT:-0.0.0.0:}${PORTA_MGMT} (Splunk management)"
echo
# echo "  Teste o HEC de qualquer maquina:"
# echo "    curl -k http://${IP:-<ip-da-ec2>}:${PORTA_HEC}/services/collector \\"
# echo "      -H 'Authorization: Splunk $TOKEN' \\"
# echo "      -d '{\"event\":\"ola do meu notebook\"}'"
echo
# echo "  Libere no Security Group da EC2: ${PORTA_WEB}, ${PORTA_HEC}, ${PORTA_S2S}."
# echo "  Para prender a API admin ao loopback: RESTRINGIR_MGMT=sim"
echo
# echo "  FALTA UM PASSO: ligar o envio de logs das aplicacoes."
# echo
# echo "    cd $BASE_DOCKER"
# echo "    sed -i 's/^OTEL_LOGS_EXPORTER=.*/OTEL_LOGS_EXPORTER=otlp/' .env"
# echo "    cd ~/splunk && bash docker-run-demo-bank.sh host"
# echo "    # (ou o atalho ~/instalar_bank_docker.sh host, gerado pelo comando acima)"
# echo
# echo "  Para incluir tambem o stdout de Node/nginx/UI, suba com o override:"
# echo
# echo "    docker compose -f docker-compose-network-mode-host.yml \\"
# echo "                   -f docker-compose-logs-fluentd.yml up -d"
# echo
# echo "  Depois, no Splunk Web, procure em Search & Reporting:"
# echo
# echo "    index=main | head 50"
# echo "    index=main sourcetype=otel | head 50"
# echo
# echo "  Os logs das apps Python carregam trace_id e span_id, entao da' para"
# echo "  pular do span no APM para a linha de log correspondente."
# echo
# echo "  Observacao: o Log Observer Connect (ver estes logs dentro do"
# echo "  Observability Cloud) exige que este Splunk seja alcancavel pela"
# echo "  nuvem da Splunk. Numa EC2 de laboratorio, o caminho pratico e'"
# echo "  pesquisar direto no Splunk Web acima."
# echo
echo "============================================================"
