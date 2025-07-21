#!/bin/bash
set -e

# Amazon Q CLI V10 ENHANCED Deployment Script
# 6 Launch Configurations across all AZs and instance families with dynamic spot pricing
# Version: 1.0 - Enhanced Production Ready

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Enhanced logging function
log() {
    local level="$1"
    shift
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case $level in
        "INFO")  echo -e "${BLUE}[$timestamp] [INFO]${NC} $*" ;;
        "SUCCESS") echo -e "${GREEN}[$timestamp] [SUCCESS]${NC} $*" ;;
        "WARN")  echo -e "${YELLOW}[$timestamp] [WARN]${NC} $*" ;;
        "ERROR") echo -e "${RED}[$timestamp] [ERROR]${NC} $*" ;;
        "PRICE") echo -e "${PURPLE}[$timestamp] [PRICE]${NC} $*" ;;
        "CONFIG") echo -e "${CYAN}[$timestamp] [CONFIG]${NC} $*" ;;
    esac
}

# Configuration
REGION="us-west-2"
STACK_NAME="amazon-q-cli-vscode-v10-enhanced-$(date +%d%b%Y | tr '[:upper:]' '[:lower:]')"
TEMPLATE_FILE="qclivscode-cfn_template.yaml"
KEY_NAME="amazon-q-key-uswest2"

# Instance families and their characteristics
declare -A INSTANCE_FAMILIES=(
    ["m5"]="General Purpose - Balanced compute, memory, and networking"
    ["m6i"]="Latest General Purpose - Intel 3rd gen processors"
    ["c5"]="Compute Optimized - High performance processors"
    ["c6i"]="Latest Compute Optimized - Intel 3rd gen processors"
    ["r5"]="Memory Optimized - High memory-to-vCPU ratio"
    ["r6i"]="Latest Memory Optimized - Intel 3rd gen processors"
)

# Availability zones
AZS=("us-west-2a" "us-west-2b" "us-west-2c" "us-west-2d")

# Default spot prices (will be updated dynamically)
declare -A DEFAULT_SPOT_PRICES=(
    ["m5"]="0.400"
    ["m6i"]="0.350"
    ["c5"]="0.300"
    ["c6i"]="0.280"
    ["r5"]="0.450"
    ["r6i"]="0.400"
)

# Dynamic spot prices (will be calculated)
declare -A SPOT_PRICES

# Function to get current spot prices for all instance types
get_current_spot_prices() {
    log "PRICE" "🔍 Fetching current spot prices for all instance families..."
    
    local instance_types=("m5.2xlarge" "m6i.2xlarge" "c5.2xlarge" "c6i.2xlarge" "r5.2xlarge" "r6i.2xlarge")
    
    for instance_type in "${instance_types[@]}"; do
        local family=$(echo "$instance_type" | cut -d'.' -f1)
        
        log "PRICE" "Checking spot prices for $instance_type across all AZs..."
        
        # Get spot price history for the last hour across all AZs
        local spot_data=$(aws ec2 describe-spot-price-history \
            --region "$REGION" \
            --instance-types "$instance_type" \
            --product-descriptions "Linux/UNIX" \
            --start-time "$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%S')" \
            --query 'SpotPrices[*].[AvailabilityZone,SpotPrice,Timestamp]' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$spot_data" ]; then
            # Get the latest prices for each AZ and calculate average
            local total_price=0
            local count=0
            local max_price=0
            
            while IFS=$'\t' read -r az price timestamp; do
                if [[ " ${AZS[@]} " =~ " ${az} " ]]; then
                    total_price=$(echo "$total_price + $price" | bc -l)
                    count=$((count + 1))
                    
                    # Track maximum price for buffer calculation
                    if (( $(echo "$price > $max_price" | bc -l) )); then
                        max_price=$price
                    fi
                    
                    log "PRICE" "  $az: \$$price"
                fi
            done <<< "$spot_data"
            
            if [ $count -gt 0 ]; then
                # Calculate average and add 25% buffer
                local avg_price=$(echo "scale=3; $total_price / $count" | bc -l)
                local buffered_price=$(echo "scale=3; $avg_price * 1.25" | bc -l)
                
                # Ensure minimum price and maximum cap
                local min_price=${DEFAULT_SPOT_PRICES[$family]}
                if (( $(echo "$buffered_price < $min_price" | bc -l) )); then
                    buffered_price=$min_price
                fi
                
                # Cap at $0.500 for safety
                if (( $(echo "$buffered_price > 0.500" | bc -l) )); then
                    buffered_price="0.500"
                fi
                
                SPOT_PRICES[$family]=$buffered_price
                log "PRICE" "✅ $family: Average=\$$avg_price, Buffered=\$$buffered_price (25% buffer)"
            else
                SPOT_PRICES[$family]=${DEFAULT_SPOT_PRICES[$family]}
                log "WARN" "No recent spot price data for $instance_type, using default: \$${DEFAULT_SPOT_PRICES[$family]}"
            fi
        else
            SPOT_PRICES[$family]=${DEFAULT_SPOT_PRICES[$family]}
            log "WARN" "Failed to fetch spot prices for $instance_type, using default: \$${DEFAULT_SPOT_PRICES[$family]}"
        fi
    done
    
    log "SUCCESS" "Spot price analysis completed"
}

# Function to display spot price summary
display_spot_price_summary() {
    log "CONFIG" "📊 ENHANCED SPOT FLEET CONFIGURATION SUMMARY"
    echo "=============================================="
    echo -e "${CYAN}Instance Family Coverage:${NC}"
    
    for family in "${!INSTANCE_FAMILIES[@]}"; do
        echo -e "  ${GREEN}$family${NC}: ${INSTANCE_FAMILIES[$family]}"
        echo -e "    Spot Price: \$${SPOT_PRICES[$family]}"
    done
    
    echo
    echo -e "${CYAN}Availability Zone Coverage:${NC}"
    for az in "${AZS[@]}"; do
        echo -e "  ${GREEN}$az${NC}: Multi-instance family deployment"
    done
    
    echo
    echo -e "${CYAN}Launch Configuration Matrix:${NC}"
    echo -e "  1. ${GREEN}m5.2xlarge${NC} in us-west-2a (General Purpose)"
    echo -e "  2. ${GREEN}m6i.2xlarge${NC} in us-west-2b (Latest General Purpose)"
    echo -e "  3. ${GREEN}c5.2xlarge${NC} in us-west-2c (Compute Optimized)"
    echo -e "  4. ${GREEN}c6i.2xlarge${NC} in us-west-2d (Latest Compute Optimized)"
    echo -e "  5. ${GREEN}r5.2xlarge${NC} in us-west-2a (Memory Optimized)"
    echo -e "  6. ${GREEN}r6i.2xlarge${NC} in us-west-2b (Latest Memory Optimized)"
    echo "=============================================="
}

# Validate prerequisites
validate_prerequisites() {
    log "INFO" "🔍 Validating prerequisites..."
    
    # Check if template file exists
    if [ ! -f "$TEMPLATE_FILE" ]; then
        log "ERROR" "CloudFormation template not found: $TEMPLATE_FILE"
        exit 1
    fi
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        log "ERROR" "AWS CLI not found. Please install AWS CLI."
        exit 1
    fi
    
    # Check bc calculator for spot price calculations
    if ! command -v bc &> /dev/null; then
        log "WARN" "bc calculator not found. Installing..."
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y bc
        elif command -v yum &> /dev/null; then
            sudo yum install -y bc
        else
            log "ERROR" "Cannot install bc calculator. Please install manually."
            exit 1
        fi
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        log "ERROR" "AWS credentials not configured or expired."
        exit 1
    fi
    
    # Check if key pair exists
    if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" &> /dev/null; then
        log "ERROR" "Key pair '$KEY_NAME' not found in region $REGION"
        exit 1
    fi
    
    log "SUCCESS" "All prerequisites validated successfully"
}

# Check for existing stack EIPs
check_existing_stack_eips() {
    log "INFO" "🔍 Checking for existing EIPs belonging to stack: $STACK_NAME"
    
    local existing_eips=$(aws ec2 describe-addresses --region "$REGION" \
        --query 'Addresses[?Tags[?Key==`aws:cloudformation:stack-name` && Value==`'$STACK_NAME'`]].{IP:PublicIp,AllocationId:AllocationId,Associated:InstanceId}' \
        --output table 2>/dev/null)
    
    if [ -n "$existing_eips" ] && [ "$existing_eips" != "[]" ]; then
        log "SUCCESS" "Found existing stack EIPs that will be preserved:"
        echo "$existing_eips"
    else
        log "INFO" "No existing EIPs found for this stack - new EIP will be created"
    fi
}

# Clean up orphaned Elastic IPs (ENHANCED - preserves stack-owned EIPs)
cleanup_eips() {
    log "INFO" "🧹 Cleaning up orphaned Elastic IPs (preserving stack-owned EIPs)..."
    
    # First, get all unassociated EIPs
    ALL_ORPHANED_EIPS=$(aws ec2 describe-addresses --region "$REGION" \
        --query 'Addresses[?AssociationId==null && InstanceId==null].AllocationId' \
        --output text)
    
    if [ -n "$ALL_ORPHANED_EIPS" ] && [ "$ALL_ORPHANED_EIPS" != "None" ]; then
        log "INFO" "Found unassociated EIPs, checking which ones belong to current stack..."
        
        # Check each EIP to see if it belongs to our stack
        ORPHANED_EIPS=""
        for eip in $ALL_ORPHANED_EIPS; do
            # Check if this EIP belongs to our stack
            STACK_OWNED=$(aws ec2 describe-addresses --region "$REGION" \
                --allocation-ids "$eip" \
                --query 'Addresses[0].Tags[?Key==`aws:cloudformation:stack-name` && Value==`'$STACK_NAME'`]' \
                --output text)
            
            if [ -z "$STACK_OWNED" ] || [ "$STACK_OWNED" = "None" ]; then
                # This EIP doesn't belong to our stack, mark for deletion
                ORPHANED_EIPS="$ORPHANED_EIPS $eip"
                log "INFO" "EIP $eip does not belong to stack $STACK_NAME - will be deleted"
            else
                log "SUCCESS" "EIP $eip belongs to stack $STACK_NAME - preserving"
            fi
        done
        
        # Delete only the truly orphaned EIPs
        if [ -n "$ORPHANED_EIPS" ]; then
            log "WARN" "Deleting orphaned EIPs NOT belonging to current stack:$ORPHANED_EIPS"
            for eip in $ORPHANED_EIPS; do
                log "INFO" "Releasing orphaned EIP: $eip"
                if aws ec2 release-address --region "$REGION" --allocation-id "$eip"; then
                    log "SUCCESS" "Released orphaned EIP: $eip"
                else
                    log "WARN" "Failed to release EIP: $eip"
                fi
            done
            
            # Wait for AWS to process releases
            log "INFO" "Waiting 30 seconds for AWS to process EIP releases..."
            sleep 30
        else
            log "SUCCESS" "All unassociated EIPs belong to current stack - none deleted"
        fi
    else
        log "SUCCESS" "No unassociated EIPs found"
    fi
}

# Check if stack already exists
check_existing_stack() {
    log "INFO" "🔍 Checking for existing stack: $STACK_NAME"
    
    if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" &> /dev/null; then
        log "WARN" "Stack '$STACK_NAME' already exists!"
        read -p "Do you want to update the existing stack? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            STACK_OPERATION="update"
            log "INFO" "Will update existing stack"
        else
            log "ERROR" "Deployment cancelled by user"
            exit 1
        fi
    else
        STACK_OPERATION="create"
        log "INFO" "Will create new stack"
    fi
}

# Deploy CloudFormation stack with enhanced parameters
deploy_stack() {
    log "INFO" "🚀 Deploying Enhanced CloudFormation stack: $STACK_NAME"
    log "INFO" "Template: $TEMPLATE_FILE"
    log "INFO" "Region: $REGION"
    log "INFO" "Operation: $STACK_OPERATION"
    
    # Prepare parameters with dynamic spot prices
    local parameters=""
    parameters+="ParameterKey=KeyName,ParameterValue=$KEY_NAME "
    parameters+="ParameterKey=SpotPriceM5,ParameterValue=${SPOT_PRICES[m5]} "
    parameters+="ParameterKey=SpotPriceM6i,ParameterValue=${SPOT_PRICES[m6i]} "
    parameters+="ParameterKey=SpotPriceC5,ParameterValue=${SPOT_PRICES[c5]} "
    parameters+="ParameterKey=SpotPriceC6i,ParameterValue=${SPOT_PRICES[c6i]} "
    parameters+="ParameterKey=SpotPriceR5,ParameterValue=${SPOT_PRICES[r5]} "
    parameters+="ParameterKey=SpotPriceR6i,ParameterValue=${SPOT_PRICES[r6i]}"
    
    log "CONFIG" "Deployment parameters:"
    log "CONFIG" "  Key Name: $KEY_NAME"
    log "CONFIG" "  M5 Spot Price: \$${SPOT_PRICES[m5]}"
    log "CONFIG" "  M6i Spot Price: \$${SPOT_PRICES[m6i]}"
    log "CONFIG" "  C5 Spot Price: \$${SPOT_PRICES[c5]}"
    log "CONFIG" "  C6i Spot Price: \$${SPOT_PRICES[c6i]}"
    log "CONFIG" "  R5 Spot Price: \$${SPOT_PRICES[r5]}"
    log "CONFIG" "  R6i Spot Price: \$${SPOT_PRICES[r6i]}"
    
    if [ "$STACK_OPERATION" = "create" ]; then
        aws cloudformation create-stack \
            --stack-name "$STACK_NAME" \
            --template-body "file://$TEMPLATE_FILE" \
            --parameters $parameters \
            --capabilities CAPABILITY_IAM \
            --region "$REGION" \
            --tags Key=Purpose,Value=AmazonQ-CLI-VSCode Key=Version,Value=V10-ENHANCED Key=InstanceFamilies,Value=M5-M6i-C5-C6i-R5-R6i
    else
        aws cloudformation update-stack \
            --stack-name "$STACK_NAME" \
            --template-body "file://$TEMPLATE_FILE" \
            --parameters $parameters \
            --capabilities CAPABILITY_IAM \
            --region "$REGION"
    fi
    
    log "SUCCESS" "Enhanced CloudFormation deployment initiated"
}

# Monitor deployment progress with enhanced logging
monitor_deployment() {
    log "INFO" "📊 Monitoring enhanced deployment progress..."
    
    local start_time=$(date +%s)
    local timeout=2400  # 40 minutes timeout for enhanced deployment
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $timeout ]; then
            log "ERROR" "Deployment timeout after 40 minutes"
            exit 1
        fi
        
        # Get stack status
        local stack_status=$(aws cloudformation describe-stacks \
            --stack-name "$STACK_NAME" \
            --region "$REGION" \
            --query 'Stacks[0].StackStatus' \
            --output text 2>/dev/null || echo "UNKNOWN")
        
        case $stack_status in
            "CREATE_COMPLETE"|"UPDATE_COMPLETE")
                log "SUCCESS" "Enhanced stack deployment completed successfully!"
                break
                ;;
            "CREATE_FAILED"|"UPDATE_FAILED"|"ROLLBACK_COMPLETE"|"UPDATE_ROLLBACK_COMPLETE")
                log "ERROR" "Stack deployment failed with status: $stack_status"
                show_stack_events
                exit 1
                ;;
            "CREATE_IN_PROGRESS"|"UPDATE_IN_PROGRESS")
                local minutes=$((elapsed / 60))
                log "INFO" "Enhanced deployment in progress... (${minutes}m elapsed, status: $stack_status)"
                ;;
            *)
                log "WARN" "Unknown stack status: $stack_status"
                ;;
        esac
        
        sleep 30
    done
}

# Show recent stack events in case of failure
show_stack_events() {
    log "INFO" "📋 Recent stack events:"
    aws cloudformation describe-stack-events \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'StackEvents[0:15].[Timestamp,ResourceStatus,ResourceType,LogicalResourceId,ResourceStatusReason]' \
        --output table
}

# Get deployment outputs with enhanced information
get_deployment_info() {
    log "INFO" "📋 Retrieving enhanced deployment information..."
    
    # Get stack outputs
    local outputs=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs')
    
    if [ "$outputs" != "null" ]; then
        echo
        log "SUCCESS" "🎉 V10 ENHANCED Deployment Complete!"
        echo "=============================================="
        
        # Extract key information
        local elastic_ip=$(echo "$outputs" | jq -r '.[] | select(.OutputKey=="ElasticIP") | .OutputValue')
        local vscode_url=$(echo "$outputs" | jq -r '.[] | select(.OutputKey=="VSCodeServerURL") | .OutputValue')
        local ssh_command=$(echo "$outputs" | jq -r '.[] | select(.OutputKey=="SSHCommand") | .OutputValue')
        local spot_fleet_id=$(echo "$outputs" | jq -r '.[] | select(.OutputKey=="SpotFleetId") | .OutputValue')
        local instance_families=$(echo "$outputs" | jq -r '.[] | select(.OutputKey=="InstanceFamilies") | .OutputValue')
        local availability_zones=$(echo "$outputs" | jq -r '.[] | select(.OutputKey=="AvailabilityZones") | .OutputValue')
        
        echo -e "${GREEN}🌐 Elastic IP:${NC} $elastic_ip"
        echo -e "${GREEN}💻 VS Code Server:${NC} $vscode_url"
        echo -e "${GREEN}🔑 SSH Command:${NC} $ssh_command"
        echo -e "${GREEN}🚀 Spot Fleet ID:${NC} $spot_fleet_id"
        echo -e "${GREEN}🏗️  Instance Families:${NC} $instance_families"
        echo -e "${GREEN}🌍 Availability Zones:${NC} $availability_zones"
        echo
        echo -e "${BLUE}📋 Enhanced Features:${NC}"
        echo "  ✅ Amazon Q CLI with 17 MCP servers"
        echo "  ✅ VS Code Server (passwordless access)"
        echo "  ✅ 6 Launch configurations for maximum availability"
        echo "  ✅ Multi-AZ deployment across all us-west-2 zones"
        echo "  ✅ Multiple instance families (M5, M6i, C5, C6i, R5, R6i)"
        echo "  ✅ Dynamic spot pricing with 25% buffer"
        echo "  ✅ Persistent storage across spot interruptions"
        echo "  ✅ Development tools: Node.js, Python, Docker"
        echo "  ✅ Cost optimized with intelligent spot selection"
        echo
        echo -e "${PURPLE}💰 Spot Price Configuration:${NC}"
        for family in "${!SPOT_PRICES[@]}"; do
            echo "  $family: \$${SPOT_PRICES[$family]}"
        done
        echo
        echo -e "${YELLOW}⏳ Note:${NC} Instance setup may take 5-10 minutes after stack creation."
        echo -e "${YELLOW}🔐 Authentication:${NC} VS Code Server is passwordless, Amazon Q CLI requires 'q login'"
        echo
    else
        log "WARN" "No stack outputs found"
    fi
}

# Wait for instance to be ready with enhanced monitoring
wait_for_instance() {
    log "INFO" "⏳ Waiting for enhanced instance to be ready..."
    
    # Get Elastic IP from stack outputs
    local elastic_ip=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`ElasticIP`].OutputValue' \
        --output text)
    
    if [ -n "$elastic_ip" ] && [ "$elastic_ip" != "None" ]; then
        log "INFO" "Testing connectivity to $elastic_ip..."
        
        local max_attempts=25  # Increased for enhanced setup
        local attempt=1
        
        while [ $attempt -le $max_attempts ]; do
            if curl -s --connect-timeout 5 "http://$elastic_ip:8080" > /dev/null 2>&1; then
                log "SUCCESS" "VS Code Server is responding at http://$elastic_ip:8080"
                
                # Additional check for spot fleet status
                local spot_fleet_id=$(aws cloudformation describe-stacks \
                    --stack-name "$STACK_NAME" \
                    --region "$REGION" \
                    --query 'Stacks[0].Outputs[?OutputKey==`SpotFleetId`].OutputValue' \
                    --output text)
                
                if [ -n "$spot_fleet_id" ]; then
                    local active_instances=$(aws ec2 describe-spot-fleet-instances \
                        --spot-fleet-request-id "$spot_fleet_id" \
                        --region "$REGION" \
                        --query 'ActiveInstances | length')
                    log "SUCCESS" "Spot fleet has $active_instances active instance(s)"
                fi
                break
            else
                log "INFO" "Attempt $attempt/$max_attempts: Enhanced VS Code Server not ready yet..."
                sleep 30
                ((attempt++))
            fi
        done
        
        if [ $attempt -gt $max_attempts ]; then
            log "WARN" "VS Code Server not responding after $max_attempts attempts"
            log "INFO" "Enhanced instance may still be setting up. Check manually in a few minutes."
        fi
    fi
}

# Cleanup function for script interruption
cleanup_on_exit() {
    log "WARN" "Script interrupted. Enhanced deployment may still be in progress."
    log "INFO" "Check CloudFormation console for stack status: $STACK_NAME"
}

# Main deployment function
main() {
    echo "=============================================="
    echo "🚀 Amazon Q CLI V10 ENHANCED Deployment Script"
    echo "   6 Launch Configs | Multi-AZ | Dynamic Pricing"
    echo "=============================================="
    echo
    
    # Set up cleanup on exit
    trap cleanup_on_exit INT TERM
    
    # Enhanced deployment steps
    validate_prerequisites
    get_current_spot_prices
    display_spot_price_summary
    
    echo
    read -p "Proceed with enhanced deployment? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "INFO" "Deployment cancelled by user"
        exit 0
    fi
    
    check_existing_stack_eips
    cleanup_eips
    check_existing_stack
    deploy_stack
    monitor_deployment
    get_deployment_info
    wait_for_instance
    
    echo
    log "SUCCESS" "🎉 V10 ENHANCED deployment completed successfully!"
    log "INFO" "Stack Name: $STACK_NAME"
    log "INFO" "Region: $REGION"
    log "INFO" "Instance Families: M5, M6i, C5, C6i, R5, R6i"
    log "INFO" "Availability Zones: us-west-2a, us-west-2b, us-west-2c, us-west-2d"
    echo "=============================================="
}

# Show usage information
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Enhanced Amazon Q CLI V10 Deployment with 6 Launch Configurations"
    echo
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  -s, --stack    Custom stack name"
    echo "  -r, --region   AWS region (default: us-west-2)"
    echo "  -k, --key      Key pair name (default: amazon-q-key-uswest2)"
    echo
    echo "Features:"
    echo "  • 6 Launch configurations across all AZs"
    echo "  • Multiple instance families (M5, M6i, C5, C6i, R5, R6i)"
    echo "  • Dynamic spot pricing with real-time analysis"
    echo "  • Enhanced availability and cost optimization"
    echo
    echo "Example:"
    echo "  $0 --stack my-enhanced-stack --region us-west-2"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -s|--stack)
            STACK_NAME="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -k|--key)
            KEY_NAME="$2"
            shift 2
            ;;
        *)
            log "ERROR" "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Run main function
main
