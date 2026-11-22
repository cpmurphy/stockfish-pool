# syntax = docker/dockerfile:1

# The stockfish-pool engine service. Build from this repository root (with the
# Stockfish submodule initialized):
#
#   git submodule update --init Stockfish
#   podman build -f Containerfile -t localhost/stockfish-pool:latest .
#
# Run it with no published ports on an internal-only network, a read-only root
# filesystem, all capabilities dropped and memory/pids/cpu limits; see
# deploy/quadlet/stockfish-pool.container.

ARG RUBY_VERSION=3.4.13
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /srv/stockfish-pool
ENV APP_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test"

FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential wget ca-certificates && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# x86-64-avx2 needs a CPU with AVX2 (check: grep -c avx2 /proc/cpuinfo);
# otherwise pass --build-arg STOCKFISH_ARCH=x86-64-sse41-popcnt. An engine built
# for the wrong CPU dies with "illegal instruction" and the pool reports "down".
ARG STOCKFISH_ARCH=x86-64-avx2
COPY Stockfish /build/Stockfish
RUN cd /build/Stockfish/src && \
    make clean && \
    make -j"$(nproc)" build ARCH="${STOCKFISH_ARCH}" && \
    strip stockfish && \
    install -m 0755 stockfish /usr/local/bin/stockfish

COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache

FROM base

COPY --from=build /usr/local/bin/stockfish /usr/local/bin/stockfish
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY Gemfile Gemfile.lock config.ru ./
COPY config ./config
COPY lib ./lib
COPY bin ./bin

# Code is root-owned; the service runs as an unprivileged user with no home
# directory and writes nothing except to /tmp.
RUN useradd --system --uid 1001 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin engine && \
    chmod -R a+rX,go-w /srv/stockfish-pool
USER engine

ENV ENGINE_PATH="/usr/local/bin/stockfish" \
    PORT="4000" \
    HOME="/tmp"
EXPOSE 4000
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
