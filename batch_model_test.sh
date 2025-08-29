#!/bin/bash

# PICARD Batch Model Testing Automation Script
# Tests multiple models sequentially: VLLM -> Agentic Server -> PICARD -> Scorer
# Author: Automated batch testing system
# Usage: ./batch_model_test.sh

set -e  # Exit on any error

# Configuration
VLLM_DIR="kz-gaudi-imagemaker"
AGENTIC_DIR="qwen-agentic-server" 
PICARD_DIR="picard"
PICARD_CONFIG="config/picard_abridged_standard.yaml"
AGENTIC_ENDPOINT="http://localhost:5002/api/chat"
VLLM_PORT=8969

# List of models to test (full HuggingFace format)
MODELS=(
    "Qwen/Qwen3-32B"
    "meta-llama/Llama-3.3-70B-Instruct"
    # Add more models here as needed
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Function to wait for service to be ready
wait_for_service() {
    local url=$1
    local service_name=$2
    local timeout=${3:-60}
    
    log_info "Waiting for $service_name to be ready at $url..."
    
    for i in $(seq 1 $timeout); do
        if curl -s --connect-timeout 3 "$url" > /dev/null 2>&1; then
            log_success "$service_name is ready!"
            return 0
        fi
        sleep 2
    done
    
    log_error "$service_name failed to start within $timeout seconds"
    return 1
}

# Function to check if Docker container is running
check_docker_container() {
    local container_pattern=$1
    if docker ps | grep -q "$container_pattern"; then
        return 0  # Container is running
    else
        return 1  # Container is not running
    fi
}

# Function to stop Docker containers
stop_docker_containers() {
    log_info "Stopping any running Docker containers..."
    # Stop containers that might be using the Gaudi runtime or VLLM
    docker ps -q --filter "ancestor=kamiwazaai/gaudi-vllm-syn1.21.4:latest" | xargs -r docker stop
    sleep 5
}

# Function to stop agentic server
stop_agentic_server() {
    log_info "Stopping agentic server..."
    pkill -f "qwen_api.py" || true
    sleep 3
}

# Function to extract model name for labeling (drop repo prefix)
get_model_label() {
    local full_model=$1
    echo "$full_model" | cut -d'/' -f2
}

# Function to test a single model
test_model() {
    local model=$1
    local label=$(get_model_label "$model")
    
    log_info "=========================================="
    log_info "Testing Model: $model"
    log_info "Label: $label"
    log_info "=========================================="
    
    # Step 1: Launch VLLM with the model
    log_info "Step 1: Launching VLLM server with model $model..."
    cd "$VLLM_DIR"
    
    # Launch in background and capture PID
    ./test_launch.sh "$model" &
    local vllm_pid=$!
    
    cd - > /dev/null
    
    # Wait for VLLM to be ready
    if ! wait_for_service "http://localhost:$VLLM_PORT/v1/models" "VLLM Server" 120; then
        log_error "VLLM failed to start for model $model"
        kill $vllm_pid 2>/dev/null || true
        stop_docker_containers
        return 1
    fi
    
    # Step 2: Launch agentic server with the model
    log_info "Step 2: Launching agentic server with model $model..."
    cd "$AGENTIC_DIR"
    
    # Launch in background
    ./start.sh "$model" &
    local agentic_pid=$!
    
    cd - > /dev/null
    
    # Wait for agentic server to be ready
    if ! wait_for_service "$AGENTIC_ENDPOINT" "Agentic Server" 60; then
        log_error "Agentic server failed to start for model $model"
        kill $agentic_pid 2>/dev/null || true
        kill $vllm_pid 2>/dev/null || true
        stop_docker_containers
        return 1
    fi
    
    # Step 3: Run PICARD test
    log_info "Step 3: Running PICARD test..."
    cd "$PICARD_DIR"
    
    # Activate virtual environment and run test
    source venv/bin/activate
    
    # Capture PICARD output to extract result directory
    local picard_output
    if picard_output=$(python src/test_runner.py \
        --definitions "$PICARD_CONFIG" \
        --api-endpoint "$AGENTIC_ENDPOINT" \
        --label "$label" 2>&1); then
        
        log_success "PICARD test completed for $model"
        
        # Extract result directory from PICARD output
        local result_dir
        result_dir=$(echo "$picard_output" | grep "Test results available at:" | sed 's/.*Test results available at: //')
        
        if [ -n "$result_dir" ] && [ -d "$result_dir" ]; then
            # Step 4: Score the results using the specific directory
            log_info "Step 4: Scoring results in $result_dir..."
            if python src/scorer.py --test-dir "$result_dir"; then
                log_success "Scoring completed for $model"
            else
                log_error "Scoring failed for $model"
            fi
        else
            log_error "Could not find result directory for scoring"
            log_info "PICARD output: $picard_output"
        fi
        
    else
        log_error "PICARD test failed for $model"
        log_info "PICARD error output: $picard_output"
    fi
    
    deactivate
    cd - > /dev/null
    
    # Step 5: Cleanup - stop services
    log_info "Step 5: Cleaning up services..."
    kill $agentic_pid 2>/dev/null || true
    kill $vllm_pid 2>/dev/null || true
    stop_agentic_server
    stop_docker_containers
    
    # Wait a bit for cleanup
    sleep 10
    
    log_success "Model $model testing cycle completed"
    return 0
}

# Main execution
main() {
    log_info "Starting batch model testing..."
    log_info "Models to test: ${MODELS[*]}"
    
    local success_count=0
    local total_count=${#MODELS[@]}
    
    # Ensure we start clean
    stop_agentic_server
    stop_docker_containers
    
    for model in "${MODELS[@]}"; do
        log_info ""
        log_info "Testing model $((success_count + 1))/$total_count: $model"
        
        if test_model "$model"; then
            ((success_count++))
            log_success "✅ Model $model completed successfully"
        else
            log_error "❌ Model $model failed"
        fi
        
        # Brief pause between models
        sleep 5
    done
    
    # Final summary
    log_info ""
    log_info "=========================================="
    log_info "BATCH TESTING SUMMARY"
    log_info "=========================================="
    log_info "Total models tested: $total_count"
    log_success "Successful: $success_count"
    log_error "Failed: $((total_count - success_count))"
    
    if [ $success_count -eq $total_count ]; then
        log_success "🎉 All models tested successfully!"
        exit 0
    else
        log_warning "⚠️  Some models failed. Check logs above."
        exit 1
    fi
}

# Trap to ensure cleanup on script exit
cleanup() {
    log_warning "Script interrupted. Cleaning up..."
    stop_agentic_server
    stop_docker_containers
    exit 1
}

trap cleanup INT TERM

# Check prerequisites
if [ ! -d "$VLLM_DIR" ]; then
    log_error "VLLM directory not found: $VLLM_DIR"
    exit 1
fi

if [ ! -d "$AGENTIC_DIR" ]; then
    log_error "Agentic server directory not found: $AGENTIC_DIR"
    exit 1
fi

if [ ! -d "$PICARD_DIR" ]; then
    log_error "PICARD directory not found: $PICARD_DIR"
    exit 1
fi

# Make scripts executable
chmod +x "$VLLM_DIR/test_launch.sh" 2>/dev/null || true
chmod +x "$AGENTIC_DIR/start.sh" 2>/dev/null || true

# Run main function
main "$@"