# 旧版坐标点击辅助，仅保留供历史验收复查。
param([int]$x, [int]$y, [switch]$double, [int]$delayMs = 120)
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class U32 {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
}
'@
[U32]::SetProcessDPIAware() | Out-Null
[U32]::SetCursorPos($x, $y) | Out-Null
Start-Sleep -Milliseconds $delayMs
[U32]::mouse_event(2,0,0,0,[IntPtr]::Zero); [U32]::mouse_event(4,0,0,0,[IntPtr]::Zero)
if ($double) { Start-Sleep -Milliseconds 80; [U32]::mouse_event(2,0,0,0,[IntPtr]::Zero); [U32]::mouse_event(4,0,0,0,[IntPtr]::Zero) }
Write-Host "clicked ($x,$y) double=$double"
