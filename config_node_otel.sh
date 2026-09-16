#!/bin/bash

set -euo pipefail

OTEL_DIR="/usr/lib/splunk-instrumentation"
OTEL_JS_TGZ="$OTEL_DIR/splunk-otel-js.tgz"
OTEL_JS_DIR="$OTEL_DIR/splunk-otel-js"
INJECTOR_CONF="/etc/opentelemetry/injector/injector.conf"

echo "============================================================"
echo " Corrigindo Splunk OpenTelemetry - Node.js"
echo "============================================================"

# ------------------------------------------------------------
# 1. Validar arquivos necessários
# ------------------------------------------------------------

echo
echo "[1/5] Validando pacote Node.js..."

if [[ ! -f "$OTEL_JS_TGZ" ]]; then
    echo "ERRO: pacote não encontrado:"
    echo "  $OTEL_JS_TGZ"
    exit 1
fi

echo "OK: $OTEL_JS_TGZ"

# ------------------------------------------------------------
# 2. Remover desativação do Node.js
# ------------------------------------------------------------

echo
echo "[2/5] Habilitando auto-instrumentação Node.js..."

if grep -q '^auto_instrumentation_disabled=nodejs$' "$INJECTOR_CONF"; then

    echo "Removendo:"
    echo "  auto_instrumentation_disabled=nodejs"

    sudo sed -i \
        '/^auto_instrumentation_disabled=nodejs$/d' \
        "$INJECTOR_CONF"

else

    echo "Linha auto_instrumentation_disabled=nodejs não encontrada."
    echo "Node.js já não está explicitamente desabilitado."

fi

# ------------------------------------------------------------
# 3. Criar diretório esperado pelo injector
# ------------------------------------------------------------

echo
echo "[3/5] Preparando diretório do agente Node.js..."

sudo mkdir -p "$OTEL_JS_DIR"

# ------------------------------------------------------------
# 4. Instalar pacote oficial @splunk/otel
# ------------------------------------------------------------

echo
echo "[4/5] Instalando pacote @splunk/otel..."

sudo npm install \
    --prefix "$OTEL_JS_DIR" \
    "$OTEL_JS_TGZ"

# ------------------------------------------------------------
# 5. Validar instalação
# ------------------------------------------------------------

echo
echo "[5/5] Validando agente Node.js..."

NODE_AGENT="$OTEL_JS_DIR/node_modules/@splunk/otel/instrument.js"

if [[ -f "$NODE_AGENT" ]]; then

    echo
    echo "============================================================"
    echo " OK - AGENTE NODE.JS INSTALADO"
    echo "============================================================"
    echo
    echo "Agente:"
    echo "  $NODE_AGENT"
    echo

else

    echo
    echo "============================================================"
    echo " ERRO - AGENTE NODE.JS NÃO ENCONTRADO"
    echo "============================================================"
    echo
    echo "Esperado:"
    echo "  $NODE_AGENT"
    echo

    exit 1
fi

echo "Configuração atual do injector:"
echo "------------------------------------------------------------"
sudo cat "$INJECTOR_CONF"
echo "------------------------------------------------------------"

echo
echo "IMPORTANTE:"
echo "Os processos Node.js NÃO foram reiniciados."
echo
echo "O próximo passo será validar o agente e então reiniciar"
echo "as aplicações Node.js do Martian Bank."
echo
