# 旧版 MPV 按键辅助；新回合使用 ../mpvkey2.ps1 的 PID 精确匹配。
param([string]$key = "RIGHT")
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class MK {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern IntPtr FindWindow(string cls, string title);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
}
'@
[MK]::SetProcessDPIAware() | Out-Null
$h = [MK]::FindWindow("mpv", $null)
if ($h -eq [IntPtr]::Zero) { Write-Host "mpv window not found"; exit 1 }
[MK]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 350
$fg = [MK]::GetForegroundWindow()
if ($fg -ne $h) { Write-Host "foreground mismatch"; exit 2 }
$vk = if ($key -eq "RIGHT") { 0x27 } elseif ($key -eq "SPACE") { 0x20 } else { 0 }
[MK]::keybd_event($vk, 0, 0, [UIntPtr]::Zero)
[MK]::keybd_event($vk, 0, 2, [UIntPtr]::Zero)
$pid2 = 0; [MK]::GetWindowThreadProcessId($h, [ref]$pid2) | Out-Null
Write-Host "sent $key to mpv hwnd=$h pid=$pid2"
