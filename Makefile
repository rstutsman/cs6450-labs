# Makefile for CS6450 KVS Lab

# Variables
MODULE_NAME := github.com/rstutsman/cs6450-labs
BIN_DIR := bin
SERVER_BINARY := $(BIN_DIR)/server
CLIENT_BINARY := $(BIN_DIR)/client
SERVER_PKG := ./kvs/server
CLIENT_PKG := ./kvs/client

# Go parameters
GOCMD := go
GOBUILD := $(GOCMD) build
GOCLEAN := $(GOCMD) clean
GOTEST := $(GOCMD) test
GOGET := $(GOCMD) get
GOMOD := $(GOCMD) mod
GOFMT := $(GOCMD) fmt

# Build flags
BUILD_FLAGS := -v
LDFLAGS := -w -s

.PHONY: help build build-server build-client run-server run-client test clean fmt vet deps tidy dev stop-dev all deploy deploy-with-source test-deployment extract-machines cloudlab-setup docker-local

all: clean build

help:
	@echo 'Usage: make <target>'
	@echo ''
	@echo 'Targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-15s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: build-server build-client ## Build both server and client binaries

build-server: $(SERVER_BINARY) ## Build the KVS server binary

build-client: $(CLIENT_BINARY) ## Build the KVS client binary

install.tar.gz: $(SERVER_BINARY) $(CLIENT_BINARY) Dockerfile cloudlab-start.sh
	@echo "Creating install package..."
	mkdir -p install
	cp $(SERVER_BINARY) $(CLIENT_BINARY) Dockerfile cloudlab-start.sh install/
	tar -czf install.tar.gz -C install .

kvs.tar.gz: $(SERVER_BINARY) $(CLIENT_BINARY) Dockerfile cloudlab-start.sh
	@echo "Building Docker image..."
	docker build --platform=linux/amd64 -t kvs:latest .
	docker save kvs:latest | gzip > kvs.tar.gz

docker-local: $(SERVER_BINARY) $(CLIENT_BINARY) Dockerfile
	@echo "Building Docker image..."
	docker build -t kvs:latest .

$(SERVER_BINARY): $(BIN_DIR) $(wildcard kvs/server/*.go) $(wildcard kvs/*.go)
	@echo "Building KVS server..."
	$(GOBUILD) $(BUILD_FLAGS) -ldflags "$(LDFLAGS)" -o $(SERVER_BINARY) $(SERVER_PKG)

$(CLIENT_BINARY): $(BIN_DIR) $(wildcard kvs/client/*.go) $(wildcard kvs/*.go)
	@echo "Building KVS client..."
	$(GOBUILD) $(BUILD_FLAGS) -ldflags "$(LDFLAGS)" -o $(CLIENT_BINARY) $(CLIENT_PKG)

$(BIN_DIR):
	@mkdir -p $(BIN_DIR)

run-server: build-server ## Build and run the KVS server (default port 8080)
	@echo "Starting KVS server on port 8080..."
	./$(SERVER_BINARY)

run-server-port: build-server ## Build and run the KVS server on custom port (usage: make run-server-port PORT=8081)
	@echo "Starting KVS server on port $(PORT)..."
	./$(SERVER_BINARY) -port=$(PORT)

run-client: build-client ## Build and run the KVS client
	@echo "Running KVS client..."
	./$(CLIENT_BINARY)

dev: ## Start development mode (server in background, client ready)
	@echo "Starting development environment..."
	@echo "Building binaries..."
	@$(MAKE) build
	@echo "Starting server in background on port 8080..."
	@./$(SERVER_BINARY) > server.log 2>&1 &
	@echo $$! > server.pid
	@sleep 1
	@echo "Server started (PID: $$(cat server.pid))"
	@echo "Server logs: tail -f server.log"
	@echo "Run client: make run-client"
	@echo "Stop server: make stop-dev"

stop-dev: ## Stop development server
	@if [ -f server.pid ]; then \
		echo "Stopping server (PID: $$(cat server.pid))..."; \
		kill $$(cat server.pid) 2>/dev/null || true; \
		rm -f server.pid; \
		echo "Server stopped."; \
	else \
		echo "No server PID file found."; \
	fi

test: ## Run tests
	@echo "Running tests..."
	$(GOTEST) -v ./...

test-coverage: ## Run tests with coverage
	@echo "Running tests with coverage..."
	$(GOTEST) -v -coverprofile=coverage.out ./...
	$(GOCMD) tool cover -html=coverage.out -o coverage.html
	@echo "Coverage report generated: coverage.html"

fmt: ## Format Go code
	@echo "Formatting code..."
	$(GOFMT) ./...

vet: ## Run go vet
	@echo "Running go vet..."
	$(GOCMD) vet ./...

lint: ## Run golint (requires golint to be installed)
	@echo "Running golint..."
	@if command -v golint >/dev/null 2>&1; then \
		golint ./...; \
	else \
		echo "golint not installed. Install with: go install golang.org/x/lint/golint@latest"; \
	fi

deps: ## Download dependencies
	@echo "Downloading dependencies..."
	$(GOGET) -d ./...

tidy: ## Tidy up go.mod
	@echo "Tidying go.mod..."
	$(GOMOD) tidy

clean: ## Clean build artifacts
	@echo "Cleaning..."
	$(GOCLEAN)
	rm -rf $(BIN_DIR)
	rm -f server.pid server.log
	rm -f coverage.out coverage.html

install: build ## Install binaries to $GOPATH/bin
	@echo "Installing binaries..."
	$(GOCMD) install $(SERVER_PKG)
	$(GOCMD) install $(CLIENT_PKG)

# Development helpers
check: fmt vet test ## Run format, vet, and test

rebuild: clean build ## Clean and rebuild everything

server-logs: ## Show server logs (if running in dev mode)
	@if [ -f server.log ]; then \
		tail -f server.log; \
	else \
		echo "No server log file found. Start with 'make dev'"; \
	fi

# Quick development cycle
quick: fmt build run-server ## Quick development cycle: format, build, and run server

# Deployment targets
deploy: build ## Deploy binaries to CloudLab machines (requires machines.txt)
	@echo "Deploying binaries to CloudLab machines..."
	./deploy-binaries.sh machines.txt

deploy-with-source: build ## Deploy binaries and source code to CloudLab machines
	@echo "Deploying binaries and source to CloudLab machines..."
	./deploy-binaries.sh -s --helper machines.txt

test-deployment: ## Test deployed binaries on CloudLab machines
	@echo "Testing deployed binaries..."
	./deploy-binaries.sh -t machines.txt

extract-machines: ## Extract machine hostnames from manifest.xml
	@echo "Extracting machine hostnames from manifest.xml..."
	./extract-machines.py -o machines.txt manifest.xml

# CloudLab workflow
cloudlab-setup: extract-machines deploy-with-source ## Complete CloudLab setup: extract machines and deploy
	@echo "CloudLab setup complete!"
	@echo "Next steps:"
	@echo "1. SSH to any machine: ssh <username>@<hostname>"
	@echo "2. Start server: ~/kvs-lab/kvs server 8080"
	@echo "3. Run client: ~/kvs-lab/kvs client 8080"
