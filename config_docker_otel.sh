#!/bin/bash

# ============================================================
# config_docker_otel.sh
#
# Configura docker_stats no Splunk OpenTelemetry Collector.
#
# docker_stats é um RECEIVER DE MÉTRICAS.
#
# Portanto:
#
#   traces            -> NÃO pode ter docker_stats
#   metrics           -> DEVE ter docker_stats
#   metrics/internal  -> NÃO precisa de docker_stats
#   logs/*            -> NÃO pode ter docker_stats
#
# ============================================================

set -u

CONFIG_FILE="/etc/otel/collector/agent_config.yaml"
BACKUP_FILE="${CONFIG_FILE}.bak_otel"
SERVICE="splunk-otel-collector"

echo
echo "============================================================"
echo " Configurando docker_stats no Splunk OTel Collector"
echo "============================================================"
echo

# ------------------------------------------------------------
# 1. Root
# ------------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    echo "[ERRO] Execute como root:"
    echo
    echo "  sudo ./config_docker_otel.sh"
    echo
    exit 1
fi

# ------------------------------------------------------------
# 2. Verifica configuração
# ------------------------------------------------------------

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERRO] Arquivo não encontrado:"
    echo "       $CONFIG_FILE"
    exit 1
fi

echo "[OK] Configuração encontrada:"
echo "     $CONFIG_FILE"

# ------------------------------------------------------------
# 3. Usuário do Collector
# ------------------------------------------------------------

if ! id splunk-otel-collector >/dev/null 2>&1; then
    echo "[ERRO] Usuário splunk-otel-collector não existe."
    exit 1
fi

# ------------------------------------------------------------
# 4. Docker
# ------------------------------------------------------------

if getent group docker >/dev/null 2>&1; then

    if id -nG splunk-otel-collector \
        | tr ' ' '\n' \
        | grep -qx "docker"; then

        echo "[OK] splunk-otel-collector já pertence ao grupo docker."

    else

        echo "[INFO] Adicionando splunk-otel-collector ao grupo docker..."

        usermod -aG docker splunk-otel-collector

        echo "[OK] Usuário adicionado ao grupo docker."

    fi

else

    echo "[ERRO] Grupo docker não encontrado."
    echo "       Verifique se o Docker está instalado."
    exit 1

fi

# ------------------------------------------------------------
# 5. Backup
# ------------------------------------------------------------

if [ ! -f "$BACKUP_FILE" ]; then

    cp "$CONFIG_FILE" "$BACKUP_FILE"

    echo "[OK] Backup criado:"
    echo "     $BACKUP_FILE"

else

    echo "[OK] Backup já existente:"
    echo "     $BACKUP_FILE"

fi

# ------------------------------------------------------------
# 6. Configuração do receiver docker_stats
# ------------------------------------------------------------

echo
echo "[INFO] Configurando receiver docker_stats..."

python3 - "$CONFIG_FILE" <<'PY'
import sys
import re

config_file = sys.argv[1]

with open(config_file, "r", encoding="utf-8") as f:
    lines = f.readlines()

# ------------------------------------------------------------
# A) Garante o bloco:
#
# receivers:
#   docker_stats:
#     endpoint: unix:///var/run/docker.sock
#
# ------------------------------------------------------------

docker_receiver_exists = any(
    re.match(r"^  docker_stats:\s*$", line)
    for line in lines
)

if not docker_receiver_exists:

    receiver_index = None

    for i, line in enumerate(lines):
        if re.match(r"^receivers:\s*$", line):
            receiver_index = i
            break

    if receiver_index is None:
        raise SystemExit(
            "[ERRO] Seção 'receivers:' não encontrada."
        )

    block = [
        "  docker_stats:\n",
        "    endpoint: unix:///var/run/docker.sock\n",
    ]

    lines[receiver_index + 1:receiver_index + 1] = block

# ------------------------------------------------------------
# B) Remove docker_stats de TODAS as pipelines.
#
# Depois colocaremos novamente SOMENTE em metrics.
#
# Isso corrige:
#
# traces
# metrics/internal
# logs/signalfx
# logs/entities
# logs
# etc.
# ------------------------------------------------------------

for i, line in enumerate(lines):

    if re.match(r"^\s+receivers\s*:", line):

        # Remove docker_stats de listas inline:
        #
        # receivers: [docker_stats, otlp]
        # receivers:[docker_stats, host_metrics, otlp]
        #
        if "[" in line and "]" in line:

            line = re.sub(
                r'(?<![A-Za-z0-9_-])docker_stats\s*,\s*',
                '',
                line
            )

            line = re.sub(
                r'(?<![A-Za-z0-9_-]),\s*docker_stats',
                '',
                line
            )

            # Caso a lista fique:
            # [docker_stats]
            line = re.sub(
                r'\[\s*docker_stats\s*\]',
                '[]',
                line
            )

            # Normaliza:
            # receivers:[...]
            # para:
            # receivers: [...]
            line = re.sub(
                r'^(\s*receivers)\s*:\s*',
                r'\1: ',
                line
            )

            lines[i] = line

# ------------------------------------------------------------
# C) Encontrar a pipeline metrics e adicionar docker_stats.
# ------------------------------------------------------------

in_service = False
in_pipelines = False
current_pipeline = None
metrics_receivers_line = None

for i, line in enumerate(lines):

    # service:
    if re.match(r"^service:\s*$", line):
        in_service = True
        in_pipelines = False
        current_pipeline = None
        continue

    if not in_service:
        continue

    # pipelines:
    if re.match(r"^\s+pipelines:\s*$", line):
        in_pipelines = True
        current_pipeline = None
        continue

    if not in_pipelines:
        continue

    # pipeline:
    #
    #     traces:
    #     metrics:
    #     logs:
    #
    match = re.match(
        r"^    ([A-Za-z0-9_-]+):\s*$",
        line
    )

    if match:
        current_pipeline = match.group(1)
        continue

    # receivers da pipeline metrics
    if current_pipeline == "metrics":

        if re.match(r"^\s{6}receivers\s*:", line):

            metrics_receivers_line = i

            # --------------------------------------------
            # Formato inline:
            #
            # receivers: [host_metrics, otlp]
            # --------------------------------------------

            if "[" in line and "]" in line:

                prefix = line[:line.index("receivers:")]
                value = line.split("receivers:", 1)[1].strip()

                # Remove espaços estranhos
                value = value.replace("[", "").replace("]", "")

                receivers = [
                    x.strip()
                    for x in value.split(",")
                    if x.strip()
                ]

                # Remove duplicados
                receivers = list(dict.fromkeys(receivers))

                # Adiciona docker_stats no início
                if "docker_stats" not in receivers:
                    receivers.insert(0, "docker_stats")

                new_line = (
                    prefix
                    + "receivers: ["
                    + ", ".join(receivers)
                    + "]\n"
                )

                lines[i] = new_line

            break

# ------------------------------------------------------------
# D) Se a pipeline metrics não tiver receivers, falha.
# ------------------------------------------------------------

if metrics_receivers_line is None:

    raise SystemExit(
        "[ERRO] Não foi encontrada a configuração "
        "receivers da pipeline metrics."
    )

# ------------------------------------------------------------
# Grava arquivo
# ------------------------------------------------------------

with open(config_file, "w", encoding="utf-8") as f:
    f.writelines(lines)

print("[OK] docker_stats configurado.")
PY

# ------------------------------------------------------------
# 7. Mostra configuração final
# ------------------------------------------------------------

echo
echo "------------------------------------------------------------"
echo "CONFIGURAÇÃO FINAL DO DOCKER_STATS"
echo "------------------------------------------------------------"

grep -n -B2 -A4 "docker_stats" "$CONFIG_FILE" || true

# ------------------------------------------------------------
# 8. Verifica que traces NÃO possui docker_stats
# ------------------------------------------------------------

echo
echo "------------------------------------------------------------"
echo "VALIDAÇÃO DAS PIPELINES"
echo "------------------------------------------------------------"

if awk '
    /^    traces:/ { in_traces=1; next }
    /^    [a-zA-Z0-9_-]+:/ && !/^    traces:/ {
        if (in_traces) exit
    }
    in_traces && /docker_stats/ {
        found=1
    }
    END {
        exit found ? 0 : 1
    }
' "$CONFIG_FILE"; then

    echo "[ERRO] docker_stats ainda está na pipeline traces!"
    exit 1

else

    echo "[OK] traces não possui docker_stats."

fi

# ------------------------------------------------------------
# 9. Confirma docker_stats em metrics
# ------------------------------------------------------------

if awk '
    /^    metrics:/ { in_metrics=1; next }
    /^    [a-zA-Z0-9_-]+:/ && !/^    metrics:/ {
        if (in_metrics) exit
    }
    in_metrics && /receivers:/ && /docker_stats/ {
        found=1
    }
    END {
        exit found ? 0 : 1
    }
' "$CONFIG_FILE"; then

    echo "[OK] metrics possui docker_stats."

else

    echo "[ERRO] docker_stats NÃO foi encontrado na pipeline metrics!"
    exit 1

fi

# ------------------------------------------------------------
# 10. Mostra pipelines
# ------------------------------------------------------------

echo
echo "------------------------------------------------------------"
echo "PIPELINES"
echo "------------------------------------------------------------"

sed -n '/^  pipelines:/,$p' "$CONFIG_FILE" | head -80

# ------------------------------------------------------------
# 11. Reinicia Collector
# ------------------------------------------------------------

echo
echo "------------------------------------------------------------"
echo "REINICIANDO COLLECTOR"
echo "------------------------------------------------------------"

systemctl restart "$SERVICE"

sleep 3

# ------------------------------------------------------------
# 12. Verifica serviço
# ------------------------------------------------------------

if systemctl is-active --quiet "$SERVICE"; then

    echo
    echo "============================================================"
    echo "[SUCESSO]"
    echo
    echo "Splunk OTel Collector está rodando."
    echo
    echo "docker_stats -> metrics"
    echo "============================================================"
    echo

else

    echo
    echo "============================================================"
    echo "[ERRO] Splunk OTel Collector NÃO iniciou."
    echo "============================================================"
    echo
    echo "Últimos logs:"
    echo

    journalctl \
        -u "$SERVICE" \
        --no-pager \
        -n 80

    echo
    echo "O backup está em:"
    echo "  $BACKUP_FILE"
    echo

    exit 1

fi
