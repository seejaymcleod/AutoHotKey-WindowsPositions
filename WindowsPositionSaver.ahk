#Requires AutoHotkey v2.0
#SingleInstance Force

OnError(LogError)

LogError(err, mode) {
    logText := A_Now . " - Error on line " . err.Line . " in " . err.What . ": " . err.Message . "`n"
    FileAppend(logText, A_ScriptDir . "\WindowsPositionSaver_ErrorLog.txt")
    return 0 ; Still show the default error (0) or suppress it (1)
}

global SettingsFile := "WindowPositions.json"
global IgnoreFile := "IgnoreList.txt"

global LayoutSlots := Map()
Loop 9
    LayoutSlots[A_Index] := Map()

global IgnoreList := Map()

; Load data on startup
LoadIgnoreList()
LoadJSON()

; --- HOTKEY DEFINITIONS ---

; Slots 1-9
Loop 9 {
    ; CTRL + ALT + SHIFT + 1-9 = SAVE
    Hotkey("^!+" A_Index, SaveLayoutHotkey)
    
    ; CTRL + SHIFT + 1-9 = LOAD
    Hotkey("^+" A_Index, LoadLayoutHotkey)
}

; CTRL + ALT + SHIFT + 0 = Toggle Ignore for Active Window
^!+0:: ToggleIgnoreActiveWindow()

SaveLayoutHotkey(ThisHotkey) {
    slot := Integer(SubStr(ThisHotkey, -1))
    SaveLayout(slot)
}

LoadLayoutHotkey(ThisHotkey) {
    slot := Integer(SubStr(ThisHotkey, -1))
    LoadLayout(slot)
}

; --- IGNORING WINDOWS ---

ToggleIgnoreActiveWindow() {
    global IgnoreList
    hwnd := WinExist("A")
    if !hwnd
        return
    
    try {
        processName := WinGetProcessName(hwnd)
        if IgnoreList.Has(processName) {
            IgnoreList.Delete(processName)
            ToolTip("Removed '" processName "' from ignore list.")
        } else {
            IgnoreList[processName] := true
            ToolTip("Added '" processName "' to ignore list.")
        }
        SaveIgnoreList()
    } catch {
        ToolTip("Could not get process name for active window.")
    }
    SetTimer(() => ToolTip(), -2000)
}

LoadIgnoreList() {
    global IgnoreList
    if FileExist(IgnoreFile) {
        text := FileRead(IgnoreFile)
        Loop Parse text, "`n", "`r" {
            if (A_LoopField != "")
                IgnoreList[A_LoopField] := true
        }
    }
}

SaveIgnoreList() {
    global IgnoreList
    text := ""
    for process, _ in IgnoreList
        text .= process "`n"
    if FileExist(IgnoreFile)
        FileDelete(IgnoreFile)
    if (text != "")
        FileAppend(text, IgnoreFile)
}

; --- CORE FUNCTIONS ---

SaveLayout(slotNumber) {
    global LayoutSlots, IgnoreList
    currentSlot := LayoutSlots[slotNumber]
    currentSlot.Clear() ; Wipe previous data for this specific slot
    
    winList := WinGetList(,, "Program Manager")
    
    for hwnd in winList {
        style := WinGetStyle(hwnd)
        if !(style & 0x10000000) ; Must be visible
            continue
            
        try {
            processName := WinGetProcessName(hwnd)
            title := WinGetTitle(hwnd)
            
            if (title == "" || processName == "Explorer.exe" && title == "")
                continue
                
            if IgnoreList.Has(processName)
                continue
                
            WinGetPos(&x, &y, &w, &h, hwnd)
            
            url := ""
            exePath := WinGetProcessPath(hwnd)
            
            ; Key format logic
            if (processName == "chrome.exe") {
                windowKey := "Chrome|" . title
                
                ; Backup active window and clipboard
                prevActive := WinGetID("A")
                oldClip := ClipboardAll()
                A_Clipboard := ""
                
                ; Activate Chrome and get URL
                WinActivate(hwnd)
                if WinWaitActive(hwnd, , 1) {
                    Send "^l"
                    Sleep 50
                    Send "^c"
                    if ClipWait(0.5) {
                        url := A_Clipboard
                    }
                }
                
                ; Restore clipboard and previous active window
                A_Clipboard := oldClip
                if (prevActive && prevActive != hwnd && WinExist(prevActive)) {
                    WinActivate(prevActive)
                }
            } else {
                windowKey := processName . "|" . title
            }
            
            currentSlot[windowKey] := {x: x, y: y, w: w, h: h, url: url, exePath: exePath}
        }
    }
    
    SaveJSON()
    ToolTip("Layout saved to Slot " . slotNumber . " (File Updated)")
    SetTimer(() => ToolTip(), -2000)
}

LoadLayout(slotNumber) {
    global LayoutSlots
    LoadJSON() ; Refresh from file in case it was manually edited
    
    currentSlot := LayoutSlots[slotNumber]
    
    if (currentSlot.Count == 0) {
        ToolTip("Slot " . slotNumber . " is empty!")
        SetTimer(() => ToolTip(), -2000)
        return
    }
    
    ; Show loading GUI
    loadingGui := Gui("+AlwaysOnTop -Caption +Border +ToolWindow")
    loadingGui.SetFont("s11", "Segoe UI")
    loadingGui.Add("Text", "w250 Center", "Restoring Layout " . slotNumber . "...`nPlease wait.")
    loadingGui.Show("NoActivate")
    
    currentWins := WinGetList(,, "Program Manager")
    matchedKeys := Map()
    movesToApply := []
    openedNewWindow := false
    
    for hwnd in currentWins {
        try {
            processName := WinGetProcessName(hwnd)
            title := WinGetTitle(hwnd)
            matched := false
            
            if (processName == "chrome.exe") {
                ; 1. Try exact website title match
                for key, pos in currentSlot {
                    if (!matchedKeys.Has(key) && key == "Chrome|" . title) {
                        WinRestore(hwnd)
                        WinMove(pos.x, pos.y, pos.w, pos.h, hwnd)
                        movesToApply.Push({hwnd: hwnd, x: pos.x, y: pos.y, w: pos.w, h: pos.h})
                        matchedKeys[key] := true
                        matched := true
                        break
                    }
                }
                ; Only exact website title match is allowed for Chrome now.
            } 
            else {
                ; Standard application matching
                for key, pos in currentSlot {
                    if (!matchedKeys.Has(key) && key == processName . "|" . title) {
                        WinRestore(hwnd)
                        WinMove(pos.x, pos.y, pos.w, pos.h, hwnd)
                        movesToApply.Push({hwnd: hwnd, x: pos.x, y: pos.y, w: pos.w, h: pos.h})
                        matchedKeys[key] := true
                        break
                    }
                }
            }
        }
    }
    
    ; 3. Open missing windows
    for key, pos in currentSlot {
        if (!matchedKeys.Has(key)) {
            if (SubStr(key, 1, 7) == "Chrome|") {
                if (pos.HasOwnProp("url") && pos.url != "") {
                    chromeWinsBefore := WinGetList("ahk_exe chrome.exe")
                    
                    Run("chrome.exe --new-window `"" pos.url "`"")
                    
                    newHwnd := 0
                    Loop 50 { ; Wait up to 5 seconds
                        Sleep 100
                        chromeWinsAfter := WinGetList("ahk_exe chrome.exe")
                        if (chromeWinsAfter.Length > chromeWinsBefore.Length) {
                            for ahwnd in chromeWinsAfter {
                                isNew := true
                                for bhwnd in chromeWinsBefore {
                                    if (ahwnd == bhwnd) {
                                        isNew := false
                                        break
                                    }
                                }
                                if (isNew) {
                                    newHwnd := ahwnd
                                    break 2
                                }
                            }
                        }
                    }
                    
                    if (newHwnd) {
                        WinRestore(newHwnd)
                        WinMove(pos.x, pos.y, pos.w, pos.h, newHwnd)
                        movesToApply.Push({hwnd: newHwnd, x: pos.x, y: pos.y, w: pos.w, h: pos.h})
                        openedNewWindow := true
                    }
                }
            }
            else if (pos.HasOwnProp("exePath") && pos.exePath != "") {
                exePath := pos.exePath
                SplitPath(exePath, &fileName)
                
                winsBefore := WinGetList("ahk_exe " fileName)
                
                if (fileName == "ApplicationFrameHost.exe") {
                    ; Workaround for UWP apps like SoundTale
                    ; They cannot be launched directly via their exePath
                    titleToType := SubStr(key, InStr(key, "|") + 1)
                    if (dashPos := InStr(titleToType, " - "))
                        titleToType := SubStr(titleToType, 1, dashPos - 1)
                        
                    Send("^{Esc}")
                    Sleep(500)
                    SendText(titleToType)
                    Sleep(1000)
                    Send("{Enter}")
                } else {
                    try Run("`"" exePath "`"")
                }
                
                newHwnd := 0
                Loop 50 { ; Wait up to 5 seconds
                    Sleep 100
                    winsAfter := WinGetList("ahk_exe " fileName)
                    if (winsAfter.Length > winsBefore.Length) {
                        for ahwnd in winsAfter {
                            isNew := true
                            for bhwnd in winsBefore {
                                if (ahwnd == bhwnd) {
                                    isNew := false
                                    break
                                }
                            }
                            if (isNew) {
                                newHwnd := ahwnd
                                break 2
                            }
                        }
                    }
                }
                
                if (newHwnd) {
                    WinRestore(newHwnd)
                    WinMove(pos.x, pos.y, pos.w, pos.h, newHwnd)
                    movesToApply.Push({hwnd: newHwnd, x: pos.x, y: pos.y, w: pos.w, h: pos.h})
                    openedNewWindow := true
                }
            }
        }
    }
    
    ; Re-apply moves if we had to open new windows to combat auto-resizing
    if (openedNewWindow) {
        Sleep(2000)
        for move in movesToApply {
            if WinExist(move.hwnd) {
                WinMove(move.x, move.y, move.w, move.h, move.hwnd)
            }
        }
    }
    
    loadingGui.Destroy()
    ToolTip("Layout restored from Slot " . slotNumber)
    SetTimer(() => ToolTip(), -2000)
}

; --- JSON FILE HANDLING ---

EncodeJSONStr(str) {
    str := StrReplace(str, "\", "\\")
    str := StrReplace(str, '"', '\"')
    str := StrReplace(str, "`n", "\n")
    str := StrReplace(str, "`r", "\r")
    return str
}

SaveJSON() {
    global LayoutSlots
    json := "{"
    firstSlot := true
    for slot, mapObj in LayoutSlots {
        if !firstSlot
            json .= ","
        firstSlot := false
        json .= "`n  `"" slot "`": {"
        firstKey := true
        for key, pos in mapObj {
            if !firstKey
                json .= ","
            firstKey := false
            urlStr := pos.HasOwnProp("url") ? pos.url : ""
            exePathStr := pos.HasOwnProp("exePath") ? pos.exePath : ""
            json .= "`n    `"" EncodeJSONStr(key) "`": { `"x`": " pos.x ", `"y`": " pos.y ", `"w`": " pos.w ", `"h`": " pos.h ", `"url`": `"" EncodeJSONStr(urlStr) "`", `"exePath`": `"" EncodeJSONStr(exePathStr) "`" }"
        }
        json .= "`n  }"
    }
    json .= "`n}"
    
    if FileExist(SettingsFile)
        FileDelete(SettingsFile)
    FileAppend(json, SettingsFile)
}

LoadJSON() {
    global LayoutSlots
    if !FileExist(SettingsFile)
        return
        
    text := FileRead(SettingsFile)
    currentSlot := 0
    
    ; Reset maps
    Loop 9
        LayoutSlots[A_Index] := Map()
        
    Loop Parse text, "`n", "`r" {
        line := Trim(A_LoopField)
        if RegExMatch(line, '^"(\d+)"\s*:\s*\{', &match) {
            currentSlot := Integer(match[1])
        }
        else if currentSlot && RegExMatch(line, '^"(.*)"\s*:\s*\{\s*"x"\s*:\s*(-?\d+)\s*,\s*"y"\s*:\s*(-?\d+)\s*,\s*"w"\s*:\s*(-?\d+)\s*,\s*"h"\s*:\s*(-?\d+)(?:,\s*"url"\s*:\s*"(.*?)")?(?:,\s*"exePath"\s*:\s*"(.*?)")?\s*\}', &match) {
            key := match[1]
            ; unescape
            key := StrReplace(key, '\"', '"')
            key := StrReplace(key, "\\", "\")
            key := StrReplace(key, "\n", "`n")
            key := StrReplace(key, "\r", "`r")
            
            urlVal := ""
            try urlVal := match[6]
            
            exePathVal := ""
            try exePathVal := match[7]
            
            ; unescape url
            if (urlVal != "") {
                urlVal := StrReplace(urlVal, '\"', '"')
                urlVal := StrReplace(urlVal, "\\", "\")
                urlVal := StrReplace(urlVal, "\n", "`n")
                urlVal := StrReplace(urlVal, "\r", "`r")
            }
            
            ; unescape exePath
            if (exePathVal != "") {
                exePathVal := StrReplace(exePathVal, '\"', '"')
                exePathVal := StrReplace(exePathVal, "\\", "\")
                exePathVal := StrReplace(exePathVal, "\n", "`n")
                exePathVal := StrReplace(exePathVal, "\r", "`r")
            }
            
            if (currentSlot >= 1 && currentSlot <= 9) {
                LayoutSlots[currentSlot][key] := {x: Integer(match[2]), y: Integer(match[3]), w: Integer(match[4]), h: Integer(match[5]), url: urlVal, exePath: exePathVal}
            }
        }
    }
}