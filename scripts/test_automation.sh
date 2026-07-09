#!/bin/bash
#
# Test Automation System Script
# Comprehensive testing of the new VPN automation features
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env

# Configuration
TEST_LOG="$ROOT_DIR/logs/automation_test.log"
PRIVADO_API_DIR="$SCRIPT_DIR/privado-api"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test results
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# Function to log and print
log_print() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message" >> "$TEST_LOG"
    
    case "$level" in
        "PASS")
            echo -e "${GREEN}✓ $message${NC}"
            ;;
        "FAIL")
            echo -e "${RED}✗ $message${NC}"
            ;;
        "INFO")
            echo -e "${BLUE}ℹ $message${NC}"
            ;;
        "WARN")
            echo -e "${YELLOW}⚠ $message${NC}"
            ;;
        *)
            echo "$message"
            ;;
    esac
}

# Function to run a test
run_test() {
    local test_name="$1"
    local test_command="$2"
    
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    log_print "INFO" "Running test: $test_name"
    
    if eval "$test_command" >/dev/null 2>&1; then
        log_print "PASS" "$test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_print "FAIL" "$test_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Function to test file existence and permissions
test_file_exists() {
    local file="$1"
    local description="$2"
    
    if [ -f "$file" ]; then
        if [ -x "$file" ]; then
            log_print "PASS" "$description exists and is executable"
        else
            log_print "WARN" "$description exists but is not executable"
        fi
        return 0
    else
        log_print "FAIL" "$description does not exist"
        return 1
    fi
}

# Function to test directory existence
test_dir_exists() {
    local dir="$1"
    local description="$2"
    
    if [ -d "$dir" ]; then
        log_print "PASS" "$description exists"
        return 0
    else
        log_print "FAIL" "$description does not exist"
        return 1
    fi
}

# Function to test dependencies
test_dependencies() {
    log_print "INFO" "Testing system dependencies..."
    
    local deps=("curl" "jq" "docker")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if command -v "$dep" >/dev/null 2>&1; then
            log_print "PASS" "Dependency $dep is installed"
        else
            log_print "FAIL" "Dependency $dep is missing"
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -eq 0 ]; then
        return 0
    else
        log_print "FAIL" "Missing dependencies: ${missing_deps[*]}"
        return 1
    fi
}

# Function to test configuration
test_configuration() {
    log_print "INFO" "Testing configuration..."
    
    local env_file="$ROOT_DIR/.env"
    if [ ! -f "$env_file" ]; then
        log_print "FAIL" ".env file not found"
        return 1
    fi
    
    # Check required variables
    local required_vars=("PRIVADO_USERNAME" "PRIVADO_PASSWORD")
    local missing_vars=()
    
    for var in "${required_vars[@]}"; do
        if grep -q "^$var=" "$env_file"; then
            local value=$(grep "^$var=" "$env_file" | cut -d'=' -f2 | tr -d '"')
            if [ -n "$value" ]; then
                log_print "PASS" "Configuration variable $var is set"
            else
                log_print "FAIL" "Configuration variable $var is empty"
                missing_vars+=("$var")
            fi
        else
            log_print "FAIL" "Configuration variable $var is missing"
            missing_vars+=("$var")
        fi
    done
    
    # Check automation settings
    local automation_vars=("WIREGUARD_AUTO_ROTATION" "WIREGUARD_AUTO_RECOVERY" "WIREGUARD_PREFERRED_COUNTRIES")
    for var in "${automation_vars[@]}"; do
        if grep -q "^$var=" "$env_file"; then
            log_print "PASS" "Automation setting $var is configured"
        else
            log_print "WARN" "Automation setting $var not found (using defaults)"
        fi
    done
    
    if [ ${#missing_vars[@]} -eq 0 ]; then
        return 0
    else
        log_print "FAIL" "Missing required variables: ${missing_vars[*]}"
        return 1
    fi
}

# Function to test Privado API scripts
test_privado_api() {
    log_print "INFO" "Testing Privado API functionality..."
    
    # Test authentication (dry run)
    if [ -f "$PRIVADO_API_DIR/privado_login.sh" ]; then
        log_print "INFO" "Testing Privado login script syntax..."
        if bash -n "$PRIVADO_API_DIR/privado_login.sh"; then
            log_print "PASS" "Privado login script syntax is valid"
        else
            log_print "FAIL" "Privado login script has syntax errors"
            return 1
        fi
    else
        log_print "FAIL" "Privado login script not found"
        return 1
    fi
    
    # Test server list script
    if [ -f "$PRIVADO_API_DIR/privado_get_servers.sh" ]; then
        log_print "INFO" "Testing server list script syntax..."
        if bash -n "$PRIVADO_API_DIR/privado_get_servers.sh"; then
            log_print "PASS" "Server list script syntax is valid"
        else
            log_print "FAIL" "Server list script has syntax errors"
            return 1
        fi
    else
        log_print "FAIL" "Server list script not found"
        return 1
    fi
    
    # Test config generation script
    if [ -f "$PRIVADO_API_DIR/privado_generate_config.sh" ]; then
        log_print "INFO" "Testing config generation script syntax..."
        if bash -n "$PRIVADO_API_DIR/privado_generate_config.sh"; then
            log_print "PASS" "Config generation script syntax is valid"
        else
            log_print "FAIL" "Config generation script has syntax errors"
            return 1
        fi
    else
        log_print "FAIL" "Config generation script not found"
        return 1
    fi
    
    return 0
}

# Function to test main automation script
test_automation_script() {
    log_print "INFO" "Testing main automation script..."
    
    local auto_script="$SCRIPT_DIR/auto_update_wireguard.sh"
    
    if [ ! -f "$auto_script" ]; then
        log_print "FAIL" "Main automation script not found"
        return 1
    fi
    
    # Test syntax
    if bash -n "$auto_script"; then
        log_print "PASS" "Main automation script syntax is valid"
    else
        log_print "FAIL" "Main automation script has syntax errors"
        return 1
    fi
    
    # Test help command
    if "$auto_script" help >/dev/null 2>&1; then
        log_print "PASS" "Main automation script help command works"
    else
        log_print "FAIL" "Main automation script help command failed"
        return 1
    fi
    
    return 0
}

# Function to test monitoring script
test_monitoring_script() {
    log_print "INFO" "Testing enhanced monitoring script..."
    
    local monitor_script="$SCRIPT_DIR/wireguard_monitor.sh"
    
    if [ ! -f "$monitor_script" ]; then
        log_print "FAIL" "Monitoring script not found"
        return 1
    fi
    
    # Test syntax
    if bash -n "$monitor_script"; then
        log_print "PASS" "Monitoring script syntax is valid"
    else
        log_print "FAIL" "Monitoring script has syntax errors"
        return 1
    fi
    
    return 0
}

# Function to test directory structure
test_directory_structure() {
    log_print "INFO" "Testing directory structure..."
    
    local dirs=(
        "$ROOT_DIR/logs"
        "$ROOT_DIR/scripts"
        "$ROOT_DIR/scripts/privado-api"
        "$ROOT_DIR/backups"
        "$ROOT_DIR/gluetun"
    )
    
    for dir in "${dirs[@]}"; do
        test_dir_exists "$dir" "Directory $(basename "$dir")"
    done
    
    return 0
}

# Function to test log file creation
test_log_creation() {
    log_print "INFO" "Testing log file creation..."
    
    local test_log_file="$ROOT_DIR/logs/test_$(date +%s).log"
    
    if echo "test" > "$test_log_file" 2>/dev/null; then
        log_print "PASS" "Can create log files"
        rm -f "$test_log_file"
        return 0
    else
        log_print "FAIL" "Cannot create log files"
        return 1
    fi
}

# Function to show summary
show_summary() {
    echo ""
    echo "=========================="
    echo "    TEST SUMMARY"
    echo "=========================="
    echo "Total tests: $TESTS_TOTAL"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
    echo ""
    
    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}🎉 All tests passed! Your automation system is ready to use.${NC}"
        echo ""
        echo "Next steps:"
        echo "1. Run: $SCRIPT_DIR/auto_update_wireguard.sh force"
        echo "2. Check logs: tail -f $ROOT_DIR/logs/auto_wireguard.log"
        echo "3. Monitor with: $SCRIPT_DIR/wireguard_monitor.sh"
        return 0
    else
        echo -e "${RED}❌ Some tests failed. Please fix the issues before using the automation system.${NC}"
        echo ""
        echo "Check the test log for details: $TEST_LOG"
        return 1
    fi
}

# Main function
main() {
    echo "🔧 Testing VPN Automation System"
    echo "================================"
    echo ""
    
    # Create logs directory
    mkdir -p "$(dirname "$TEST_LOG")"
    
    # Initialize test log
    echo "VPN Automation System Test - $(date)" > "$TEST_LOG"
    echo "========================================" >> "$TEST_LOG"
    
    # Run tests
    test_dependencies
    test_directory_structure
    test_configuration
    test_file_exists "$SCRIPT_DIR/auto_update_wireguard.sh" "Main automation script"
    test_file_exists "$SCRIPT_DIR/restart_vpn_stack.sh" "VPN stack restart script"
    test_file_exists "$SCRIPT_DIR/wireguard_monitor.sh" "Enhanced monitoring script"
    test_file_exists "$PRIVADO_API_DIR/privado_login.sh" "Privado login script"
    test_file_exists "$PRIVADO_API_DIR/privado_get_servers.sh" "Privado server list script"
    test_file_exists "$PRIVADO_API_DIR/privado_generate_config.sh" "Privado config generation script"
    test_privado_api
    test_automation_script
    test_monitoring_script
    test_log_creation
    
    # Show summary
    show_summary
}

# Run main function
main "$@"