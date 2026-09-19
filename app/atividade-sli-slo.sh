docker build -t imgpage .
docker run --name page -p 8030:80 -d imgpage
docker ps

echo ""
echo "URL de acesso: ATIVIDADE SLI/SLO"
echo ""
echo http://$(curl -s checkip.amazonaws.com):8030
echo ""
echo ""
