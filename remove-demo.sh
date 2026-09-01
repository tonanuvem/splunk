```bash
cat > ~/parar_martian_bank.sh <<'EOF'
#!/bin/bash

set +e

BASE="$HOME/martian-bank-demo"

echo
echo "=================================================="
echo " PARANDO MARTIAN BANK"
echo "=================================================="


# ==================================================
# 1. PARAR MICROSSERVIÇOS PELOS PID
# ==================================================

echo
echo "1. PARANDO MICROSSERVIÇOS"
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

                echo "⚠️ Processo ainda está rodando."
                echo "   Forçando encerramento..."

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
# 2. GARANTIR QUE NÃO SOBRARAM PROCESSOS
# ==================================================

echo
echo "=================================================="
echo "2. VERIFICANDO PROCESSOS RESTANTES"
echo "=================================================="


if [ -d "$BASE" ]; then

    REMAINING=$(ps -ef | grep -E \
        'node|python3' \
        | grep "$BASE" \
        | grep -v grep || true)

    if [ -n "$REMAINING" ]; then

        echo "⚠️ Ainda existem processos relacionados ao Martian Bank:"
        echo
        echo "$REMAINING"

        echo
        echo "🛑 Encerrando processos restantes..."

        echo "$REMAINING" \
            | awk '{print $2}' \
            | xargs -r kill -9 2>/dev/null

        echo "✅ Processos restantes encerrados."

    else

        echo "✅ Nenhum processo do Martian Bank restante."

    fi

fi


# ==================================================
# 3. PARAR MONGODB
# ==================================================

echo
echo "=================================================="
echo "3. PARANDO MONGODB"
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
# 4. STATUS FINAL
# ==================================================

echo
echo "=================================================="
echo "4. STATUS FINAL"
echo "=================================================="


echo
echo "Processos Martian Bank:"

if ps -ef | grep -E 'node|python3' \
    | grep "$BASE" \
    | grep -v grep >/dev/null 2>&1; then

    echo "⚠️ Ainda existem processos."

    ps -ef | grep -E 'node|python3' \
        | grep "$BASE" \
        | grep -v grep

else

    echo "✅ Nenhum processo rodando."

fi


echo
echo "MongoDB:"

if docker ps --format '{{.Names}}' \
    | grep -qx "martian-mongodb"; then

    echo "⚠️ MongoDB ainda está rodando."

else

    echo "✅ MongoDB parado."

fi


# ==================================================
# 5. PORTAS
# ==================================================

echo
echo "=================================================="
echo "5. PORTAS"
echo "=================================================="


echo
echo "Portas relacionadas ao Martian Bank:"

sudo ss -lntp 2>/dev/null \
    | grep -E ':3000|:5000|:8000|:8001|:27017' \
    || echo "✅ Nenhuma porta do Martian Bank está LISTEN."


# ==================================================
# FINAL
# ==================================================

echo
echo "=================================================="
echo " MARTIAN BANK PARADO"
echo "=================================================="


echo
echo "Dados do MongoDB foram PRESERVADOS."

echo
echo "Para iniciar novamente:"
echo
echo "~/instalar_martian_bank.sh"

echo
echo "=================================================="

EOF

chmod +x ~/parar_martian_bank.sh

echo
echo "Script criado:"
echo "~/parar_martian_bank.sh"
echo
echo "Executando script"
~/parar_martian_bank.sh
