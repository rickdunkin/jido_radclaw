ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.5
ARG DEBIAN_VERSION=bookworm-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS build

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends build-essential ca-certificates git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && \
    mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config

RUN mix deps.get --only prod && \
    mix deps.compile

COPY lib lib
COPY priv priv

RUN mix compile && \
    mix release jido_claw

FROM debian:${DEBIAN_VERSION} AS app

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends ca-certificates libncurses6 libstdc++6 openssl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN useradd --system --create-home --home-dir /app --shell /usr/sbin/nologin jidoclaw && \
    chown jidoclaw:jidoclaw /app

COPY --from=build --chown=jidoclaw:jidoclaw /app/_build/prod/rel/jido_claw ./

USER jidoclaw

ENV HOME=/app

EXPOSE 4000

CMD ["bin/jido_claw", "start"]
