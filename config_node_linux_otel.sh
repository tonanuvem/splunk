#!/bin/bash

set -euo pipefail

# ============================================================
# config_node_otel.sh
#
# Configuração idempotente do Splunk OpenTelemetry para Node.js
# no Martian Bank.
#
# - Remove auto_instrumentation_disabled=nodejs
# - Instala @splunk/otel a partir do pacote oficial .tgz
# - Valida instrument.js
# - Reinicia somente as aplicações Node.js do Martian Bank
# - Não reinicia o Collector
# - Evita mensagens do injector durante a execução
# ============================================================

OTEL_DIR="/usr/lib/splunk-instrumentation"
OTEL_JS_TGZ="$OTEL_DIR/splunk-otel-js.tgz"
OTEL_JS_DIR="$OTEL_DIR/splunk-otel-js"
NODE_AGENT="$OTEL_JS_DIR/node_modules/@splunk/otel/instrument.js"
INJECTOR_CONF="/etc/opentelemetry/injector/injector.conf"

MARTIAN_DIR="/home/ec2-user/martian-bank-demo"

# ------------------------------------------------------------
# Executar comandos administrativos sem o LD_PRELOAD
# ------------------------------------------------------------

SUDO="sudo env LD_PRELOAD="

echo "============================================================"
echo " Splunk OpenTelemetry - Node.js"
echo "============================================================"

# ------------------------------------------------------------
# 1. Validar ambiente
# ------------------------------------------------------------

echo
echo "[1/6] Validando ambiente..."

if [[ ! -d "$MARTIAN_DIR" ]]; then
    echo "ERRO: Martian Bank não encontrado:"
    echo "  $MARTIAN_DIR"
    exit 1
fi

if [[ ! -f "$OTEL_JS_TGZ" ]]; then
    echo "ERRO: pacote Node.js do Splunk não encontrado:"
    echo "  $OTEL_JS_TGZ"
    exit 1
fi

if [[ ! -f "$INJECTOR_CONF" ]]; then
    echo "ERRO: injector.conf não encontrado:"
    echo "  $INJECTOR_CONF"
    exit 1
fi

echo "OK: Martian Bank"
echo "OK: pacote Splunk Node.js"
echo "OK: injector.conf"

# ------------------------------------------------------------
# 2. Remover desativação do Node.js
# ------------------------------------------------------------

echo
echo "[2/6] Habilitando auto-instrumentação Node.js..."

if $SUDO grep -q '^auto_instrumentation_disabled=nodejs$' "$INJECTOR_CONF"; then

    echo "Removendo auto_instrumentation_disabled=nodejs..."

    $SUDO sed -i \
        '/^auto_instrumentation_disabled=nodejs$/d' \
        "$INJECTOR_CONF"

    echo "OK: Node.js não está mais desabilitado."

else

    echo "OK: Node.js já não está desabilitado."

fi

# ------------------------------------------------------------
# 3. Garantir instalação do @splunk/otel
# ------------------------------------------------------------

echo
echo "[3/6] Verificando agente Node.js..."

if [[ -f "$NODE_AGENT" ]]; then

    echo "OK: agente Node.js já instalado:"
    echo "  $NODE_AGENT"

else

    echo "Agente Node.js não encontrado."
    echo "Instalando pacote @splunk/otel..."

    $SUDO mkdir -p "$OTEL_JS_DIR"

    $SUDO npm install \
        --prefix "$OTEL_JS_DIR" \
        "$OTEL_JS_TGZ"

    echo "OK: pacote instalado."

fi

# ------------------------------------------------------------
# 4. Validar instrument.js
# ------------------------------------------------------------

echo
echo "[4/6] Validando instrument.js..."

if ! $SUDO test -f "$NODE_AGENT"; then

    echo "ERRO: instrument.js não foi encontrado após instalação:"
    echo "  $NODE_AGENT"
    exit 1

fi

echo "OK: $NODE_AGENT"

# ------------------------------------------------------------
# 5. Testar carregamento do agente
# ------------------------------------------------------------

echo
echo "[5/6] Testando carregamento do agente Node.js..."

TEST_OUTPUT=$(
    env LD_PRELOAD= \
    node \
      -r "$NODE_AGENT" \
      -e 'console.log("NODE OTEL TEST OK")'
)

if [[ "$TEST_OUTPUT" != *"NODE OTEL TEST OK"* ]]; then

    echo "ERRO: não foi possível carregar o agente Node.js."
    echo
    echo "$TEST_OUTPUT"
    exit 1

fi

echo "OK: $TEST_OUTPUT"

# ------------------------------------------------------------
# 6. Reiniciar aplicações Node.js
# ------------------------------------------------------------

echo
echo "[6/6] Reiniciando aplicações Node.js do Martian Bank..."
echo

# ------------------------------------------------------------
# Identificar processos Node.js do Martian Bank
# ------------------------------------------------------------

PIDS=$(ps -eo pid,args | \
    grep "$MARTIAN_DIR" | \
    grep -E 'node|vite|nodemon' | \
    grep -v grep | \
    awk '{print $1}' || true)

if [[ -n "$PIDS" ]]; then

    echo "Processos encontrados:"
    echo "$PIDS"
    echo

    echo "Encerrando processos Node.js..."

    for PID in $PIDS; do

        if kill -0 "$PID" 2>/dev/null; then
            echo "  STOP PID $PID"
            kill "$PID" 2>/dev/null || true
        fi

    done

    # Esperar encerramento
    for i in {1..10}; do

        STILL_RUNNING=""

        for PID in $PIDS; do
            if kill -0 "$PID" 2>/dev/null; then
                STILL_RUNNING="yes"
            fi
        done

        [[ -z "$STILL_RUNNING" ]] && break

        sleep 1

    done

    # Se algum processo ainda estiver vivo
    for PID in $PIDS; do

        if kill -0 "$PID" 2>/dev/null; then
            echo "  FORCE STOP PID $PID"
            kill -9 "$PID" 2>/dev/null || true
        fi

    done

else

    echo "Nenhum processo Node.js do Martian Bank estava rodando."

fi

# ------------------------------------------------------------
# Pequena pausa para garantir encerramento
# ------------------------------------------------------------

sleep 2

# ------------------------------------------------------------
# Reiniciar utilizando os mesmos comandos do ambiente atual
# ------------------------------------------------------------

echo "Iniciando aplicações Node.js..."

cd "$MARTIAN_DIR"

# UI
if [[ -f "$MARTIAN_DIR/ui/node_modules/.bin/vite" ]]; then

    echo "  Iniciando UI (porta 3000)..."

    cd "$MARTIAN_DIR/ui"

    nohup ./node_modules/.bin/vite \
        > /tmp/martian-ui.log 2>&1 &

fi

# customer-auth
if [[ -f "$MARTIAN_DIR/customer-auth/server.js" ]]; then

    echo "  Iniciando customer-auth (porta 8000)..."

    cd "$MARTIAN_DIR/customer-auth"

    nohup ./node_modules/.bin/nodemon server.js \
        > /tmp/martian-customer-auth.log 2>&1 &

fi

# atm-locator
if [[ -f "$MARTIAN_DIR/atm-locator/server.js" ]]; then

    echo "  Iniciando atm-locator (porta 8001)..."

    cd "$MARTIAN_DIR/atm-locator"

    nohup ./node_modules/.bin/nodemon server.js \
        > /tmp/martian-atm-locator.log 2>&1 &

fi

# ------------------------------------------------------------
# Aguardar inicialização
# ------------------------------------------------------------

echo
echo "Aguardando aplicações iniciarem..."

sleep 5

# ------------------------------------------------------------
# Mostrar processos
# ------------------------------------------------------------

echo
echo "Processos Node.js:"
echo "------------------------------------------------------------"

ps -eo pid,ppid,args | \
    grep "$MARTIAN_DIR" | \
    grep -E 'node|vite|nodemon' | \
    grep -v grep || true

echo
echo "============================================================"
echo " CONCLUÍDO"
echo "============================================================"
echo
echo "Agente:"
echo "  $NODE_AGENT"
echo
echo "Configuração:"
echo "  $INJECTOR_CONF"
echo
echo "Aplicações Node.js reiniciadas."
echo
echo "Próxima validação:"
echo "  sudo ss -ntp | grep -E '4317|4318'"
echo
echo "E depois gerar tráfego HTTP no Martian Bank."
echo
