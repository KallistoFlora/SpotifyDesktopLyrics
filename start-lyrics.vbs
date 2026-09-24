' Spotify desktop lyrics - silent launcher (no console window)
' Double-click to run in the background; quit via the tray icon (right click -> exit)
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
d = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & d & "\lyrics-overlay.ps1"""
sh.Run cmd, 0, False
