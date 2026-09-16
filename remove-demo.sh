cat > ~/parar_bank.sh <<'EOF'
#!/bin/bash

set +e

# ==================================================
# MARTIAN BANK - PARAR E LIMPAR
#
# Cobre as DUAS formas de execucao:
#   - local  : processos node/python3 iniciados pelo instalar_bank.sh
#   - docker : containers do compose iniciados pelo instalar_bank_docker.sh
#
# Uso:
#   ~/parar_bank.sh              para tudo (preserva imagens e dados)
#   ~/parar_bank.sh --imagens    tambem remove as imagens martian-bank*
#   ~/parar_bank.sh --dados      tambem remove o MongoDB E OS DADOS
#   ~/parar_bank.sh --imagens --dados
# ==================================================

BASE="$HOME/martian-bank-demo"
BASE_DOCKER="$HOME/martian-bank-demo-docker"

REMOVER_IMAGENS=false
REMOVER_DADOS=false

for ARG in "$@"; do
    case "$ARG" in
        --imagens) REMOVER_IMAGENS=true ;;
        --dados)   REMOVER_DADOS=true ;;
        -h|--help)
            echo "Uso: ~/parar_bank.sh [--imagens] [--dados]"
            echo
            echo "  --imagens   remove tambem as imagens martian-bank*"
            echo "              (o proximo start precisa rebuildar, ~10 min)"
            echo "  --dados     remove o container martian-mongodb E o volume"
            echo "              martian-mongodb-data (APAGA contas e transacoes)"
            exit 0
            ;;
    esac
done

echo
echo "=================================================="
echo " PARANDO MARTIAN BANK"
echo "=================================================="

if [ "$REMOVER_IMAGENS" = "true" ]; then
    echo " + remover imagens martian-bank*"
fi

if [ "$REMOVER_DADOS" = "true" ]; then
    echo " + REMOVER DADOS DO MONGODB (irreversivel)"
fi

if command -v docker >/dev/null 2>&1; then
    TEM_DOCKER=true
else
    TEM_DOCKER=false
    echo
    echo "ℹ️ Docker nao encontrado - as etapas de container serao puladas."
fi


# ==================================================
# 1. PARAR PELOS PID
# ==================================================

echo
echo "1. PARANDO MICROSSERVIÇOS PELOS PID"
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

    PID_FILE="$BASE/$SERVICE.pid"

    if [ -f "$PID_FILE" ]; then

        PID=$(cat "$PID_FILE")

        echo
        echo "🔎 $SERVICE - PID $PID"

        if kill -0 "$PID" 2>/dev/null; then

            echo "🛑 Parando $SERVICE..."

            kill "$PID" 2>/dev/null

            sleep 2

            if kill -0 "$PID" 2>/dev/null; then

                echo "⚠️ Forçando encerramento..."

                kill -9 "$PID" 2>/dev/null

            fi

            echo "✅ $SERVICE parado."

        else

            echo "ℹ️ $SERVICE já estava parado."

        fi

        rm -f "$PID_FILE"

    else

        echo "ℹ️ $SERVICE - PID não encontrado."

    fi

done


# ==================================================
# 2. PARAR PROCESSOS PELO CAMINHO
# ==================================================

echo
echo "=================================================="
echo "2. PROCURANDO PROCESSOS ORFAOS"
echo "=================================================="


pkill -f "$BASE/customer-auth" 2>/dev/null || true
pkill -f "$BASE/atm-locator" 2>/dev/null || true
pkill -f "$BASE/ui" 2>/dev/null || true
pkill -f "$BASE/dashboard" 2>/dev/null || true
pkill -f "$BASE/accounts" 2>/dev/null || true
pkill -f "$BASE/transactions" 2>/dev/null || true
pkill -f "$BASE/loan" 2>/dev/null || true

echo "✅ Processos locais verificados."


# ==================================================
# 3. PARAR A EXECUCAO EM DOCKER
# ==================================================

echo
echo "=================================================="
echo "3. PARANDO A EXECUÇÃO EM DOCKER"
echo "=================================================="


if [ "$TEM_DOCKER" != "true" ]; then

    echo "ℹ️ Docker nao disponivel - etapa pulada."

else

    # --- 3a. pelos arquivos de compose, se o clone existir ---

    echo
    echo "3a. Compose do martian-bank-demo-docker"
    echo "--------------------------------------------------"

    if [ -d "$BASE_DOCKER" ]; then

        for COMPOSE in \
            docker-compose-network-mode-host.yml \
            docker-compose-network-docker-internal.yml \
            docker-compose.yaml
        do

            if [ -f "$BASE_DOCKER/$COMPOSE" ]; then

                echo
                echo "🛑 down: $COMPOSE"

                docker compose -f "$BASE_DOCKER/$COMPOSE" \
                    down --remove-orphans 2>/dev/null \
                    || echo "ℹ️ nada rodando para $COMPOSE"

            fi

        done

    else

        echo "ℹ️ $BASE_DOCKER nao existe."

    fi


    # --- 3b. pelos nomes de projeto (funciona sem o clone) ---

    echo
    echo "3b. Projetos do compose por nome"
    echo "--------------------------------------------------"

    for PROJETO in martianbank-otel-host martianbank-otel-hg
    do

        ATIVOS=$(docker compose -p "$PROJETO" ps -aq 2>/dev/null)

        if [ -n "$ATIVOS" ]; then

            echo
            echo "🛑 down: projeto $PROJETO"

            docker compose -p "$PROJETO" down --remove-orphans 2>/dev/null || true

        else

            echo "ℹ️ projeto $PROJETO - nada a parar."

        fi

    done


    # --- 3c. varredura por imagem martian-bank* ---
    # pega containers criados na mao ou com outro nome de projeto

    echo
    echo "3c. Containers remanescentes (imagem martian-bank*)"
    echo "--------------------------------------------------"

    RESTANTES=$(docker ps -a --format '{{.ID}}|{{.Image}}|{{.Names}}' 2>/dev/null \
        | awk -F'|' '$2 ~ /^martian-bank/ {print $1" "$3}')

    if [ -n "$RESTANTES" ]; then

        echo "$RESTANTES" | while read -r CID CNOME; do

            echo "🛑 removendo container $CNOME"

            docker rm -f "$CID" >/dev/null 2>&1

        done

        echo "✅ Containers removidos."

    else

        echo "ℹ️ Nenhum container martian-bank* restante."

    fi


    # --- 3d. redes criadas pelo compose ---

    echo
    echo "3d. Redes do compose"
    echo "--------------------------------------------------"

    REDES=$(docker network ls --format '{{.Name}}' 2>/dev/null \
        | grep -E '^martianbank-otel-(host|hg)_|bankapp-network$')

    if [ -n "$REDES" ]; then

        for REDE in $REDES; do

            echo "🛑 removendo rede $REDE"

            docker network rm "$REDE" >/dev/null 2>&1 \
                || echo "ℹ️ rede $REDE em uso ou ja removida"

        done

    else

        echo "ℹ️ Nenhuma rede do martian-bank restante."

    fi


    # --- 3e. imagens (somente com --imagens) ---

    echo
    echo "3e. Imagens"
    echo "--------------------------------------------------"

    if [ "$REMOVER_IMAGENS" = "true" ]; then

        IMAGENS=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
            | grep -E '^martian-bank')

        if [ -n "$IMAGENS" ]; then

            for IMG in $IMAGENS; do

                echo "🗑️ removendo imagem $IMG"

                docker rmi "$IMG" >/dev/null 2>&1 \
                    || echo "ℹ️ imagem $IMG em uso"

            done

            echo "✅ Imagens removidas."
            echo "⚠️ O proximo start vai rebuildar tudo (demora alguns minutos)."

        else

            echo "ℹ️ Nenhuma imagem martian-bank* encontrada."

        fi

    else

        QTD=$(docker images --format '{{.Repository}}' 2>/dev/null \
            | grep -cE '^martian-bank')

        echo "💾 $QTD imagem(ns) martian-bank* PRESERVADA(S)."
        echo "   Para remover tambem: ~/parar_bank.sh --imagens"

    fi

fi


# ==================================================
# 4. GARANTIR PORTAS LIVRES
# ==================================================

echo
echo "=================================================="
echo "4. LIBERANDO PORTAS DO MARTIAN BANK"
echo "=================================================="


# 3000 ui | 5000 dashboard | 8000 auth | 8001 atm
# 8080 nginx | 50051-50053 accounts/transactions/loan (modo host)
for PORT in 3000 5000 8000 8001 8080 50051 50052 50053
do

    if sudo ss -lnt 2>/dev/null | grep -q ":$PORT "; then

        echo
        echo "⚠️ Porta $PORT ainda está ocupada."

        echo "🛑 Encerrando processo da porta $PORT..."

        sudo fuser -k "$PORT/tcp" 2>/dev/null || true

        sleep 2

        if sudo ss -lnt 2>/dev/null | grep -q ":$PORT "; then

            echo "⚠️ Porta $PORT ainda ocupada."
            echo "   Forçando encerramento..."

            sudo fuser -k -9 "$PORT/tcp" 2>/dev/null || true

        else

            echo "✅ Porta $PORT liberada."

        fi

    else

        echo "✅ Porta $PORT já estava livre."

    fi

done


# ==================================================
# 5. MONGODB
# ==================================================

echo
echo "=================================================="
echo "5. PARANDO MONGODB"
echo "=================================================="


if [ "$TEM_DOCKER" != "true" ]; then

    echo "ℹ️ Docker nao disponivel - etapa pulada."

elif docker ps -a --format '{{.Names}}' | grep -qx "martian-mongodb"; then

    if docker ps --format '{{.Names}}' | grep -qx "martian-mongodb"; then

        echo "🛑 Parando martian-mongodb..."

        docker stop martian-mongodb

        echo "✅ MongoDB parado."

    else

        echo "ℹ️ MongoDB já estava parado."

    fi

    if [ "$REMOVER_DADOS" = "true" ]; then

        echo
        echo "🗑️ Removendo container e volume do MongoDB..."

        docker rm -f martian-mongodb >/dev/null 2>&1

        docker volume rm martian-mongodb-data >/dev/null 2>&1 \
            && echo "✅ Volume martian-mongodb-data removido." \
            || echo "ℹ️ Volume martian-mongodb-data nao existe ou esta em uso."

        echo "⚠️ Contas, transacoes e emprestimos foram APAGADOS."

    fi

else

    echo "ℹ️ Container martian-mongodb não existe."

fi


# ==================================================
# 6. STATUS DOS PROCESSOS
# ==================================================

echo
echo "=================================================="
echo "6. STATUS FINAL DOS PROCESSOS LOCAIS"
echo "=================================================="


REMAINING=$(ps -ef \
    | grep -E 'martian-bank-demo' \
    | grep -v grep \
    || true)


if [ -n "$REMAINING" ]; then

    echo "⚠️ Ainda existem processos relacionados ao Martian Bank:"
    echo
    echo "$REMAINING"

else

    echo "✅ Nenhum processo do Martian Bank restante."

fi


# ==================================================
# 7. STATUS DOS CONTAINERS
# ==================================================

echo
echo "=================================================="
echo "7. STATUS DOS CONTAINERS"
echo "=================================================="


if [ "$TEM_DOCKER" != "true" ]; then

    echo "ℹ️ Docker nao disponivel."

else

    CONTAINERS=$(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null \
        | grep -E 'martian-bank|martian-mongodb')

    if [ -n "$CONTAINERS" ]; then

        echo "⚠️ Ainda existem containers do Martian Bank rodando:"
        echo
        echo "$CONTAINERS"

    else

        echo "✅ Nenhum container do Martian Bank rodando."

    fi

fi


# ==================================================
# 8. STATUS DAS PORTAS
# ==================================================

echo
echo "=================================================="
echo "8. STATUS DAS PORTAS"
echo "=================================================="


PORTAS=$(sudo ss -lntp 2>/dev/null \
    | grep -E ':3000|:5000|:8000|:8001|:8080|:5005[123]' \
    || true)


if [ -n "$PORTAS" ]; then

    echo "⚠️ Ainda existem portas ocupadas:"
    echo
    echo "$PORTAS"

else

    echo "✅ Portas do Martian Bank estão livres."

fi


# ==================================================
# 9. MONGODB
# ==================================================

echo
echo "=================================================="
echo "9. STATUS MONGODB"
echo "=================================================="


if [ "$TEM_DOCKER" = "true" ] \
    && docker ps --format '{{.Names}}' | grep -qx "martian-mongodb"; then

    echo "⚠️ MongoDB ainda está rodando."

else

    echo "✅ MongoDB parado."

fi


# ==================================================
# FINAL
# ==================================================

echo
echo "=================================================="
echo " MARTIAN BANK PARADO"
echo "=================================================="


echo
echo "✅ Processos locais parados."
echo "✅ Containers e redes do compose removidos."
echo "✅ Portas verificadas."
echo "✅ MongoDB parado."
echo

if [ "$REMOVER_DADOS" = "true" ]; then
    echo "🗑️ Dados do MongoDB REMOVIDOS."
else
    echo "💾 Dados do MongoDB foram PRESERVADOS."
fi

if [ "$REMOVER_IMAGENS" = "true" ]; then
    echo "🗑️ Imagens martian-bank* REMOVIDAS."
else
    echo "💾 Imagens martian-bank* foram PRESERVADAS."
fi


echo
echo "Para iniciar novamente:"
echo
echo "  local:  ~/instalar_bank.sh"
echo "  docker: ~/instalar_bank_docker.sh host"
echo "          ~/instalar_bank_docker.sh bridge"


echo
echo "=================================================="

EOF

chmod +x ~/parar_bank.sh

echo
echo "✅ Script atualizado:"
echo "~/parar_bank.sh"
echo
echo "Uso:"
echo "  ~/parar_bank.sh              para tudo (preserva imagens e dados)"
echo "  ~/parar_bank.sh --imagens    remove tambem as imagens martian-bank*"
echo "  ~/parar_bank.sh --dados      remove tambem o MongoDB e os dados"
echo
echo "Executando script"
~/parar_bank.sh "$@"
