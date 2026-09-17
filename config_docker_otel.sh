#!/bin/bash

# Garante a execução com privilégios de administrador
if [ "$EUID" -ne 0 ]; then
  echo "Por favor, execute este script como root (ex: sudo ./setup_otel_docker.sh)"
  exit 1
fi

CONFIG_FILE="/etc/otel/collector/agent_config.yaml"

echo "--- Configurando Receiver Nativo (docker_stats) no Splunk OTel ---"

# 1. Configuração de permissões no grupo Docker (Idempotente)
if getent group docker > /dev/null 2>&1; then
    if ! id -nG splunk-otel-collector | grep -qw "docker"; then
        usermod -aG docker splunk-otel-collector
        echo "[OK] Permissão de leitura no socket do Docker concedida."
    else
        echo "[OK] Permissão no grupo 'docker' já existente."
    fi
fi

# 2. Backup do arquivo de configuração atual
if [ ! -f "${CONFIG_FILE}.bak_otel" ]; then
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak_otel"
    echo "[OK] Backup de segurança criado em ${CONFIG_FILE}.bak_otel"
fi

# 3. Injeção da configuração do receiver (Idempotente e Segura)
if ! grep -q "^  docker_stats:" "$CONFIG_FILE"; then
    echo "Injetando configurações no $CONFIG_FILE..."

    # a) Declara o receiver 'docker_stats' e aponta para o socket do Docker
    sed -i '/^receivers:/a \  docker_stats:\n    endpoint: unix:///var/run/docker.sock\n    metrics:\n      container.network.io.usage.rx_packets:\n        enabled: true\n      container.network.io.usage.tx_packets:\n        enabled: true' "$CONFIG_FILE"

    # b) Adiciona o novo receiver na pipeline de métricas de forma exata e segura
    # Procura a string exata do array original e adiciona o docker_stats no início dela
    sed -i 's/receivers: \[host_metrics/receivers: \[docker_stats, host_metrics/' "$CONFIG_FILE"

    echo "[OK] Parâmetros do OpenTelemetry inseridos com sucesso."
else
    echo "[INFO] O receiver 'docker_stats' já está presente. Nenhuma alteração no YAML foi feita."
fi

# 4. Reinicialização e Validação do Serviço
echo "Reiniciando o serviço splunk-otel-collector..."
systemctl restart splunk-otel-collector
sleep 6

if systemctl is-active --quiet splunk-otel-collector; then

    echo "[SUCESSO] Splunk OTel Collector reiniciado com o receiver nativo rodando!"
    echo
    echo "As métricas aparecem como container.cpu.utilization,"
    echo "container.memory.usage.total e container.memory.percent,"
    echo "com as dimensões container.name, container.id e container.image.name."
    echo "Não há dashboard pronto: use o SIGNALFLOW-DASHBOARD.md."

else

    # Um erro de YAML derruba o collector já na validação da config, em
    # milissegundos. Sem reverter, a EC2 fica sem telemetria nenhuma - e o
    # motivo passa despercebido. Então mostramos o erro e desfazemos.
    echo "[ERRO] O collector não subiu após a mudança."
    echo
    echo "Erro reportado:"
    journalctl -u splunk-otel-collector --since "1 minute ago" --no-pager 2>/dev/null \
        | grep -iE "error|invalid|cannot|failed to|required" | tail -5

    if [ -f "${CONFIG_FILE}.bak_otel" ]; then

        echo
        echo "[INFO] Revertendo para ${CONFIG_FILE}.bak_otel ..."

        cp "${CONFIG_FILE}.bak_otel" "$CONFIG_FILE"

        systemctl reset-failed splunk-otel-collector 2>/dev/null
        systemctl restart splunk-otel-collector
        sleep 6

        if systemctl is-active --quiet splunk-otel-collector; then
            echo "[OK] Collector restaurado e ativo. A mudança foi desfeita."
            echo "     Investigue o agent_config.yaml antes de tentar de novo."
        else
            echo "[ERRO] Nem com o backup o collector sobe:"
            echo "  sudo journalctl -u splunk-otel-collector --no-pager -n 50"
        fi

    fi

    exit 1

fi
