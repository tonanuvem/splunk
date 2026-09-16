cat > ~/instalar_bank_docker.sh <<'EOF'
#!/bin/bash

set -e

echo "=================================================="
echo " MARTIAN BANK DEMO + SPLUNK (CONTAINERS)"
echo " APM (traces) + LOGS + RUM"
echo "=================================================="

# ==================================================
# CONFIGURACAO
# ==================================================

BASE="$HOME/martian-bank-demo-docker"

REPO="https://github.com/tonanuvem/bank-demo.git"

# Variante de rede: host (padrao) ou bridge
MODE="${1:-host}"

TEST_NAME="Teste"
TEST_EMAIL="teste@teste.com"
TEST_PASSWORD="Teste@123"

DEPLOYMENT_ENV="${DEPLOYMENT_ENV:-lab-fiap}"

# Token de RUM (opcional). Se vazio, o frontend sobe sem RUM.
# Crie em: Settings > Access Tokens > (token) > Authorization Scopes > RUM
SPLUNK_RUM_TOKEN="${SPLUNK_RUM_TOKEN:-}"

COLLECTOR_CONF="/etc/otel/collector/splunk-otel-collector.conf"

case "$MODE" in
    host)
        COMPOSE_FILE="docker-compose-network-mode-host.yml"
        ;;
    bridge|docker-internal)
        MODE="bridge"
        COMPOSE_FILE="docker-compose-network-docker-internal.yml"
        ;;
    *)
        echo "❌ Modo invalido: $MODE"
        echo "   Use: host (padrao) ou bridge"
        exit 1
        ;;
esac

echo
echo "Modo de rede: $MODE"
echo "Compose:      $COMPOSE_FILE"
echo "Ambiente:     $DEPLOYMENT_ENV"


# ==================================================
# 1. DOCKER
# ==================================================

echo
echo "1. VERIFICANDO DOCKER"
echo "=================================================="

if ! command -v docker >/dev/null 2>&1; then
    echo "❌ Docker nao esta instalado."
    exit 1
fi

echo "✅ Docker:"
docker --version

if ! docker compose version >/dev/null 2>&1; then
    echo "❌ Plugin 'docker compose' (v2) nao encontrado."
    echo "   Instale docker-compose-plugin."
    exit 1
fi

echo "✅ Compose:"
docker compose version | head -1


# ==================================================
# 2. GIT
# ==================================================

echo
echo "2. VERIFICANDO GIT"
echo "=================================================="

if ! command -v git >/dev/null 2>&1; then

    echo "🚀 Instalando Git..."

    if command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y git
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y git
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y git
    fi

fi

echo "✅ Git:"
git --version


# ==================================================
# 3. BAIXANDO O DEMO (FORK COM OS Dockerfile-otel)
# ==================================================

echo
echo "3. BAIXANDO DEMO BANK"
echo "=================================================="

if [ ! -d "$BASE/.git" ]; then

    echo "🚀 Clonando repositorio..."
    echo "$REPO"

    git clone "$REPO" "$BASE"

else

    echo "✅ Repositorio ja existe:"
    echo "$BASE"

    cd "$BASE"

    echo "🔄 Atualizando repositorio..."

    # A secao 7 reescreve ui/src/slices/apiUrls.js. Se um commit novo tocar
    # esse arquivo, o `git pull --ff-only` aborta ("local changes would be
    # overwritten") e, com um `|| true`, o erro passaria despercebido: a EC2
    # ficaria presa numa versao antiga sem ninguem notar. Descartamos primeiro
    # as alteracoes que o proprio script fez - ele as reaplica adiante.
    git checkout -- ui/src/slices/apiUrls.js 2>/dev/null || true

    if git pull --ff-only; then

        echo "✅ Repositorio atualizado:"
        git log --oneline -1

    else

        echo
        echo "⚠️ NAO FOI POSSIVEL ATUALIZAR O REPOSITORIO."
        echo "   A EC2 vai rodar com a versao que ja estava aqui:"
        git log --oneline -1
        echo
        echo "   Alteracoes locais em conflito:"
        git status --short
        echo
        echo "   Para forcar a versao do GitHub (descarta o que esta local):"
        echo "     cd $BASE && git fetch origin && git reset --hard origin/main"

    fi

fi

cd "$BASE"

if [ ! -f "$BASE/$COMPOSE_FILE" ]; then
    echo
    echo "❌ $COMPOSE_FILE nao encontrado em $BASE"
    echo "   Esse arquivo vem do fork tonanuvem/bank-demo."
    echo "   Confirme que os arquivos de instrumentacao foram commitados."
    exit 1
fi

echo "✅ Compose encontrado:"
echo "$BASE/$COMPOSE_FILE"


# ==================================================
# 4. SPLUNK OTEL COLLECTOR
# ==================================================

echo
echo "4. VERIFICANDO SPLUNK OTEL COLLECTOR"
echo "=================================================="

if ! systemctl is-active --quiet splunk-otel-collector; then

    echo "❌ splunk-otel-collector nao esta ativo."
    echo
    echo "   Instale/inicie o collector antes de continuar:"
    echo "   sudo systemctl status splunk-otel-collector"
    exit 1

fi

echo "✅ Collector ativo:"
systemctl is-active splunk-otel-collector

SPLUNK_REALM=$(sudo grep -E '^SPLUNK_REALM=' "$COLLECTOR_CONF" | cut -d= -f2- | tr -d '"' || true)
ACCESS_TOKEN=$(sudo grep -E '^SPLUNK_ACCESS_TOKEN=' "$COLLECTOR_CONF" | cut -d= -f2- | tr -d '"' || true)
HEC_TOKEN=$(sudo grep -E '^SPLUNK_HEC_TOKEN=' "$COLLECTOR_CONF" | cut -d= -f2- | tr -d '"' || true)

echo "   Realm: ${SPLUNK_REALM:-<nao encontrado>}"


# ==================================================
# 5. LOGS: HABILITANDO O PIPELINE HEC
# ==================================================

echo
echo "5. LOGS: VERIFICANDO O DESTINO"
echo "=================================================="

echo "O pipeline de logs do agent_config.yaml exporta via splunk_hec para"
echo "\$SPLUNK_HEC_URL. IMPORTANTE: o Splunk Observability Cloud NAO aceita"
echo "mais ingestao direta de logs - o Log Observer nativo foi descontinuado"
echo "em favor do Log Observer Connect, que le logs de um Splunk Cloud/"
echo "Enterprise. O endpoint /v1/log responde 404 mesmo sem token."
echo

HEC_TESTE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -X POST "${SPLUNK_HEC_URL:-https://ingest.$SPLUNK_REALM.observability.splunkcloud.com/v1/log}" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "000")

echo "Teste do endpoint de logs: HTTP $HEC_TESTE"

COLLECTOR_CHANGED=false

if [ "$HEC_TESTE" = "404" ]; then

    echo
    echo "⚠️ Confirmado: este endpoint nao aceita logs."
    echo "   Os traces (APM) NAO sao afetados - usam outro pipeline."
    echo
    echo "   Deixando OTEL_LOGS_EXPORTER=none para evitar que o collector"
    echo "   entre em retry infinito contra um endpoint morto."

    LOGS_EXPORTER="none"

    # Se uma execucao anterior deste script preencheu o HEC token, limpamos:
    # com ele preenchido o collector tenta entregar e falha em loop.
    if [ -n "$HEC_TOKEN" ]; then

        echo
        echo "🧹 Limpando SPLUNK_HEC_TOKEN (preenchido por uma execucao anterior)"

        sudo cp "$COLLECTOR_CONF" "$COLLECTOR_CONF.bkp.$(date +%s)"

        sudo sed -i "s|^SPLUNK_HEC_TOKEN=.*|SPLUNK_HEC_TOKEN=|" "$COLLECTOR_CONF"

        COLLECTOR_CHANGED=true

    fi

    echo
    echo "   Para demonstrar logs no Splunk, e' preciso um Splunk Cloud ou"
    echo "   Enterprise recebendo por HEC, e ligar o Log Observer Connect."
    echo "   Nesse caso, aponte SPLUNK_HEC_URL para ele e rode com:"
    echo "     SPLUNK_HEC_URL=https://<host>:8088/services/collector \\"
    echo "     SPLUNK_HEC_TOKEN=<token> ~/instalar_bank_docker.sh $MODE"

else

    echo
    echo "✅ Endpoint de logs respondeu $HEC_TESTE - ingestao parece disponivel."

    LOGS_EXPORTER="otlp"

    if [ -z "$HEC_TOKEN" ] && [ -n "$ACCESS_TOKEN" ]; then

        echo "🚀 Configurando SPLUNK_HEC_TOKEN..."

        sudo cp "$COLLECTOR_CONF" "$COLLECTOR_CONF.bkp.$(date +%s)"

        sudo sed -i "s|^SPLUNK_HEC_TOKEN=.*|SPLUNK_HEC_TOKEN=$ACCESS_TOKEN|" "$COLLECTOR_CONF"

        COLLECTOR_CHANGED=true

    fi

fi

echo
echo "ℹ️ Independente disso, os logs continuam visiveis localmente:"
echo "   docker compose -f $COMPOSE_FILE logs -f dashboard"


# ==================================================
# 6. REDE: OTLP E FLUENT_FORWARD
# ==================================================

echo
echo "6. CONFIGURANDO INTERFACE DE ESCUTA DO COLLECTOR"
echo "=================================================="

if [ "$MODE" = "bridge" ]; then

    echo "Modo bridge: os containers alcancam o collector pelo gateway do"
    echo "Docker (host.docker.internal), entao 127.0.0.1 nao serve para OTLP."
    echo

    if sudo grep -qE '^SPLUNK_LISTEN_INTERFACE=0\.0\.0\.0' "$COLLECTOR_CONF"; then

        echo "✅ SPLUNK_LISTEN_INTERFACE ja e' 0.0.0.0."

    else

        sudo cp "$COLLECTOR_CONF" "$COLLECTOR_CONF.bkp.$(date +%s)"

        if sudo grep -qE '^SPLUNK_LISTEN_INTERFACE=' "$COLLECTOR_CONF"; then
            sudo sed -i "s|^SPLUNK_LISTEN_INTERFACE=.*|SPLUNK_LISTEN_INTERFACE=0.0.0.0|" "$COLLECTOR_CONF"
        else
            echo 'SPLUNK_LISTEN_INTERFACE=0.0.0.0' | sudo tee -a "$COLLECTOR_CONF" >/dev/null
        fi

        COLLECTOR_CHANGED=true

        echo "✅ SPLUNK_LISTEN_INTERFACE=0.0.0.0"
        echo
        echo "⚠️ SEGURANCA: isso tambem expoe 4317/4318 na interface publica."
        echo "   Confirme que o Security Group NAO libera essas portas."

    fi

else

    echo "Modo host: os containers compartilham a rede da EC2, entao"
    echo "127.0.0.1:4317 ja e' o collector. Nada a mudar."

fi

echo
echo "ℹ️ Os logs de Node/nginx/UI usam o log driver fluentd do Docker apontando"
echo "   para 127.0.0.1:8006 (receiver fluent_forward). Quem abre essa conexao"
echo "   e' o daemon do Docker, no host - por isso funciona nos dois modos."


if [ "$COLLECTOR_CHANGED" = "true" ]; then

    echo
    echo "🔄 Reiniciando o collector..."

    sudo systemctl restart splunk-otel-collector

    sleep 5

    echo "✅ Collector reiniciado:"
    systemctl is-active splunk-otel-collector

fi

echo
echo "Portas em escuta:"
sudo ss -lntp 2>/dev/null | grep -E ':4317|:4318|:8006' || echo "⚠️ Nenhuma porta do collector encontrada."


# ==================================================
# 7. URLS DA UI
# ==================================================

echo
echo "7. CONFIGURANDO URLS DA UI"
echo "=================================================="

backup_file() {

    local FILE="$1"

    if [ -f "$FILE" ] && [ ! -f "$FILE.ec2.original" ]; then

        echo "📦 Backup:"
        echo "$FILE"

        cp "$FILE" "$FILE.ec2.original"

    fi

}

API_URLS="$BASE/ui/src/slices/apiUrls.js"

backup_file "$API_URLS"

cat > "$API_URLS" <<'JS'
/*
 * MARTIAN BANK - EC2
 *
 * A UI usa automaticamente o hostname/IP
 * utilizado pelo navegador.
 */

const HOST = window.location.hostname;
const PROTOCOL = window.location.protocol;

const VITE_USERS_URL =
  `${PROTOCOL}//${HOST}:8000/api/users/`;

const VITE_ATM_URL =
  `${PROTOCOL}//${HOST}:8001/api/atm/`;

const VITE_ACCOUNTS_URL =
  `${PROTOCOL}//${HOST}:5000/account/`;

const VITE_TRANSFER_URL =
  `${PROTOCOL}//${HOST}:5000/transaction/`;

const VITE_LOAN_URL =
  `${PROTOCOL}//${HOST}:5000/loan/`;

const ApiUrls = {
  VITE_USERS_URL,
  VITE_ATM_URL,
  VITE_ACCOUNTS_URL,
  VITE_TRANSFER_URL,
  VITE_LOAN_URL,
};

export default ApiUrls;
JS

echo "✅ apiUrls.js configurado (usa o hostname do navegador)."


# ==================================================
# 8. .ENV DO COMPOSE
# ==================================================

echo
echo "8. CONFIGURANDO .ENV"
echo "=================================================="

cat > "$BASE/.env" <<ENVFILE
SPLUNK_REALM=$SPLUNK_REALM
DEPLOYMENT_ENV=$DEPLOYMENT_ENV
APP_VERSION=1.0.0

SPLUNK_RUM_TOKEN=$SPLUNK_RUM_TOKEN
SPLUNK_RUM_APP_NAME=martian-bank-ui

OTEL_LOGS_EXPORTER=$LOGS_EXPORTER
OTEL_METRICS_EXPORTER=none
SPLUNK_PROFILER_ENABLED=false

DB_URL=mongodb://localhost:27017/martianbank
DB_URL_BRIDGE=mongodb://host.docker.internal:27017/martianbank
ENVFILE

echo "✅ $BASE/.env"

if [ -z "$SPLUNK_RUM_TOKEN" ]; then

    echo
    echo "⚠️ SPLUNK_RUM_TOKEN vazio: o frontend sobe SEM RUM."
    echo "   Para habilitar, rode de novo assim:"
    echo "   SPLUNK_RUM_TOKEN=xxxx ~/instalar_bank_docker.sh $MODE"

else

    echo "✅ RUM habilitado (token de ${#SPLUNK_RUM_TOKEN} caracteres)."

fi


# ==================================================
# 9. MONGODB
# ==================================================

echo
echo "9. CRIANDO MONGODB"
echo "=================================================="

if docker ps -a --format '{{.Names}}' | grep -qx "martian-mongodb"; then

    echo "✅ Container martian-mongodb ja existe."

    if ! docker ps --format '{{.Names}}' | grep -qx "martian-mongodb"; then

        echo "🚀 Iniciando MongoDB..."
        docker start martian-mongodb

    fi

else

    echo "🚀 Criando MongoDB..."

    docker run -d \
        --name martian-mongodb \
        --restart unless-stopped \
        -p 27017:27017 \
        -v martian-mongodb-data:/data/db \
        mongo:7

fi

echo
echo "Aguardando MongoDB..."

MONGO_OK=false

for i in {1..30}; do

    if docker exec martian-mongodb \
        mongosh --quiet \
        --eval 'db.adminCommand("ping").ok' 2>/dev/null \
        | grep -q "1"; then

        echo "✅ MongoDB esta pronto."
        MONGO_OK=true
        break

    fi

    echo "Aguardando MongoDB... ($i/30)"
    sleep 2

done

if [ "$MONGO_OK" != "true" ]; then

    echo "❌ MongoDB nao respondeu."
    docker logs --tail 50 martian-mongodb
    exit 1

fi


# ==================================================
# 10. LIBERANDO AS PORTAS
# ==================================================

echo
echo "10. VERIFICANDO PROCESSOS ANTIGOS"
echo "=================================================="

echo "Parando qualquer execucao anterior do compose..."

docker compose -f "$BASE/docker-compose-network-mode-host.yml" down --remove-orphans 2>/dev/null || true
docker compose -f "$BASE/docker-compose-network-docker-internal.yml" down --remove-orphans 2>/dev/null || true

if [ "$MODE" = "host" ]; then

    echo
    echo "Modo host disputa porta com a EC2 inteira."
    echo "Verificando processos nativos (run-demo-bank.sh):"

    for PORT in 3000 5000 8000 8001 50051 50052 50053; do

        PIDS=$(sudo lsof -t -i:"$PORT" 2>/dev/null || true)

        if [ -n "$PIDS" ]; then

            echo "⚠️ Porta $PORT ocupada."

            for PID in $PIDS; do

                CMD=$(ps -p "$PID" -o cmd= 2>/dev/null || true)

                if echo "$CMD" | grep -qE 'martian-bank-demo|node server.js|python3 (accounts|loan|transaction|dashboard)'; then

                    echo "🛑 Parando processo $PID:"
                    echo "$CMD"

                    kill "$PID" 2>/dev/null || true

                else

                    echo "ℹ️ Processo $PID nao pertence ao Martian Bank nativo:"
                    echo "$CMD"

                fi

            done

        fi

    done

    sleep 2

fi


# ==================================================
# 11. BUILD E START
# ==================================================

echo
echo "11. BUILD DAS IMAGENS INSTRUMENTADAS"
echo "=================================================="

echo "Isso demora alguns minutos na primeira vez"
echo "(pip install + opentelemetry-bootstrap em 4 servicos Python)."
echo

cd "$BASE"

docker compose -f "$COMPOSE_FILE" build

echo
echo "=================================================="
echo "12. SUBINDO OS CONTAINERS"
echo "=================================================="

docker compose -f "$COMPOSE_FILE" up -d

echo
echo "Aguardando servicos..."
sleep 20


# ==================================================
# 13. CONTAINERS
# ==================================================

echo
echo "=================================================="
echo "13. CONTAINERS"
echo "=================================================="

docker compose -f "$COMPOSE_FILE" ps


# ==================================================
# 14. PORTAS
# ==================================================

echo
echo "=================================================="
echo "14. PORTAS"
echo "=================================================="

sudo ss -lntp 2>/dev/null \
    | grep -E ':3000|:5000|:8000|:8001|:8080' \
    || true


# ==================================================
# 15. TESTAR SERVICOS
# ==================================================

echo
echo "=================================================="
echo "15. TESTANDO SERVICOS"
echo "=================================================="

test_service() {

    local PORT="$1"
    local NAME="$2"
    local URL="$3"

    echo
    echo "----------------------------------------"
    echo "$NAME"
    echo "Porta: $PORT"
    echo "URL:   $URL"
    echo "----------------------------------------"

    if sudo ss -lnt 2>/dev/null | grep -q ":$PORT "; then

        echo "✅ Porta $PORT esta LISTEN."

        HTTP_STATUS=$(curl -s \
            -o /dev/null \
            -w "%{http_code}" \
            --max-time 10 \
            -L \
            "$URL" || true)

        case "$HTTP_STATUS" in
            200|201|204|301|302)
                echo "HTTP Status: $HTTP_STATUS ✅"
                ;;
            000)
                echo "HTTP Status: sem resposta ❌"
                ;;
            *)
                echo "HTTP Status: $HTTP_STATUS ⚠️ (servico respondeu, mas nao com sucesso)"
                ;;
        esac

    else

        echo "❌ Porta $PORT NAO esta LISTEN."

    fi

}

# ATENCAO: os servicos Node nao tem rota em "/" - as rotas vivem em
# /api/users e /api/atm. Bater na raiz devolve 404 e parece falha, mas e' o
# Express respondendo normalmente. Usamos o Swagger UI (/docs), que existe
# nos dois e devolve 200 - assim o teste valida o servico DE VERDADE.
test_service 3000 "UI" "http://localhost:3000"
test_service 8000 "CUSTOMER AUTH (swagger)" "http://localhost:8000/docs"
test_service 8001 "ATM LOCATOR (swagger)" "http://localhost:8001/docs"
test_service 5000 "DASHBOARD (BACKEND PYTHON)" "http://localhost:5000"


# ==================================================
# 16. TESTAR CORS
# ==================================================

echo
echo "=================================================="
echo "16. TESTANDO CORS DO BACKEND"
echo "=================================================="

CORS_RESPONSE=$(curl -s -i \
    -X OPTIONS \
    "http://localhost:5000/account/allaccounts" \
    -H "Origin: http://localhost:3000" \
    -H "Access-Control-Request-Method: GET" \
    || true)

echo "$CORS_RESPONSE" | head -20

if echo "$CORS_RESPONSE" | grep -qi "Access-Control-Allow-Origin"; then

    echo
    echo "✅ CORS esta habilitado."

else

    echo
    echo "⚠️ CORS nao foi identificado na resposta."

fi

if echo "$CORS_RESPONSE" | grep -qi "Access-Control-Expose-Headers.*Server-Timing"; then

    echo "✅ Server-Timing exposto (correlacao RUM -> APM deve fechar)."

else

    echo "⚠️ Server-Timing nao exposto - a correlacao RUM -> APM pode nao fechar."

fi


# ==================================================
# 17. CRIAR USUARIO
# ==================================================

echo
echo "=================================================="
echo "17. CRIANDO USUARIO DE TESTE"
echo "=================================================="

AUTH_READY=false

echo
echo "Aguardando Customer Auth..."

for i in {1..30}; do

    if curl -s --max-time 3 "http://localhost:8000/api/users/" >/dev/null 2>&1; then

        AUTH_READY=true
        break

    fi

    echo "Aguardando Customer Auth... ($i/30)"
    sleep 2

done

if [ "$AUTH_READY" = "true" ]; then

    echo "✅ Customer Auth disponivel."

    echo
    echo "Tentando criar usuario..."

    REGISTER_RESPONSE=$(curl -s \
        --max-time 10 \
        -X POST \
        "http://localhost:8000/api/users/" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$TEST_NAME\",
            \"email\": \"$TEST_EMAIL\",
            \"password\": \"$TEST_PASSWORD\"
        }")

    echo
    echo "Resposta:"
    echo "$REGISTER_RESPONSE" | sed -E 's/"token":"[^"]+"/"token":"***OCULTO***"/g'

    if echo "$REGISTER_RESPONSE" | grep -qiE 'already exists|user already|duplicate'; then

        echo
        echo "ℹ️ Usuario ja existe."

    elif echo "$REGISTER_RESPONSE" | grep -qiE '"token"|"email"|success|created'; then

        echo
        echo "✅ Usuario criado."

    else

        echo
        echo "⚠️ Nao foi possivel confirmar o cadastro."

    fi

else

    echo
    echo "❌ Customer Auth nao respondeu."
    echo
    docker compose -f "$COMPOSE_FILE" logs --tail 30 customer-auth || true

fi


# ==================================================
# 18. GERAR TELEMETRIA
# ==================================================

echo
echo "=================================================="
echo "18. GERANDO TELEMETRIA (TRACES + LOGS)"
echo "=================================================="

echo "Todas as chamadas passam pelo dashboard, que por sua vez chama os outros"
echo "cinco servicos. E' esse encadeamento que produz o trace distribuido -"
echo "no APM o service map deve mostrar os 6 servicos ligados ao dashboard."
echo
echo "Obs.: /account/allaccounts, /transaction/history e /loan/history leem"
echo "request.form, entao vao como form-encoded (-F). /api/atm/ e /api/users/auth"
echo "leem JSON. A barra final em /api/atm/ importa: sem ela o Flask responde"
echo "308 e o POST nao chega ao atm-locator."
echo

for i in 1 2 3; do

    echo "  --- rodada $i ---"

    # dashboard -> accounts
    curl -s --max-time 10 \
        -X POST "http://localhost:5000/account/allaccounts" \
        -F "email_id=$TEST_EMAIL" \
        -o /dev/null -w "  accounts      POST /account/allaccounts -> HTTP %{http_code}\n" || true

    # dashboard -> transactions
    curl -s --max-time 10 \
        -X POST "http://localhost:5000/transaction/history" \
        -F "account_number=0" \
        -o /dev/null -w "  transactions  POST /transaction/history -> HTTP %{http_code}\n" || true

    # dashboard -> loan
    curl -s --max-time 10 \
        -X POST "http://localhost:5000/loan/history" \
        -F "email=$TEST_EMAIL" \
        -o /dev/null -w "  loan          POST /loan/history        -> HTTP %{http_code}\n" || true

    # dashboard -> atm-locator (Node)
    curl -s --max-time 10 \
        -X POST "http://localhost:5000/api/atm/" \
        -H "Content-Type: application/json" \
        -d '{"isOpenNow": false, "isInterPlanetary": false}' \
        -o /dev/null -w "  atm-locator   POST /api/atm/            -> HTTP %{http_code}\n" || true

    # dashboard -> customer-auth (Node)
    curl -s --max-time 10 \
        -X POST "http://localhost:5000/api/users/auth" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"$TEST_EMAIL\", \"password\": \"$TEST_PASSWORD\"}" \
        -o /dev/null -w "  customer-auth POST /api/users/auth      -> HTTP %{http_code}\n" || true

    sleep 2

done


# ==================================================
# 19. VERIFICANDO O COLLECTOR
# ==================================================

echo
echo "=================================================="
echo "19. VERIFICANDO O COLLECTOR"
echo "=================================================="

echo "Erros recentes do collector (vazio = bom sinal):"

sudo journalctl -u splunk-otel-collector --since "3 minutes ago" 2>/dev/null \
    | grep -iE 'error|refused|failed|permanent' \
    | tail -10 \
    || echo "  (nenhum erro recente)"


# ==================================================
# 20. STATUS FINAL
# ==================================================

echo
echo "=================================================="
echo "20. STATUS DOS CONTAINERS"
echo "=================================================="

docker compose -f "$COMPOSE_FILE" ps --format 'table {{.Name}}\t{{.Service}}\t{{.Status}}'


# ==================================================
# 21. MONGODB
# ==================================================

echo
echo "=================================================="
echo "21. MONGODB"
echo "=================================================="

docker ps \
    --filter name=martian-mongodb \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

echo
echo "MongoDB:"
echo "mongodb://localhost:27017/martianbank"


# ==================================================
# FINAL
# ==================================================

echo
echo "=================================================="
echo " MARTIAN BANK INICIADO (CONTAINERS)"
echo "=================================================="

IP=$(curl -s --max-time 5 checkip.amazonaws.com || true)
IP=$(echo "$IP" | tr -d '[:space:]')

if [ -n "$IP" ]; then

    echo
    echo "URL de acesso:"
    echo
    echo "http://$IP:3000"
    # URLs das APIs - descomente se quiser exibi-las
    # echo
    # echo "APIs:"
    # echo "Customer Auth: http://$IP:8000        (swagger em /docs)"
    # echo "ATM Locator:   http://$IP:8001        (swagger em /docs)"
    # echo "Dashboard:     http://$IP:5000"
    # echo "Nginx:         http://$IP:8080"

else

    echo
    echo "⚠️ Nao foi possivel obter o IP publico."

fi

echo
echo "LOGIN DE TESTE:"
echo
echo "Email: $TEST_EMAIL"
echo "Senha: $TEST_PASSWORD"

echo
# ------------------------------------------------------------------
# Blocos "ONDE OLHAR NO SPLUNK" e "COMANDOS UTEIS" comentados.
# Descomente se quiser a saida completa no fim da execucao.
# ------------------------------------------------------------------
# echo "--------------------------------------------------"
# echo "ONDE OLHAR NO SPLUNK"
# echo "--------------------------------------------------"
# echo
# echo "APM   > Services        (filtre Environment = $DEPLOYMENT_ENV)"
# echo "        dashboard, accounts, transactions, loan,"
# echo "        customer-auth, atm-locator"
# echo
# echo "Log Observer            (filtre service.name ou deployment.environment)"
# echo "        Python: logs via OTLP, com trace_id/span_id -> Related Content"
# echo "        Node/nginx/UI: stdout via log driver fluentd"
# echo
# if [ -n "$SPLUNK_RUM_TOKEN" ]; then
# echo "RUM   > Browser         aplicacao martian-bank-ui"
# else
# echo "RUM                     desabilitado (SPLUNK_RUM_TOKEN vazio)"
# fi

# echo
# echo "--------------------------------------------------"
# echo "COMANDOS UTEIS"
# echo "--------------------------------------------------"
# echo
# echo "cd $BASE"
# echo
# echo "# logs de um servico (funciona mesmo com o driver fluentd)"
# echo "docker compose -f $COMPOSE_FILE logs -f dashboard"
# echo
# echo "# parar tudo"
# echo "docker compose -f $COMPOSE_FILE down"
# echo
# echo "# trocar de variante de rede"
# echo "~/instalar_bank_docker.sh host"
# echo "~/instalar_bank_docker.sh bridge"
echo
echo "=================================================="

EOF

chmod +x ~/instalar_bank_docker.sh

echo
echo "=================================================="
echo " SCRIPT CRIADO"
echo "=================================================="
echo
echo "~/instalar_bank_docker.sh"
echo
echo "Uso:"
echo "  ~/instalar_bank_docker.sh host     # network_mode: host (padrao)"
echo "  ~/instalar_bank_docker.sh bridge   # bridge + host.docker.internal"
echo
echo "Com RUM:"
echo "  SPLUNK_RUM_TOKEN=xxxx ~/instalar_bank_docker.sh host"
echo
echo "=================================================="
echo "Executando script"
~/instalar_bank_docker.sh "$@"
