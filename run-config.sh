# 1. Métricas de container — antes de subir a aplicação, para o docker_stats já pegar tudo:
sudo bash ~/splunk/config_docker_otel.sh

# 2. Splunk Enterprise — precisa vir antes do instalador da aplicação:
sudo bash GLIBC_TUNABLES=glibc.pthread.rseq=0 ~/splunk/config_splunk_enterprise.sh

# 3. Log Observer Connect: -  O Log Observer Connect deixa voce pesquisar, dentro do Splunk Observability
# Cloud, logs que estao num Splunk plataforma (Enterprise ou Cloud). Os logs NAO sao copiados.
# Observability consulta o seu Splunk na hora.
sudo bash ~/splunk/config_log_observer_connect.sh

echo ""
echo "###### FIM DAS CONFIGURAÇÕES DO SPLUNK ######"
echo ""
echo ""
