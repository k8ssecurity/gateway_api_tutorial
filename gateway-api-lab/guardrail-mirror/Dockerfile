# Stdlib-only HTTP server — only Docker needed on the host.
FROM golang:1.23 AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -o /guardrail-mirror .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /guardrail-mirror /guardrail-mirror
EXPOSE 8080
ENTRYPOINT ["/guardrail-mirror"]
