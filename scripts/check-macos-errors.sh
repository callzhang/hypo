#!/bin/bash
# Script to check for macOS error logs from HypoMenuBar

echo "Checking for error-level logs from com.hypo.clipboard subsystem..."
echo "Press Ctrl+C to stop"
echo ""

log stream --predicate 'subsystem == "com.hypo.clipboard"' --level error --style compact





