#!/bin/bash
# List all windows to help identify the cast window

osascript << 'EOF'
tell application "System Events"
    set windowList to {}
    repeat with proc in processes
        try
            set procName to name of proc
            repeat with win in windows of proc
                try
                    set winName to name of win
                    set winSize to size of win
                    set winPos to position of win
                    set winWidth to item 1 of winSize
                    set winHeight to item 2 of winSize
                    set winID to id of win
                    if winName is not "" then
                        set end of windowList to procName & " | " & winName & " | " & winWidth & "x" & winHeight & " | ID:" & winID
                    end if
                end try
            end repeat
        end try
    end repeat
    return windowList
end tell
EOF

