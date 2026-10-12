FROM groovy:4.0-jdk17

USER root

WORKDIR /lib
COPY vars /lib/vars

RUN mkdir -p /tmp/out && groovyc -d /tmp/out /lib/vars/*.groovy