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
            echo "  --rseq-workaround  recria o Splunk Enterprise com"
            echo "                     GLIBC_TUNABLES=glibc.pthread.rseq=0,"
            echo "                     contorno NAO OFICIAL para o KV Store"
            echo "                     em kernel 6.19+ (MongoDB SERVER-121912)."
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

IP=$(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null)
[ -n "$IP" ] || IP="<ip-da-vm>"

echo
echo "============================================================"
echo " FIM DAS CONFIGURACOES DO SPLUNK"
echo "============================================================"
echo
echo "  Splunk Web:  http://$IP:8090"
echo "  Usuario:     admin"
echo "  Senha:       Teste@123"
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
