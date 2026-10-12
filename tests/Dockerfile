FROM debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends bash shellcheck jq util-linux coreutils gzip tar gawk grep sed ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /lib
COPY . /lib

CMD ["bash", "tests/test.sh"]