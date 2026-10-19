ARG ZOER_FRONTEND_BASE_IMAGE=nginx:alpine
FROM ${ZOER_FRONTEND_BASE_IMAGE}
ARG ZOER_GIT_COMMIT=unknown
ARG ZOER_GIT_DIRTY=false
LABEL org.opencontainers.image.revision=${ZOER_GIT_COMMIT}
LABEL sh.zoer.git.dirty=${ZOER_GIT_DIRTY}
RUN rm -rf /usr/share/nginx/html/*
COPY dist/ /usr/share/nginx/html/
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
