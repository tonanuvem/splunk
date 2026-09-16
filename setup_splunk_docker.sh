#!/bin/bash

# Garante que o script está sendo executado como root
if [ "$EUID" -ne 0 ]; then
  echo "Por favor, execute este script como root (ex: sudo ./setup_splunk_docker.sh)"
  exit 1
fi

CONFIG_FILE="/etc/otel/collector/agent_config.yaml"

echo "--- Iniciando configuração do Splunk OTel Collector para Docker ---"

# 1. Configurar Permissões (Idempotente)
if getent group docker > /dev/null 2>&1; then
    if ! id -nG splunk-otel-collector | grep -qw "docker"; then
        echo "Adicionando usuário 'splunk-otel-collector' ao grupo 'docker'..."
        usermod -aG docker splunk-otel-collector
    else
        echo "[OK] Usuário 'splunk-otel-collector' já pertence ao grupo 'docker'."
    fi
else
    echo "[AVISO] Grupo 'docker' não encontrado no sistema. O Docker está instalado?"
fi

# 2. Criar um backup de segurança do arquivo yaml (caso ainda não exista)
if [ ! -f "${CONFIG_FILE}.bak" ]; then
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    echo "Backup original criado em ${CONFIG_FILE}.bak"
fi

# 3. Atualizar o arquivo de configuração (Idempotente)
# Verifica se a string já existe no arquivo para não duplicar
if ! grep -q "smartagent/docker-container-stats" "$CONFIG_FILE"; then
    echo "Injetando configurações do Docker no $CONFIG_FILE..."

    # a) Injeta a declaração do receiver logo após a chave raiz "receivers:"
    sed -i '/^receivers:/a \  smartagent/docker-container-stats:\n    type: docker-container-stats' "$CONFIG_FILE"

    # b) Injeta o receiver na array de receivers da pipeline de "metrics:"
    # O comando busca o bloco "metrics:" e adiciona o monitor dentro da lista "[ ... ]"
    sed -i '/^ *metrics:/,/receivers: \[/ s/receivers: \[/receivers: \[smartagent\/docker-container-stats, /' "$CONFIG_FILE"

    echo "[OK] Configurações inseridas com sucesso."
else
    echo "[OK] O monitor 'smartagent/docker-container-stats' já está presente no YAML. Nenhuma alteração feita."
fi

# 4. Validar e Reiniciar o Serviço
echo "Reiniciando o serviço splunk-otel-collector..."
systemctl restart splunk-otel-collector
sleep 2 # Aguarda 2 segundos para o daemon estabilizar

if systemctl is-active --quiet splunk-otel-collector; then
    echo "[SUCESSO] Splunk OpenTelemetry Collector reiniciado e rodando perfeitamente!"
else
    echo "[ERRO] O serviço falhou ao iniciar. Verifique o backup em ${CONFIG_FILE}.bak ou analise os logs usando: sudo journalctl -u splunk-otel-collector --no-pager -n 50"
    exit 1
fi
