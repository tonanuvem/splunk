#!/bin/bash
#
# ============================================================================
# Silenciar (ou melhor: consertar) o ruido do modo --discovery
# ============================================================================
#
# O collector roda com --discovery: ele varre a maquina e os containers, e
# quando reconhece um servico conhecido tenta coletar metricas dele sozinho.
# No lab isso gerava erro em loop no journal:
#
#   mongodbreceiver: "Last error: EOF"
#   nginxreceiver:   "expected 200 response, got 400 / 404"
#
# As duas causas sao configuracao, nao defeito:
#
#   MongoDB - a regra de discovery da Splunk assume TLS por padrao. O Mongo do
#             lab nao usa TLS, entao ele fecha a conexao e o receiver reporta
#             EOF. Basta declarar tls::insecure.
#
#   nginx   - o receiver precisa do endpoint stub_status, que a config do demo
#             nao tinha. Ja foi resolvido do outro lado: o nginx do bank-demo
#             agora serve /status (o caminho padrao do receiver). Rode o
#             instalador para aplicar.
#
# O ganho nao e' so' silencio: os dois passam a ENVIAR metricas de verdade,
# que aparecem na Infraestrutura do Splunk.
#
# Documentacao:
#   https://docs.splunk.com/observability/en/gdi/opentelemetry/automatic-discovery/linux/linux-advanced-config.html
#
# Uso:
#   sudo ./config_discovery_otel.sh
#   sudo DESLIGAR=sim ./config_discovery_otel.sh    # so' silencia, sem coletar
# ============================================================================

set -u

CONFIG_D="/etc/otel/collector/config.d"
PROPS="$CONFIG_D/properties.discovery.yaml"
DESLIGAR="${DESLIGAR:-nao}"

echo "============================================================"
echo " DISCOVERY DO OTEL COLLECTOR"
echo "============================================================"

if [ "$EUID" -ne 0 ]; then
    echo "[ERRO] Execute como root: sudo ./config_discovery_otel.sh"
    exit 1
fi

if ! systemctl is-active --quiet splunk-otel-collector; then
    echo "[ERRO] splunk-otel-collector nao esta ativo."
    exit 1
fi


# ------------------------------------------------------------
# 1. Erros atuais (para comparar depois)
# ------------------------------------------------------------

echo
echo "[1/4] Erros de discovery nos ultimos 5 minutos"

contar_erros() {
    journalctl -u splunk-otel-collector --since "5 minutes ago" --no-pager 2>/dev/null \
        | grep -c "$1"
}

ANTES_MONGO=$(contar_erros "mongodbreceiver")
ANTES_NGINX=$(contar_erros "nginxreceiver")

echo "  mongodbreceiver: $ANTES_MONGO"
echo "  nginxreceiver:   $ANTES_NGINX"


# ------------------------------------------------------------
# 2. Arquivo de propriedades
# ------------------------------------------------------------

echo
echo "[2/4] Escrevendo $PROPS"

mkdir -p "$CONFIG_D"

[ -f "$PROPS" ] && cp "$PROPS" "$PROPS.bkp.$(date +%s)"

if [ "$DESLIGAR" = "sim" ]; then

    cat > "$PROPS" <<'YAML'
# Desliga a descoberta automatica de MongoDB e nginx.
# Use quando o objetivo for apenas parar o ruido no journal, sem coletar
# metricas desses dois servicos.
splunk.discovery:
  receivers:
    mongodb:
      enabled: false
    nginx:
      enabled: false
YAML
    echo "  modo: DESLIGAR (sem coleta)"

else

    cat > "$PROPS" <<'YAML'
# Corrige a descoberta automatica em vez de desliga-la: assim MongoDB e nginx
# passam a enviar metricas de verdade para a Infraestrutura do Splunk.
splunk.discovery:
  receivers:
    mongodb:
      config:
        # A regra padrao assume TLS. O MongoDB do laboratorio nao usa, entao
        # o servidor fecha a conexao e o receiver reporta "Last error: EOF".
        tls::insecure: true
        tls::insecure_skip_verify: true
    nginx:
      config:
        # O nginx do bank-demo passou a servir /status (stub_status), que e' o
        # caminho padrao deste receiver.
        endpoint: "http://localhost:8080/status"
YAML
    echo "  modo: CORRIGIR (mongodb sem TLS, nginx via /status)"

fi

chown splunk-otel-collector:splunk-otel-collector "$PROPS" 2>/dev/null
chmod 0644 "$PROPS"


# ------------------------------------------------------------
# 3. Reiniciar, com reversao
# ------------------------------------------------------------

echo
echo "[3/4] Reiniciando o collector"

systemctl restart splunk-otel-collector
sleep 8

if systemctl is-active --quiet splunk-otel-collector; then

    echo "  [OK] collector ativo"

else

    echo "  [ERRO] o collector nao subiu. Revertendo..."
    journalctl -u splunk-otel-collector --since "1 minute ago" --no-pager 2>/dev/null \
        | grep -iE "error|invalid|cannot" | tail -3
    rm -f "$PROPS"
    systemctl reset-failed splunk-otel-collector 2>/dev/null
    systemctl restart splunk-otel-collector
    sleep 6
    systemctl is-active --quiet splunk-otel-collector \
        && echo "  [OK] collector restaurado (o arquivo foi removido)" \
        || echo "  [ERRO] collector continua fora - veja o journal"
    exit 1

fi


# ------------------------------------------------------------
# 4. O ruido parou mesmo?
# ------------------------------------------------------------

echo
echo "[4/4] Conferindo o resultado (90s de observacao)"
echo "  aguardando o collector completar alguns ciclos de coleta..."

sleep 90

DEPOIS_MONGO=$(journalctl -u splunk-otel-collector --since "90 seconds ago" --no-pager 2>/dev/null | grep -c "mongodbreceiver")
DEPOIS_NGINX=$(journalctl -u splunk-otel-collector --since "90 seconds ago" --no-pager 2>/dev/null | grep -c "nginxreceiver")

echo
echo "  mongodbreceiver: $ANTES_MONGO antes  ->  $DEPOIS_MONGO agora"
echo "  nginxreceiver:   $ANTES_NGINX antes  ->  $DEPOIS_NGINX agora"
echo

if [ "$DEPOIS_MONGO" -eq 0 ] && [ "$DEPOIS_NGINX" -eq 0 ]; then

    echo "  ✅ Ruido eliminado."
    [ "$DESLIGAR" != "sim" ] && {
        echo
        echo "  As metricas devem comecar a aparecer no Splunk em alguns minutos:"
        echo "    Infrastructure > procure por mongodb.* e nginx.*"
    }

else

    echo "  ⚠️ Ainda ha mensagens. As mais recentes:"
    journalctl -u splunk-otel-collector --since "90 seconds ago" --no-pager 2>/dev/null \
        | grep -E "mongodbreceiver|nginxreceiver" \
        | sed -E 's/.*"error": "([^"]{0,110}).*/    -> \1/' | tail -4
    echo
    echo "  Se persistir, silencie sem coletar:"
    echo "    sudo DESLIGAR=sim ./config_discovery_otel.sh"

fi

echo
echo "============================================================"
