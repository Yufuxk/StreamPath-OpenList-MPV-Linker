# 向指定 MPV 窗口发送验收按键。
param([string]$key = "RIGHT", [int]$targetPid = 0)
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class MK2 {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  public static IntPtr found = IntPtr.Zero;
  public static uint want = 0;
  public static bool Cb(IntPtr h, IntPtr l) {
    uint pid; GetWindowThreadProcessId(h, out pid);
    if (pid == want && IsWindowVisible(h)) {
      found = h; return false;
    }
    return true;
  }
}
'@
[MK2]::SetProcessDPIAware() | Out-Null
[MK2]::want = [uint32]$targetPid
[MK2]::EnumWindows([MK2+EnumProc]{ param($h, $l) [MK2]::Cb($h, $l) }, [IntPtr]::Zero) | Out-Null
$h = [MK2]::found
if ($h -eq [IntPtr]::Zero) { Write-Host "no window for pid $targetPid"; exit 1 }
[MK2]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 500
$fg = [MK2]::GetForegroundWindow()
if ($fg -ne $h) { Write-Host "foreground mismatch (fg=$fg want=$h)"; exit 2 }
$vk = switch ($key) { "RIGHT" {0x27} "LEFT" {0x25} "SPACE" {0x20} "L" {0x4C} "H" {0x48} "J" {0x4A} "K" {0x4B} default {0} }
[MK2]::keybd_event([byte]$vk, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 60
[MK2]::keybd_event([byte]$vk, 0, 2, [UIntPtr]::Zero)
Write-Host "sent $key to hwnd=$h pid=$targetPid (foreground verified)"
