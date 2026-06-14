FROM golang:1.23 AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -o /llm-guardrail-webhook .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /llm-guardrail-webhook /llm-guardrail-webhook
EXPOSE 8000
ENTRYPOINT ["/llm-guardrail-webhook"]
