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
#   ~/carga_locust.sh --duracao 20m        repete os cenarios por 20 minutos e para
#   ~/carga_locust.sh --tempo 180s         cada cenario por 3 minutos (nao e' o total)
#   ~/carga_locust.sh --cenario account    so um cenario
#   ~/carga_locust.sh --continuo           repete ate Ctrl+C
#   ~/carga_locust.sh --web                sobe a UI do locust em :8089 (interativo)
#
# --tempo e' por CENARIO; --duracao e' o total. Com os 5 cenarios e o padrao
# de 60s, uma rodada leva ~5 min, entao --duracao 20m da' cerca de 4 rodadas.
# ==================================================

BASE="$HOME/bank-demo-docker"

USUARIOS=5
TEMPO="60s"
CENARIO="todos"
CONTINUO=false
WEB=false
DURACAO=""

# Aceita 20m, 1h, 90s ou um numero solto (segundos).
converter_tempo() {
    case "$1" in
        *h) echo $(( ${1%h} * 3600 )) ;;
        *m) echo $(( ${1%m} * 60 )) ;;
        *s) echo "${1%s}" ;;
        *)  echo "$1" ;;
    esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        --usuarios) USUARIOS="$2"; shift 2 ;;
        --tempo)    TEMPO="$2";    shift 2 ;;
        --cenario)  CENARIO="$2";  shift 2 ;;
        --duracao)  DURACAO="$2";  shift 2 ;;
        --continuo) CONTINUO=true; shift ;;
        --web)      WEB=true;      shift ;;
        -h|--help)
            echo "Uso: ~/carga_locust.sh [--usuarios N] [--duracao 20m] [--tempo 60s]"
            echo "                        [--cenario auth|atm|account|transaction|loan|todos]"
            echo "                        [--continuo] [--web]"
            echo
            echo "  --duracao  tempo TOTAL: repete os cenarios ate acabar e para sozinho"
            echo "  --tempo    tempo de CADA cenario dentro de uma rodada"
            exit 0 ;;
        *) echo "Opcao desconhecida: $1"; exit 1 ;;
    esac
done


FIM=""
if [ -n "$DURACAO" ]; then
    DUR_S=$(converter_tempo "$DURACAO")
    case "$DUR_S" in
        ''|*[!0-9]*) echo "❌ --duracao invalida: '$DURACAO' (use 20m, 1h ou 1200s)"; exit 1 ;;
    esac
    [ "$DUR_S" -lt 1 ] && { echo "❌ --duracao precisa ser maior que zero."; exit 1; }
    FIM=$(( $(date +%s) + DUR_S ))
    CONTINUO=true
fi

echo "=================================================="
echo " TESTE DE CARGA - FIAP OTEL BANK"
echo "=================================================="
if [ -n "$FIM" ]; then
    echo
    echo "Rodando por $DURACAO, ate as $(date -d "@$FIM" +%H:%M 2>/dev/null || date -r "$FIM" +%H:%M 2>/dev/null)."
    echo "Para antes com Ctrl+C."
fi


# ==================================================
# 1. DESCOBRIR O COMPOSE EM USO
# ==================================================

echo
echo "1. IDENTIFICANDO A EXECUCAO"
echo "=================================================="

if [ ! -d "$BASE" ]; then
    echo "❌ $BASE nao existe."
    echo "   Rode antes: cd ~/splunk && bash run-docker-bank.sh host"
    exit 1
fi

cd "$BASE" || exit 1

PROJETO=$(docker ps --format '{{.Names}}' \
    | grep -oE '^(fiapbank|martianbank)-otel-(host|hg)' \
    | head -1)

if [ -z "$PROJETO" ]; then
    echo "❌ Nenhum container do Martian Bank rodando."
    echo "   Rode antes: cd ~/splunk && bash run-docker-bank.sh host"
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
    local T="$TEMPO"

    # Com prazo definido, encurta o ultimo cenario em vez de estourar o
    # tempo que o instrutor reservou.
    if [ -n "$FIM" ]; then
        local RESTA=$(( FIM - $(date +%s) ))
        [ "$RESTA" -le 0 ] && return 0
        [ "$RESTA" -lt "$(converter_tempo "$TEMPO")" ] && T="${RESTA}s"
    fi

    echo
    echo "--------------------------------------------------"
    echo "▶ $NOME  ($USUARIOS usuarios, $T)"
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
            --run-time "$T" \
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

    if [ -n "$FIM" ] && [ "$(date +%s)" -ge "$FIM" ]; then
        break
    fi

    if [ "$CONTINUO" = "true" ]; then
        echo
        if [ -n "$FIM" ]; then
            RESTA_MIN=$(( (FIM - $(date +%s) + 59) / 60 ))
            echo "=========== RODADA $RODADA - restam ~${RESTA_MIN} min ==========="
        else
            echo "=================== RODADA $RODADA ==================="
        fi
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
if [ -n "$FIM" ]; then
    echo " CARGA FINALIZADA - $RODADA rodada(s) em $DURACAO"
else
    echo " CARGA FINALIZADA"
fi
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
echo "  ~/carga_locust.sh --duracao 20m   repete por 20 min e para sozinho"
echo "  ~/carga_locust.sh --continuo      repete ate Ctrl+C"
echo "  ~/carga_locust.sh --web           UI do locust em :8089"
echo
echo "=================================================="
echo "Executando"
~/carga_locust.sh "$@"
