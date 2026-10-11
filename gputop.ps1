<#
.SYNOPSIS
    gputop, a top-like GPU monitor for the Windows console.

.DESCRIPTION
    Reads the GPU performance counters built into Windows 10 (1709 or later)
    and Windows 11. No extra install is needed and it works with AMD, Intel
    and NVIDIA adapters alike.

    Per adapter   utilization, busiest engine, dedicated and shared memory
    Per process   utilization, busiest engine, dedicated memory

    Temperature, power and fan speed are not exposed by these counters.

    Besides the live screen there are plain output modes for scripts.
    -Query, -QueryProcess and -Json print one sample and exit, or repeat with
    -Loop. -Stream prints one line per sample until it is stopped.

.PARAMETER Interval
    Refresh interval in seconds. Default 1.

.PARAMETER Top
    Number of processes to list. Default 10 on the screen. Use 0 to hide the
    process table. The plain output modes list every active process unless
    -Top is given.

.PARAMETER Once
    Take a single sample and exit.

.PARAMETER LogCsv
    Append one row per adapter per refresh to this CSV file.

.PARAMETER LogProcessCsv
    Append one row per active process per refresh to this CSV file.

.PARAMETER All
    Also show software adapters and unnamed adapters with no activity.

.PARAMETER Gpu
    GPU numbers to include, as shown on the screen. Default is every GPU.

.PARAMETER Query
    Print the chosen per GPU fields as CSV. Available fields are
    timestamp, gpu, name, luid, util_pct, busiest_engine, vram_used_mb,
    vram_total_mb, vram_pct, shared_used_mb.

.PARAMETER QueryProcess
    Print the chosen per process fields as CSV. Available fields are
    timestamp, gpu, pid, name, util_pct, engine, vram_used_mb.

.PARAMETER Json
    Print the whole sample as JSON, adapters and processes together.

.PARAMETER Stream
    Print one plain line per sample and keep going. Use gpu for one line per
    adapter or process for one line per process.

.PARAMETER Loop
    Repeat -Query, -QueryProcess or -Json every interval instead of exiting
    after one sample. With -Json each sample is one compact line.

.PARAMETER Count
    Stop after this many samples. Works in every mode.

.PARAMETER NoHeader
    Leave out the header line of -Query, -QueryProcess and -Stream.

.EXAMPLE
    .\gputop.ps1

.EXAMPLE
    .\gputop.ps1 -Interval 2 -Top 15

.EXAMPLE
    .\gputop.ps1 -LogCsv gpu_log.csv -LogProcessCsv proc_log.csv

.EXAMPLE
    .\gputop.ps1 -Query util_pct,vram_used_mb -NoHeader

.EXAMPLE
    .\gputop.ps1 -Json | ConvertFrom-Json

.EXAMPLE
    .\gputop.ps1 -Stream gpu -Gpu 0

.NOTES
    If scripts are blocked on your machine, start it like this.
    powershell -ExecutionPolicy Bypass -File .\gputop.ps1

    Exit codes in the plain output modes
    0  a sample was printed
    1  no GPU data was available
    2  the arguments were not valid
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 60)]
    [int]$Interval = 1,

    [ValidateRange(0, 50)]
    [int]$Top = 10,

    [switch]$Once,

    [string]$LogCsv,

    [string]$LogProcessCsv,

    [switch]$All,

    [string[]]$Gpu,

    [string[]]$Query,

    [string[]]$QueryProcess,

    [switch]$Json,

    [ValidateSet('gpu', 'process')]
    [string]$Stream,

    [switch]$Loop,

    [ValidateRange(0, 1000000)]
    [int]$Count = 0,

    [switch]$NoHeader
)

$script:CounterPaths = @(
    '\GPU Engine(*)\Utilization Percentage',
    '\GPU Adapter Memory(*)\Dedicated Usage',
    '\GPU Adapter Memory(*)\Shared Usage',
    '\GPU Process Memory(*)\Dedicated Usage'
)
$script:Mask32 = [int64]4294967295
$script:Invariant = [Globalization.CultureInfo]::InvariantCulture
$script:BarWidth = 30
$script:LastLineCount = 0
$script:LastWidth = -1
$script:LastHeight = -1
$script:Source = 'counter'
$script:EngineNames = @{
    '3d'              = '3D'
    'videodecode'     = 'VideoDecode'
    'videoencode'     = 'VideoEncode'
    'videoprocessing' = 'VideoProcessing'
    'videocodec'      = 'VideoCodec'
    'legacyoverlay'   = 'LegacyOverlay'
    'securityhigh'    = 'SecurityHigh'
}

$script:GpuFields = @('timestamp', 'gpu', 'name', 'luid', 'util_pct', 'busiest_engine',
    'vram_used_mb', 'vram_total_mb', 'vram_pct', 'shared_used_mb')
$script:ProcessFields = @('timestamp', 'gpu', 'pid', 'name', 'util_pct', 'engine', 'vram_used_mb')
$script:GpuLogFields = @('timestamp', 'gpu', 'name', 'util_pct', 'busiest_engine',
    'vram_used_mb', 'vram_total_mb', 'shared_used_mb')
$script:StreamHeaderEvery = 20

function Write-StdErr([string]$Text) {
    try { $Host.UI.WriteErrorLine($Text) } catch { [Console]::Error.WriteLine($Text) }
}

function Stop-WithError([string]$Message) {
    Write-StdErr ('gputop: ' + $Message)
    exit 2
}

# ---------------------------------------------------------------------------
# Adapter names and VRAM sizes
# ---------------------------------------------------------------------------

function ConvertTo-ByteCount($Value) {
    if ($null -eq $Value) { return 0.0 }
    if ($Value -is [byte[]]) {
        if ($Value.Length -ge 8) { return [double][BitConverter]::ToUInt64($Value, 0) }
        if ($Value.Length -ge 4) { return [double][BitConverter]::ToUInt32($Value, 0) }
        return 0.0
    }
    try { return [double]$Value } catch { return 0.0 }
}

function Get-AdapterInfo {
    # ByLuid   adapters keyed by the LUID string used in counter instance names
    # Hardware display adapters known to the device manager (fallback source)
    $byLuid = @{}
    $hardware = New-Object System.Collections.Generic.List[object]

    try {
        $keys = Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\DirectX' -ErrorAction Stop
        foreach ($key in $keys) {
            try {
                $p = Get-ItemProperty -Path $key.PSPath -ErrorAction Stop
                if ($null -eq $p.AdapterLuid) { continue }
                if (-not $p.Description) { continue }
                $raw = [int64]$p.AdapterLuid
                $high = ($raw -shr 32) -band $script:Mask32
                $low = $raw -band $script:Mask32
                $id = 'luid_0x{0:x8}_0x{1:x8}' -f $high, $low
                $byLuid[$id] = [pscustomobject]@{
                    Name      = ([string]$p.Description).Trim()
                    VramBytes = (ConvertTo-ByteCount $p.DedicatedVideoMemory)
                }
            } catch { }
        }
    } catch { }

    try {
        $classPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        $keys = Get-ChildItem -Path $classPath -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^\d{4}$' }
        foreach ($key in $keys) {
            try {
                $p = Get-ItemProperty -Path $key.PSPath -ErrorAction Stop
                if (-not $p.DriverDesc) { continue }
                $hardware.Add([pscustomobject]@{
                    Name      = ([string]$p.DriverDesc).Trim()
                    VramBytes = (ConvertTo-ByteCount $p.'HardwareInformation.qwMemorySize')
                })
            } catch { }
        }
    } catch { }

    return [pscustomobject]@{ ByLuid = $byLuid; Hardware = $hardware }
}

# ---------------------------------------------------------------------------
# Counter sampling
# ---------------------------------------------------------------------------

function Format-EngineType([string]$Type) {
    # Get-Counter reports instance names in lower case. Restore the usual spelling.
    $t = $Type.ToLowerInvariant()
    if ($script:EngineNames.ContainsKey($t)) { return $script:EngineNames[$t] }
    if ($t.Length -eq 0) { return $t }
    return $t.Substring(0, 1).ToUpperInvariant() + $t.Substring(1)
}

function Read-CounterSamples([int]$Seconds) {
    $out = New-Object System.Collections.Generic.List[object]
    try {
        $result = Get-Counter -Counter $script:CounterPaths -SampleInterval $Seconds -MaxSamples 1 -ErrorAction SilentlyContinue
        if ($result) {
            foreach ($s in $result.CounterSamples) {
                if (-not $s.InstanceName) { continue }
                $out.Add([pscustomobject]@{
                    Inst   = [string]$s.InstanceName
                    Val    = [double]$s.CookedValue
                    Shared = (([string]$s.Path) -like '*shared usage')
                })
            }
        }
    } catch { }
    return ,$out
}

function Read-CimSamples {
    # Fallback for systems where Get-Counter cannot resolve the counter paths.
    # The WMI class names do not depend on the display language.
    $out = New-Object System.Collections.Generic.List[object]
    $prefix = 'Win32_PerfFormattedData_GPUPerformanceCounters_'
    try {
        foreach ($r in @(Get-CimInstance -ClassName ($prefix + 'GPUEngine') -ErrorAction Stop)) {
            $out.Add([pscustomobject]@{ Inst = [string]$r.Name; Val = [double]$r.UtilizationPercentage; Shared = $false })
        }
    } catch { }
    try {
        foreach ($r in @(Get-CimInstance -ClassName ($prefix + 'GPUAdapterMemory') -ErrorAction Stop)) {
            $out.Add([pscustomobject]@{ Inst = [string]$r.Name; Val = [double]$r.DedicatedUsage; Shared = $false })
            $out.Add([pscustomobject]@{ Inst = [string]$r.Name; Val = [double]$r.SharedUsage; Shared = $true })
        }
    } catch { }
    try {
        foreach ($r in @(Get-CimInstance -ClassName ($prefix + 'GPUProcessMemory') -ErrorAction Stop)) {
            $out.Add([pscustomobject]@{ Inst = [string]$r.Name; Val = [double]$r.DedicatedUsage; Shared = $false })
        }
    } catch { }
    return ,$out
}

function Get-Snapshot([int]$Seconds) {
    $samples = $null
    if ($script:Source -eq 'counter') {
        $samples = Read-CounterSamples $Seconds
        if ($samples.Count -eq 0) {
            $alt = Read-CimSamples
            if ($alt.Count -gt 0) {
                $script:Source = 'cim'
                $samples = $alt
            }
        }
    } else {
        $samples = Read-CimSamples
    }

    $adapters = @{}
    $procs = @{}
    if ($null -eq $samples -or $samples.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Adapters = $adapters; Procs = $procs }
    }

    $hex = '(0x[0-9a-f]+_0x[0-9a-f]+)'
    foreach ($s in $samples) {
        $inst = $s.Inst
        $val = $s.Val

        if ($inst -match ('^pid_(\d+)_luid_' + $hex + '_phys_\d+_eng_(\d+)_engtype_(.+)$')) {
            # GPU Engine, one instance per process per engine
            $procId = [int]$Matches[1]
            $luid = 'luid_' + $Matches[2].ToLowerInvariant()
            $engKey = $Matches[3] + '|' + (Format-EngineType $Matches[4])

            if (-not $adapters.ContainsKey($luid)) {
                $adapters[$luid] = [pscustomobject]@{ Luid = $luid; Engines = @{}; Dedicated = 0.0; Shared = 0.0 }
            }
            $a = $adapters[$luid]
            $a.Engines[$engKey] = [double]$a.Engines[$engKey] + $val

            $procKey = '{0}|{1}' -f $procId, $luid
            if (-not $procs.ContainsKey($procKey)) {
                $procs[$procKey] = [pscustomobject]@{ ProcId = $procId; Luid = $luid; Engines = @{}; Dedicated = 0.0 }
            }
            $pr = $procs[$procKey]
            $pr.Engines[$engKey] = [double]$pr.Engines[$engKey] + $val
        }
        elseif ($inst -match ('^pid_(\d+)_luid_' + $hex + '_phys_\d+$')) {
            # GPU Process Memory
            $procId = [int]$Matches[1]
            $luid = 'luid_' + $Matches[2].ToLowerInvariant()
            $procKey = '{0}|{1}' -f $procId, $luid
            if (-not $procs.ContainsKey($procKey)) {
                $procs[$procKey] = [pscustomobject]@{ ProcId = $procId; Luid = $luid; Engines = @{}; Dedicated = 0.0 }
            }
            $procs[$procKey].Dedicated += $val
        }
        elseif ($inst -match ('^luid_' + $hex + '_phys_\d+$')) {
            # GPU Adapter Memory
            $luid = 'luid_' + $Matches[1].ToLowerInvariant()
            if (-not $adapters.ContainsKey($luid)) {
                $adapters[$luid] = [pscustomobject]@{ Luid = $luid; Engines = @{}; Dedicated = 0.0; Shared = 0.0 }
            }
            if ($s.Shared) {
                $adapters[$luid].Shared += $val
            } else {
                $adapters[$luid].Dedicated += $val
            }
        }
    }

    return [pscustomobject]@{ Ok = $true; Adapters = $adapters; Procs = $procs }
}

# ---------------------------------------------------------------------------
# Aggregation
# ---------------------------------------------------------------------------

function Get-Peak($Engines) {
    # Same idea as Task Manager. The load of an adapter or a process is the
    # load of its busiest engine.
    $best = [pscustomobject]@{ Value = 0.0; Type = '' }
    foreach ($k in $Engines.Keys) {
        $v = [double]$Engines[$k]
        if ($v -gt $best.Value) {
            $best.Value = $v
            $best.Type = ($k -split '\|', 2)[1]
        }
    }
    $best.Value = [math]::Min(100.0, $best.Value)
    return $best
}

function Get-TypeSummary($Engines) {
    # One entry per engine type, busiest first
    $byType = @{}
    foreach ($k in $Engines.Keys) {
        $type = ($k -split '\|', 2)[1]
        $v = [math]::Min(100.0, [double]$Engines[$k])
        if (-not $byType.ContainsKey($type) -or $v -gt $byType[$type]) { $byType[$type] = $v }
    }
    $list = foreach ($t in $byType.Keys) {
        [pscustomobject]@{ Type = $t; Value = $byType[$t] }
    }
    return @($list | Sort-Object -Property @{ Expression = 'Value'; Descending = $true }, @{ Expression = 'Type'; Descending = $false })
}

function Get-View($Snap, $Info, [bool]$ShowAll, $GpuFilter) {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($luid in ($Snap.Adapters.Keys | Sort-Object)) {
        $a = $Snap.Adapters[$luid]
        $peak = Get-Peak $a.Engines
        $name = $null
        $vram = 0.0
        $known = $Info.ByLuid[$luid]
        if ($known) {
            $name = $known.Name
            $vram = $known.VramBytes
        }
        $rows.Add([pscustomobject]@{
            Index     = -1
            Luid      = $luid
            Name      = $name
            VramBytes = $vram
            Util      = $peak.Value
            TopEngine = $peak.Type
            Dedicated = $a.Dedicated
            Shared    = $a.Shared
            Types     = @(Get-TypeSummary $a.Engines)
        })
    }

    if ($ShowAll) {
        $gpus = $rows.ToArray()
    } else {
        $gpus = @($rows | Where-Object {
            if ($_.Name -eq 'Microsoft Basic Render Driver') { return $false }
            if (-not $_.Name -and $_.Dedicated -le 0 -and $_.Util -lt 0.05) { return $false }
            return $true
        })
    }

    # Fallbacks when the LUID lookup did not give a name or a VRAM size
    $unnamed = @($gpus | Where-Object { -not $_.Name })
    if ($unnamed.Count -eq 1 -and $Info.Hardware.Count -eq 1) {
        $unnamed[0].Name = $Info.Hardware[0].Name
        $unnamed[0].VramBytes = $Info.Hardware[0].VramBytes
    }
    $index = 0
    foreach ($g in $gpus) {
        if (-not $g.Name) { $g.Name = 'Unknown adapter ' + $g.Luid }
        if ($g.VramBytes -le 0) {
            $match = @($Info.Hardware | Where-Object { $_.Name -eq $g.Name -and $_.VramBytes -gt 0 })
            if ($match.Count -ge 1) { $g.VramBytes = $match[0].VramBytes }
        }
        $g.Index = $index
        $index++
    }

    # GPU numbers are assigned before -Gpu is applied, so they stay stable
    $total = $gpus.Count
    if ($null -ne $GpuFilter) {
        $gpus = @($gpus | Where-Object { $GpuFilter -contains $_.Index })
    }

    $indexByLuid = @{}
    foreach ($g in $gpus) { $indexByLuid[$g.Luid] = $g.Index }

    $names = @{}
    try {
        Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $names[[int]$_.Id] = $_.ProcessName }
    } catch { }

    $list = foreach ($pr in $Snap.Procs.Values) {
        if (-not $indexByLuid.ContainsKey($pr.Luid)) { continue }
        $peak = Get-Peak $pr.Engines
        if ($peak.Value -lt 0.1 -and $pr.Dedicated -lt 1MB) { continue }
        $procName = $names[[int]$pr.ProcId]
        if (-not $procName) { $procName = '?' }
        [pscustomobject]@{
            Gpu       = $indexByLuid[$pr.Luid]
            ProcId    = $pr.ProcId
            Name      = $procName
            Util      = $peak.Value
            Engine    = $peak.Type
            Dedicated = $pr.Dedicated
        }
    }
    $procRows = @($list | Sort-Object -Property @{ Expression = 'Util'; Descending = $true },
        @{ Expression = 'Dedicated'; Descending = $true }, @{ Expression = 'ProcId'; Descending = $false })

    return [pscustomobject]@{ Ok = $Snap.Ok; Gpus = $gpus; Procs = $procRows; TotalGpus = $total }
}

function Get-Problem($View, $GpuFilter) {
    # Lines that explain why there is nothing to show, or nothing at all
    if (-not $View.Ok) {
        return @(
            'No GPU counter data was returned.',
            'Windows 10 version 1709 or later is required.',
            'Check that this command lists the GPU counter sets.',
            "  Get-Counter -ListSet 'GPU*'"
        )
    }
    if ($View.TotalGpus -eq 0) {
        return @(
            'No hardware GPU was found.',
            'Only software or inactive adapters are present. Use -All to show them.'
        )
    }
    if ($View.Gpus.Count -eq 0) {
        $hint = 'The only GPU number is 0.'
        if ($View.TotalGpus -gt 1) { $hint = 'GPU numbers run from 0 to {0}.' -f ($View.TotalGpus - 1) }
        return @(('No GPU matches -Gpu {0}.' -f ($GpuFilter -join ',')), $hint)
    }
    return $null
}

# ---------------------------------------------------------------------------
# Records shared by the CSV, JSON and stream outputs
# ---------------------------------------------------------------------------

function ConvertTo-Tenth([double]$Value) {
    return [math]::Round($Value, 1, [MidpointRounding]::AwayFromZero)
}

function ConvertTo-Mb([double]$Bytes) {
    return [int64][math]::Round($Bytes / 1MB, [MidpointRounding]::AwayFromZero)
}

function Get-GpuRecord($G, $Stamp) {
    $pct = $null
    if ($G.VramBytes -gt 0) {
        $pct = ConvertTo-Tenth ([math]::Min(100.0, 100.0 * $G.Dedicated / $G.VramBytes))
    }
    return [ordered]@{
        timestamp      = $Stamp
        gpu            = [int]$G.Index
        name           = [string]$G.Name
        luid           = [string]$G.Luid
        util_pct       = (ConvertTo-Tenth $G.Util)
        busiest_engine = [string]$G.TopEngine
        vram_used_mb   = (ConvertTo-Mb $G.Dedicated)
        vram_total_mb  = (ConvertTo-Mb $G.VramBytes)
        vram_pct       = $pct
        shared_used_mb = (ConvertTo-Mb $G.Shared)
    }
}

function Get-ProcessRecord($R, $Stamp) {
    return [ordered]@{
        timestamp    = $Stamp
        gpu          = [int]$R.Gpu
        pid          = [int]$R.ProcId
        name         = [string]$R.Name
        util_pct     = (ConvertTo-Tenth $R.Util)
        engine       = [string]$R.Engine
        vram_used_mb = (ConvertTo-Mb $R.Dedicated)
    }
}

function Format-CsvValue([string]$Field, $Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [double]) { return $Value.ToString('F1', $script:Invariant) }
    if ($Value -is [string]) {
        if ($Field -eq 'name' -or $Value -match '[,"]') {
            return '"' + ($Value -replace '"', '""') + '"'
        }
        return $Value
    }
    return ([IFormattable]$Value).ToString($null, $script:Invariant)
}

function Format-CsvLine($Record, [string[]]$Fields) {
    $values = foreach ($f in $Fields) { Format-CsvValue $f $Record[$f] }
    return (@($values) -join ',')
}

function Resolve-Fields([string[]]$Requested, [string[]]$Valid, [string]$Option) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($item in $Requested) {
        foreach ($part in ($item -split ',')) {
            $name = $part.Trim().ToLowerInvariant()
            if ($name.Length -eq 0) { continue }
            if ($Valid -notcontains $name) {
                Stop-WithError ('{0} does not know the field {1}. Available fields are {2}.' -f $Option, $name, ($Valid -join ', '))
            }
            $out.Add($name)
        }
    }
    if ($out.Count -eq 0) {
        Stop-WithError ('{0} needs at least one field. Available fields are {1}.' -f $Option, ($Valid -join ', '))
    }
    return ,$out.ToArray()
}

function Get-JsonObject($View, $ProcRows, [datetime]$Now) {
    $gpus = foreach ($g in $View.Gpus) {
        $rec = Get-GpuRecord $g $null
        $rec.Remove('timestamp')
        $engines = [ordered]@{}
        foreach ($t in $g.Types) { $engines[[string]$t.Type] = (ConvertTo-Tenth $t.Value) }
        $rec['engines'] = $engines
        $rec
    }
    $procs = foreach ($r in $ProcRows) {
        $rec = Get-ProcessRecord $r $null
        $rec.Remove('timestamp')
        $rec
    }
    return [ordered]@{
        timestamp = $Now.ToString('yyyy-MM-ddTHH:mm:sszzz', $script:Invariant)
        source    = $script:Source
        gpus      = @($gpus)
        processes = @($procs)
    }
}

function Format-Tenth($Value) {
    if ($null -eq $Value) { return '-' }
    return ([double]$Value).ToString('F1', $script:Invariant)
}

function Get-StreamLines($View, $ProcRows, [string]$Kind, [datetime]$Now, [bool]$WithHeader) {
    $time = $Now.ToString('HH:mm:ss', $script:Invariant)
    $lines = New-Object System.Collections.Generic.List[string]
    if ($Kind -eq 'gpu') {
        $fmt = '{0,-8}  {1,3}  {2,5}  {3,-18}  {4,7}  {5,5}  {6,9}'
        if ($WithHeader) { $lines.Add(($fmt -f '#time', 'gpu', 'util%', 'engine', 'vram_mb', 'vram%', 'shared_mb')) }
        foreach ($g in $View.Gpus) {
            $rec = Get-GpuRecord $g $null
            $engine = $rec['busiest_engine']
            if (-not $engine) { $engine = '-' }
            $lines.Add(($fmt -f $time, $rec['gpu'], (Format-Tenth $rec['util_pct']), (Limit-Text $engine 18),
                $rec['vram_used_mb'], (Format-Tenth $rec['vram_pct']), $rec['shared_used_mb']))
        }
    } else {
        $fmt = '{0,-8}  {1,3}  {2,7}  {3,5}  {4,-18}  {5,7}  {6}'
        if ($WithHeader) { $lines.Add(($fmt -f '#time', 'gpu', 'pid', 'util%', 'engine', 'vram_mb', 'name')) }
        foreach ($g in $View.Gpus) {
            $mine = @($ProcRows | Where-Object { $_.Gpu -eq $g.Index })
            if ($mine.Count -eq 0) {
                $lines.Add(($fmt -f $time, $g.Index, '-', '-', '-', '-', '-'))
                continue
            }
            foreach ($r in $mine) {
                $rec = Get-ProcessRecord $r $null
                $engine = $rec['engine']
                if (-not $engine) { $engine = '-' }
                $lines.Add(($fmt -f $time, $rec['gpu'], $rec['pid'], (Format-Tenth $rec['util_pct']),
                    (Limit-Text $engine 18), $rec['vram_used_mb'], $rec['name']))
            }
        }
    }
    return ,$lines.ToArray()
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

function Seg([string]$Text, [string]$Color = 'Gray') {
    return [pscustomobject]@{ T = $Text; C = $Color }
}

function New-Bar([double]$Percent, [int]$Width) {
    $p = [math]::Max(0.0, [math]::Min(100.0, $Percent))
    $fill = [int][math]::Round($Width * $p / 100.0)
    return ('|' * $fill) + (' ' * ($Width - $fill))
}

function Get-LoadColor([double]$Percent) {
    if ($Percent -ge 80) { return 'Red' }
    if ($Percent -ge 50) { return 'Yellow' }
    return 'Green'
}

function Limit-Text([string]$Text, [int]$Max) {
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max - 1) + '~'
}

function Get-Screen($View, $Problem, [int]$Seconds, [bool]$Live, [int]$TopN) {
    $screen = New-Object System.Collections.Generic.List[object]
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    $head = New-Object System.Collections.Generic.List[object]
    $head.Add((Seg 'gputop' 'Cyan'))
    $head.Add((Seg ('   {0}   refresh {1}s' -f $stamp, $Seconds)))
    if ($script:Source -eq 'cim') { $head.Add((Seg '   source WMI' 'DarkGray')) }
    if ($Live) { $head.Add((Seg '   press q to quit' 'DarkGray')) }
    $screen.Add($head.ToArray())
    $screen.Add(@())

    if ($Problem) {
        $first = $true
        foreach ($text in $Problem) {
            $color = 'Gray'
            if ($first) { $color = 'Yellow' } elseif ($text.StartsWith('  ')) { $color = 'White' }
            $screen.Add(@( (Seg $text $color) ))
            $first = $false
        }
        return ,$screen
    }

    foreach ($g in $View.Gpus) {
        $screen.Add(@(
            (Seg ('GPU {0}' -f $g.Index) 'Cyan'),
            (Seg ('  ' + $g.Name) 'White')
        ))

        $engine = $g.TopEngine
        if (-not $engine) { $engine = 'idle' }
        $screen.Add(@(
            (Seg '  Util   ['),
            (Seg (New-Bar $g.Util $script:BarWidth) (Get-LoadColor $g.Util)),
            (Seg ']'),
            (Seg (' {0,5:N1} %' -f (ConvertTo-Tenth $g.Util)) 'White'),
            (Seg ('   busiest engine ' + $engine) 'DarkGray')
        ))

        $usedMb = $g.Dedicated / 1MB
        if ($g.VramBytes -gt 0) {
            $totalMb = $g.VramBytes / 1MB
            $pct = [math]::Min(100.0, 100.0 * $g.Dedicated / $g.VramBytes)
            $screen.Add(@(
                (Seg '  VRAM   ['),
                (Seg (New-Bar $pct $script:BarWidth) (Get-LoadColor $pct)),
                (Seg ']'),
                (Seg (' {0,5:N1} %' -f (ConvertTo-Tenth $pct)) 'White'),
                (Seg ('   {0:N0} / {1:N0} MB' -f $usedMb, $totalMb))
            ))
        } else {
            $screen.Add(@(
                (Seg '  VRAM   '),
                (Seg ('{0:N0} MB in use' -f $usedMb) 'White'),
                (Seg '   total size unknown' 'DarkGray')
            ))
        }

        $screen.Add(@( (Seg ('  Shared {0:N0} MB' -f ($g.Shared / 1MB))) ))

        $line = New-Object System.Collections.Generic.List[object]
        $line.Add((Seg '  Engine '))
        $busy = @($g.Types | Where-Object { $_.Value -ge 0.05 } | Select-Object -First 4)
        if ($busy.Count -eq 0) {
            $line.Add((Seg 'all idle' 'DarkGray'))
        } else {
            foreach ($t in $busy) {
                $line.Add((Seg ('{0} ' -f $t.Type)))
                $line.Add((Seg ('{0:N1} %   ' -f (ConvertTo-Tenth $t.Value)) (Get-LoadColor $t.Value)))
            }
        }
        $screen.Add($line.ToArray())
        $screen.Add(@())
    }

    $shown = @($View.Procs | Select-Object -First $TopN)
    if ($shown.Count -gt 0) {
        $fmt = '{0,5} {1,7}  {2,-24} {3,6}  {4,-18} {5,9}'
        $screen.Add(@( (Seg ($fmt -f 'GPU', 'PID', 'NAME', 'GPU %', 'ENGINE', 'VRAM MB') 'Cyan') ))
        foreach ($r in $shown) {
            $engine = $r.Engine
            if (-not $engine) { $engine = '' }
            $text = $fmt -f $r.Gpu, $r.ProcId, (Limit-Text $r.Name 24),
                ('{0:N1}' -f (ConvertTo-Tenth $r.Util)), (Limit-Text $engine 18), ('{0:N0}' -f ($r.Dedicated / 1MB))
            $color = 'Gray'
            if ($r.Util -ge 1) { $color = 'White' }
            $screen.Add(@( (Seg $text $color) ))
        }
    }

    return ,$screen
}

function Write-Screen($Screen, [bool]$Live) {
    $width = 0
    $height = 0
    try {
        $width = [Console]::WindowWidth - 1
        $height = [Console]::WindowHeight
    } catch { }
    if ($width -lt 20) { $width = 120 }
    if ($height -lt 5) { $height = 1000 }

    $maxLines = $Screen.Count
    if ($Live) {
        if ($width -ne $script:LastWidth -or $height -ne $script:LastHeight) {
            try { Clear-Host } catch { }
            $script:LastWidth = $width
            $script:LastHeight = $height
            $script:LastLineCount = 0
        }
        try { [Console]::SetCursorPosition(0, 0) } catch { }
        $maxLines = [math]::Min($Screen.Count, $height - 1)
    }

    for ($i = 0; $i -lt $maxLines; $i++) {
        $used = 0
        foreach ($seg in $Screen[$i]) {
            $t = [string]$seg.T
            $room = $width - $used
            if ($room -le 0) { break }
            if ($t.Length -gt $room) { $t = $t.Substring(0, $room) }
            if ($t.Length -gt 0) {
                Write-Host $t -NoNewline -ForegroundColor $seg.C
                $used += $t.Length
            }
        }
        if ($Live -and $used -lt $width) { Write-Host (' ' * ($width - $used)) -NoNewline }
        Write-Host ''
    }

    if ($Live) {
        # Wipe lines left over from a longer previous frame
        $extra = [math]::Min($script:LastLineCount, $height - 1) - $maxLines
        for ($i = 0; $i -lt $extra; $i++) { Write-Host (' ' * $width) }
        $script:LastLineCount = $maxLines
    }
}

# ---------------------------------------------------------------------------
# CSV logging
# ---------------------------------------------------------------------------

function Add-CsvLog([string]$Path, [string[]]$Fields, $Records) {
    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            Set-Content -LiteralPath $Path -Encoding UTF8 -Value ($Fields -join ',')
        }
        $lines = @(foreach ($rec in $Records) { Format-CsvLine $rec $Fields })
        if ($lines.Count -gt 0) { Add-Content -LiteralPath $Path -Encoding UTF8 -Value $lines }
    } catch {
        # Logging must never stop the monitor
    }
}

function Test-QuitKey {
    try {
        while ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq [ConsoleKey]::Q -or $k.Key -eq [ConsoleKey]::Escape) { return $true }
        }
    } catch { }
    return $false
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Output mode
$modes = New-Object System.Collections.Generic.List[string]
if ($PSBoundParameters.ContainsKey('Query')) { $modes.Add('query') }
if ($PSBoundParameters.ContainsKey('QueryProcess')) { $modes.Add('queryprocess') }
if ($Json) { $modes.Add('json') }
if ($Stream) { $modes.Add('stream') }
if ($modes.Count -gt 1) { Stop-WithError 'Use only one of -Query, -QueryProcess, -Json and -Stream.' }
$mode = 'screen'
if ($modes.Count -eq 1) { $mode = $modes[0] }

$queryFields = $null
if ($mode -eq 'query') { $queryFields = Resolve-Fields $Query $script:GpuFields '-Query' }
if ($mode -eq 'queryprocess') { $queryFields = Resolve-Fields $QueryProcess $script:ProcessFields '-QueryProcess' }

$gpuFilter = $null
if ($PSBoundParameters.ContainsKey('Gpu')) {
    $numbers = New-Object System.Collections.Generic.List[int]
    foreach ($item in $Gpu) {
        foreach ($part in ($item -split ',')) {
            $text = $part.Trim()
            if ($text.Length -eq 0) { continue }
            $number = 0
            if (-not [int]::TryParse($text, [ref]$number) -or $number -lt 0) {
                Stop-WithError ('-Gpu takes GPU numbers such as 0 or 0,1 but got {0}.' -f $text)
            }
            $numbers.Add($number)
        }
    }
    if ($numbers.Count -eq 0) { Stop-WithError '-Gpu needs at least one GPU number.' }
    $gpuFilter = $numbers.ToArray()
}

# How many samples to take. 0 means until stopped.
$oneShotMode = @('query', 'queryprocess', 'json') -contains $mode
$iterations = 0
if ($Once) { $iterations = 1 }
elseif ($Count -gt 0) { $iterations = $Count }
elseif ($oneShotMode -and -not $Loop) { $iterations = 1 }

$live = ($mode -eq 'screen' -and $iterations -ne 1)
$topGiven = $PSBoundParameters.ContainsKey('Top')

$info = Get-AdapterInfo
$exitCode = 0
$sample = 0
$warned = $false
$printed = 0
$cursorWasVisible = $true

try {
    if ($live) {
        try {
            $cursorWasVisible = [Console]::CursorVisible
            [Console]::CursorVisible = $false
        } catch { }
        try { Clear-Host } catch { }
        Write-Host 'gputop is collecting the first sample...'
    }

    while ($true) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $snap = Get-Snapshot $Interval
        $view = Get-View $snap $info $All.IsPresent $gpuFilter
        $problem = Get-Problem $view $gpuFilter
        $now = Get-Date
        $stamp = $now.ToString('yyyy-MM-dd HH:mm:ss', $script:Invariant)
        $sample++

        if ($mode -eq 'screen') {
            Write-Screen (Get-Screen $view $problem $Interval $live $Top) $live
        } elseif ($problem) {
            if (-not $warned) {
                foreach ($text in $problem) { Write-StdErr ('gputop: ' + $text.Trim()) }
                $warned = $true
            }
        } else {
            $printed++
            # The plain modes list every active process unless -Top was given
            $procRows = $view.Procs
            if ($topGiven) { $procRows = @($view.Procs | Select-Object -First $Top) }

            if ($mode -eq 'query') {
                if ($sample -eq 1 -and -not $NoHeader) { Write-Output ($queryFields -join ',') }
                foreach ($g in $view.Gpus) {
                    Write-Output (Format-CsvLine (Get-GpuRecord $g $stamp) $queryFields)
                }
            } elseif ($mode -eq 'queryprocess') {
                if ($sample -eq 1 -and -not $NoHeader) { Write-Output ($queryFields -join ',') }
                foreach ($r in $procRows) {
                    Write-Output (Format-CsvLine (Get-ProcessRecord $r $stamp) $queryFields)
                }
            } elseif ($mode -eq 'json') {
                $object = Get-JsonObject $view $procRows $now
                if ($iterations -eq 1) {
                    Write-Output (ConvertTo-Json -InputObject $object -Depth 6)
                } else {
                    Write-Output (ConvertTo-Json -InputObject $object -Depth 6 -Compress)
                }
            } else {
                $withHeader = (-not $NoHeader) -and ((($sample - 1) % $script:StreamHeaderEvery) -eq 0)
                foreach ($text in (Get-StreamLines $view $procRows $Stream $now $withHeader)) {
                    Write-Output $text
                }
            }
        }

        if (-not $problem) {
            if ($LogCsv) {
                Add-CsvLog $LogCsv $script:GpuLogFields @(foreach ($g in $view.Gpus) { Get-GpuRecord $g $stamp })
            }
            if ($LogProcessCsv) {
                Add-CsvLog $LogProcessCsv $script:ProcessFields @(foreach ($r in $view.Procs) { Get-ProcessRecord $r $stamp })
            }
        }

        if ($iterations -gt 0 -and $sample -ge $iterations) { break }

        # Keep the pace even if sampling returned early. The screen also listens for q.
        $quit = $false
        if ($live) { $quit = Test-QuitKey }
        while (-not $quit -and $watch.ElapsedMilliseconds -lt ($Interval * 1000)) {
            Start-Sleep -Milliseconds 100
            if ($live) { $quit = Test-QuitKey }
        }
        if ($quit) { break }
    }
} finally {
    if ($live) {
        try { [Console]::CursorVisible = $cursorWasVisible } catch { }
        Write-Host ''
    }
}

# A plain output mode that never printed a sample reports failure
if ($mode -ne 'screen' -and $printed -eq 0) { $exitCode = 1 }
if ($exitCode -ne 0) { exit $exitCode }
