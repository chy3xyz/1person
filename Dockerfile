# --- Build stage: zserver (Zig backend) ---
# Uses zigup to install the exact pinned Zig 0.17.0-dev.1567. zfinal + zcli
# are fetched by the Zig package manager from build.zig.zon git URLs.
# Links libpq (Postgres client) + sqlite3 from Alpine.

FROM alpine:3.21 AS builder

RUN apk add --no-cache git curl bash build-base postgresql-dev sqlite-dev ca-certificates

# Pinned Zig toolchain from official ziglang.org builds
COPY backend/zserver/scripts/install-zig.sh ./backend/zserver/scripts/install-zig.sh
RUN bash backend/zserver/scripts/install-zig.sh /opt/zig
ENV PATH="/opt/zig:${PATH}"

WORKDIR /src

COPY . .

# Build zserver (ReleaseSafe). Zig fetches zfinal/zcli from build.zig.zon.
ARG VERSION=dev
ARG COMMIT=unknown
RUN cd backend/zserver && zig build -Doptimize=ReleaseSafe -Dcommit=${COMMIT}

# --- Runtime stage ---
FROM alpine:3.21

RUN apk add --no-cache ca-certificates tzdata postgresql-libs sqlite-libs

WORKDIR /app

# Runtime layout keeps ./zserver binary + ./zserver/migrations (entrypoint contract).
COPY --from=builder /src/backend/zserver/zig-out/bin/zserver ./zserver
COPY --from=builder /src/backend/zserver/migrations ./zserver/migrations
COPY docker/entrypoint.sh .
RUN sed -i 's/\r$//' entrypoint.sh && chmod +x entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["./entrypoint.sh"]
