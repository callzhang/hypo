#!/usr/bin/env python3
"""
Get window bounds for Xiaomi cast window using PyObjC (more reliable than AppleScript)
"""

import subprocess
import sys

def get_window_bounds():
    """Get window bounds using AppleScript with better error handling"""
    
    script = '''
    tell application "System Events"
        set targetBounds to ""
        repeat with proc in processes
            try
                set procName to name of proc
                if procName contains "小米" then
                    try
                        -- Get all windows
                        set winList to windows of proc
                        if (count of winList) > 0 then
                            set win to item 1 of winList
                            set winPos to position of win
                            set winSize to size of win
                            set winX to item 1 of winPos
                            set winY to item 2 of winPos
                            set winW to item 1 of winSize
                            set winH to item 2 of winSize
                            set targetBounds to winX & "," & winY & "," & winW & "," & winH
                            exit repeat
                        end if
                    end try
                end if
            end try
        end repeat
        return targetBounds
    end tell
    '''
    
    try:
        result = subprocess.run(
            ['osascript', '-e', script],
            capture_output=True,
            text=True,
            timeout=5
        )
        bounds = result.stdout.strip()
        if bounds and bounds != "":
            return bounds
        return None
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return None

if __name__ == "__main__":
    bounds = get_window_bounds()
    if bounds:
        print(bounds)
        sys.exit(0)
    else:
        print("", end="")
        sys.exit(1)

