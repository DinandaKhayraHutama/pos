FROM golang:1.27-alpine AS build
WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -trimpath -o /out/justclick ./cmd/justclick

FROM gcr.io/distroless/static-debian12
COPY --from=build /out/justclick /justclick
ENTRYPOINT ["/justclick"]
CMD ["serve"]
