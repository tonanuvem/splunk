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
# Nome curto de proposito: usuario e senha sao os unicos campos que o aluno
# DIGITA no formulario (URL e certificado sao colados). O papel continua
# 'logobserver', que e' descritivo e so' aparece na administracao do Splunk.
USUARIO_LOC="${USUARIO_LOC:-log}"
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

# Senha fixa, a mesma do resto do laboratorio. Isso resolve de vez o problema
# que a versao anterior tinha: ela sorteava uma senha nova a cada execucao, e
# re-rodar o script para corrigir qualquer detalhe invalidava a senha ja
# colada no formulario do Observability. Com um valor fixo, executar de novo
# e' inofensivo - o resultado e' sempre o mesmo.
LOC_PASS="${LOC_PASS:-Teste@123}"

if [ ${#LOC_PASS} -lt 8 ]; then
    echo "[ERRO] A senha precisa de no minimo 8 caracteres (regra do Splunk)."
    exit 1
fi

# Guarda contra um tiro no pe: se USUARIO_LOC apontasse para uma conta
# administrativa, o passo [4/6] faria `-d roles=logobserver` nela, SUBSTITUINDO
# os papeis existentes. O admin perderia o papel de administrador e ninguem
# mais entraria no Splunk para desfazer.
case "$USUARIO_LOC" in
    admin|sc_admin|splunk-system-user)
        echo
        echo "[ERRO] USUARIO_LOC=$USUARIO_LOC nao e' permitido."
        echo
        echo "  Este script ATRIBUI o papel '$PAPEL' a conta informada,"
        echo "  substituindo os papeis que ela tiver. Em uma conta"
        echo "  administrativa isso removeria o acesso de admin."
        echo
        echo "  Se a intencao e' mesmo usar o admin no Log Observer Connect,"
        echo "  nao rode este script: basta digitar admin e a senha do admin"
        echo "  direto no formulario do Observability. Mas pense duas vezes -"
        echo "  essa credencial fica guardada na nuvem e da' administracao"
        echo "  total do seu Splunk, que esta com a 8089 exposta."
        exit 1 ;;
esac

api() { docker exec "$CONTAINER" curl -s -k -u "admin:$SPLUNK_ADMIN_PASS" "$@"; }


# ------------------------------------------------------------
# 0. A porta 8089 esta mesmo alcancavel de fora?
# ------------------------------------------------------------

echo
echo "[0/6] Alcancabilidade da porta 8089"

# "Unable to connect" no formulario do Observability e' quase sempre isto:
# a porta nao publicada em 0.0.0.0, ou o firewall/Security Group fechado.
# Vale conferir antes de criar contas e certificados.

PUB_8089=$(docker port "$CONTAINER" 8089 2>/dev/null | head -1)

if [ -z "$PUB_8089" ]; then
    echo "  [ERRO] o container nao publica a porta 8089."
    echo "         Recrie com: sudo ./config_splunk_enterprise.sh"
    exit 1
fi

echo "  publicada em: $PUB_8089"

case "$PUB_8089" in
    127.0.0.1:*|localhost:*)
        echo "  [ERRO] publicada apenas no loopback - a nuvem da Splunk nao alcanca."
        echo "         Recrie sem RESTRINGIR_MGMT:"
        echo "           docker rm -f $CONTAINER && sudo ./config_splunk_enterprise.sh"
        exit 1 ;;
    *)
        echo "  [OK] publicada em todas as interfaces" ;;
esac

if (exec 3<>/dev/tcp/localhost/8089) 2>/dev/null; then
    echo "  [OK] responde localmente"
else
    echo "  [ERRO] nem localmente responde - o Splunk esta no ar?"
    exit 1
fi

IP_PUBLICO=$(curl -s --max-time 5 checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')
IP_LOCAL=$(hostname -I 2>/dev/null | awk '{print $1}')

echo
echo "  IP publico desta maquina: ${IP_PUBLICO:-<nao detectado>}"
echo "  IP da interface local:    ${IP_LOCAL:-<nao detectado>}"
echo
echo "  ⚠️ Use o IP PUBLICO no formulario. Se os dois forem diferentes, a"
echo "     maquina esta atras de NAT: o encaminhamento da 8089 precisa existir"
echo "     ate ela, senao a Splunk nao chega."
echo
echo "  Teste decisivo, do SEU notebook (nao daqui):"
echo "    curl -k -v --max-time 10 https://${IP_PUBLICO:-<ip>}:8089/services/server/info"
echo
echo "  Se der timeout, o problema e' firewall/Security Group - e nenhum"
echo "  ajuste dentro do Splunk vai resolver."


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
echo "[1b/6] KV Store"

# A autenticacao por token guarda os tokens no KV Store (um MongoDB embutido
# no Splunk). Se ele nao sobe, o endpoint responde
# "KVStore is not ready. Token auth system will not work." -- e o formulario
# do Observability mostra o generico "Unable to connect".
KV=$(docker exec -u splunk "$CONTAINER" /opt/splunk/bin/splunk show kvstore-status \
        -auth "admin:$SPLUNK_ADMIN_PASS" 2>/dev/null | grep -iE "^\s*status" | head -1)

echo "  ${KV:-<sem resposta>}"

if echo "$KV" | grep -qi "ready"; then

    echo "  [OK] KV Store pronto"

else

    # Antes de listar causas genericas, procura a assinatura da
    # incompatibilidade MongoDB x kernel 6.19+, que nao tem conserto do lado
    # do Splunk e mandaria o usuario investigar disco e CPU a toa.
    if docker exec -u splunk "$CONTAINER" sh -c \
        "grep -l 'known incompatibility' /opt/splunk/var/log/splunk/mongod.log" \
        >/dev/null 2>&1; then

        echo
        echo "  [AVISO] Log Observer Connect indisponivel nesta maquina."
        echo "          Nao e' erro de configuracao, e nao ha o que corrigir"
        echo "          nos scripts: e' uma limitacao do kernel deste host."
        echo
        echo "  CAUSA: incompatibilidade do MongoDB do KV Store com o kernel."
        echo
        docker exec -u splunk "$CONTAINER" sh -c \
            "grep -h 'known incompatibility' /opt/splunk/var/log/splunk/mongod.log | tail -1" \
            2>/dev/null | cut -c1-200 | sed 's/^/    /'
        echo
        echo "  O kernel desta maquina e' $(uname -r). O MongoDB embutido no KV"
        echo "  Store nao sobe em kernel 6.19 ou mais novo (TCMalloc/rseq,"
        echo "  MongoDB SERVER-121912). Nao ha ajuste dentro do Splunk que"
        echo "  resolva: o container usa o kernel do host."
        echo
        echo "  Caminhos possiveis:"
        echo
        echo "   a) Trocar o kernel. A faixa afetada vai de 6.19 ate 7.0.13;"
        echo "      este esta em $(uname -r). Fora da faixa serve tanto o"
        echo "      7.0.14+ quanto qualquer 6.18 ou anterior. Veja o que ha:"
        echo "        apt-cache policy linux-aws"
        echo "      No Ubuntu 24.04 o 7.0.14 ainda nao foi publicado, mas o"
        echo "      kernel GA 6.8 continua em noble/main e nao e' afetado."
        echo "      Instale a imagem e fixe no GRUB antes de reiniciar:"
        echo "        sudo apt install linux-image-6.8.0-1008-aws \\"
        echo "                         linux-modules-6.8.0-1008-aws"
        echo "        sudo sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"Advanced options for Ubuntu>Ubuntu, with Linux 6.8.0-1008-aws\"|' /etc/default/grub"
        echo "        sudo update-grub && sudo reboot"
        echo "      Sem fixar no GRUB a maquina volta no 7.0 e nada muda."
        echo
        echo "   b) Tentar o contorno de comunidade (nao oficial, 1 minuto):"
        echo "        sudo GLIBC_TUNABLES=glibc.pthread.rseq=0 bash run-config.sh"
        echo "      O config_splunk_enterprise.sh detecta que o container atual"
        echo "      nao tem a variavel e recria sozinho; nao precisa remover."
        echo
        echo "   c) SEGUIR SEM o Log Observer Connect. Esta e' a saida pratica"
        echo "      para a aula: o KV Store nao afeta indexacao nem busca."
        echo "      Os logs continuam chegando e pesquisaveis no Splunk Web:"
        echo "        index=main | head 50"
        echo "      O que se perde e' apenas ve-los DENTRO do Observability."
        echo
        # 78 = EX_CONFIG: o ambiente nao suporta, nao houve falha de execucao.
        # O run-config.sh trata esse codigo como esperado e segue verde.
        exit 78

    fi

    echo
    echo "  [ERRO] O KV STORE NAO ESTA PRONTO."
    echo "         Sem ele nao ha autenticacao por token, e o Log Observer"
    echo "         Connect nao conecta - por mais certos que estejam conta,"
    echo "         papel, certificado e firewall."
    echo
    echo "  Causas mais comuns, em ordem:"
    echo

    # 1) espaco em disco
    LIVRE_MB=$(df -Pm /var/lib/docker 2>/dev/null | awk 'NR==2{print $4}')
    [ -z "$LIVRE_MB" ] && LIVRE_MB=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
    echo "  1. Espaco em disco: ${LIVRE_MB:-?} MB livres"
    if [ -n "$LIVRE_MB" ] && [ "$LIVRE_MB" -lt 5000 ]; then
        echo "     ⚠️ O Splunk exige 5 GB livres. Libere espaco:"
        echo "        docker system prune -a --volumes"
    else
        echo "     [OK] acima do minimo de 5 GB"
    fi

    # 2) suporte a AVX na CPU
    echo
    if grep -qm1 avx /proc/cpuinfo 2>/dev/null; then
        echo "  2. CPU com AVX: [OK]"
    else
        echo "  2. CPU SEM AVX: o MongoDB do KV Store exige AVX."
        echo "     Nesse caso, troque o tipo de maquina - nao ha contorno."
    fi

    # 3) ainda inicializando
    echo
    echo "  3. Pode estar apenas inicializando. Acompanhe:"
    echo "       docker exec -u splunk $CONTAINER tail -f /opt/splunk/var/log/splunk/mongod.log"
    echo
    echo "  Erros recentes do KV Store:"
    # -u splunk: o docker exec entra como 'ansible' e os logs sao do 'splunk'
    docker exec -u splunk "$CONTAINER" sh -c \
        "grep -i kvstore /opt/splunk/var/log/splunk/splunkd.log 2>/dev/null | tail -6" \
        2>/dev/null | cut -c1-150 | sed 's/^/     /'

    echo
    echo "  Ultimas linhas do mongod.log:"
    docker exec -u splunk "$CONTAINER" sh -c \
        "tail -8 /opt/splunk/var/log/splunk/mongod.log 2>/dev/null" \
        2>/dev/null | cut -c1-150 | sed 's/^/     /' 

    echo
    echo "  Corrigido o problema, rode este script de novo."

fi

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
# ATENCAO: a documentacao da Splunk lista apenas 'search' e 'edit_tokens_own',
# mas na pratica o endpoint que o formulario chama
# (GET /services/authorization/tokens) responde:
#   "requires capability: edit_tokens_all or list_tokens_all"
# Sem list_tokens_all a conexao falha com o generico "Unable to connect".
# Usamos list_tokens_all (somente leitura) em vez de edit_tokens_all, que
# permitiria criar token para qualquer usuario.
RESP_PAPEL=$(api -X POST "$METODO_URL" $CAMPO_NOME \
    -d capabilities=search \
    -d capabilities=edit_tokens_own \
    -d capabilities=list_tokens_all \
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

    echo "  [OK] usuario ja existe - reaplicando senha e papel"
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

# Quem rodou a versao anterior tem uma conta 'logobserver' sobrando. Nao
# apagamos por conta propria: pode estar em uso num formulario ja salvo.
if [ "$USUARIO_LOC" != "logobserver" ] \
   && api "https://localhost:8089/services/authentication/users/logobserver?output_mode=json" 2>/dev/null \
      | grep -q '"name":"logobserver"'; then
    echo
    echo "  ℹ️ Existe tambem a conta antiga 'logobserver', de uma execucao"
    echo "     anterior. Ela nao atrapalha. Para remover:"
    echo "       docker exec $CONTAINER curl -s -k -u admin:'<senha>' -X DELETE \\"
    echo "         https://localhost:8089/services/authentication/users/logobserver"
fi

echo
echo "[5/6] Testando o MESMO endpoint que o formulario usa"

# O formulario do Observability chama /services/authorization/tokens. Testar
# exatamente ele, com a conta de servico, separa as tres causas possiveis do
# "Unable to connect" que a tela mostra -- que e' uma mensagem generica e
# aparece tanto para rede quanto para permissao ou token auth desligado.
COD_TOKENS=$(docker exec "$CONTAINER" curl -s -k -o /dev/null -w "%{http_code}" \
    -u "$USUARIO_LOC:$LOC_PASS" \
    "https://localhost:8089/services/authorization/tokens?output_mode=json" 2>/dev/null)

case "$COD_TOKENS" in
    200)
        echo "  [OK] HTTP 200 - conta, permissao e token auth estao corretos."
        echo "       Se o formulario ainda disser 'Unable to connect', o que"
        echo "       falta e' liberar a 8089 para os IPs da Splunk (secao final)." ;;
    401)
        echo "  [ERRO] HTTP 401 - credencial invalida para $USUARIO_LOC." ;;
    403)
        echo "  [ERRO] HTTP 403 - falta capacidade no papel $PAPEL."
        echo "         O endpoint exige list_tokens_all (ou edit_tokens_all)."
        echo "         Se o papel ja existia de uma versao anterior do script,"
        echo "         rode de novo: ele atualiza as capacidades." ;;
    400|500)
        echo "  [ERRO] HTTP $COD_TOKENS - provavelmente a autenticacao por token"
        echo "         esta desligada. Habilite em Settings > Tokens." ;;
    *)
        echo "  [AVISO] HTTP ${COD_TOKENS:-<sem resposta>} - resposta inesperada." ;;
esac

echo
echo "  Para repetir de fora, do seu proprio computador:"
echo "    curl -k -u $USUARIO_LOC:'$LOC_PASS' \\"
echo "      \"https://\${IP:-<ip>}:8089/services/authorization/tokens?output_mode=json\""

echo
echo "[5b/6] Testando a conta com uma busca real"

# Nao adianta criar e torcer: rodamos uma busca como o proprio usuario.
TESTE=$(docker exec "$CONTAINER" curl -s -k -u "$USUARIO_LOC:$LOC_PASS" \
    -X POST "https://localhost:8089/services/search/jobs/export" \
    -d search="search index=$INDICE | head 1" \
    -d output_mode=json -d earliest_time=-24h 2>/dev/null | head -c 200)

if echo "$TESTE" | grep -q '"result"'; then
    echo "  [OK] a conta consegue buscar em index=$INDICE"
elif echo "$TESTE" | grep -qi "unauthorized\|401"; then
    echo "  [ERRO] a conta nao autenticou - revise papel e senha"
elif echo "$TESTE" | grep -qi "minimum free disk space"; then
    echo "  [ERRO] o Splunk recusou a busca por falta de espaco em disco."
    echo "         Ele exige 5 GB livres em /opt/splunk/var. A conta em si"
    echo "         autenticou - o problema e' a maquina, nao a permissao."
    echo "         Libere espaco:  docker system prune -a"
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

# Duas tentativas, porque a primeira falha em ambientes comuns: dentro do
# container o `openssl` nao esta no PATH do docker exec (fica em
# /opt/splunk/bin/openssl). Pelo host e' mais simples e funciona direto.
CERT=""

if command -v openssl >/dev/null 2>&1; then
    CERT=$(echo | openssl s_client -connect "localhost:8089" 2>/dev/null \
           | openssl x509 -outform PEM 2>/dev/null)
fi

if [ -z "$CERT" ]; then
    CERT=$(docker exec "$CONTAINER" sh -c \
        "/opt/splunk/bin/openssl s_client -connect localhost:8089 </dev/null 2>/dev/null \
         | /opt/splunk/bin/openssl x509 -outform PEM" 2>/dev/null)
fi

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
echo "  No Observability Cloud: Logs > Logs Connections > Add new connection > Splunk Enterprise"
echo
echo "    Username:               $USUARIO_LOC"
echo "    Password:               $LOC_PASS"
echo "    Splunk platform URL:    https://${IP:-<ip-da-ec2>}:8089"
echo "    Connection name:        fiap"
echo "    Certificado:            /tmp/splunk-loc-cert.pem"
echo
# echo "------------------------------------------------------------"
cat /tmp/splunk-loc-cert.pem 
# echo "------------------------------------------------------------"
# echo
# echo "  A nuvem da Splunk abre conexao PARA a sua EC2. Sem a regra no"
# echo "  Security Group, o formulario falha por timeout."
# echo
# echo "  Libere a 8089 (TCP) apenas para os IPs da Splunk no realm $REALM:"
# echo
# echo "    $IPS_SPLUNK"
# echo
# echo "  Use esses IPs em vez de 0.0.0.0/0: a 8089 e' a API administrativa"
# echo "  do Splunk, e deixa-la aberta para a internet inteira e' outra"
# echo "  conversa, mesmo num laboratorio."
echo
echo "============================================================"
