cat > ~/instalar_bank_docker.sh <<'EOF'
#!/bin/bash

set -e

echo "=================================================="
echo " BANK DEMO + SPLUNK (CONTAINERS)"
echo " APM (traces) + LOGS + RUM"
echo "=================================================="

# ==================================================
# CONFIGURACAO
# ==================================================

BASE="$HOME/bank-demo-docker"

REPO="https://github.com/tonanuvem/bank-demo.git"

# Variante de rede: host (padrao) ou bridge
MODE="${1:-host}"

TEST_NAME="Teste"
TEST_EMAIL="teste@teste.com"
TEST_PASSWORD="Teste@123"

DEPLOYMENT_ENV="${DEPLOYMENT_ENV:-lab-fiap}"

# Token de RUM (opcional). Se vazio, o frontend sobe sem RUM.
# Crie em: Settings > Access Tokens > (token) > Authorization Scopes > RUM
#
# Ordem de precedencia: variavel de ambiente > .env da execucao anterior >
# o que o aluno digitar. Esse token e' PUBLICO por natureza (vai embutido na
# pagina que o navegador baixa), entao pode aparecer na tela sem problema --
# ao contrario do SPLUNK_ACCESS_TOKEN, que nunca deve ser exibido.
SPLUNK_RUM_TOKEN="${SPLUNK_RUM_TOKEN:-}"

perguntar_rum() {

    if [ -n "$SPLUNK_RUM_TOKEN" ]; then
        return 0
    fi

    # Reaproveita o da execucao anterior, para reinstalar nao exigir
    # digitar de novo.
    if [ -f "$BASE/.env" ]; then
        SPLUNK_RUM_TOKEN=$(grep -E '^SPLUNK_RUM_TOKEN=' "$BASE/.env" 2>/dev/null \
            | cut -d= -f2- | tr -d '"' | head -1) || true
        if [ -n "$SPLUNK_RUM_TOKEN" ]; then
            echo "ℹ️  RUM: reaproveitando o token da execucao anterior."
            return 0
        fi
    fi

    # Sem terminal (rodando por pipe, cron, CI) nao da' para perguntar:
    # seguir sem RUM e' melhor do que travar a instalacao esperando stdin.
    if [ ! -t 0 ]; then
        echo "ℹ️  RUM: sem terminal interativo, seguindo sem RUM."
        return 0
    fi

    echo
    echo "=================================================="
    echo " TOKEN DE RUM (opcional)"
    echo "=================================================="
    echo
    # echo "O RUM instrumenta o NAVEGADOR: mostra carregamento de pagina,"
    # echo "erros de JavaScript e liga o clique do usuario ao traco do"
    # echo "backend. Sem ele o resto (APM, logs, metricas) funciona igual."
    # echo
    # echo "Onde pegar, no Splunk Observability Cloud:"
    # echo "  Settings > Access Tokens > (seu token) > Authorization Scopes"
    # echo "  e marque RUM. Copie o valor do token."
    echo
    echo "Cole o token abaixo e tecle Enter."
    echo "Para seguir SEM RUM, apenas tecle Enter."
    echo
    printf "  SPLUNK_RUM_TOKEN: "
    read -r SPLUNK_RUM_TOKEN || true

    # Tolera colar "SPLUNK_RUM_TOKEN=xxx" inteiro, aspas e espacos.
    SPLUNK_RUM_TOKEN="${SPLUNK_RUM_TOKEN#SPLUNK_RUM_TOKEN=}"
    SPLUNK_RUM_TOKEN=$(echo "$SPLUNK_RUM_TOKEN" | tr -d '"'"'"' \t\r\n')

    if [ -z "$SPLUNK_RUM_TOKEN" ]; then
        echo
        echo "  Seguindo sem RUM."
        return 0
    fi

    # Nao da' para validar o token de verdade aqui (quem valida e' o
    # navegador do aluno, contra a Splunk). So' avisa se o formato
    # destoar do esperado, sem bloquear.
    if ! echo "$SPLUNK_RUM_TOKEN" | grep -qE '^[A-Za-z0-9_-]{16,}$'; then
        echo
        echo "  ⚠️ Esse valor nao parece um token (esperado: 20+ caracteres,"
        echo "     sem espacos). Vou usar assim mesmo; se o RUM nao aparecer,"
        echo "     confira em Settings > Access Tokens."
    fi

    echo
    echo "  ✅ RUM habilitado (token de ${#SPLUNK_RUM_TOKEN} caracteres)."
}

perguntar_rum

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

# 1. Metricas de container - antes de subir a aplicacao, para o docker_stats
#    ja pegar tudo:
sudo bash ~/splunk/config_docker_otel.sh

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
# Faltava ler a URL: sem isso o teste da secao 5 caia no endpoint padrao do
# Observability (morto) mesmo quando o collector ja apontava para um Splunk
# Enterprise local, e os logs ficavam desligados a toa.
HEC_URL=$(sudo grep -E '^SPLUNK_HEC_URL=' "$COLLECTOR_CONF" | cut -d= -f2- | tr -d '"' || true)

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

ALVO_HEC="${SPLUNK_HEC_URL:-${HEC_URL:-https://ingest.$SPLUNK_REALM.observability.splunkcloud.com/v1/log}}"
TOKEN_HEC="${SPLUNK_HEC_TOKEN:-$HEC_TOKEN}"

echo "Destino configurado no collector:"
echo "  $ALVO_HEC"
echo

if [ -n "$TOKEN_HEC" ]; then

    # Com token da' para provar o caminho inteiro, e nao so' se a URL existe:
    # um "code":0 significa que o Splunk aceitou o evento de verdade.
    RESP_HEC=$(curl -s -k --max-time 15 -X POST "$ALVO_HEC" \
        -H "Authorization: Splunk $TOKEN_HEC" \
        -d '{"event":"teste do instalador do FIAP Bank"}' 2>/dev/null)

    HEC_TESTE=$(curl -s -k -o /dev/null -w "%{http_code}" --max-time 15 -X POST "$ALVO_HEC" \
        -H "Authorization: Splunk $TOKEN_HEC" \
        -d '{"event":"teste do instalador do FIAP Bank"}' 2>/dev/null || echo "000")

else

    RESP_HEC=""
    HEC_TESTE=$(curl -s -k -o /dev/null -w "%{http_code}" --max-time 10 \
        -X POST "$ALVO_HEC" -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "000")

fi

echo "Teste do endpoint de logs: HTTP $HEC_TESTE ${RESP_HEC:+- $RESP_HEC}"

COLLECTOR_CHANGED=false

if echo "$RESP_HEC" | grep -q '"code":0'; then

    echo
    echo "✅ O Splunk ACEITOU o evento de teste."
    echo "   Ligando OTEL_LOGS_EXPORTER=otlp: os logs das apps Python vao"
    echo "   sair com trace_id e span_id, correlacionados com o APM."

    LOGS_EXPORTER="otlp"
    COLLECTOR_CHANGED=false

elif [ "$HEC_TESTE" = "404" ]; then

    echo
    echo "⚠️ Confirmado: este endpoint nao aceita logs."
    echo "   Os traces (APM) NAO sao afetados - usam outro pipeline."
    echo
    echo "   Deixando OTEL_LOGS_EXPORTER=none para evitar que o collector"
    echo "   entre em retry infinito contra um endpoint morto."

    LOGS_EXPORTER="none"

    # NAO mexemos no SPLUNK_HEC_TOKEN. Uma versao anterior deste script o
    # limpava para evitar o retry infinito, mas isso e' desnecessario (com
    # OTEL_LOGS_EXPORTER=none e o log driver fluentd desligado, nada alimenta
    # a pipeline de logs) e arriscado: em algumas versoes do collector o
    # exporter splunk_hec nao valida com o token vazio e o servico nem sobe.
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

    ULTIMO_BKP=$(sudo ls -t "$COLLECTOR_CONF".bkp.* 2>/dev/null | head -1)

    sudo systemctl restart splunk-otel-collector

    sleep 6

    if systemctl is-active --quiet splunk-otel-collector; then

        echo "✅ Collector reiniciado e ativo."

    else

        echo
        echo "❌ O COLLECTOR NAO SUBIU APOS A MUDANCA."
        echo
        echo "Erro reportado:"
        sudo journalctl -u splunk-otel-collector --since "1 minute ago" --no-pager 2>/dev/null \
            | grep -iE "error|invalid|cannot|failed to|required" | tail -5

        if [ -n "$ULTIMO_BKP" ]; then

            echo
            echo "🔙 Revertendo para o backup: $ULTIMO_BKP"

            sudo cp "$ULTIMO_BKP" "$COLLECTOR_CONF"

            sudo systemctl reset-failed splunk-otel-collector 2>/dev/null
            sudo systemctl restart splunk-otel-collector

            sleep 6

            if systemctl is-active --quiet splunk-otel-collector; then
                echo "✅ Collector restaurado e ativo (a mudanca foi desfeita)."
            else
                echo "❌ Nem com o backup o collector sobe. Investigue o agent_config.yaml:"
                echo "   sudo journalctl -u splunk-otel-collector -n 50 --no-pager"
                exit 1
            fi

        else

            echo "⚠️ Nenhum backup encontrado para reverter."
            exit 1

        fi

    fi

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
 * BANK - EC2
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
SPLUNK_RUM_APP_NAME=bank-ui

OTEL_LOGS_EXPORTER=$LOGS_EXPORTER
OTEL_METRICS_EXPORTER=none
SPLUNK_PROFILER_ENABLED=false

DB_URL=mongodb://localhost:27017/martianbank
DB_URL_BRIDGE=mongodb://host.docker.internal:27017/martianbank
ENVFILE

echo "✅ $BASE/.env"

if [ -z "$SPLUNK_RUM_TOKEN" ]; then

    echo
    echo "⚠️ Sem token de RUM: o frontend sobe SEM RUM."
    echo "   Para habilitar depois, rode de novo e cole o token quando"
    echo "   ele perguntar, ou passe direto:"
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

criar_mongodb() {
    docker run -d \
        --name fiap-mongodb \
        --restart unless-stopped \
        -p 27017:27017 \
        -v fiap-mongodb-data:/data/db \
        mongo:7 >/dev/null
}

if docker ps -a --format '{{.Names}}' | grep -qx "fiap-mongodb"; then

    echo "✅ Container fiap-mongodb ja existe."

    if ! docker ps --format '{{.Names}}' | grep -qx "fiap-mongodb"; then
        echo "🚀 Iniciando MongoDB..."
        docker start fiap-mongodb >/dev/null
        sleep 3
    fi

    # "Existe" nao basta: se o container foi criado sem -p 27017:27017, ele
    # sobe, responde a `docker exec` e parece saudavel - mas nenhuma aplicacao
    # alcanca o banco, porque em network_mode: host elas usam localhost:27017.
    # Foi exatamente esse caso que derrubou tudo com
    # "Operation users.findOne() buffering timed out".
    if [ -z "$(docker port fiap-mongodb 27017 2>/dev/null)" ]; then

        echo
        echo "⚠️ O container existe mas NAO publica a porta 27017."
        echo "   Sem isso as aplicacoes nao conseguem conectar."
        echo "🔄 Recriando o container (o volume fiap-mongodb-data e' preservado,"
        echo "   entao os dados continuam)."

        docker rm -f fiap-mongodb >/dev/null 2>&1
        criar_mongodb
        sleep 5

    else

        echo "   porta publicada: $(docker port fiap-mongodb 27017)"

    fi

else

    echo "🚀 Criando MongoDB..."
    criar_mongodb

fi

echo
echo "Aguardando MongoDB..."

MONGO_OK=false

for i in {1..30}; do

    # Testa pelo HOST (localhost:27017), que e' como as aplicacoes conectam.
    # Um `docker exec ... ping` responderia OK mesmo sem a porta publicada.
    if docker exec fiap-mongodb \
        mongosh --quiet \
        --eval 'db.adminCommand("ping").ok' 2>/dev/null \
        | grep -q "1" \
       && (exec 3<>/dev/tcp/localhost/27017) 2>/dev/null; then

        echo "✅ MongoDB esta pronto e acessivel em localhost:27017."
        MONGO_OK=true
        break

    fi

    echo "Aguardando MongoDB... ($i/30)"
    sleep 2

done

if [ "$MONGO_OK" != "true" ]; then

    echo "❌ MongoDB nao respondeu."
    docker logs --tail 50 fiap-mongodb
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

                    echo "ℹ️ Processo $PID nao pertence ao Bank nativo:"
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
# A PARTIR DAQUI: VERIFICACOES
#
# O `set -e` do topo protege a instalacao (clone, build, up), onde falhar no
# meio e' pior do que parar. Mas daqui para baixo sao checagens, e uma delas
# falhando NAO pode derrubar o script: a stack ja esta no ar. Sem isso, um
# simples timeout de curl numa atribuicao (`VAR=$(curl ...)`) encerra tudo em
# silencio, sem nem imprimir o resumo final.
# ==================================================

set +e


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

    # 30s e nao 10s: no primeiro cadastro o Node ainda esta esquentando, o
    # mongoose abre a conexao e o bcrypt gera o hash. Numa EC2 modesta os 10s
    # originais estouravam.
    REGISTER_RESPONSE=$(curl -s \
        --max-time 30 \
        -X POST \
        "http://localhost:8000/api/users/" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$TEST_NAME\",
            \"email\": \"$TEST_EMAIL\",
            \"password\": \"$TEST_PASSWORD\"
        }")
    CURL_RC=$?

    if [ "$CURL_RC" -ne 0 ]; then
        echo
        echo "⚠️ O curl falhou (codigo $CURL_RC)."
        case "$CURL_RC" in
            28) echo "   Timeout: o customer-auth demorou demais para responder." ;;
            7)  echo "   Conexao recusada: o customer-auth nao esta ouvindo na 8000." ;;
        esac
        echo "   Veja: docker compose -f $COMPOSE_FILE logs --tail 30 customer-auth"
        echo "   O usuario pode ser criado depois pela propria tela de cadastro."
    fi

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
    --filter name=fiap-mongodb \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

echo
echo "MongoDB:"
echo "mongodb://localhost:27017/martianbank"


# ==================================================
# FINAL
# ==================================================

echo
echo "=================================================="
echo " BANK INICIADO (CONTAINERS)"
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

# ------------------------------------------------------------
# Onde ver os logs, quando existe um Splunk Enterprise recebendo
# ------------------------------------------------------------

if docker ps --format '{{.Names}}' | grep -qx "splunk-enterprise"; then

    # A porta vem do proprio container, e nao fixa no texto: quem rodou o
    # config_splunk_enterprise.sh com PORTA_WEB= veria a porta errada aqui.
    PORTA_SPLUNK_WEB=$(docker port splunk-enterprise 8000 2>/dev/null | head -1 | sed 's/.*://')

    echo
    echo "--------------------------------------------------"
    echo "LOGS NO SPLUNK ENTERPRISE"
    echo "--------------------------------------------------"
    echo
    echo "  Splunk Web: http://${IP:-<ip-da-ec2>}:${PORTA_SPLUNK_WEB:-8090}"
    echo "  Usuario:    admin"
    echo "  Senha:      Teste@123   (padrao do config_splunk_enterprise.sh)"
    echo
    echo "  Em Search & Reporting, com Time range = Last 24 hours:"
    echo
    echo "    index=main | head 50"
    echo "    index=main sourcetype=otel | head 50"
    echo
    echo "  Filtrando por servico e por ambiente:"
    echo
    echo "    index=main service.name=dashboard"
    echo "    index=main deployment.environment=$DEPLOYMENT_ENV"
    echo
    echo "  Correlacao com o APM - pegue um trace_id no Splunk Observability"
    echo "  e procure a linha de log correspondente aqui:"
    echo
    echo "    index=main trace_id=<cole-o-trace-id>"

    if [ "$LOGS_EXPORTER" = "otlp" ]; then
        echo
        echo "  ✅ O envio de logs esta LIGADO nesta execucao."
    else
        echo
        echo "  ⚠️ O envio de logs esta DESLIGADO (OTEL_LOGS_EXPORTER=$LOGS_EXPORTER)."
        echo "     Veja o motivo na secao 5, no inicio desta saida."
    fi

fi

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
# echo "RUM   > Browser         aplicacao bank-ui"
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
echo "O token de RUM e' perguntado durante a instalacao."
echo "Para passar direto, sem digitar:"
echo "  SPLUNK_RUM_TOKEN=xxxx ~/instalar_bank_docker.sh host"
echo
echo "=================================================="
echo "Executando script"
~/instalar_bank_docker.sh "$@"
