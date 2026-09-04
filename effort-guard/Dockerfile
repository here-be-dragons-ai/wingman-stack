# syntax=docker/dockerfile:1

# Pinned to minor version tags rather than digests on purpose: this repository
# has no bot watching for base image updates, and a digest pin with nobody to
# refresh it turns into an unpatched image. A minor tag still receives security
# patches while blocking a surprise major upgrade.
FROM golang:1.27-alpine AS build

WORKDIR /src

COPY go.mod ./
COPY main.go main_test.go ./

RUN go vet ./... && go test ./... && CGO_ENABLED=0 go build -o /effort-guard .


FROM alpine:3.24

# tini earns its place: as PID 1 a process gets no default signal dispositions,
# so the Go binary -- which installs no handlers -- would ignore the SIGTERM
# that `docker compose down` sends and wait out the timeout before being killed.
RUN apk add --no-cache tini

COPY --from=build /effort-guard /usr/local/bin/effort-guard

# Nothing here needs root: the binary is static, reads only its environment, and
# 8080 is above the privileged range.
USER nobody

EXPOSE 8080

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["effort-guard"]
