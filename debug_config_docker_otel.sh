#!/bin/bash

# ============================================================
# config_docker_otel.sh
#
# Configura o receiver nativo docker_stats no Splunk OTel
# Collector para coletar métricas dos containers Docker.
#
# IMPORTANTE:
#   docker_stats -> metrics
#   docker_stats NÃO pode estar em traces
# ============================================================

set -u

# ------------------------------------------------------------
# 0. Garante execução como root
# ------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "Por favor, execute este script como root:"
    echo "  sudo ./config_docker_otel.sh"
    exit 1
fi

CONFIG_FILE="/etc/otel/collector/agent_config.yaml"
BACKUP_FILE="${CONFIG_FILE}.bak_otel"
SERVICE="splunk-otel-collector"

echo
echo "============================================================"
echo " Configurando Docker Stats no Splunk OpenTelemetry Collector"
echo "============================================================"
echo

# ------------------------------------------------------------
# 1. Verifica arquivo de configuração
# ------------------------------------------------------------
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERRO] Arquivo não encontrado:"
    echo "       $CONFIG_FILE"
    exit 1
fi

# ------------------------------------------------------------
# 2. Verifica usuário do Collector
# ------------------------------------------------------------
if ! id splunk-otel-collector >/dev/null 2>&1; then
    echo "[ERRO] Usuário 'splunk-otel-collector' não existe."
    exit 1
fi

# ------------------------------------------------------------
# 3. Configuração de acesso ao Docker
# ------------------------------------------------------------
if getent group docker >/dev/null 2>&1; then

    if id -nG splunk-otel-collector | tr ' ' '\n' | grep -qx "docker"; then
        echo "[OK] splunk-otel-collector já pertence ao grupo docker."
    else
        echo "[INFO] Adicionando splunk-otel-collector ao grupo docker..."
        usermod -aG docker splunk-otel-collector
        echo "[OK] Usuário adicionado ao grupo docker."
    fi

else
    echo "[AVISO] Grupo docker não encontrado."
    echo "        Verifique se o Docker está instalado."
fi

# ------------------------------------------------------------
# 4. Backup
# ------------------------------------------------------------
if [ ! -f "$BACKUP_FILE" ]; then
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    echo "[OK] Backup criado:"
    echo "     $BACKUP_FILE"
else
    echo "[OK] Backup existente mantido:"
    echo "     $BACKUP_FILE"
fi

# ------------------------------------------------------------
# 5. Configura docker_stats
#
# Não usamos apenas grep para determinar se já existe.
# O script precisa corrigir uma configuração anterior onde
# docker_stats foi colocado na pipeline de traces.
# ------------------------------------------------------------
echo
echo "[INFO] Corrigindo configuração do docker_stats..."

python3 - "$CONFIG_FILE" <<'PY'
import sys
import re

config_file = sys.argv[1]

with open(config_file, "r", encoding="utf-8") as f:
    lines = f.readlines()

# ------------------------------------------------------------
# Remove docker_stats de receivers das pipelines de traces
# e adiciona em metrics.
#
# Esperamos estrutura semelhante a:
#
# service:
#   pipelines:
#     traces:
#       receivers: [...]
#     metrics:
#       receivers: [...]
# ------------------------------------------------------------

in_service = False
in_pipelines = False
current_pipeline = None

for i, line in enumerate(lines):

    stripped = line.strip()

    # service:
    if re.match(r"^service:\s*$", line):
        in_service = True
        in_pipelines = False
        current_pipeline = None
        continue

    # Nova seção de nível superior
    if in_service and re.match(r"^[A-Za-z0-9_]+:\s*$", line):
        if not line.startswith(" "):
            in_service = False
            in_pipelines = False
            current_pipeline = None
            continue

    # pipelines:
    if in_service and re.match(r"^\s+pipelines:\s*$", line):
        in_pipelines = True
        current_pipeline = None
        continue

    if in_service and in_pipelines:

        # pipeline traces / metrics
        match = re.match(r"^\s{4}([A-Za-z0-9_-]+):\s*$", line)

        if match:
            current_pipeline = match.group(1)
            continue

        # receivers da pipeline
        if current_pipeline in ("traces", "metrics"):

            if re.match(r"^\s{6}receivers:\s*", line):

                # Extrai o conteúdo depois de receivers:
                prefix, value = line.split("receivers:", 1)

                # Remove docker_stats de qualquer lista existente
                value = re.sub(
                    r'(?<![A-Za-z0-9_-])docker_stats\s*,?\s*',
                    '',
                    value
                )

                # Corrige vírgulas resultantes
                value = re.sub(r',\s*,', ',', value)
                value = re.sub(r'\[\s*,', '[', value)
                value = re.sub(r',\s*\]', ']', value)

                # ------------------------------------------------
                # Adiciona docker_stats SOMENTE em metrics
                # ------------------------------------------------
                if current_pipeline == "metrics":

                    if value.strip().startswith("["):
                        content = value.strip()

                        if content == "[]":
                            content = "[docker_stats]"
                        else:
                            content = content.replace(
                                "[",
                                "[docker_stats, ",
                                1
                            )

                        line = prefix + "receivers:" + content + "\n"

                # traces fica sem docker_stats
                lines[i] = line

# ------------------------------------------------------------
# Verifica se docker_stats foi realmente inserido em metrics.
# Se a pipeline metrics usa formato multilinha:
#
# receivers:
#   - otlp
#   - hostmetrics
#
# tratamos separadamente.
# ------------------------------------------------------------

# Reprocessamento simples para formato multilinha
in_service = False
in_pipelines = False
current_pipeline = None
metrics_receivers_block = False
metrics_has_docker = False
traces_receivers_block = False

for i, line in enumerate(lines):

    if re.match(r"^service:\s*$", line):
        in_service = True
        in_pipelines = False
        current_pipeline = None
        continue

    if in_service and re.match(r"^\s+pipelines:\s*$", line):
        in_pipelines = True
        continue

    if in_service and in_pipelines:

        match = re.match(r"^\s{4}([A-Za-z0-9_-]+):\s*$", line)
        if match:
            current_pipeline = match.group(1)
            continue

        if current_pipeline == "metrics" and re.match(
            r"^\s{6}receivers:\s*$", line
        ):
            metrics_receivers_block = True
            metrics_has_docker = False
            continue

        if current_pipeline == "traces" and re.match(
            r"^\s{6}receivers:\s*$", line
        ):
            traces_receivers_block = True
            continue

        # Fim de bloco multilinha
        if metrics_receivers_block:
            if re.match(r"^\s{6}[A-Za-z0-9_-]+:", line):
                if not metrics_has_docker:
                    lines.insert(i, "        - docker_stats\n")
                metrics_receivers_block = False

        if traces_receivers_block:
            if re.match(r"^\s{6}[A-Za-z0-9_-]+:", line):
                traces_receivers_block = False

        if metrics_receivers_block and re.match(
            r"^\s{8}-\s*docker_stats\s*$", line
        ):
            metrics_has_docker = True

# ------------------------------------------------------------
# Se ainda não encontramos docker_stats em metrics, fazemos
# uma inserção segura logo após receivers: da pipeline metrics.
# ------------------------------------------------------------

in_service = False
in_pipelines = False
current_pipeline = None
inserted = False

for i, line in enumerate(lines):

    if re.match(r"^service:\s*$", line):
        in_service = True
        continue

    if in_service and re.match(r"^\s+pipelines:\s*$", line):
        in_pipelines = True
        continue

    if in_service and in_pipelines:

        match = re.match(r"^\s{4}([A-Za-z0-9_-]+):\s*$", line)
        if match:
            current_pipeline = match.group(1)
            continue

        if current_pipeline == "metrics":
            if re.match(r"^\s{6}receivers:\s*", line):

                if "docker_stats" not in line:
                    # Formato inline
                    if "[" in line:
                        prefix, value = line.split("receivers:", 1)
                        value = value.strip()

                        if value == "[]":
                            new_value = "[docker_stats]"
                        else:
                            new_value = value.replace(
                                "[",
                                "[docker_stats, ",
                                1
                            )

                        lines[i] = prefix + "receivers: " + new_value + "\n"

                    # Formato multilinha
                    elif line.rstrip().endswith(":"):
                        lines.insert(i + 1, "        - docker_stats\n")

                inserted = True
                break

# ------------------------------------------------------------
# Grava configuração
# ------------------------------------------------------------
with open(config_file, "w", encoding="utf-8") as f:
    f.writelines(lines)

print("[OK] YAML atualizado.")
PY

# ------------------------------------------------------------
# 6. Verificação visual da configuração
# ------------------------------------------------------------
echo
echo "------------------------------------------------------------"
echo "Ocorrências de docker_stats:"
echo "------------------------------------------------------------"

grep -n -B3 -A5 "docker_stats" "$CONFIG_FILE" || true

# ------------------------------------------------------------
# 7. IMPORTANTE:
#    Garante que docker_stats NÃO esteja na pipeline traces
# ------------------------------------------------------------
if grep -A15 -E '^[[:space:]]+traces:' "$CONFIG_FILE" \
    | grep -q "docker_stats"; then

    echo
    echo "[ERRO] docker_stats ainda aparece na pipeline traces."
    echo "[ERRO] A configuração não será aplicada."
    echo
    echo "Faça:"
    echo "  sudo cp '$BACKUP_FILE' '$CONFIG_FILE'"
    exit 1
fi

# ------------------------------------------------------------
# 8. Verifica se docker_stats está em metrics
# ------------------------------------------------------------
if grep -A15 -E '^[[:space:]]+metrics:' "$CONFIG_FILE" \
    | grep -q "docker_stats"; then

    echo
    echo "[OK] docker_stats está associado à pipeline metrics."
else
    echo
    echo "[ERRO] Não foi possível confirmar docker_stats na pipeline metrics."
    echo
    echo "Configuração atual:"
    grep -A20 -E '^[[:space:]]+(metrics|traces):' "$CONFIG_FILE" || true
    exit 1
fi

# ------------------------------------------------------------
# 9. Reinicia o Collector
# ------------------------------------------------------------
echo
echo "------------------------------------------------------------"
echo "Reiniciando $SERVICE..."
echo "------------------------------------------------------------"

systemctl restart "$SERVICE"

sleep 3

# ------------------------------------------------------------
# 10. Validação do serviço
# ------------------------------------------------------------
if systemctl is-active --quiet "$SERVICE"; then

    echo
    echo "============================================================"
    echo "[SUCESSO]"
    echo "Splunk OTel Collector está em execução."
    echo "docker_stats configurado na pipeline de métricas."
    echo "============================================================"
    echo

else

    echo
    echo "============================================================"
    echo "[ERRO] O Collector não iniciou."
    echo "============================================================"
    echo
    echo "Últimos logs:"
    echo

    journalctl -u "$SERVICE" --no-pager -n 50

    echo
    echo "O backup original está em:"
    echo "  $BACKUP_FILE"
    echo

    exit 1
fi
