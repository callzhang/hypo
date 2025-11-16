#!/usr/bin/env python3
"""
Find and focus the Android cast window using macOS Accessibility API
"""

import subprocess
import sys

def find_and_focus_cast_window():
    """Find cast window by process name or dimensions and focus it"""
    
    # Try using osascript with a simpler approach
    script = '''
    tell application "System Events"
        set targetProc to missing value
        set targetWindow to missing value
        
        -- Find 小米互联服务 process
        repeat with proc in processes
            try
                set procName to name of proc
                if procName contains "小米" or procName contains "Xiaomi" or procName contains "Interconnectivity" then
                    set targetProc to proc
                    -- Get first window of this process
                    try
                        set targetWindow to window 1 of proc
                    end try
                    exit repeat
                end if
            end try
        end repeat
        
        -- If not found, try by dimensions
        if targetWindow is missing value then
            set maxHeight to 0
            repeat with proc in processes
                try
                    repeat with win in windows of proc
                        try
                            set winSize to size of win
                            set winWidth to item 1 of winSize
                            set winHeight to item 2 of winSize
                            if winHeight > winWidth and winHeight > 400 and winWidth > 200 and winWidth < 600 then
                                if winHeight > maxHeight then
                                    set maxHeight to winHeight
                                    set targetWindow to win
                                    set targetProc to proc
                                end if
                            end if
                        end try
                    end repeat
                end try
            end repeat
        end if
        
        if targetWindow is not missing value then
            set frontmost of targetProc to true
            delay 0.5
            perform action "AXRaise" of targetWindow
            delay 0.5
            return "found"
        else
            return "not_found"
        end if
    end tell
    '''
    
    try:
        result = subprocess.run(
            ['osascript', '-e', script],
            capture_output=True,
            text=True,
            timeout=5
        )
        return result.stdout.strip() == "found"
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return False

if __name__ == "__main__":
    if find_and_focus_cast_window():
        print("found")
        sys.exit(0)
    else:
        print("not_found")
        sys.exit(1)

