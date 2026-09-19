# A pagina e' a MESMA que roda como artifact no claude.ai, sem fork: la' o
# claude.ai envolve o conteudo num documento completo, e aqui esse envelope
# e' montado no build. Assim index.html continua publicavel como artifact.
FROM alpine:3.20 AS build
WORKDIR /src
COPY _head.html index.html _foot.html ./
RUN mkdir -p /out \
 && cat _head.html > /out/index.html \
 && grep -v '^<title>' index.html >> /out/index.html \
 && cat _foot.html >> /out/index.html \
 && grep -q '<!doctype html>' /out/index.html \
 && grep -q 'Gerar planilha' /out/index.html

FROM nginx:alpine
COPY --from=build /out/index.html /usr/share/nginx/html/index.html
RUN printf 'server {\n\
  listen 80;\n\
  charset utf-8;\n\
  root /usr/share/nginx/html;\n\
  location = /saude { return 200 "ok\\n"; add_header Content-Type text/plain; }\n\
  location / { try_files $uri /index.html; }\n\
}\n' > /etc/nginx/conf.d/default.conf
HEALTHCHECK --interval=10s --timeout=3s --retries=5 \
  CMD wget -qO- http://127.0.0.1/saude >/dev/null 2>&1 || exit 1
