# Temporary diagnostic: samples memory, disk and the processes on the
# machine, works out which tests are running from the JSON reporter's file,
# and posts both as commit statuses so they survive a runner that freezes.
param(
  [string]$Log,
  [string]$StopFile,
  [string]$Report,
  [string]$Name
)

$ErrorActionPreference = 'Continue'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Mem {
  [StructLayout(LayoutKind.Sequential)]
  public struct MEMORYSTATUSEX {
    public uint dwLength; public uint dwMemoryLoad;
    public ulong ullTotalPhys; public ulong ullAvailPhys;
    public ulong ullTotalPageFile; public ulong ullAvailPageFile;
    public ulong ullTotalVirtual; public ulong ullAvailVirtual;
    public ulong ullAvailExtendedVirtual;
  }
  [DllImport("kernel32.dll")]
  static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX m);
  public static MEMORYSTATUSEX Read() {
    var m = new MEMORYSTATUSEX();
    m.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
    GlobalMemoryStatusEx(ref m);
    return m;
  }
}
'@

$api = "$env:GITHUB_API_URL/repos/$env:GITHUB_REPOSITORY/statuses/$env:GITHUB_SHA"
$headers = @{ Authorization = "Bearer $env:GITHUB_TOKEN"; Accept = 'application/vnd.github+json' }
$start = Get-Date
$lastPost = [datetime]::MinValue
$lastTests = ''
$suites = @{}
$tests = @{}
$running = @{}
$offset = 0

function Post($context, $description) {
  if ($description.Length -gt 139) { $description = $description.Substring(0, 139) }
  $body = @{ state = 'pending'; context = $context; description = $description } | ConvertTo-Json
  try {
    Invoke-RestMethod -Method Post -Uri $api -Headers $headers -Body $body -TimeoutSec 10 | Out-Null
  } catch {
    Add-Content -Path $Log -Value "post failed: $_"
  }
}

function ReadReport {
  if (-not (Test-Path $Report)) { return }
  $fs = [System.IO.File]::Open($Report, 'Open', 'Read', 'ReadWrite')
  try {
    $fs.Seek($script:offset, 'Begin') | Out-Null
    $reader = New-Object System.IO.StreamReader($fs)
    $text = $reader.ReadToEnd()
  } finally { $fs.Close() }
  $cut = $text.LastIndexOf("`n")
  if ($cut -lt 0) { return }
  $script:offset += [System.Text.Encoding]::UTF8.GetByteCount($text.Substring(0, $cut + 1))
  foreach ($line in $text.Substring(0, $cut).Split("`n")) {
    if (-not $line.Trim()) { continue }
    try { $e = $line | ConvertFrom-Json } catch { continue }
    switch ($e.type) {
      'suite' { $script:suites[[string]$e.suite.id] = [string]$e.suite.path }
      'testStart' {
        $script:tests[[string]$e.test.id] = @([string]$e.test.suiteID, [string]$e.test.name)
        $script:running[[string]$e.test.id] = Get-Date
      }
      'testDone' { $script:running.Remove([string]$e.testID) }
    }
  }
}

while (-not (Test-Path $StopFile)) {
  try {
    $m = [Mem]::Read()
    $availMB = [int]($m.ullAvailPhys / 1MB)
    $commitMB = [int](($m.ullTotalPageFile - $m.ullAvailPageFile) / 1MB)
    $limitMB = [int]($m.ullTotalPageFile / 1MB)
    $disks = ([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
      ForEach-Object { "$($_.Name.Substring(0,1)):$([int]($_.AvailableFreeSpace / 1GB))G" }) -join ' '
    $procs = [System.Diagnostics.Process]::GetProcesses()
    $big = $procs | Sort-Object PrivateMemorySize64 -Descending | Select-Object -First 3
    $bigText = ($big | ForEach-Object { "$($_.ProcessName)=$([int]($_.PrivateMemorySize64 / 1MB))" }) -join ','
    $testers = @($procs | Where-Object { $_.ProcessName -eq 'flutter_tester' }).Count
    $elapsed = [int]((Get-Date) - $start).TotalSeconds

    ReadReport
    $now = Get-Date
    $active = $running.GetEnumerator() | Sort-Object Value | ForEach-Object {
      $t = $tests[$_.Key]
      $file = $suites[$t[0]]
      if ($file) { $file = [System.IO.Path]::GetFileNameWithoutExtension($file) -replace '_test$', '' }
      "$file($([int]($now - $_.Value).TotalSeconds)s)"
    }
    $testText = ($active | Where-Object { $_ -notmatch '^\(' } | Select-Object -Unique) -join ' '

    $res = "t$elapsed avail=$availMB commit=$commitMB/$limitMB disk $disks procs=$($procs.Count) testers=$testers big $bigText"
    Add-Content -Path $Log -Value "$(Get-Date -Format 'HH:mm:ss') $res | $testText"

    $due = ((Get-Date) - $lastPost).TotalSeconds -ge 10
    if ($due) {
      Post "diag/$Name/res" $res
      if ($testText -ne $lastTests) { Post "diag/$Name/tests" "t$elapsed $testText"; $lastTests = $testText }
      $lastPost = Get-Date
    }

    if ($availMB -lt 1500) {
      $victim = $procs | Where-Object { $_.ProcessName -match '^(dart|dartvm|dartaotruntime|flutter_tester)$' } |
        Sort-Object PrivateMemorySize64 -Descending | Select-Object -First 1
      if ($victim) {
        $msg = "KILL t$elapsed $($victim.ProcessName)#$($victim.Id)=$([int]($victim.PrivateMemorySize64 / 1MB))MB while $testText"
        Add-Content -Path $Log -Value $msg
        Post "diag/$Name/alert" $msg
        Stop-Process -Id $victim.Id -Force
      }
    }
  } catch {
    Add-Content -Path $Log -Value "watchdog error: $_"
  }
  Start-Sleep -Seconds 2
}
Add-Content -Path $Log -Value 'watchdog stopped'
