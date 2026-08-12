FROM node:22-bookworm-slim AS codex

ARG CODEX_VERSION=0.147.0
RUN npm install --global "@openai/codex@${CODEX_VERSION}" \
    && npm cache clean --force

FROM elixir:1.19.5-slim AS build

ENV MIX_ENV=prod
WORKDIR /src/elixir

RUN apt-get update \
    && apt-get install --yes --no-install-recommends build-essential ca-certificates git \
    && rm -rf /var/lib/apt/lists/* \
    && mix local.hex --force \
    && mix local.rebar --force

COPY elixir/mix.exs elixir/mix.lock ./
COPY elixir/config ./config
RUN mix deps.get --only prod && mix deps.compile

COPY elixir/assets ./assets
COPY elixir/lib ./lib
COPY elixir/priv ./priv
COPY elixir/WORKFLOW.md ./WORKFLOW.md
RUN mix assets.deploy && mix release symphony

FROM elixir:1.19.5-slim AS runtime

ENV LANG=C.UTF-8 \
    MIX_ENV=prod \
    HOME=/var/lib/symphony \
    CODEX_HOME=/var/lib/symphony/codex \
    MIX_HOME=/opt/mix \
    HEX_HOME=/var/lib/symphony/state/hex \
    REBAR_CACHE_DIR=/var/lib/symphony/state/rebar

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
      bash build-essential ca-certificates curl git jq openssh-client ripgrep util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/mix /var/lib/symphony/state /var/lib/symphony/workspaces /var/lib/symphony/codex \
    && MIX_HOME=/opt/mix mix local.hex --force \
    && MIX_HOME=/opt/mix mix local.rebar --force \
    && groupadd --gid 10001 symphony \
    && useradd --uid 10001 --gid 10001 --home-dir /var/lib/symphony --shell /usr/sbin/nologin symphony \
    && chown -R 10001:10001 /var/lib/symphony

COPY --from=codex /usr/local/bin/node /usr/local/bin/node
COPY --from=codex /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/@openai/codex/bin/codex.js /usr/local/bin/codex
COPY --from=build /src/elixir/_build/prod/rel/symphony /app
COPY elixir/WORKFLOW.md /app/WORKFLOW.md
COPY deploy/dokploy /app/deploy/dokploy

WORKDIR /app
EXPOSE 4021
VOLUME ["/var/lib/symphony/state", "/var/lib/symphony/workspaces", "/var/lib/symphony/codex"]
USER 10001:10001
ENTRYPOINT ["/app/deploy/dokploy/entrypoint.sh"]
