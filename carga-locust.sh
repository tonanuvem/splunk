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
DETALHE=false
REBUILD=false
CENARIO_N=0
CENARIO_TOT=1

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
        --detalhe)  DETALHE=true;  shift ;;
        --rebuild)  REBUILD=true;  shift ;;
        --web)      WEB=true;      shift ;;
        -h|--help)
            echo "Uso: ~/carga_locust.sh [--usuarios N] [--duracao 20m] [--tempo 60s]"
            echo "                        [--cenario auth|atm|account|transaction|loan|todos]"
            echo "                        [--continuo] [--web]"
            echo
            echo "  --duracao  tempo TOTAL: repete os cenarios ate acabar e para sozinho"
            echo "  --tempo    tempo de CADA cenario dentro de uma rodada"
            echo "  --detalhe  mostra a saida completa do locust, nao so' o resumo"
            echo "  --rebuild  forca reconstruir a imagem do locust"
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
echo "2. ROTAS EXERCITADAS E AS JORNADAS DE NEGOCIO"
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

# So' as rotas que sao jornada do exercicio. Os cenarios batem em outras
# (cadastro, perfil, logout, consulta de contas, Zelle), mas listar tudo
# afogava justamente o que o aluno precisa achar. Os numeros sao os dos grupos.
rotas_do_cenario() {
    case "$1" in
    auth)
        echo "AUTENTICACAO    $U_USERS   (customer-auth)"
        echo "   POST /api/users/auth         [1] AUTENTICACAO" ;;
    account)
        echo "CONTAS          $U_ACCOUNTS   (dashboard -> accounts)"
        echo "   POST /account/create         [2] ABRIR CONTA" ;;
    transaction)
        echo "TRANSFERENCIAS  $U_TRANSFER   (dashboard -> transactions)"
        echo "   POST /transaction/           [3] TRANSFERIR"
        echo "   POST /transaction/history    [4] EXTRATO" ;;
    loan)
        echo "EMPRESTIMOS     $U_LOAN   (dashboard -> loan)"
        echo "   POST /loan/                  [5] SOLICITAR EMPRESTIMO" ;;
    atm)
        echo "CAIXAS          $U_ATM   (atm-locator)"
        echo "   POST /api/atm/               [6] LOCALIZAR CAIXAS" ;;
    esac
}

if [ "$CENARIO" = "todos" ]; then
    for C in auth account transaction loan atm; do
        echo; rotas_do_cenario "$C"
    done
else
    echo
    rotas_do_cenario "$CENARIO"
fi


# ==================================================
# 3. GARANTIR O CONTAINER DO LOCUST
# ==================================================

echo
echo "3. PREPARANDO O LOCUST"
echo "=================================================="

LOCUST_CT="${PROJETO}-locust-1"
LOCUST_IMG="fiap-bank-locust"

# Os locustfiles sao COPIADOS para dentro da imagem, sem volume. Editar um
# cenario no repositorio nao muda nada enquanto a imagem nao for refeita --
# e o container antigo segue rodando o codigo velho, silenciosamente.
cenarios_mais_novos_que_a_imagem() {
    local DIR="$BASE/performance_locust"
    [ -d "$DIR" ] || return 1

    local CRIADA FONTE
    CRIADA=$(docker image inspect -f '{{.Created}}' "$LOCUST_IMG" 2>/dev/null)
    [ -z "$CRIADA" ] && return 1          # imagem nao existe: o up ja constroi

    CRIADA=$(date -d "$CRIADA" +%s 2>/dev/null) || return 1
    FONTE=$(find "$DIR" -type f -name '*.py' -printf '%T@\n' 2>/dev/null \
            | sort -rn | head -1 | cut -d. -f1)
    [ -z "$FONTE" ] && return 1

    [ "$FONTE" -gt "$CRIADA" ]
}

# O rebuild compara a imagem com os arquivos LOCAIS. Se o repositorio da
# aplicacao estiver atrasado, o cenario corrigido no GitHub nao esta' aqui, e
# nada parece desatualizado -- o container roda o codigo velho e ninguem ve.
if [ -d "$BASE/.git" ]; then
    if git -C "$BASE" fetch -q origin 2>/dev/null; then
        ATRAS=$(git -C "$BASE" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
        if [ "${ATRAS:-0}" -gt 0 ]; then
            echo "⚠️  $BASE esta $ATRAS commit(s) atras do origin/main."
            echo "    Os cenarios de carga vem DESTE diretorio, nao do GitHub."
            echo "    Atualize antes de confiar nos numeros:"
            echo "      git -C $BASE pull"
            echo
        fi
    fi
fi

if [ "$REBUILD" = "true" ] || cenarios_mais_novos_que_a_imagem; then
    echo "♻️  Cenarios mudaram desde o build - reconstruindo a imagem..."
    docker compose -f "$COMPOSE_FILE" --profile load build locust \
        && docker rm -f "$LOCUST_CT" >/dev/null 2>&1
fi

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

    CENARIO_N=$((CENARIO_N + 1))

    # Com prazo, o progresso e' do tempo total; sem prazo, e' a posicao do
    # cenario na rodada -- que e' a unica nocao de "quanto falta" que existe.
    local PROG
    if [ -n "$FIM" ]; then
        local DECORRIDO=$(( $(date +%s) - (FIM - DUR_S) ))
        local PCT=$(( DECORRIDO * 100 / DUR_S ))
        [ "$PCT" -gt 100 ] && PCT=100
        PROG=$(printf "[%3d%%]" "$PCT")
    else
        PROG=$(printf "[%d/%d]" "$CENARIO_N" "$CENARIO_TOT")
    fi

    echo
    echo "$PROG ▶ $NOME  ·  $USUARIOS usuarios, $T"

    # O locust so' imprime no fim. Sem isso o terminal fica parado 60s por
    # cenario e parece travado. Roda em segundo plano e mostra o andamento.
    local SAIDA TMP PID DUR DECOR PCT
    TMP=$(mktemp)

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
        >"$TMP" 2>&1 &
    PID=$!

    DUR=$(converter_tempo "$T")
    case "$DUR" in ''|*[!0-9]*) DUR=60 ;; esac
    [ "$DUR" -lt 1 ] && DUR=1

    # Fora de um terminal (saida redirecionada, pipe, CI) o \r viraria lixo
    # no arquivo; nesse caso apenas espera em silencio.
    if [ -t 1 ]; then
        # Barra em ASCII de proposito: o bash fatia ${var:0:n} por BYTES, e um
        # bloco unicode tem 3 -- cortava no meio do caractere e desalinhava.
        local INICIO_CEN CHEIO VAZIO N
        INICIO_CEN=$(date +%s)
        CHEIO="####################"
        VAZIO="                    "
        while kill -0 "$PID" 2>/dev/null; do
            DECOR=$(( $(date +%s) - INICIO_CEN ))
            PCT=$(( DECOR * 100 / DUR ))
            [ "$PCT" -gt 100 ] && PCT=100
            N=$(( PCT / 5 ))
            printf '\r   [%s%s] %3d%%   %ss de %ss ' \
                   "${CHEIO:0:$N}" "${VAZIO:0:$(( 20 - N ))}" "$PCT" "$DECOR" "$DUR"
            sleep 2
        done
        printf '\r%-60s\r' " "
    fi

    wait "$PID" 2>/dev/null
    SAIDA=$(cat "$TMP")
    rm -f "$TMP"

    if [ "$DETALHE" = "true" ]; then
        echo "$SAIDA" | grep -vE "^\[|Starting|Shutting|Cleaning|spawn rate|All users"
        return 0
    fi

    resumir "$SAIDA"
}


# O locust imprime duas tabelas por cenario, uma por endpoint. Numa rodada de
# cinco cenarios isso enche a tela e esconde justamente o que interessa. Aqui
# fica so' a linha Aggregated das duas, condensada.
resumir() {

    local SAIDA="$1"
    local AGREGADOS RESUMO PERCENTIS

    AGREGADOS=$(echo "$SAIDA" | grep -E "^[[:space:]]*Aggregated")
    RESUMO=$(echo "$AGREGADOS" | head -1)
    PERCENTIS=$(echo "$AGREGADOS" | tail -1)

    if [ -z "$RESUMO" ]; then
        echo "   (sem estatisticas - o locust nao chegou a rodar)"
        echo "$SAIDA" | grep -iE "error|refused|timeout" | head -3 | sed 's/^/   /'
        return 0
    fi

    # Aggregated  <reqs>  <fails>(<pct>) | <avg> <min> <max> <med> | <req/s> <fail/s>
    local REQS FAILS AVG MAX MED RPS P95
    REQS=$(echo "$RESUMO"    | awk '{print $2}')
    FAILS=$(echo "$RESUMO"   | awk '{print $3}')
    AVG=$(echo "$RESUMO"     | awk '{print $5}')
    MAX=$(echo "$RESUMO"     | awk '{print $7}')
    MED=$(echo "$RESUMO"     | awk '{print $8}')
    RPS=$(echo "$RESUMO"     | awk '{print $10}')
    # na tabela de percentis: 50 66 75 80 90 95 ... -> p95 e' o sexto valor
    [ "$PERCENTIS" != "$RESUMO" ] && P95=$(echo "$PERCENTIS" | awk '{print $7}')

    local ALERTA=""
    case "$FAILS" in
        0|0\(*) : ;;
        *) ALERTA="  ⚠️" ;;
    esac

    echo "   ${REQS} req · ${FAILS} falhas · ${RPS} req/s · med ${MED}ms · p95 ${P95:-?}ms · max ${MAX}ms${ALERTA}"
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

case "$CENARIO" in
    todos) CENARIO_TOT=5 ;;
    *)     CENARIO_TOT=1 ;;
esac

RODADA=1

while true; do

    CENARIO_N=0

    if [ -n "$FIM" ] && [ "$(date +%s)" -ge "$FIM" ]; then
        break
    fi

    if [ "$CONTINUO" = "true" ]; then
        echo
        if [ -n "$FIM" ]; then
            RESTA=$(( FIM - $(date +%s) ))
            if [ "$RESTA" -ge 60 ]; then
                echo "--- RODADA $RODADA · restam ~$(( RESTA / 60 )) min ---"
            else
                echo "--- RODADA $RODADA · restam ${RESTA}s ---"
            fi
        else
            echo "--- RODADA $RODADA ---"
        fi
    fi

    case "$CENARIO" in
        auth)        executar auth_locust.py        "[1] AUTENTICACAO (customer-auth)" ;;
        atm)         executar atm_locust.py         "[6] CAIXAS ELETRONICOS (atm-locator)" ;;
        account)     executar account_locust.py     "[2] CONTAS (dashboard -> accounts)" ;;
        transaction) executar transaction_locust.py "[3][4] TRANSFERENCIAS (dashboard -> transactions)" ;;
        loan)        executar loan_locust.py        "[5] EMPRESTIMOS (dashboard -> loan)" ;;
        todos)
            # Mesma ordem do item 2, que e' a numeracao dos grupos.
            executar auth_locust.py        "[1] AUTENTICACAO (customer-auth)"
            executar account_locust.py     "[2] CONTAS (dashboard -> accounts)"
            executar transaction_locust.py "[3][4] TRANSFERENCIAS (dashboard -> transactions)"
            executar loan_locust.py        "[5] EMPRESTIMOS (dashboard -> loan)"
            executar atm_locust.py         "[6] CAIXAS ELETRONICOS (atm-locator)"
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
# echo "monte os graficos com o SignalFlow do repositorio."
echo
echo "=================================================="

EOF

chmod +x ~/carga_locust.sh

echo
echo "=================================================="
echo " SCRIPT DE CARGA CRIADO"
echo "=================================================="
echo
# echo "~/carga_locust.sh"
# echo
# echo "  ~/carga_locust.sh                 todos os cenarios, 5 usuarios, 60s cada"
# echo "  ~/carga_locust.sh --usuarios 20   mais carga"
# echo "  ~/carga_locust.sh --duracao 20m   repete por 20 min e para sozinho"
# echo "  ~/carga_locust.sh --continuo      repete ate Ctrl+C"
# echo "  ~/carga_locust.sh --web           UI do locust em :8089"
# echo
# echo "=================================================="
echo "Executando"
~/carga_locust.sh "$@"
