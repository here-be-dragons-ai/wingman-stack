# syntax=docker/dockerfile:1

FROM golang:1-alpine AS build

WORKDIR /src

COPY go.mod ./
COPY main.go main_test.go ./

RUN go vet ./... && go test ./... && CGO_ENABLED=0 go build -o /effort-guard .


FROM alpine

RUN apk add --no-cache tini

COPY --from=build /effort-guard /usr/local/bin/effort-guard

EXPOSE 8080

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["effort-guard"]
