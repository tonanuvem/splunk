#!/bin/bash
#
# ============================================================================
# Splunk Universal Forwarder - instalacao e configuracao
# ============================================================================
#
# LEIA ANTES DE RODAR
#
# O Universal Forwarder (UF) e' so' um REMETENTE. Ele nao indexa nem mostra
# nada: ele empurra arquivos de log para um INDEXADOR Splunk (Enterprise ou
# Cloud Platform) na porta 9997. Sem um indexador do outro lado, o UF instala,
# sobe, monitora os arquivos... e os logs nao chegam a lugar nenhum.
#
# E ele NAO fala com o Splunk Observability Cloud. O caminho para os logs
# aparecerem no Observability e':
#
#     UF (ou o OTel collector) --> Splunk Enterprise/Cloud --> Log Observer Connect
#
# Vale lembrar que nesta EC2 ja existe o Splunk OTel Collector, que tambem
# sabe enviar logs por HEC. Se o objetivo e' so' ver os logs da aplicacao no
# Splunk, o collector resolve sem precisar do UF. O UF continua util para
# arquivos do sistema operacional e para demonstrar o forwarder classico.
#
# Documentacao (URLs verificadas):
#   Instalacao:
#     https://help.splunk.com/en/splunk-cloud-platform/forward-and-process-data/universal-forwarder-manual/9.1/install-the-universal-forwarder/install-a-nix-universal-forwarder
#   Configuracao por arquivos:
#     https://help.splunk.com/en/splunk-cloud-platform/forward-and-process-data/universal-forwarder-manual/10.4/configure-the-universal-forwarder/configure-the-universal-forwarder-using-configuration-files
#   Download:
#     https://www.splunk.com/en_us/download/universal-forwarder.html
#
# Uso:
#   sudo ./config_log_splunkfwd.sh                      # indexador em localhost:9997
#   sudo INDEXADOR=10.0.0.5:9997 ./config_log_splunkfwd.sh
#   sudo SPLUNKFWD_PASS='SuaSenha@123' ./config_log_splunkfwd.sh
# ============================================================================

set -u

SPLUNK_HOME="/opt/splunkforwarder"
VERSAO="10.4.3"
BUILD="4174a2deda5d"
PACOTE="splunkforwarder-${VERSAO}-${BUILD}-linux-amd64.tgz"
URL="https://download.splunk.com/products/universalforwarder/releases/${VERSAO}/linux/${PACOTE}"

INDEXADOR="${INDEXADOR:-localhost:9997}"
USUARIO="splunkfwd"

echo "============================================================"
echo " Splunk Universal Forwarder"
echo "============================================================"
echo "  SPLUNK_HOME: $SPLUNK_HOME"
echo "  Indexador:   $INDEXADOR"
echo


# ------------------------------------------------------------
# 0. root
# ------------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    echo "[ERRO] Execute como root:"
    echo "  sudo ./config_log_splunkfwd.sh"
    exit 1
fi


# ------------------------------------------------------------
# 1. Senha do admin
# ------------------------------------------------------------

# O primeiro start do Splunk PEDE usuario e senha de forma interativa, o que
# trava qualquer automacao. Semeamos a senha para o start rodar sozinho.
if [ -z "${SPLUNKFWD_PASS:-}" ]; then
    SPLUNKFWD_PASS="Fiap@$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 10)"
    SENHA_GERADA=true
else
    SENHA_GERADA=false
fi


# ------------------------------------------------------------
# 2. Usuario de servico
# ------------------------------------------------------------

echo "[1/7] Usuario de servico"

if id "$USUARIO" >/dev/null 2>&1; then
    echo "  [OK] usuario $USUARIO ja existe"
else
    useradd -r -m -d "/home/$USUARIO" -s /bin/bash "$USUARIO"
    echo "  [OK] usuario $USUARIO criado"
fi


# ------------------------------------------------------------
# 3. Download
# ------------------------------------------------------------

echo
echo "[2/7] Pacote"

# Baixa para /tmp e NAO para o diretorio do repositorio: o pacote tem ~137 MB
# e o extraido passa de 300 MB - versionar isso por acidente e' facil.
if [ -x "$SPLUNK_HOME/bin/splunk" ]; then

    echo "  [OK] ja instalado em $SPLUNK_HOME - pulando download"

else

    if [ ! -f "/tmp/$PACOTE" ]; then
        echo "  baixando (~137 MB)..."
        wget -q --show-progress -O "/tmp/$PACOTE" "$URL" || {
            echo "  [ERRO] falha no download"; exit 1; }
    else
        echo "  [OK] pacote ja em /tmp"
    fi

    echo "  extraindo em /opt ..."
    tar xzf "/tmp/$PACOTE" -C /opt

fi

chown -R "$USUARIO:$USUARIO" "$SPLUNK_HOME"
echo "  [OK] permissoes ajustadas para $USUARIO"


# ------------------------------------------------------------
# 4. Primeiro start (sem prompt)
# ------------------------------------------------------------

echo
echo "[3/7] Iniciando o forwarder"

if sudo -u "$USUARIO" "$SPLUNK_HOME/bin/splunk" status 2>/dev/null | grep -q running; then

    echo "  [OK] ja esta rodando"

else

    sudo -u "$USUARIO" "$SPLUNK_HOME/bin/splunk" start \
        --accept-license --answer-yes --no-prompt \
        --seed-passwd "$SPLUNKFWD_PASS" >/dev/null 2>&1

    sleep 3

    if sudo -u "$USUARIO" "$SPLUNK_HOME/bin/splunk" status 2>/dev/null | grep -q running; then
        echo "  [OK] forwarder iniciado"
    else
        echo "  [ERRO] o forwarder nao subiu. Veja:"
        echo "    sudo -u $USUARIO $SPLUNK_HOME/bin/splunk status"
        exit 1
    fi

fi


# ------------------------------------------------------------
# 5. Boot-start
# ------------------------------------------------------------

echo
echo "[4/7] Inicializacao automatica"

# Rodando como usuario comum, o Splunk avisa que nao consegue criar a unit do
# systemd. Como aqui estamos como root, criamos apontando para o usuario.
if systemctl list-unit-files 2>/dev/null | grep -q "SplunkForwarder.service"; then
    echo "  [OK] boot-start ja configurado"
else
    "$SPLUNK_HOME/bin/splunk" enable boot-start -user "$USUARIO" -systemd-managed 1 --accept-license --answer-yes --no-prompt >/dev/null 2>&1 \
        && echo "  [OK] unit do systemd criada" \
        || echo "  [AVISO] nao foi possivel criar a unit - o forwarder nao sobe sozinho apos reboot"
fi


# ------------------------------------------------------------
# 6. Destino (forward-server)
# ------------------------------------------------------------

echo
echo "[5/7] Destino dos logs"

if sudo -u "$USUARIO" "$SPLUNK_HOME/bin/splunk" list forward-server \
        -auth "admin:$SPLUNKFWD_PASS" 2>/dev/null | grep -q "$INDEXADOR"; then

    echo "  [OK] $INDEXADOR ja configurado"

else

    sudo -u "$USUARIO" "$SPLUNK_HOME/bin/splunk" add forward-server "$INDEXADOR" \
        -auth "admin:$SPLUNKFWD_PASS" >/dev/null 2>&1 \
        && echo "  [OK] destino $INDEXADOR adicionado" \
        || echo "  [AVISO] nao foi possivel adicionar o destino (senha do admin?)"

fi


# ------------------------------------------------------------
# 7. Monitoramento
# ------------------------------------------------------------

echo
echo "[6/7] Arquivos monitorados"

adicionar_monitor() {
    local CAMINHO="$1"
    [ -e "$CAMINHO" ] || { echo "  [--] $CAMINHO nao existe"; return; }

    if sudo -u "$USUARIO" "$SPLUNK_HOME/bin/splunk" list monitor \
            -auth "admin:$SPLUNKFWD_PASS" 2>/dev/null | grep -q "$CAMINHO"; then
        echo "  [OK] $CAMINHO ja monitorado"
    else
        sudo -u "$USUARIO" "$SPLUNK_HOME/bin/splunk" add monitor "$CAMINHO" \
            -auth "admin:$SPLUNKFWD_PASS" >/dev/null 2>&1 \
            && echo "  [OK] $CAMINHO" \
            || echo "  [AVISO] falhou em $CAMINHO"
    fi
}

adicionar_monitor "/var/log"

# Logs dos containers do Martian Bank. O UF roda como $USUARIO e o diretorio
# do Docker e' restrito ao root, entao so' adiciona se der para ler.
if [ -d /var/lib/docker/containers ]; then
    if sudo -u "$USUARIO" test -r /var/lib/docker/containers 2>/dev/null; then
        adicionar_monitor "/var/lib/docker/containers"
    else
        echo "  [--] /var/lib/docker/containers sem permissao para $USUARIO"
        echo "       (os logs dos containers ja saem pelo OTel collector)"
    fi
fi


# ------------------------------------------------------------
# 8. O indexador existe?
# ------------------------------------------------------------

echo
echo "[7/7] Verificando o indexador"

HOST_IDX="${INDEXADOR%%:*}"
PORTA_IDX="${INDEXADOR##*:}"

# `timeout` existe no Amazon Linux, mas nem em todo lugar - por isso o fallback.
if command -v timeout >/dev/null 2>&1; then
    TESTE_TCP="timeout 5 bash -c"
else
    TESTE_TCP="bash -c"
fi

if $TESTE_TCP "</dev/tcp/$HOST_IDX/$PORTA_IDX" 2>/dev/null; then

    echo "  [OK] $INDEXADOR esta aceitando conexao."
    echo "       Os logs devem comecar a aparecer no Splunk em instantes."

else

    echo "  [ATENCAO] NADA ESCUTANDO EM $INDEXADOR."
    echo
    echo "  O forwarder esta instalado e monitorando os arquivos, mas nao ha"
    echo "  indexador para recebe-los - os logs ficam na fila e nao chegam a"
    echo "  lugar nenhum. O UF sozinho nao resolve: ele precisa de um Splunk"
    echo "  Enterprise ou Cloud Platform do outro lado."
    echo
    echo "  Para subir um Splunk Enterprise nesta propria EC2 (licenca free,"
    echo "  500 MB/dia), em container:"
    echo
    echo "    docker run -d --name splunk-enterprise \\"
    echo "      -p 8000:8000 -p 8088:8088 -p 9997:9997 \\"
    echo "      -e SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com \\"
    echo "      -e SPLUNK_START_ARGS=--accept-license \\"
    echo "      -e SPLUNK_PASSWORD='<senha>' \\"
    echo "      splunk/splunk:latest"
    echo
    echo "  Depois habilite o recebimento na porta 9997 (Settings >"
    echo "  Forwarding and receiving > Configure receiving)."
    echo
    echo "  Lembre que a porta 8000 conflita com o customer-auth do Martian"
    echo "  Bank em modo host - publique o Splunk Web em outra, ex.: 8090:8000."

fi


# ------------------------------------------------------------
# Resumo
# ------------------------------------------------------------

echo
echo "============================================================"
echo " RESUMO"
echo "============================================================"
echo
echo "  Instalado em: $SPLUNK_HOME"
echo "  Usuario:      $USUARIO"
echo "  Destino:      $INDEXADOR"
echo

if [ "$SENHA_GERADA" = "true" ]; then
    echo "  SENHA DO ADMIN GERADA (anote, nao fica salva em lugar nenhum):"
    echo
    echo "      $SPLUNKFWD_PASS"
    echo
    echo "  Para definir voce mesmo numa proxima vez:"
    echo "      sudo SPLUNKFWD_PASS='SuaSenha@123' ./config_log_splunkfwd.sh"
    echo
fi

echo "  Comandos uteis:"
echo "      sudo -u $USUARIO $SPLUNK_HOME/bin/splunk status"
echo "      sudo -u $USUARIO $SPLUNK_HOME/bin/splunk list monitor -auth admin:<senha>"
echo "      sudo -u $USUARIO $SPLUNK_HOME/bin/splunk list forward-server -auth admin:<senha>"
echo
echo "============================================================"
