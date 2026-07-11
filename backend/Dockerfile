# Stage 1: Build
FROM elixir:1.18-otp-28-alpine AS builder

ENV MIX_ENV=prod

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache build-base git

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Install dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy application code
COPY config config
COPY lib lib
COPY priv priv

# Compile the release
RUN mix compile
RUN mix release

# Stage 2: Runtime — must match the builder's Alpine version for OpenSSL compatibility
FROM elixir:1.18-otp-28-alpine AS runner

ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Build identity — pass with `docker compose build --build-arg GIT_SHA=... `
# so the running release reports exactly which commit it was built from
# (deploys are rsync + rebuild, so semver alone can't identify a build).
# Defaults to "dev" when not supplied.
ARG GIT_SHA=dev
ARG BUILD_DATE=
ENV HS_GIT_SHA=$GIT_SHA \
    HS_BUILD_DATE=$BUILD_DATE

WORKDIR /app

# Install runtime dependencies (Elixir/OTP already present from base)
# ffmpeg provides `ffprobe`, used to validate audio uploads
# (duration + stream inspection). Hard dependency for audio posts:
# Media.Audio.probe/2 fails-closed if ffprobe is missing.
# vips-tools provides `vipsthumbnail`, used by Media.ImageOptimizer
# to resize + recompress + strip-metadata for image uploads. Soft
# dependency: if absent, uploads still succeed but skip optimization.
RUN apk add --no-cache \
      libstdc++ \
      ncurses-libs \
      ca-certificates \
      postgresql-client \
      ffmpeg \
      vips-tools

# Create a non-root user
RUN addgroup --system app && \
    adduser --system --ingroup app --home /app app

# Copy the release from the builder stage
COPY --from=builder --chown=app:app /app/_build/prod/rel/hybridsocial ./

# Ensure uploads directory exists and is writable
RUN mkdir -p /app/uploads && chown app:app /app/uploads

USER app

EXPOSE 4000

ENTRYPOINT ["bin/hybridsocial"]
CMD ["start"]
