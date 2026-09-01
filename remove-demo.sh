cat > ~/parar_bank.sh <<'EOF'
#!/bin/bash

set +e

BASE="$HOME/martian-bank-demo"

echo
echo "=================================================="
echo " PARANDO MARTIAN BANK"
echo "=================================================="


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


# ==================================================
# 3. GARANTIR PORTAS LIVRES
# ==================================================

echo
echo "=================================================="
echo "3. LIBERANDO PORTAS DO MARTIAN BANK"
echo "=================================================="


for PORT in 3000 5000 8000 8001
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
# 4. MONGODB
# ==================================================

echo
echo "=================================================="
echo "4. PARANDO MONGODB"
echo "=================================================="


if docker ps -a --format '{{.Names}}' \
    | grep -qx "martian-mongodb"; then

    if docker ps --format '{{.Names}}' \
        | grep -qx "martian-mongodb"; then

        echo "🛑 Parando martian-mongodb..."

        docker stop martian-mongodb

        echo "✅ MongoDB parado."

    else

        echo "ℹ️ MongoDB já estava parado."

    fi

else

    echo "ℹ️ Container martian-mongodb não existe."

fi


# ==================================================
# 5. STATUS DOS PROCESSOS
# ==================================================

echo
echo "=================================================="
echo "5. STATUS FINAL DOS PROCESSOS"
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
# 6. STATUS DAS PORTAS
# ==================================================

echo
echo "=================================================="
echo "6. STATUS DAS PORTAS"
echo "=================================================="


PORTAS=$(sudo ss -lntp 2>/dev/null \
    | grep -E ':3000|:5000|:8000|:8001' \
    || true)


if [ -n "$PORTAS" ]; then

    echo "⚠️ Ainda existem portas ocupadas:"
    echo
    echo "$PORTAS"

else

    echo "✅ Portas 3000, 5000, 8000 e 8001 estão livres."

fi


# ==================================================
# 7. MONGODB
# ==================================================

echo
echo "=================================================="
echo "7. STATUS MONGODB"
echo "=================================================="


if docker ps --format '{{.Names}}' \
    | grep -qx "martian-mongodb"; then

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
echo "✅ Serviços parados."
echo "✅ Portas verificadas."
echo "✅ MongoDB parado."
echo
echo "💾 Dados do MongoDB foram PRESERVADOS."


echo
echo "Para iniciar novamente:"
echo
echo "~/instalar_bank.sh"


echo
echo "=================================================="

EOF

chmod +x ~/parar_martian_bank.sh

echo
echo "✅ Script atualizado:"
echo "~/parar_bank.sh"
echo
echo "Executando script"
~/parar_bank.sh
