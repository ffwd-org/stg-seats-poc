# Multi-stage Elixir build
FROM elixir:1.17-otp-27 AS build

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && mix local.rebar --force

# Set build env
ENV MIX_ENV=prod

# Install deps first (better caching)
COPY mix.exs mix.lock* ./
RUN mix deps.get --only prod && mix deps.compile

# Copy config and lib
COPY config config
COPY lib lib

# Compile and build release
RUN mix compile && mix release

# --- Runtime stage ---
FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses5 locales ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

COPY --from=build /app/_build/prod/rel/stg_seats /app

EXPOSE 4000

CMD ["/app/bin/stg_seats", "start"]
