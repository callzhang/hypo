#!/bin/bash
# Focus the cast window using AppleScript - optimized version

osascript << 'EOF'
tell application "System Events"
    -- Try exact process name first (fastest)
    set targetNames to {"Xiaomi Interconnectivity", "小米互联服务", "Xiaomi", "Interconnectivity"}
    repeat with targetName in targetNames
        try
            set proc to first process whose name contains targetName
            if proc is not missing value then
                set frontmost of proc to true
                delay 0.1
                try
                    set win to window 1 of proc
                    perform action "AXRaise" of win
                end try
                return "focused"
            end if
        end try
    end repeat
    
    -- Fallback: search all processes (but limit to first 30)
    set processCount to 0
    repeat with proc in processes
        set processCount to processCount + 1
        if processCount > 30 then exit repeat  -- Limit search
        try
            set procName to name of proc
            if procName is "Xiaomi Interconnectivity" or procName contains "Xiaomi Interconnectivity" or procName contains "小米" then
                set frontmost of proc to true
                delay 0.1
                try
                    set win to window 1 of proc
                    perform action "AXRaise" of win
                end try
                return "focused"
            end if
        end try
    end repeat
    return "not_found"
end tell
EOF

