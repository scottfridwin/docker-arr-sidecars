#!/usr/bin/env bash
set -uo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Initialize counters
total_tests=0
passed_tests=0
failed_tests=0
failed_test_files=()

echo "========================================="
echo "Running All Tests"
echo "========================================="
echo ""

# Find and run all test-*.bash files
while IFS= read -r -d '' test_file; do
    test_name=$(basename "$test_file")
    ((total_tests++))

    echo "Running: $test_name"
    echo "-----------------------------------------"

    if bash "$test_file"; then
        echo "✅ $test_name PASSED"
        ((passed_tests++))
    else
        echo "❌ $test_name FAILED"
        ((failed_tests++))
        failed_test_files+=("$test_name")
    fi

    echo ""
done < <(find "$SCRIPT_DIR" -maxdepth 1 -type f -name "test-*.bash" -print0 | sort -z)

# Print summary
echo "========================================="
echo "Test Summary"
echo "========================================="
echo "Total test files: $total_tests"
echo "Passed: $passed_tests"
echo "Failed: $failed_tests"

if ((failed_tests > 0)); then
    echo ""
    echo "Failed tests:"
    for failed_test in "${failed_test_files[@]}"; do
        echo "  - $failed_test"
    done
    echo ""
    exit 1
else
    echo ""
    echo "🎉 All tests passed!"
    echo ""
    exit 0
fi
