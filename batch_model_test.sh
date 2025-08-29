#!/bin/bash

# PICARD Batch Model Testing Automation Script
# Tests multiple models sequentially: VLLM -> Agentic Server -> PICARD -> Scorer
# Author: Automated batch testing system
# Usage: ./batch_model_test.sh

# Removed set -e for better cleanup handling and batch resilience

# Configuration
VLLM_DIR="kz-gaudi-imagemaker"
AGENTIC_DIR="qwen-agentic-server" 
PICARD_DIR="picard"
#PICARD_CONFIG="config/picard_abridged_standard.yaml"
PICARD_CONFIG="config/debug.yaml"
AGENTIC_ENDPOINT="http://localhost:5002/api/chat"
VLLM_PORT=8969

# List of models to test (full HuggingFace format)
MODELS=(
    "meta-llama/Llama-3.1-70B-Instruct"
    "meta-llama/Llama-3.3-70B-Instruct"
    "meta-llama/Llama-3.1-405B-Instruct"
    "meta-llama/Llama-4-Scout-17B-16E-Instruct"
    "Qwen/Qwen3-32B"
    "Qwen/Qwen3-235B-A22B"
    "Qwen/Qwen3-235B-A22B-Instruct-2507"
    "Qwen/Qwen3-235B-A22B-Thinking-2507"
    "Qwen/Qwen3-4B"
    "Qwen/Qwen3-4B-Instruct-2507"
    "Qwen/Qwen3-4B-Thinking-2507"
    "Qwen/Qwen3-30B-A3B"
    "Qwen/Qwen3-30B-A3B-Instruct-2507"
    "Qwen/Qwen3-30B-A3B-Thinking-2507"
    "Qwen/Qwen3-14B"
    "Qwen/Qwen3-8B"

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

# Function to wait for VLLM with smart detection
wait_for_vllm() {
    local url=$1
    local container_id=$2
    local max_wait=1800  # 30 minutes max
    local check_interval=10
    local last_log_line=""
    
    log_info "Waiting for VLLM server to be ready..."
    log_info "Monitoring Docker logs for download/startup progress..."
    
    for i in $(seq 1 $((max_wait / check_interval))); do
        # Check if service is ready first
        if curl -s --connect-timeout 3 "$url" > /dev/null 2>&1; then
            log_success "VLLM Server is ready!"
            return 0
        fi
        
        # Show progress from Docker logs
        local current_log
        current_log=$(docker logs --tail 1 "$container_id" 2>&1 | head -1)
        if [ "$current_log" != "$last_log_line" ] && [ -n "$current_log" ]; then
            log_info "VLLM: $current_log"
            last_log_line="$current_log"
        fi
        
        sleep $check_interval
    done
    
    log_error "VLLM failed to start within $((max_wait / 60)) minutes"
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
    docker ps -q --filter "ancestor=kamiwazaai/gaudi-vllm-syn1.21.4:latest" | xargs -r docker stop || true
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
    
    # Debug: Show the exact command being executed
    log_info "DEBUG: About to execute: ./detached_launch.sh \"$model\""
    log_info "DEBUG: Current directory: $(pwd)"
    log_info "DEBUG: detached_launch.sh exists: $(ls -la detached_launch.sh 2>/dev/null || echo 'FILE NOT FOUND')"
    
    # Launch and capture both PID and container ID
    local container_id
    container_id=$(./detached_launch.sh "$model")
    local vllm_pid=$!
    log_info "DEBUG: Started VLLM process with PID: $vllm_pid"
    log_info "DEBUG: Docker container ID: $container_id"
    
    cd - > /dev/null
    
    # Wait for VLLM to be ready with smart detection
    if ! wait_for_vllm "http://localhost:$VLLM_PORT/v1/models" "$container_id"; then
        log_error "VLLM failed to start for model $model"
        kill $vllm_pid 2>/dev/null || true
        stop_docker_containers
        return 1
    fi
    
    # Step 2: Launch agentic server with model $model..."
    log_info "Step 2: Launching agentic server with model $model..."
    cd "$AGENTIC_DIR"
    
    # Debug: Show the exact command being executed
    log_info "DEBUG: About to execute: ./start.sh \"$model\""
    log_info "DEBUG: Current directory: $(pwd)"
    log_info "DEBUG: start.sh exists: $(ls -la start.sh 2>/dev/null || echo 'FILE NOT FOUND')"
    
    # Launch in background (suppress output)
    ./start.sh "$model" > /dev/null 2>&1 &
    local agentic_pid=$!
    log_info "DEBUG: Started agentic server process with PID: $agentic_pid"
    
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
    
    # Run PICARD with real-time output
    if python src/test_runner.py \
        --definitions "$PICARD_CONFIG" \
        --api-endpoint "$AGENTIC_ENDPOINT" \
        --label "$label"; then
        
        log_success "PICARD test completed for $model"
        
        # Find the most recent result directory (since we can't capture the output)
        local result_dir
        result_dir=$(ls -td results/*/ 2>/dev/null | head -1 | sed 's|/$||')
        
        # Debug: Show what we found
        log_info "DEBUG: Looking for result directory..."
        log_info "DEBUG: ls -td results/*/ found: $(ls -td results/*/ 2>/dev/null | head -3)"
        log_info "DEBUG: Selected result_dir: '$result_dir'"
        log_info "DEBUG: Directory exists: $([ -d "$result_dir" ] && echo 'YES' || echo 'NO')"
        
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
        fi
        
    else
        log_error "PICARD test failed for $model"
    fi
    
    deactivate
    cd - > /dev/null
    
    # Step 5: Cleanup - stop services
    log_info "Step 5: Cleaning up services..."
    kill $agentic_pid 2>/dev/null || true
    kill $vllm_pid 2>/dev/null || true
    stop_agentic_server || true
    stop_docker_containers || true
    
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
        
        # Debug: Show what's about to happen
        log_info "DEBUG: About to call test_model for: $model"
        
        if test_model "$model"; then
            ((success_count++))
            log_success "✅ Model $model completed successfully"
            log_info "DEBUG: test_model returned success (0), success_count now: $success_count"
        else
            log_error "❌ Model $model failed"
            log_info "DEBUG: test_model returned failure (non-zero), success_count remains: $success_count"
        fi
        
        # Brief pause between models
        log_info "DEBUG: Sleeping 5 seconds before next model..."
        sleep 5
        log_info "DEBUG: Continuing to next iteration of loop..."
    done
    
    log_info "DEBUG: Finished main loop. success_count=$success_count, total_count=$total_count"
    
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
chmod +x "$VLLM_DIR/detached_launch.sh" 2>/dev/null || true
chmod +x "$AGENTIC_DIR/start.sh" 2>/dev/null || true

# Run main function
main "$@"
