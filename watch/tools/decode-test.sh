#!/bin/sh
# Compiles the Watch's data types for macOS and runs tools/decode-test.swift against them.
set -e
cd "$(dirname "$0")/.."
dir="$(mktemp -d)"
cp tools/decode-test.swift "$dir/main.swift"
swiftc -o "$dir/decode-test" Workouts/Models.swift Shared/PlanTypes.swift Shared/Plan.swift Shared/WeekPlan.swift Shared/Schedule.swift "$dir/main.swift"
"$dir/decode-test"
rm -rf "$dir"
