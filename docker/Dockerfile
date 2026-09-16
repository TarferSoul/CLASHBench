FROM python:3.12-slim
ARG CODEX_VERSION
ARG CLAUDE_VERSION
ARG OPENCODE_VERSION
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get -o Acquire::http::Timeout=30 -o Acquire::Retries=1 update && apt-get -o Acquire::http::Timeout=30 -o Acquire::Retries=1 install -y --no-install-recommends \
    python3 python3-pip python3-venv nodejs npm bash coreutils procps psmisc \
    iproute2 net-tools lsof curl ca-certificates git jq sudo \
    sqlite3 redis-server redis-tools postgresql postgresql-client nginx ffmpeg \
    build-essential libpq-dev util-linux tini \
    && rm -rf /var/lib/apt/lists/*
RUN test -n "$CODEX_VERSION" && test -n "$CLAUDE_VERSION" && test -n "$OPENCODE_VERSION" \
    && npm install --prefix /opt/harness/codex "@openai/codex@$CODEX_VERSION" \
    && npm install --prefix /opt/harness/claude "@anthropic-ai/claude-code@$CLAUDE_VERSION" \
    && npm install --prefix /opt/harness/opencode "opencode-ai@$OPENCODE_VERSION"
RUN pip install --no-cache-dir \
       numpy pandas flask gunicorn duckdb redis psycopg2-binary sqlalchemy requests \
    && useradd -m -s /bin/bash agentb
COPY clashbench /opt/acb/acb
RUN mkdir -p /opt/node/bin \
    && ln -s /usr/bin/node /opt/node/bin/node \
    && for cli in codex claude opencode; do \
         ln -s /opt/acb/acb/harness.py /usr/local/bin/$cli; \
         ln -s /opt/acb/acb/harness.py /opt/node/bin/$cli; \
       done \
    && chmod 755 /opt/acb/acb/harness.py
ENV PYTHONPATH=/opt/acb
ENTRYPOINT ["/usr/bin/tini", "--", "python3", "-m", "acb.container"]
