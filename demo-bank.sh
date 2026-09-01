cat > ~/instalar_martian_bank.sh <<'EOF'
#!/bin/bash

set -e

echo "=================================================="
echo " MARTIAN BANK DEMO + SPLUNK"
echo "=================================================="

BASE="$HOME/martian-bank-demo"


echo
echo "1. VERIFICANDO DOCKER"
echo "=================================================="

if ! command -v docker >/dev/null 2>&1; then
    echo "❌ Docker não está instalado."
    exit 1
fi

echo "✅ Docker encontrado:"
docker --version


echo
echo "2. INSTALANDO NODE.JS SE NECESSÁRIO"
echo "=================================================="

if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then

    echo "✅ Node.js já instalado:"
    node --version

    echo "✅ npm já instalado:"
    npm --version

else

    echo "⚠️ Node.js/npm não encontrados."
    echo "🚀 Instalando Node.js 20 LTS..."

    if command -v dnf >/dev/null 2>&1; then

        curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
        sudo dnf install -y nodejs

    elif command -v yum >/dev/null 2>&1; then

        curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
        sudo yum install -y nodejs

    elif command -v apt-get >/dev/null 2>&1; then

        curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
        sudo apt-get install -y nodejs

    else
        echo "❌ Sistema operacional não suportado."
        exit 1
    fi

    echo
    echo "Node instalado:"
    node --version

    echo "npm instalado:"
    npm --version

fi


echo
echo "3. VERIFICANDO PYTHON"
echo "=================================================="

if ! command -v python3 >/dev/null 2>&1; then
    echo "❌ Python 3 não está instalado."
    exit 1
fi

echo "✅ Python:"
python3 --version


echo
echo "4. BAIXANDO MARTIAN BANK"
echo "=================================================="

if [ ! -d "$BASE/.git" ]; then

    echo "🚀 Clonando repositório..."

    git clone https://github.com/cisco-open/martian-bank-demo.git "$BASE"

else

    echo "✅ Repositório já existe:"
    echo "$BASE"

    cd "$BASE"

    echo "🔄 Atualizando repositório..."

    git pull --ff-only || true

fi

cd "$BASE"


echo
echo "5. CONFIGURANDO UI PARA EC2"
echo "=================================================="

API_URLS="$BASE/ui/src/slices/apiUrls.js"

cat > "$API_URLS" <<'JS'
/*
 * URLs da API para execução em EC2.
 *
 * A UI usa o mesmo hostname/IP utilizado pelo navegador.
 *
 * Exemplo:
 *
 * UI:
 *   http://18.215.161.178:3000
 *
 * APIs:
 *   http://18.215.161.178:8000
 *   http://18.215.161.178:8001
 *   http://18.215.161.178:5000
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

echo "✅ apiUrls.js ajustado para EC2."

echo
echo "URLs configuradas:"
cat "$API_URLS"


echo
echo "6. CONFIGURANDO VITE PARA ACESSO EXTERNO"
echo "=================================================="

VITE_CONFIG="$BASE/ui/vite.config.js"

cat > "$VITE_CONFIG" <<'JS'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],

  server: {
    host: '0.0.0.0',
    port: 3000,
    strictPort: true,
  },

  preview: {
    host: '0.0.0.0',
    port: 3000,
  },
})
JS

echo "✅ Vite configurado para 0.0.0.0:3000."


echo
echo "7. CONFIGURANDO CORS DOS SERVIÇOS FLASK"
echo "=================================================="

for SERVICE_FILE in \
    "$BASE/accounts/accounts.py" \
    "$BASE/transactions/transaction.py" \
    "$BASE/loan/loan.py"
do

    if [ -f "$SERVICE_FILE" ]; then

        echo
        echo "Configurando CORS:"
        echo "$SERVICE_FILE"

        if ! grep -q "from flask_cors import CORS" "$SERVICE_FILE"; then

            sed -i '/from flask import Flask, request, jsonify/a from flask_cors import CORS' "$SERVICE_FILE"

        fi

        if ! grep -q "CORS(app)" "$SERVICE_FILE"; then

            sed -i '/app = Flask(__name__)/a CORS(app)' "$SERVICE_FILE"

        fi

        echo "✅ CORS configurado."

    else

        echo "⚠️ Arquivo não encontrado:"
        echo "$SERVICE_FILE"

    fi

done


echo
echo "8. CRIANDO MONGODB NO DOCKER"
echo "=================================================="

if docker ps -a --format '{{.Names}}' | grep -qx "martian-mongodb"; then

    echo "✅ Container martian-mongodb já existe."

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
echo "9. AGUARDANDO MONGODB"
echo "=================================================="

MONGO_OK=false

for i in {1..30}; do

    if docker exec martian-mongodb \
        mongosh --quiet \
        --eval 'db.adminCommand("ping").ok' 2>/dev/null | grep -q "1"; then

        echo "✅ MongoDB está pronto."

        MONGO_OK=true

        break
    fi

    echo "Aguardando MongoDB... ($i/30)"

    sleep 2

done


if [ "$MONGO_OK" != "true" ]; then

    echo "❌ MongoDB não respondeu."

    docker logs --tail 50 martian-mongodb

    exit 1

fi


echo
echo "10. CONFIGURANDO .ENV DOS MICROSSERVIÇOS"
echo "=================================================="

SERVICES=(
    customer-auth
    atm-locator
    dashboard
    accounts
    loan
    transactions
)

DB_URL="mongodb://localhost:27017/martianbank"

for SERVICE in "${SERVICES[@]}"; do

    if [ -d "$BASE/$SERVICE" ]; then

        echo "Configurando: $SERVICE"

        cat > "$BASE/$SERVICE/.env" <<ENV
DB_URL="$DB_URL"
ENV

    else

        echo "⚠️ Diretório não encontrado: $SERVICE"

    fi

done


echo
echo "11. ALTERANDO run_local.sh PARA LINUX + EC2"
echo "=================================================="

RUN_LOCAL="$BASE/scripts/run_local.sh"

if [ ! -f "$RUN_LOCAL" ]; then

    echo "❌ Arquivo não encontrado:"
    echo "$RUN_LOCAL"

    exit 1

fi


if [ ! -f "$RUN_LOCAL.original" ]; then

    echo "📦 Criando backup do run_local.sh original..."

    cp "$RUN_LOCAL" "$RUN_LOCAL.original"

fi


cat > "$RUN_LOCAL" <<'SCRIPT'
#!/bin/bash

set -e

BASE="$(cd "$(dirname "$0")/.." && pwd)"

cd "$BASE"

echo
echo "=================================================="
echo " MARTIAN BANK - LINUX / EC2"
echo "=================================================="


echo
echo "Node.js: $(node --version)"
echo "npm:     $(npm --version)"
echo "Python:  $(python3 --version)"


echo
echo "=================================================="
echo "Running Javascript microservices"
echo "=================================================="


run_javascript_microservice() {

    local service_name="$1"
    local service_alias="$2"

    echo
    echo "Running $service_name microservice..."
    echo "=================================================="

    cd "$BASE/$service_name"

    echo "📦 npm install..."

    npm install

    LOG="$BASE/$service_name.log"

    echo "🚀 Iniciando $service_name..."

    nohup npm run "$service_alias" > "$LOG" 2>&1 &

    PID=$!

    echo "$PID" > "$BASE/$service_name.pid"

    sleep 3

    if kill -0 "$PID" 2>/dev/null; then

        echo "✅ $service_name is running"
        echo "   PID: $PID"
        echo "   LOG: $LOG"

    else

        echo "❌ Falha ao iniciar $service_name"

        echo
        echo "Últimas linhas do log:"
        tail -30 "$LOG"

    fi

}


run_javascript_microservice "ui" "ui"

run_javascript_microservice "customer-auth" "auth"

run_javascript_microservice "atm-locator" "atm"


echo
echo "=================================================="
echo "Running Python microservices"
echo "=================================================="


run_python_microservice() {

    local service_name="$1"
    local service_alias="$2"

    echo
    echo "Running $service_name microservice..."
    echo "=================================================="

    cd "$BASE/$service_name"

    echo "🐍 Criando ambiente virtual..."

    rm -rf venv_bankapp

    python3 -m venv venv_bankapp

    source venv_bankapp/bin/activate

    echo "📦 Instalando dependências..."

    pip install -r requirements.txt

    LOG="$BASE/$service_name.log"

    echo "🚀 Iniciando $service_name..."

    nohup python3 "$service_alias.py" > "$LOG" 2>&1 &

    PID=$!

    echo "$PID" > "$BASE/$service_name.pid"

    sleep 3

    if kill -0 "$PID" 2>/dev/null; then

        echo "✅ $service_name is running"
        echo "   PID: $PID"
        echo "   LOG: $LOG"

    else

        echo "❌ Falha ao iniciar $service_name"

        echo
        echo "Últimas linhas do log:"
        tail -30 "$LOG"

    fi

    deactivate

}


run_python_microservice "dashboard" "dashboard"

run_python_microservice "accounts" "accounts"

run_python_microservice "transactions" "transaction"

run_python_microservice "loan" "loan"


echo
echo "=================================================="
echo " MARTIAN BANK - STARTUP FINALIZADO"
echo "=================================================="


echo
echo "Processos iniciados:"
echo

ps -ef | grep -E 'node|python3' | grep "$BASE" | grep -v grep || true


echo
echo "Logs disponíveis em:"
echo "$BASE/*.log"

SCRIPT

chmod +x "$RUN_LOCAL"

echo "✅ run_local.sh foi adaptado para Linux/EC2."


echo
echo "12. CONFERINDO .ENV"
echo "=================================================="

for SERVICE in "${SERVICES[@]}"; do

    if [ -f "$BASE/$SERVICE/.env" ]; then

        echo "✅ $SERVICE/.env"

    else

        echo "❌ $SERVICE/.env NÃO ENCONTRADO"

    fi

done


echo
echo "13. EXECUTANDO MARTIAN BANK"
echo "=================================================="

cd "$BASE/scripts"

chmod +x run_local.sh

echo
echo "🚀 Executando:"
echo "./run_local.sh"
echo

./run_local.sh


echo
echo "=================================================="
echo "14. AGUARDANDO SERVIÇOS"
echo "=================================================="

sleep 5


echo
echo "=================================================="
echo "15. VERIFICANDO PROCESSOS"
echo "=================================================="

ps -ef | grep -E 'node|python3' | grep "$BASE" | grep -v grep || true


echo
echo "=================================================="
echo "16. PORTAS"
echo "=================================================="

echo
echo "Portas TCP abertas:"

sudo ss -lntp 2>/dev/null | grep -E ':3000|:8000|:8001|:5000' || true


echo
echo "=================================================="
echo "17. TESTANDO SERVIÇOS LOCALMENTE"
echo "=================================================="


test_port() {

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

        echo "✅ Porta $PORT está LISTEN."

        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
            --max-time 10 \
            "$URL" || true)

        echo "HTTP Status: $HTTP_STATUS"

    else

        echo "❌ Porta $PORT NÃO está LISTEN."

    fi

}


test_port 3000 "UI" "http://localhost:3000"

test_port 8000 "CUSTOMER AUTH" "http://localhost:8000"

test_port 8001 "ATM LOCATOR" "http://localhost:8001"

test_port 5000 "ACCOUNTS / TRANSACTIONS / LOAN" "http://localhost:5000"


echo
echo "=================================================="
echo "18. LOG DA UI"
echo "=================================================="

if [ -f "$BASE/ui.log" ]; then

    echo "Últimas 30 linhas:"
    echo

    tail -30 "$BASE/ui.log"

else

    echo "⚠️ ui.log não encontrado."

fi


echo
echo "=================================================="
echo "19. STATUS DOS MICROSSERVIÇOS"
echo "=================================================="

for SERVICE in \
    ui \
    customer-auth \
    atm-locator \
    dashboard \
    accounts \
    transactions \
    loan
do

    if [ -f "$BASE/$SERVICE.pid" ]; then

        PID=$(cat "$BASE/$SERVICE.pid")

        if kill -0 "$PID" 2>/dev/null; then

            echo "✅ $SERVICE - PID $PID - RUNNING"

        else

            echo "❌ $SERVICE - PID $PID - PARADO"

        fi

    else

        echo "⚠️ $SERVICE - PID não encontrado"

    fi

done


echo
echo "=================================================="
echo "20. URL DA MARTIAN BANK"
echo "=================================================="


IP=$(curl -s --max-time 5 \
    http://169.254.169.254/latest/meta-data/public-ipv4 || true)


if [ -n "$IP" ]; then

    echo
    echo "🌐 IP público da EC2:"
    echo "$IP"

    echo
    echo "🚀 ACESSE NO NAVEGADOR:"
    echo
    echo "http://$IP:3000"

    echo
    echo "APIs:"
    echo
    echo "Customer Auth:"
    echo "http://$IP:8000"

    echo
    echo "ATM Locator:"
    echo "http://$IP:8001"

    echo
    echo "Accounts / Transactions / Loan:"
    echo "http://$IP:5000"

else

    echo "⚠️ Não foi possível obter o IP público da EC2."

    echo
    echo "Use:"
    echo
    echo "http://IP_PUBLICO_DA_EC2:3000"

fi


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


echo
echo "=================================================="
echo "22. LOGS DOS SERVIÇOS"
echo "=================================================="

echo
echo "Arquivos de log:"

ls -lh "$BASE"/*.log 2>/dev/null || true


echo
echo "=================================================="
echo " MARTIAN BANK INICIADO"
echo "=================================================="


echo
echo "IMPORTANTE:"
echo
echo "Libere no Security Group da EC2:"
echo
echo "TCP 3000"
echo "TCP 5000"
echo "TCP 8000"
echo "TCP 8001"
echo
echo "Depois acesse:"
echo
echo "http://IP_PUBLICO_DA_EC2:3000"


echo
echo "Para acompanhar a UI:"
echo
echo "tail -f $BASE/ui.log"


echo
echo "Para acompanhar todos os logs:"
echo
echo "tail -f $BASE/*.log"


echo
echo "=================================================="

EOF

chmod +x ~/instalar_martian_bank.sh

echo
echo "=================================================="
echo " SCRIPT CRIADO"
echo "=================================================="

echo
echo "Execute:"
echo
echo "./instalar_martian_bank.sh"
echo
