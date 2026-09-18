#!/usr/bin/env bash
#
# Roda, na ordem, as tres configuracoes do lado Splunk.
# Nenhuma delas depende da aplicacao estar no ar.

cd "$(dirname "$0")" || exit 1

# O contorno do KV Store e' opt-in: "bash run-config.sh --rseq-workaround".
# Ele e' repassado como FLAG, nao como variavel de ambiente, porque o sudo
# apaga o ambiente por padrao (env_reset) e a variavel nao chegaria la'.
ARGS_SPLUNK=""
for ARG in "$@"; do
    case "$ARG" in
        --rseq-workaround) ARGS_SPLUNK="--rseq-workaround" ;;
        -h|--help)
            echo "uso: bash run-config.sh [--rseq-workaround]"
            echo
            echo "  --rseq-workaround  forca a recriacao do Splunk Enterprise"
            echo "                     com GLIBC_TUNABLES=glibc.pthread.rseq=0."
            echo "                     Normalmente nao e' preciso: o passo do"
            echo "                     Log Observer Connect ja aplica sozinho"
            echo "                     quando detecta o problema de kernel."
            exit 0 ;;
    esac
done

# 1. Metricas de container - antes de subir a aplicacao, para o docker_stats
#    ja pegar tudo:
sudo bash ./config_docker_otel.sh

# 2. Splunk Enterprise - precisa vir antes do instalador da aplicacao:
sudo bash ./config_splunk_enterprise.sh $ARGS_SPLUNK

# 3. Log Observer Connect: deixa voce pesquisar, dentro do Splunk Observability
#    Cloud, logs que estao num Splunk plataforma (Enterprise ou Cloud). Os logs
#    NAO sao copiados: o Observability consulta o seu Splunk na hora.
sudo bash ./config_log_observer_connect.sh
STATUS_LOC=$?

# O IMDS da AWS exige token (IMDSv2), entao consultar /latest/meta-data
# direto volta vazio. O checkip resolve e e' o mesmo que os outros scripts usam.
IP=$(curl -s --max-time 5 checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')
[ -n "$IP" ] || IP="<ip-da-vm>"

# A senha so e' Teste@123 se este script criou o container. Num container
# preexistente o /opt/splunk/etc guardou a senha antiga, e afirmar a nova
# mandaria o aluno bater de cabeca na tela de login. Entao: verificar.
SENHA_PADRAO="Teste@123"
CODIGO=$(sudo docker exec splunk-enterprise \
    curl -s -k -o /dev/null -w '%{http_code}' --max-time 10 \
    -u "admin:$SENHA_PADRAO" https://localhost:8089/services/server/info 2>/dev/null)

case "$CODIGO" in
    200) SENHA_MSG="$SENHA_PADRAO" ;;
    401) SENHA_MSG="(nao e' $SENHA_PADRAO - foi definida quando o container"$'\n'"               foi criado. Para zerar: docker rm -f splunk-enterprise"$'\n'"               e rode de novo; os indices ficam no volume.)" ;;
    *)   SENHA_MSG="(nao consegui verificar; deveria ser $SENHA_PADRAO)" ;;
esac

echo
echo "============================================================"
echo " FIM DAS CONFIGURACOES DO SPLUNK"
echo "============================================================"
echo
echo "  Splunk Web:  http://$IP:8090"
echo "  Usuario:     admin"
echo "  Senha:       $SENHA_MSG"
echo
echo "  Busca para conferir os logs:"
echo "    index=main | head 50"
echo

case "$STATUS_LOC" in
    0)
        echo "  [OK] Log Observer Connect configurado."
        echo "       Falta so' o lado da Splunk: termine o formulario"
        echo "       em Observability > Settings > Log Observer Connect."
        ;;
    78)
        # Limitacao de ambiente, nao falha: o proprio script ja explicou
        # a causa acima. Nao deve manchar o resultado da configuracao.
        echo "  [AVISO] Log Observer Connect indisponivel (kernel do host)."
        echo "          O motivo esta detalhado acima. Nao afeta o resto:"
        echo "          tracos e metricas seguem no Observability Cloud, e os"
        echo "          logs seguem indexados e pesquisaveis no Splunk Web."
        ;;
    *)
        echo "  [ERRO] config_log_observer_connect.sh falhou (codigo $STATUS_LOC)."
        echo "         Releia a saida acima antes de seguir."
        ;;
esac

echo
echo "  Proximo passo - subir a aplicacao:"
echo "    bash ~/splunk/docker-run-demo-bank.sh host"
echo

# O codigo 78 e' esperado: nao propaga como falha.
[ "$STATUS_LOC" = "78" ] && exit 0
exit "$STATUS_LOC"
