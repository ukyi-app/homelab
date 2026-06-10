# syntax=docker/dockerfile:1
FROM --platform=$BUILDPLATFORM golang:1.22-bookworm AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY src ./src
ENV CGO_ENABLED=0 GOOS=linux GOARCH=arm64
RUN go build -trimpath -ldflags="-s -w" -o /out/api ./src

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/api /app/api
USER 65532:65532
EXPOSE 8080 9090
ENTRYPOINT ["/app/api"]
