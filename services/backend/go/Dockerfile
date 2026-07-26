# syntax=docker/dockerfile:1
# Lambda container image (ADR-0024 / go-backend-adoption-proposal.md §3.2/§4): Go is
# deployed to AWS Lambda only, never ECS (that's the Python backend's role). Built &
# pushed by CI (never locally — root CLAUDE.md), pushed to ECR, deployed via
# `aws lambda update-function-code --image-uri ...`.
# --platform=linux/arm64 is hardcoded (not $TARGETPLATFORM) on every stage below:
# the `go build` step also hardcodes GOARCH=arm64 (Graviton, proposal §3.2), and the
# two must always match regardless of which host architecture runs `docker build` --
# a mismatch here fails at container start with "exec format error", not at build
# time (caught by locally running the built image during Phase 1 verification).
FROM --platform=linux/arm64 golang:1.26 AS builder
WORKDIR /src

# Dependencies first (cached unless go.mod/go.sum change).
COPY go.mod go.sum ./
RUN go mod download

# CGO_ENABLED=0 for a small static binary (~10-20MB image).
COPY cmd ./cmd
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o /out/api ./cmd/api

# Lambda Web Adapter (proposal §4.2, decision "(A) LWA"): translates Lambda invoke
# events <-> HTTP so `api` above runs completely unmodified as a plain net/http
# server, both here and locally/in tests.
FROM --platform=linux/arm64 public.ecr.aws/awsguru/aws-lambda-adapter:1.0.1 AS lambda-adapter

# provided.al2023 (proposal §4.1): the AWS-recommended custom runtime base for Go
# Lambda functions since the go1.x managed runtime's deprecation.
FROM --platform=linux/arm64 public.ecr.aws/lambda/provided:al2023
COPY --from=lambda-adapter /lambda-adapter /opt/extensions/lambda-adapter
COPY --from=builder /out/api /var/task/api

ENV PORT=8000
ENTRYPOINT ["/var/task/api"]
