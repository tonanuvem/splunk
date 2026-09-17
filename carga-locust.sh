cat > ~/carga_locust.sh <<'EOF'
#!/bin/bash

set +e

# ==================================================
# TESTE DE CARGA COM LOCUST
#
# Por que um script: a imagem do locust sobe com ENTRYPOINT "sleep infinity",
# entao `compose up locust` apenas cria o container - o locust nao roda.
# E' preciso executa-lo DENTRO do container, e apontando as URLs certas,
# que mudam conforme a variante de rede.
#
# Uso:
#   ~/carga_locust.sh                      todos os cenarios, 5 usuarios, 60s cada
#   ~/carga_locust.sh --usuarios 20        mais carga
#   ~/carga_locust.sh --tempo 180s         cada cenario por 3 minutos
#   ~/carga_locust.sh --cenario account    so um cenario
#   ~/carga_locust.sh --continuo           repete ate Ctrl+C (bom p/ deixar rodando na aula)
#   ~/carga_locust.sh --web                sobe a UI do locust em :8089 (interativo)
# ==================================================

BASE="$HOME/martian-bank-demo-docker"

USUARIOS=5
TEMPO="60s"
CENARIO="todos"
CONTINUO=false
WEB=false

while [ $# -gt 0 ]; do
    case "$1" in
        --usuarios) USUARIOS="$2"; shift 2 ;;
        --tempo)    TEMPO="$2";    shift 2 ;;
        --cenario)  CENARIO="$2";  shift 2 ;;
        --continuo) CONTINUO=true; shift ;;
        --web)      WEB=true;      shift ;;
        -h|--help)
            echo "Uso: ~/carga_locust.sh [--usuarios N] [--tempo 60s] [--cenario auth|atm|account|transaction|loan|todos] [--continuo] [--web]"
            exit 0 ;;
        *) echo "Opcao desconhecida: $1"; exit 1 ;;
    esac
done


echo "=================================================="
echo " TESTE DE CARGA - MARTIAN BANK"
echo "=================================================="


# ==================================================
# 1. DESCOBRIR O COMPOSE EM USO
# ==================================================

echo
echo "1. IDENTIFICANDO A EXECUCAO"
echo "=================================================="

if [ ! -d "$BASE" ]; then
    echo "❌ $BASE nao existe. Rode antes: ~/instalar_bank_docker.sh host"
    exit 1
fi

cd "$BASE" || exit 1

PROJETO=$(docker ps --format '{{.Names}}' \
    | grep -oE '^(fiapbank|martianbank)-otel-(host|hg)' \
    | head -1)

if [ -z "$PROJETO" ]; then
    echo "❌ Nenhum container do Martian Bank rodando."
    echo "   Rode antes: ~/instalar_bank_docker.sh host"
    exit 1
fi

case "$PROJETO" in
    *-host) MODO="host";   COMPOSE_FILE="docker-compose-network-mode-host.yml" ;;
    *-hg)   MODO="bridge"; COMPOSE_FILE="docker-compose-network-docker-internal.yml" ;;
esac

echo "✅ Projeto:  $PROJETO"
echo "   Modo:     $MODO"
echo "   Compose:  $COMPOSE_FILE"


# ==================================================
# 2. URLS DE DESTINO
# ==================================================

echo
echo "2. DEFININDO AS URLS"
echo "=================================================="

# Os locustfiles leem estas variaveis de api_urls.py. Em modo host o container
# compartilha a rede da EC2, entao localhost resolve; em bridge e' preciso usar
# os nomes de servico do compose.
if [ "$MODO" = "host" ]; then

    U_ACCOUNTS="http://localhost:5000/account"
    U_USERS="http://localhost:8000/api/users"
    U_ATM="http://localhost:8001/api/atm"
    U_TRANSFER="http://localhost:5000/transaction"
    U_LOAN="http://localhost:5000/loan"

else

    U_ACCOUNTS="http://dashboard:5000/account"
    U_USERS="http://customer-auth:8000/api/users"
    U_ATM="http://atm-locator:8001/api/atm"
    U_TRANSFER="http://dashboard:5000/transaction"
    U_LOAN="http://dashboard:5000/loan"

fi

echo "   accounts:     $U_ACCOUNTS"
echo "   users:        $U_USERS"
echo "   atm:          $U_ATM"


# ==================================================
# 3. GARANTIR O CONTAINER DO LOCUST
# ==================================================

echo
echo "3. PREPARANDO O LOCUST"
echo "=================================================="

LOCUST_CT="${PROJETO}-locust-1"

if ! docker ps --format '{{.Names}}' | grep -qx "$LOCUST_CT"; then

    echo "🚀 Subindo o servico locust (profile 'load')..."

    docker compose -f "$COMPOSE_FILE" --profile load up -d locust

    sleep 5

fi

if ! docker ps --format '{{.Names}}' | grep -qx "$LOCUST_CT"; then
    echo "❌ Container $LOCUST_CT nao subiu."
    exit 1
fi

echo "✅ $LOCUST_CT no ar"


# ==================================================
# 4. EXECUCAO
# ==================================================

executar() {

    local ARQ="$1"
    local NOME="$2"

    echo
    echo "--------------------------------------------------"
    echo "▶ $NOME  ($USUARIOS usuarios, $TEMPO)"
    echo "--------------------------------------------------"

    docker exec \
        -e VITE_ACCOUNTS_URL="$U_ACCOUNTS" \
        -e VITE_USERS_URL="$U_USERS" \
        -e VITE_ATM_URL="$U_ATM" \
        -e VITE_TRANSFER_URL="$U_TRANSFER" \
        -e VITE_LOAN_URL="$U_LOAN" \
        "$LOCUST_CT" \
        locust -f "/service/$ARQ" \
            --headless \
            -u "$USUARIOS" \
            -r 1 \
            --run-time "$TEMPO" \
            --only-summary \
        2>&1 | grep -vE "^\[|Starting|Shutting|Cleaning|spawn rate|All users" | tail -20
}


if [ "$WEB" = "true" ]; then

    echo
    echo "=================================================="
    echo "4. MODO WEB (interativo)"
    echo "=================================================="

    IP=$(curl -s --max-time 5 checkip.amazonaws.com | tr -d '[:space:]')

    echo
    echo "Abra no navegador:  http://${IP:-<ip-da-ec2>}:8089"
    echo
    echo "No formulario do locust use como Host:"
    echo "  $U_ACCOUNTS"
    echo
    echo "Ctrl+C aqui encerra o locust."
    echo

    docker exec -it \
        -e VITE_ACCOUNTS_URL="$U_ACCOUNTS" \
        -e VITE_USERS_URL="$U_USERS" \
        -e VITE_ATM_URL="$U_ATM" \
        -e VITE_TRANSFER_URL="$U_TRANSFER" \
        -e VITE_LOAN_URL="$U_LOAN" \
        "$LOCUST_CT" \
        locust -f /service/account_locust.py --web-host 0.0.0.0 --web-port 8089

    exit 0

fi


echo
echo "=================================================="
echo "4. GERANDO CARGA"
echo "=================================================="
echo
echo "Cada cenario exercita um caminho diferente. No APM isso aparece como"
echo "o service map se preenchendo: dashboard no centro, chamando accounts,"
echo "transactions, loan, e os dois servicos Node."

RODADA=1

while true; do

    if [ "$CONTINUO" = "true" ]; then
        echo
        echo "=================== RODADA $RODADA ==================="
    fi

    case "$CENARIO" in
        auth)        executar auth_locust.py        "AUTENTICACAO (customer-auth)" ;;
        atm)         executar atm_locust.py         "CAIXAS ELETRONICOS (atm-locator)" ;;
        account)     executar account_locust.py     "CONTAS (dashboard -> accounts)" ;;
        transaction) executar transaction_locust.py "TRANSFERENCIAS (dashboard -> transactions)" ;;
        loan)        executar loan_locust.py        "EMPRESTIMOS (dashboard -> loan)" ;;
        todos)
            executar auth_locust.py        "AUTENTICACAO (customer-auth)"
            executar atm_locust.py         "CAIXAS ELETRONICOS (atm-locator)"
            executar account_locust.py     "CONTAS (dashboard -> accounts)"
            executar transaction_locust.py "TRANSFERENCIAS (dashboard -> transactions)"
            executar loan_locust.py        "EMPRESTIMOS (dashboard -> loan)"
            ;;
        *)
            echo "❌ Cenario invalido: $CENARIO"
            echo "   Use: auth | atm | account | transaction | loan | todos"
            exit 1 ;;
    esac

    [ "$CONTINUO" != "true" ] && break

    RODADA=$((RODADA + 1))

done


# ==================================================
# FINAL
# ==================================================

echo
echo "=================================================="
echo " CARGA FINALIZADA"
echo "=================================================="
echo
echo "No Splunk, com a janela em -15m ou -1h:"
echo
echo "  APM > Service Map        o encadeamento entre os 6 servicos"
echo "  APM > Services           latencia e taxa de erro por servico"
echo "  Infrastructure > Hosts   CPU/memoria da EC2"
echo
echo "As metricas de container (docker_stats) nao tem dashboard pronto:"
echo "monte os graficos com o SignalFlow do repositorio."
echo
echo "=================================================="

EOF

chmod +x ~/carga_locust.sh

echo
echo "=================================================="
echo " SCRIPT DE CARGA CRIADO"
echo "=================================================="
echo
echo "~/carga_locust.sh"
echo
echo "  ~/carga_locust.sh                 todos os cenarios, 5 usuarios, 60s cada"
echo "  ~/carga_locust.sh --usuarios 20   mais carga"
echo "  ~/carga_locust.sh --continuo      repete ate Ctrl+C"
echo "  ~/carga_locust.sh --web           UI do locust em :8089"
echo
echo "=================================================="
echo "Executando"
~/carga_locust.sh "$@"
