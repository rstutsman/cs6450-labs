# Stage 1: build the Go binary
FROM golang:1.22-alpine AS builder

RUN apk add make
WORKDIR /app
#COPY go.mod go.sum ./
COPY go.mod ./
RUN go mod download

COPY . .
#RUN go build -o kvs main.go
RUN make

# Stage 2: minimal runtime image
FROM alpine:3.20

RUN apk add bash
WORKDIR /root/
COPY --from=builder /app/bin .
COPY cloudlab-start.sh .

# Optional: expose port if you're running a server
EXPOSE 8080

CMD ["/bin/bash", "./cloudlab-start.sh"]
