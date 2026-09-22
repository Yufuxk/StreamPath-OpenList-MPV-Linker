# 旧版滚轮辅助，仅保留供历史验收复查。
param([int]$x, [int]$y, [int]$notches = 3)
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class W2 {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
}
'@
[W2]::SetProcessDPIAware() | Out-Null
[W2]::SetCursorPos($x, $y) | Out-Null
Start-Sleep -Milliseconds 200
for ($i = 0; $i -lt [Math]::Abs($notches); $i++) {
  $d = if ($notches -lt 0) { [uint32]4294967176 } else { [uint32]120 }
  [W2]::mouse_event(0x0800, 0, 0, $d, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 150
}
Write-Host "wheel $notches at ($x,$y)"
