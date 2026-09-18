# 1. Métricas de container — antes de subir a aplicação, para o docker_stats já pegar tudo:
sudo bash ~/splunk/config_docker_otel.sh

# 2. Splunk Enterprise — precisa vir antes do instalador da aplicação:
sudo bash ~/splunk/config_splunk_enterprise.sh

echo ""
echo "###### FIM DAS CONFIGURAÇÕES DO SPLUNK ######"
echo ""
echo ""
