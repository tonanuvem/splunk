```bash
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
echo "5. CRIANDO MONGODB NO DOCKER"
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
echo "6. AGUARDANDO MONGODB"
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
echo "7. CONFIGURANDO .ENV DOS MICROSSERVIÇOS"
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
echo "8. ALTERANDO run_local.sh PARA LINUX"
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
echo " MARTIAN BANK - LINUX"
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

echo "✅ run_local.sh foi adaptado para Linux."


echo
echo "9. CONFERINDO .ENV"
echo "=================================================="

for SERVICE in "${SERVICES[@]}"; do

    if [ -f "$BASE/$SERVICE/.env" ]; then

        echo "✅ $SERVICE/.env"

    else

        echo "❌ $SERVICE/.env NÃO ENCONTRADO"

    fi

done


echo
echo "10. EXECUTANDO MARTIAN BANK"
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
echo "11. AGUARDANDO SERVIÇOS"
echo "=================================================="

sleep 5


echo
echo "=================================================="
echo "12. VERIFICANDO PROCESSOS"
echo "=================================================="

ps -ef | grep -E 'node|python3' | grep "$BASE" | grep -v grep || true


echo
echo "=================================================="
echo "13. VERIFICANDO PORTA 3000"
echo "=================================================="

if sudo ss -lntp 2>/dev/null | grep -q ':3000'; then

    echo "✅ Porta 3000 está em LISTEN."

    sudo ss -lntp | grep ':3000'

else

    echo "⚠️ Porta 3000 não está escutando."

fi


echo
echo "=================================================="
echo "14. TESTANDO MARTIAN BANK LOCALMENTE"
echo "=================================================="

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 10 \
    http://localhost:3000 || true)

echo "HTTP Status: $HTTP_STATUS"

if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "304" ]; then

    echo "✅ Martian Bank respondeu corretamente."

elif [ "$HTTP_STATUS" = "000" ]; then

    echo "⚠️ Não foi possível conectar à porta 3000."

else

    echo "⚠️ Aplicação respondeu com HTTP $HTTP_STATUS."

fi


echo
echo "=================================================="
echo "15. LOG DA UI"
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
echo "16. STATUS DOS MICROSSERVIÇOS"
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
echo "17. URL DA MARTIAN BANK"
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

else

    echo "⚠️ Não foi possível obter o IP público da EC2."

    echo
    echo "Use:"
    echo
    echo "http://IP_PUBLICO_DA_EC2:3000"

fi


echo
echo "=================================================="
echo "18. MONGODB"
echo "=================================================="

docker ps \
    --filter name=martian-mongodb \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'


echo
echo "MongoDB:"
echo "mongodb://localhost:27017/martianbank"


echo
echo "=================================================="
echo "19. LOGS DOS SERVIÇOS"
echo "=================================================="

echo
echo "Arquivos de log:"
ls -lh "$BASE"/*.log 2>/dev/null || true


echo
echo "=================================================="
echo " MARTIAN BANK INICIADO"
echo "=================================================="

echo
echo "Se a porta 3000 estiver liberada no Security Group,"
echo "acesse a URL exibida acima pelo navegador."

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
```
