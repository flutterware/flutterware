# Temporary diagnostic: samples memory and the processes below one root
# process, and kills the largest of them before the machine runs out.
param(
  [int]$RootPid,
  [string]$Log,
  [string]$StopFile
)

$ErrorActionPreference = 'Continue'
$alerts = 0

function Descendants($all, $root) {
  $children = @{}
  foreach ($p in $all) {
    $key = [int]$p.ParentProcessId
    if (-not $children.ContainsKey($key)) { $children[$key] = @() }
    $children[$key] += $p
  }
  $out = @()
  $queue = New-Object System.Collections.Queue
  $queue.Enqueue([int]$root)
  $seen = @{}
  while ($queue.Count -gt 0) {
    $id = $queue.Dequeue()
    if ($seen.ContainsKey($id)) { continue }
    $seen[$id] = $true
    if ($children.ContainsKey($id)) {
      foreach ($c in $children[$id]) {
        if ($c.ProcessId -eq $PID) { continue }
        $out += $c
        $queue.Enqueue([int]$c.ProcessId)
      }
    }
  }
  return $out
}

while (-not (Test-Path $StopFile)) {
  try {
    $mem = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $all = Get-CimInstance Win32_Process
    $tree = Descendants $all $RootPid
    $availMB = [int]$mem.AvailableMBytes
    $commitPct = [math]::Round(100.0 * $mem.CommittedBytes / $mem.CommitLimit, 1)
    $top = $tree | Sort-Object PrivatePageCount -Descending | Select-Object -First 6
    $summary = ($top | ForEach-Object { "$($_.Name)#$($_.ProcessId)=$([int]($_.PrivatePageCount / 1MB))MB" }) -join ' '
    $byName = ($tree | Group-Object Name | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join ' '
    $line = "$(Get-Date -Format 'HH:mm:ss') avail=${availMB}MB commit=${commitPct}% all=$($all.Count) tree=$($tree.Count) | $summary | $byName"
    Add-Content -Path $Log -Value $line

    if ($availMB -lt 1500 -or $commitPct -gt 90 -or $tree.Count -gt 300) {
      $alerts++
      Add-Content -Path $Log -Value "ALERT $alerts at $(Get-Date -Format o): avail=${availMB}MB commit=${commitPct}% tree=$($tree.Count)"
      foreach ($p in ($tree | Sort-Object PrivatePageCount -Descending | Select-Object -First 15)) {
        $cmd = "$($p.CommandLine)"
        if ($cmd.Length -gt 600) { $cmd = $cmd.Substring(0, 600) }
        Add-Content -Path $Log -Value "  pid=$($p.ProcessId) ppid=$($p.ParentProcessId) $($p.Name) $([int]($p.PrivatePageCount / 1MB))MB :: $cmd"
      }
      $victim = $tree | Sort-Object PrivatePageCount -Descending | Select-Object -First 1
      if ($tree.Count -gt 300) {
        # A process storm: the largest single process is not the problem.
        $victim = $tree | Where-Object { $_.Name -eq 'flutter_tester.exe' } | Sort-Object PrivatePageCount -Descending | Select-Object -First 1
      }
      if ($victim) {
        Add-Content -Path $Log -Value "  KILL pid=$($victim.ProcessId) $($victim.Name)"
        & taskkill /F /T /PID $victim.ProcessId 2>&1 | ForEach-Object { Add-Content -Path $Log -Value "    $_" }
      }
    }
  } catch {
    Add-Content -Path $Log -Value "watchdog error: $_"
  }
  Start-Sleep -Seconds 3
}
Add-Content -Path $Log -Value "watchdog stopped, $alerts alerts"
