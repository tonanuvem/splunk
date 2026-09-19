#!/usr/bin/env bash
#
# Sobe a pagina do exercicio de SLIs e SLOs num container nginx.
#
#   bash atividade-sli-slo.sh              # sobe na porta 8030
#   bash atividade-sli-slo.sh --porta 8040
#   bash atividade-sli-slo.sh --parar
#   bash atividade-sli-slo.sh --logs
#
# A pagina servida aqui e' a MESMA publicada como artifact no claude.ai.
# A diferenca esta' no download da planilha: no artifact quem salva e' a
# capability do proprio claude.ai, e aqui e' o download normal do navegador.
# A pagina detecta em qual dos dois esta' rodando.

set -euo pipefail

cd "$(dirname "$0")"

IMAGEM="fiap-atividade-sli-slo"
CONTAINER="fiap-atividade-sli-slo"
PORTA="${PORTA:-8030}"
ACAO="subir"

while [ $# -gt 0 ]; do
    case "$1" in
        --porta) PORTA="${2:-}"; shift 2 ;;
        --parar) ACAO="parar"; shift ;;
        --logs)  ACAO="logs";  shift ;;
        -h|--help)
            sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "[ERRO] opcao desconhecida: $1"
            echo "       use --porta N, --parar, --logs ou --help"
            exit 1 ;;
    esac
done

case "$PORTA" in
    ''|*[!0-9]*) echo "[ERRO] porta invalida: '$PORTA'"; exit 1 ;;
esac


# ------------------------------------------------------------
# Docker disponivel?
# ------------------------------------------------------------

command -v docker >/dev/null 2>&1 || {
    echo "[ERRO] Docker nao encontrado nesta maquina."
    exit 1
}

docker info >/dev/null 2>&1 || {
    echo "[ERRO] O Docker esta instalado mas o daemon nao responde."
    echo "       Inicie com: sudo systemctl start docker"
    echo "       Se for falta de permissao: sudo usermod -aG docker \$USER"
    echo "       (nesse caso, saia e entre de novo na sessao)"
    exit 1
}


# ------------------------------------------------------------
# --parar / --logs
# ------------------------------------------------------------

if [ "$ACAO" = "parar" ]; then
    if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
        docker rm -f "$CONTAINER" >/dev/null
        echo "[OK] $CONTAINER removido."
    else
        echo "[INFO] $CONTAINER nao estava rodando."
    fi
    echo "       A imagem foi mantida. Para apaga-la: docker rmi $IMAGEM"
    exit 0
fi

if [ "$ACAO" = "logs" ]; then
    docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER" || {
        echo "[ERRO] $CONTAINER nao existe. Suba primeiro: bash $(basename "$0")"
        exit 1
    }
    exec docker logs -f "$CONTAINER"
fi


# ------------------------------------------------------------
# Porta livre? (ignorando o proprio container, numa reexecucao)
# ------------------------------------------------------------

if ss -lnt 2>/dev/null | grep -q ":$PORTA "; then
    if docker port "$CONTAINER" 2>/dev/null | grep -q ":$PORTA$"; then
        echo "[INFO] porta $PORTA em uso pelo proprio $CONTAINER - sera recriado."
    else
        DONO=$(ss -lntp 2>/dev/null | grep ":$PORTA " \
               | grep -oE 'users:\(\("[^"]+' | cut -d'"' -f2 | head -1)
        echo "[ERRO] a porta $PORTA ja esta ocupada por ${DONO:-outro processo}."
        echo "       Escolha outra: bash $(basename "$0") --porta 8040"
        exit 1
    fi
fi


# ------------------------------------------------------------
# Build e run
# ------------------------------------------------------------

echo "=================================================="
echo " ATIVIDADE SLI/SLO - pagina do entregavel"
echo "=================================================="
echo
echo "[1/3] Construindo a imagem"

# O build valida o conteudo: se o envelope ou o botao sumirem, ele falha
# aqui, e nao numa tela em branco na frente da turma.
docker build -q -t "$IMAGEM" . >/dev/null || {
    echo "  [ERRO] falha no build. Rode sem -q para ver o motivo:"
    echo "         docker build -t $IMAGEM $(pwd)"
    exit 1
}
echo "  [OK] $IMAGEM"

echo
echo "[2/3] Subindo o container"

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

docker run -d \
    --name "$CONTAINER" \
    --restart unless-stopped \
    -p "0.0.0.0:${PORTA}:80" \
    "$IMAGEM" >/dev/null || {
    echo "  [ERRO] falha ao subir o container."
    exit 1
}
echo "  [OK] $CONTAINER na porta $PORTA"

echo
echo "[3/3] Aguardando a pagina responder"

PRONTO=nao
for _ in $(seq 1 20); do
    SAUDE=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || true)
    if [ "$SAUDE" = "healthy" ]; then PRONTO=sim; break; fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
        echo "  [ERRO] o container parou. Ultimas linhas:"
        docker logs --tail 15 "$CONTAINER" 2>&1 | sed 's/^/         /'
        exit 1
    fi
    sleep 1
done

if [ "$PRONTO" = "sim" ]; then
    echo "  [OK] respondendo"
else
    echo "  [AVISO] ainda nao respondeu. Veja: bash $(basename "$0") --logs"
fi


# ------------------------------------------------------------
# Onde acessar
# ------------------------------------------------------------

IP_PUB=$(curl -s --max-time 5 checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')
IP_LOC=$(hostname -I 2>/dev/null | awk '{print $1}')

echo
echo "=================================================="
echo " ACESSO - ATIVIDADE SLI/SLO"
echo "=================================================="
echo
[ -n "$IP_PUB" ] && echo "  Para os alunos:   http://${IP_PUB}:${PORTA}"
[ -n "$IP_LOC" ] && echo "  Na rede local:    http://${IP_LOC}:${PORTA}"
echo "  Nesta maquina:    http://localhost:${PORTA}"
echo
if [ -n "$IP_PUB" ]; then
    echo "  Libere a porta $PORTA no Security Group, senao so' voce enxerga."
    echo
fi
echo "  Parar:  bash $(basename "$0") --parar"
echo "  Logs:   bash $(basename "$0") --logs"
echo
