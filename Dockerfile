# --- Build stage: zserver (Zig backend) ---
# Uses zigup to install the exact pinned Zig 0.17.0-dev.1567, provisions the
# pinned zfinal/zcli checkouts via scripts/provision-zig-deps.sh, and links
# libpq (Postgres client) + sqlite3 from Alpine.

FROM alpine:3.21 AS builder

RUN apk add --no-cache git curl bash build-base postgresql-dev sqlite-dev ca-certificates

# Pinned Zig toolchain from official ziglang.org builds
COPY zserver/scripts/install-zig.sh ./zserver/scripts/install-zig.sh
RUN bash zserver/scripts/install-zig.sh /opt/zig
ENV PATH="/opt/zig:${PATH}"

WORKDIR /src

# Copy the full repo (zig_ws is provisioned fresh below).
COPY . .

# Provision the pinned framework checkouts (zfinal v0.24.0 + zcli) into
# <repo>/zig_ws so the build is reproducible from a clean checkout.
RUN bash zserver/scripts/provision-zig-deps.sh

# Build zserver (ReleaseSafe).
ARG VERSION=dev
ARG COMMIT=unknown
RUN cd zserver && zig build -Doptimize=ReleaseSafe -Dcommit=${COMMIT}

# --- Runtime stage ---
FROM alpine:3.21

RUN apk add --no-cache ca-certificates tzdata postgresql-libs sqlite-libs

WORKDIR /app

# zserver binary + migrations (zserver migrate reads server/migrations
# relative to the working directory).
COPY --from=builder /src/zserver/zig-out/bin/zserver ./zserver
COPY --from=builder /src/server/migrations ./server/migrations
COPY docker/entrypoint.sh .
RUN sed -i 's/\r$//' entrypoint.sh && chmod +x entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["./entrypoint.sh"]
