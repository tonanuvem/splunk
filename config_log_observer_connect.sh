#!/bin/bash
#
# ============================================================================
# Log Observer Connect - preparar o Splunk Enterprise
# ============================================================================
#
# O QUE E' E COMO FUNCIONA
#
# O Log Observer Connect deixa voce pesquisar, dentro do Splunk Observability
# Cloud, logs que estao num Splunk plataforma (Enterprise ou Cloud). Os logs
# NAO sao copiados: o Observability consulta o seu Splunk na hora.
#
# Isso significa que a conexao e' de FORA PARA DENTRO: a nuvem da Splunk abre
# conexao para o SEU search head na porta 8089. Ou seja, a EC2 precisa estar
# alcancavel pela internet nessa porta, a partir dos IPs da Splunk.
#
# Este script prepara o lado do Splunk Enterprise:
#   - habilita a autenticacao por token
#   - cria o papel com as capacidades exatas que a documentacao exige
#   - cria a conta de servico
#   - extrai o certificado TLS para colar no formulario
#   - testa a conta rodando uma busca de verdade
#
# Documentacao:
#   https://help.splunk.com/en/splunk-observability-cloud/manage-data/view-splunk-platform-logs/set-up-log-observer-connect-for-splunk-enterprise
#
# Uso:
#   sudo ./config_log_observer_connect.sh
#   sudo SPLUNK_ADMIN_PASS='<senha do admin>' ./config_log_observer_connect.sh
# ============================================================================

set -u

CONTAINER="${CONTAINER:-splunk-enterprise}"
REALM="${REALM:-us1}"
PAPEL="logobserver"
USUARIO_LOC="${USUARIO_LOC:-logobserver}"
INDICE="${INDICE:-main}"

echo "============================================================"
echo " LOG OBSERVER CONNECT - lado do Splunk Enterprise"
echo "============================================================"

if [ "$EUID" -ne 0 ]; then
    echo "[ERRO] Execute como root: sudo ./config_log_observer_connect.sh"
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "[ERRO] Container '$CONTAINER' nao esta rodando."
    echo "       Rode antes: sudo ./config_splunk_enterprise.sh"
    exit 1
fi

# Mesma senha padrao do config_splunk_enterprise.sh
SPLUNK_ADMIN_PASS="${SPLUNK_ADMIN_PASS:-Teste@123}"

if [ -z "${LOC_PASS:-}" ]; then
    LOC_PASS="Loc@$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)"
fi

api() { docker exec "$CONTAINER" curl -s -k -u "admin:$SPLUNK_ADMIN_PASS" "$@"; }


# ------------------------------------------------------------
# 1. Credenciais do admin valem?
# ------------------------------------------------------------

echo
echo "[1/6] Verificando o acesso de admin"

if api "https://localhost:8089/services/server/info?output_mode=json" 2>/dev/null | grep -q '"version"'; then
    echo "  [OK] admin autenticou"
else
    echo "  [ERRO] senha do admin invalida (ou splunkd fora do ar)"
    exit 1
fi


# ------------------------------------------------------------
# 2. Autenticacao por token
# ------------------------------------------------------------

echo
echo "[2/6] Autenticacao por token"

# O Log Observer Connect usa token; sem isso a conexao falha na validacao.
api -X POST "https://localhost:8089/services/admin/token-auth/tokens_auth" \
    -d disabled=0 >/dev/null 2>&1

ESTADO_TOKEN=$(api "https://localhost:8089/services/admin/token-auth/tokens_auth?output_mode=json" 2>/dev/null \
    | grep -oE '"disabled":(true|false)' | head -1)

case "$ESTADO_TOKEN" in
    *false) echo "  [OK] autenticacao por token ativa" ;;
    *)      echo "  [AVISO] nao consegui confirmar o estado: ${ESTADO_TOKEN:-<sem resposta>}"
            echo "          habilite em Settings > Tokens > Enable Token Authentication" ;;
esac


# ------------------------------------------------------------
# 3. Papel com as capacidades exatas
# ------------------------------------------------------------

echo
echo "[3/6] Papel '$PAPEL'"

# A documentacao pede: 'search' e 'edit_tokens_own' habilitados,
# 'indexes_list_all' DESABILITADO, e o indice liberado explicitamente.
# srchTimeWin = 2592000 (30 dias), srchJobsQuota = 40.
if api "https://localhost:8089/services/authorization/roles/$PAPEL?output_mode=json" 2>/dev/null | grep -q "\"name\":\"$PAPEL\""; then
    echo "  [OK] papel ja existe - atualizando"
    METODO_URL="https://localhost:8089/services/authorization/roles/$PAPEL"
    CAMPO_NOME=""
else
    METODO_URL="https://localhost:8089/services/authorization/roles"
    CAMPO_NOME="-d name=$PAPEL"
fi

# shellcheck disable=SC2086
RESP_PAPEL=$(api -X POST "$METODO_URL" $CAMPO_NOME \
    -d capabilities=search \
    -d capabilities=edit_tokens_own \
    -d srchIndexesAllowed="$INDICE" \
    -d srchIndexesDefault="$INDICE" \
    -d srchJobsQuota=40 \
    -d srchTimeWin=2592000 \
    --write-out ' HTTP:%{http_code}' 2>/dev/null | tail -c 60)

echo "  resposta:$RESP_PAPEL"


# ------------------------------------------------------------
# 4. Conta de servico
# ------------------------------------------------------------

echo
echo "[4/6] Conta de servico '$USUARIO_LOC'"

if api "https://localhost:8089/services/authentication/users/$USUARIO_LOC?output_mode=json" 2>/dev/null | grep -q "\"name\":\"$USUARIO_LOC\""; then

    echo "  [OK] usuario ja existe - redefinindo a senha"
    api -X POST "https://localhost:8089/services/authentication/users/$USUARIO_LOC" \
        -d password="$LOC_PASS" -d roles="$PAPEL" >/dev/null 2>&1

else

    api -X POST "https://localhost:8089/services/authentication/users" \
        -d name="$USUARIO_LOC" -d password="$LOC_PASS" -d roles="$PAPEL" \
        -d realname="Log Observer Connect" >/dev/null 2>&1
    echo "  [OK] usuario criado"

fi


# ------------------------------------------------------------
# 5. A conta funciona mesmo?
# ------------------------------------------------------------

echo
echo "[5/6] Testando a conta com uma busca real"

# Nao adianta criar e torcer: rodamos uma busca como o proprio usuario.
TESTE=$(docker exec "$CONTAINER" curl -s -k -u "$USUARIO_LOC:$LOC_PASS" \
    -X POST "https://localhost:8089/services/search/jobs/export" \
    -d search="search index=$INDICE | head 1" \
    -d output_mode=json -d earliest_time=-24h 2>/dev/null | head -c 200)

if echo "$TESTE" | grep -q '"result"'; then
    echo "  [OK] a conta consegue buscar em index=$INDICE"
elif echo "$TESTE" | grep -qi "unauthorized\|401"; then
    echo "  [ERRO] a conta nao autenticou - revise papel e senha"
elif [ -z "$TESTE" ]; then
    echo "  [AVISO] a busca nao retornou nada."
    echo "          A conta pode estar ok, mas o indice '$INDICE' esta vazio -"
    echo "          ligue o envio de logs antes (OTEL_LOGS_EXPORTER=otlp)."
else
    echo "  [AVISO] resposta inesperada: $TESTE"
fi


# ------------------------------------------------------------
# 6. Certificado TLS para colar no formulario
# ------------------------------------------------------------

echo
echo "[6/6] Certificado TLS"

CERT=$(docker exec "$CONTAINER" sh -c \
    "openssl s_client -connect localhost:8089 -servername localhost </dev/null 2>/dev/null \
     | openssl x509 -outform PEM" 2>/dev/null)

if [ -n "$CERT" ]; then
    echo "$CERT" > /tmp/splunk-loc-cert.pem
    echo "  [OK] salvo em /tmp/splunk-loc-cert.pem"
    echo "       (o formulario pede APENAS o primeiro certificado da cadeia)"
else
    echo "  [AVISO] nao consegui extrair. Pegue manualmente com:"
    echo "    openssl s_client -connect <ip>:8089 </dev/null | openssl x509"
fi


# ------------------------------------------------------------
# Resumo
# ------------------------------------------------------------

IP=$(curl -s --max-time 5 checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')

case "$REALM" in
    us0) IPS_SPLUNK="34.199.200.84, 52.20.177.252, 52.201.67.203, 54.89.1.85" ;;
    us1) IPS_SPLUNK="44.230.152.35, 44.231.27.66, 44.225.234.52, 44.230.82.104" ;;
    *)   IPS_SPLUNK="(consulte a documentacao para o realm $REALM)" ;;
esac

echo
echo "============================================================"
echo " DADOS PARA O FORMULARIO"
echo "============================================================"
echo
echo "  No Observability Cloud: Logs > Add new connection > Splunk Enterprise"
echo
echo "    Splunk Enterprise URL:  https://${IP:-<ip-da-ec2>}:8089"
echo "    Username:               $USUARIO_LOC"
echo "    Password:               $LOC_PASS"
echo "    Certificado:            /tmp/splunk-loc-cert.pem"
echo
echo "------------------------------------------------------------"
echo " ANTES DE CLICAR EM SALVAR: LIBERE A PORTA 8089"
echo "------------------------------------------------------------"
echo
echo "  A nuvem da Splunk abre conexao PARA a sua EC2. Sem a regra no"
echo "  Security Group, o formulario falha por timeout."
echo
echo "  Libere a 8089 (TCP) apenas para os IPs da Splunk no realm $REALM:"
echo
echo "    $IPS_SPLUNK"
echo
echo "  Use esses IPs em vez de 0.0.0.0/0: a 8089 e' a API administrativa"
echo "  do Splunk, e deixa-la aberta para a internet inteira e' outra"
echo "  conversa, mesmo num laboratorio."
echo
echo "============================================================"
