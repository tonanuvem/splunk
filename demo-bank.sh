cat > ~/instalar_bank.sh <<'EOF'
#!/bin/bash

set -e

echo "=================================================="
echo " MARTIAN BANK DEMO + SPLUNK"
echo " EC2 + CORS + USUARIO DE TESTE"
echo "=================================================="

BASE="$HOME/martian-bank-demo"


# ==================================================
# 1. DOCKER
# ==================================================

echo
echo "1. VERIFICANDO DOCKER"
echo "=================================================="

if ! command -v docker >/dev/null 2>&1; then
    echo "❌ Docker não está instalado."
    exit 1
fi

echo "✅ Docker:"
docker --version


# ==================================================
# 2. NODE.JS
# ==================================================

echo
echo "2. VERIFICANDO NODE.JS"
echo "=================================================="

if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then

    echo "✅ Node.js:"
    node --version

    echo "✅ npm:"
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
    echo "Node.js:"
    node --version

    echo "npm:"
    npm --version

fi


# ==================================================
# 3. PYTHON
# ==================================================

echo
echo "3. VERIFICANDO PYTHON"
echo "=================================================="

if ! command -v python3 >/dev/null 2>&1; then
    echo "❌ Python 3 não está instalado."
    exit 1
fi

echo "✅ Python:"
python3 --version


# ==================================================
# 4. GIT
# ==================================================

echo
echo "4. VERIFICANDO GIT"
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
# 5. MARTIAN BANK
# ==================================================

echo
echo "5. BAIXANDO DEMO BANK"
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


# ==================================================
# 6. FUNÇÃO DE BACKUP
# ==================================================

backup_file() {

    local FILE="$1"

    if [ -f "$FILE" ] && [ ! -f "$FILE.ec2.original" ]; then

        echo "📦 Backup:"
        echo "$FILE"

        cp "$FILE" "$FILE.ec2.original"

    fi

}


# ==================================================
# 7. CONFIGURANDO API URLS DA UI
# ==================================================

echo
echo "7. CONFIGURANDO URLS DA UI PARA EC2"
echo "=================================================="

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

echo "✅ apiUrls.js configurado."


# ==================================================
# 8. VITE
# ==================================================

echo
echo "8. CONFIGURANDO VITE"
echo "=================================================="

VITE_CONFIG="$BASE/ui/vite.config.js"

backup_file "$VITE_CONFIG"

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

echo "✅ Vite configurado:"
echo "   0.0.0.0:3000"


# ==================================================
# 9. CORS FLASK
# ==================================================

echo
echo "9. CONFIGURANDO CORS"
echo "=================================================="


configure_flask_cors() {

    local FILE="$1"

    if [ ! -f "$FILE" ]; then

        echo "⚠️ Arquivo não encontrado:"
        echo "$FILE"

        return

    fi

    echo
    echo "Configurando:"
    echo "$FILE"

    backup_file "$FILE"

    if ! grep -q "from flask_cors import CORS" "$FILE"; then

        sed -i '/from flask import Flask/a from flask_cors import CORS' "$FILE"

    fi

    if ! grep -q "CORS(app)" "$FILE"; then

        sed -i '/app = Flask(__name__)/a CORS(app)' "$FILE"

    fi

    echo "✅ CORS configurado."

}


configure_flask_cors "$BASE/accounts/accounts.py"

configure_flask_cors "$BASE/transactions/transaction.py"

configure_flask_cors "$BASE/loan/loan.py"


# ==================================================
# 10. MONGODB
# ==================================================

echo
echo "10. CRIANDO MONGODB"
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


# ==================================================
# 11. AGUARDANDO MONGODB
# ==================================================

echo
echo "11. AGUARDANDO MONGODB"
echo "=================================================="

MONGO_OK=false

for i in {1..30}; do

    if docker exec martian-mongodb \
        mongosh --quiet \
        --eval 'db.adminCommand("ping").ok' 2>/dev/null \
        | grep -q "1"; then

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


# ==================================================
# 12. .ENV
# ==================================================

echo
echo "12. CONFIGURANDO .ENV"
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

        echo "Configurando:"
        echo "$SERVICE"

        cat > "$BASE/$SERVICE/.env" <<ENV
DB_URL="$DB_URL"
ENV

        echo "✅ $SERVICE/.env"

    else

        echo "⚠️ Diretório não encontrado:"
        echo "$SERVICE"

    fi

done


# ==================================================
# 13. RUN_LOCAL
# ==================================================

echo
echo "13. CONFIGURANDO run_local.sh"
echo "=================================================="

RUN_LOCAL="$BASE/scripts/run_local.sh"

if [ ! -f "$RUN_LOCAL" ]; then

    echo "❌ Arquivo não encontrado:"
    echo "$RUN_LOCAL"

    exit 1

fi


backup_file "$RUN_LOCAL"


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
echo " JAVASCRIPT MICROSERVICES"
echo "=================================================="


run_javascript_microservice() {

    local service_name="$1"
    local service_alias="$2"

    echo
    echo "Running $service_name..."
    echo "=================================================="

    cd "$BASE/$service_name"

    echo "📦 npm install..."

    npm install

    LOG="$BASE/$service_name.log"

    echo "🚀 Iniciando..."

    nohup npm run "$service_alias" > "$LOG" 2>&1 &

    PID=$!

    echo "$PID" > "$BASE/$service_name.pid"

    sleep 3

    if kill -0 "$PID" 2>/dev/null; then

        echo "✅ $service_name está rodando"
        echo "   PID: $PID"
        echo "   LOG: $LOG"

    else

        echo "❌ Falha ao iniciar $service_name"

        echo
        tail -30 "$LOG"

    fi

}


run_javascript_microservice "ui" "ui"

run_javascript_microservice "customer-auth" "auth"

run_javascript_microservice "atm-locator" "atm"


echo
echo "=================================================="
echo " PYTHON MICROSERVICES"
echo "=================================================="


run_python_microservice() {

    local service_name="$1"
    local service_alias="$2"

    echo
    echo "Running $service_name..."
    echo "=================================================="

    cd "$BASE/$service_name"

    echo "🐍 Criando ambiente virtual..."

    rm -rf venv_bankapp

    python3 -m venv venv_bankapp

    source venv_bankapp/bin/activate

    echo "📦 Instalando dependências..."

    pip install -r requirements.txt

    LOG="$BASE/$service_name.log"

    echo "🚀 Iniciando..."

    nohup python3 "$service_alias.py" > "$LOG" 2>&1 &

    PID=$!

    echo "$PID" > "$BASE/$service_name.pid"

    sleep 3

    if kill -0 "$PID" 2>/dev/null; then

        echo "✅ $service_name está rodando"
        echo "   PID: $PID"
        echo "   LOG: $LOG"

    else

        echo "❌ Falha ao iniciar $service_name"

        echo
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


ps -ef | grep -E 'node|python3' | grep "$BASE" | grep -v grep || true


echo
echo "Logs:"
echo "$BASE/*.log"

SCRIPT

chmod +x "$RUN_LOCAL"

echo "✅ run_local.sh configurado."


# ==================================================
# 14. EXECUTAR
# ==================================================

echo
echo "14. INICIANDO MARTIAN BANK"
echo "=================================================="

cd "$BASE/scripts"

./run_local.sh


# ==================================================
# 15. AGUARDAR SERVIÇOS
# ==================================================

echo
echo "15. AGUARDANDO SERVIÇOS"
echo "=================================================="

sleep 8


# ==================================================
# 16. PROCESSOS
# ==================================================

echo
echo "16. PROCESSOS"
echo "=================================================="

ps -ef | grep -E 'node|python3' | grep "$BASE" | grep -v grep || true


# ==================================================
# 17. PORTAS
# ==================================================

echo
echo "17. PORTAS"
echo "=================================================="

sudo ss -lntp 2>/dev/null \
    | grep -E ':3000|:5000|:8000|:8001' \
    || true


# ==================================================
# 18. TESTE DOS SERVIÇOS
# ==================================================

echo
echo "18. TESTANDO SERVIÇOS"
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

        echo "✅ Porta $PORT está LISTEN."

        HTTP_STATUS=$(curl -s \
            -o /dev/null \
            -w "%{http_code}" \
            --max-time 10 \
            "$URL" || true)

        echo "HTTP Status: $HTTP_STATUS"

    else

        echo "❌ Porta $PORT NÃO está LISTEN."

    fi

}


test_service 3000 "UI" "http://localhost:3000"

test_service 8000 "CUSTOMER AUTH" "http://localhost:8000"

test_service 8001 "ATM LOCATOR" "http://localhost:8001"

test_service 5000 "BACKEND PYTHON" "http://localhost:5000"


# ==================================================
# 19. CRIAR USUARIO DE TESTE
# ==================================================

echo
echo "=================================================="
echo "19. CRIANDO USUARIO DE TESTE"
echo "=================================================="


TEST_NAME="Teste"
TEST_EMAIL="teste@teste.com"
TEST_PASSWORD="teste@teste.com"


AUTH_READY=false


echo
echo "Aguardando Customer Auth..."


for i in {1..30}; do

    if curl -s \
        --max-time 3 \
        http://localhost:8000/api/users/ \
        >/dev/null 2>&1; then

        AUTH_READY=true

        break

    fi

    echo "Aguardando Customer Auth... ($i/30)"

    sleep 2

done


if [ "$AUTH_READY" = "true" ]; then

    echo "✅ Customer Auth disponível."


    echo
    echo "Tentando criar usuário..."

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
    echo "$REGISTER_RESPONSE"


    if echo "$REGISTER_RESPONSE" | grep -qiE \
        'already exists|user already|duplicate'; then

        echo
        echo "ℹ️ Usuário já existe."

    elif echo "$REGISTER_RESPONSE" | grep -qiE \
        '"token"|"email"|success|created'; then

        echo
        echo "✅ Usuário criado."

    else

        echo
        echo "⚠️ Não foi possível confirmar o cadastro."

    fi


else

    echo
    echo "❌ Customer Auth não respondeu."

fi


# ==================================================
# 20. VALIDAR LOGIN
# ==================================================

echo
echo "=================================================="
echo "20. VALIDANDO LOGIN"
echo "=================================================="


if [ "$AUTH_READY" = "true" ]; then

    LOGIN_RESPONSE=$(curl -s \
        --max-time 10 \
        -X POST \
        "http://localhost:8000/api/users/auth" \
        -H "Content-Type: application/json" \
        -d "{
            \"email\": \"$TEST_EMAIL\",
            \"password\": \"$TEST_PASSWORD\"
        }")


    echo
    echo "Resposta do login:"

    echo "$LOGIN_RESPONSE" \
        | sed -E 's/"token":"[^"]+"/"token":"***TOKEN OCULTO***"/g'


    LOGIN_TOKEN=$(echo "$LOGIN_RESPONSE" \
        | sed -nE 's/.*"token"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')


    if [ -n "$LOGIN_TOKEN" ]; then

        echo
        echo "✅ LOGIN VALIDADO COM SUCESSO!"

        echo
        echo "Usuário:"
        echo "$TEST_EMAIL"

        echo
        echo "Senha:"
        echo "$TEST_PASSWORD"

        echo
        echo "Token JWT:"
        echo "${LOGIN_TOKEN:0:20}..."

    else

        echo
        echo "❌ LOGIN NÃO VALIDADO."

        echo
        echo "Verifique o log:"
        echo "tail -50 $BASE/customer-auth.log"

    fi

fi


# ==================================================
# 21. IP PUBLICO
# ==================================================

echo
echo "=================================================="
echo "21. URL DA MARTIAN BANK"
echo "=================================================="


IP=$(curl -s checkip.amazonaws.com || true)


if [ -n "$IP" ]; then

    echo
    echo "🌐 IP público da EC2:"
    echo "$IP"

    echo
    echo "🚀 ACESSE NO NAVEGADOR:"
    echo
    echo "http://$IP:3000"

    echo
    echo "LOGIN DE TESTE:"
    echo
    echo "Usuário: teste@teste.com"
    echo "Senha:   teste@teste.com"

    echo
    echo "APIs:"
    echo
    echo "Customer Auth:"
    echo "http://$IP:8000"

    echo
    echo "ATM Locator:"
    echo "http://$IP:8001"

    echo
    echo "Backend:"
    echo "http://$IP:5000"

else

    echo
    echo "⚠️ Não foi possível obter o IP público."

fi


# ==================================================
# 22. STATUS
# ==================================================

echo
echo "=================================================="
echo "22. STATUS DOS MICROSSERVIÇOS"
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


# ==================================================
# 23. MONGODB
# ==================================================

echo
echo "=================================================="
echo "23. MONGODB"
echo "=================================================="


docker ps \
    --filter name=martian-mongodb \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'


echo
echo "MongoDB:"
echo "mongodb://localhost:27017/martianbank"


# ==================================================
# 24. LOGS
# ==================================================

echo
echo "=================================================="
echo "24. LOGS"
echo "=================================================="


ls -lh "$BASE"/*.log 2>/dev/null || true


# ==================================================
# FINAL
# ==================================================

echo
echo "=================================================="
echo " MARTIAN BANK INICIADO"
echo "=================================================="


echo
echo "IMPORTANTE:"
echo
echo "Liberar no Security Group da EC2:"
echo
echo "TCP 3000"
echo "TCP 5000"
echo "TCP 8000"
echo "TCP 8001"


echo
echo "LOGIN DE TESTE:"
echo
echo "Email: teste@teste.com"
echo "Senha: teste@teste.com"


echo
echo "Para acompanhar a UI:"
echo
echo "tail -f $BASE/ui.log"


echo
echo "Para acompanhar Customer Auth:"
echo
echo "tail -f $BASE/customer-auth.log"


echo
echo "=================================================="

EOF

chmod +x ~/instalar_bank.sh

echo
echo "=================================================="
echo " SCRIPT CRIADO"
echo "=================================================="
echo
echo "Execute:"
echo
echo "~/instalar_bank.sh"
echo
