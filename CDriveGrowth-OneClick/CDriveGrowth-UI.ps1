[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ScanScript,
    [Parameter(Mandatory = $true)][string]$OutputDir
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$color = @{
    Canvas = [System.Drawing.ColorTranslator]::FromHtml('#EFF3F8')
    White = [System.Drawing.Color]::White
    Ink = [System.Drawing.ColorTranslator]::FromHtml('#142338')
    Muted = [System.Drawing.ColorTranslator]::FromHtml('#4C5E76')
    Header = [System.Drawing.ColorTranslator]::FromHtml('#142C4C')
    HeaderText = [System.Drawing.ColorTranslator]::FromHtml('#D1DEEF')
    Accent = [System.Drawing.ColorTranslator]::FromHtml('#1856B8')
    Pale = [System.Drawing.ColorTranslator]::FromHtml('#E4EBF5')
    Good = [System.Drawing.ColorTranslator]::FromHtml('#14644C')
    Low = [System.Drawing.ColorTranslator]::FromHtml('#A03422')
}
$font = @{
    Body = [System.Drawing.Font]::new('Microsoft YaHei UI', [single]10)
    Small = [System.Drawing.Font]::new('Microsoft YaHei UI', [single]9)
    Title = [System.Drawing.Font]::new('Microsoft YaHei UI', [single]22, [System.Drawing.FontStyle]::Bold)
    Strong = [System.Drawing.Font]::new('Microsoft YaHei UI', [single]11, [System.Drawing.FontStyle]::Bold)
    Metric = [System.Drawing.Font]::new('Microsoft YaHei UI', [single]17, [System.Drawing.FontStyle]::Bold)
}
$form = New-Object System.Windows.Forms.Form
$form.Text = '磁盘空间诊断'
$form.AutoScaleDimensions = [System.Drawing.SizeF]::new(96, 96)
$form.AutoScaleMode = 'Dpi'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = [System.Drawing.Size]::new(748, 489)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.BackColor = $color.Canvas
$form.ForeColor = $color.Ink
$form.Font = $font.Body

function Add-Control {
    param($Parent, [string]$Type, [string]$Text, [int]$Left, [int]$Top, [int]$Width, [int]$Height)
    $control = New-Object "System.Windows.Forms.$Type"
    $control.Text = $Text
    $control.SetBounds($Left, $Top, $Width, $Height)
    $Parent.Controls.Add($control)
    return $control
}

function Add-Button {
    param($Parent, [string]$Text, [int]$Left, [int]$Top, [int]$Width, [int]$Height, [switch]$Primary)
    $button = Add-Control $Parent Button $Text $Left $Top $Width $Height
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $button.UseVisualStyleBackColor = $false
    if ($Primary) {
        $button.BackColor = $color.Accent
        $button.ForeColor = $color.White
    } else {
        $button.BackColor = $color.Pale
        $button.ForeColor = $color.Header
    }
    return $button
}

function Open-Path {
    param([string]$Path)
    try {
        Invoke-Item -LiteralPath $Path
    } catch {
        $null = [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '无法打开', 'OK', 'Warning')
    }
}

function Read-ScanReport {
    param([string]$Path)
    $result = @{
        Interval = ''; Available = ''; Actual = ''; Logical = ''; Gap = ''; Baseline = $false
        Groups = [ordered]@{
            '增长目录' = [System.Collections.Generic.List[object]]::new()
            '新增或变大的文件' = [System.Collections.Generic.List[object]]::new()
            '消失或缩小的文件' = [System.Collections.Generic.List[object]]::new()
            '当前最大文件' = [System.Collections.Generic.List[object]]::new()
        }
    }
    $group = ''
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        switch -Regex ($line) {
            '^本次跳过的文件或目录' { return $result }
            '^比较区间\s+(.+)$' { $result.Interval = $Matches[1]; continue }
            '^本次扫描开始时的 [CDE] 盘剩余空间\s+(.+)$' { $result.Available = $Matches[1]; continue }
            '^首次扫描' { $result.Baseline = $true; continue }
            '^[CDE] 盘实际占用变化\s+(.+? MiB)\s+' { $result.Actual = $Matches[1]; continue }
            '^可比较文件的逻辑大小净变化\s+(.+? MiB)\s+' { $result.Logical = $Matches[1]; continue }
            '^实际占用变化减去文件逻辑净变化\s+(.+? MiB)\s+' { $result.Gap = $Matches[1]; continue }
            '^目录净增长前' { $group = '增长目录'; continue }
            '^新增或变大前' { $group = '新增或变大的文件'; continue }
            '^消失或缩小前' { $group = '消失或缩小的文件'; continue }
            '^当前可读取文件中最大' { $group = '当前最大文件'; continue }
            '^\s+(.+? MiB)\s+\([^)]*\)\s+(?:(净增长|新增|变大|消失|缩小)\s+)?([CDE]:\\.*)$' {
                if ($group) {
                    $result.Groups[$group].Add([pscustomobject]@{
                        Size = $Matches[1]; Change = $Matches[2]; Path = $Matches[3]
                    })
                }
                continue
            }
        }
    }
    return $result
}

function Get-PathAdvice {
    param([string]$Path, [string]$Change)
    if ($Change -eq '消失') {
        return @('已消失', '本次扫描已找不到这个路径。文件可能已移走或改名，无需按旧路径清理。')
    }
    if ($Path -match '^[A-Z]:\\\$Recycle\.Bin(?:\\|$)') {
        return @('可通过系统清理', '先打开回收站检查是否有要恢复的文件，再通过 Windows 清空选定项目。')
    }
    if ($Path -match '^[A-Z]:\\(?:Windows(?:\.old|Apps)?|Program Files(?: \(x86\))?|ProgramData|System Volume Information|Recovery|Boot|EFI|\$Windows\.~(?:BT|WS))(?=\\|$)' -or
        $Path -match '(?:^[A-Z]:\\(?:pagefile\.sys|hiberfil\.sys|swapfile\.sys|bootmgr|bootnxt)$|\.sys$)') {
        return @('勿手动删除', '此路径通常属于 Windows、已安装应用或系统数据。使用 Windows 存储设置、应用卸载或软件自带的清理功能。')
    }
    if ($Path -match '^[A-Z]:\\Users\\[^\\]+\\AppData\\Local\\Temp(?:\\|$)') {
        return @('可通过系统清理', '关闭相关应用后，在 Windows「设置 → 系统 → 存储 → 临时文件」检查并选择可清理项目。')
    }
    if ($Path -match '^[A-Z]:\\Users\\[^\\]+\\(?:Downloads|Desktop|Documents|Pictures|Videos|Music)\\.+') {
        return @('确认后可删', '通常是个人文件。先确认用途、备份和同步状态，再决定移到其他盘或放入回收站。')
    }
    return @('先核实用途', '仅凭路径无法确认是否可删。先识别所属应用或文件用途，再选择迁移、卸载或应用自带的清理方式。')
}

function Show-ScanResult {
    param([string]$Path)
    try {
        $result = Read-ScanReport $Path
    } catch {
        $null = [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '无法读取报告', 'OK', 'Warning')
        return
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = '扫描结果 · 磁盘空间诊断'
    $dialog.AutoScaleDimensions = [System.Drawing.SizeF]::new(96, 96)
    $dialog.AutoScaleMode = 'Dpi'
    $dialog.StartPosition = 'CenterParent'
    $dialog.ClientSize = [System.Drawing.Size]::new(748, 550)
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.BackColor = $color.Canvas
    $dialog.ForeColor = $color.Ink
    $dialog.Font = $font.Body

    $banner = Add-Control $dialog Panel '' 0 0 748 78
    $banner.BackColor = $color.Header
    $heading = Add-Control $banner Label '扫描结果' 24 8 698 40
    $heading.Font = $font.Title
    $heading.ForeColor = $color.White
    $stamp = $result.Interval
    if (-not $stamp) {
        $stamp = '首次扫描已建立基线。再次扫描同一盘后可查看变化。'
    }
    $interval = Add-Control $banner Label $stamp 26 49 698 24
    $interval.ForeColor = $color.HeaderText

    $metrics = @(
        @{ Label = '磁盘实际占用变化'; Value = $result.Actual }
        @{ Label = '可见文件净变化'; Value = $result.Logical }
        @{ Label = '两者差额'; Value = $result.Gap }
    )
    if ($result.Baseline) {
        $metrics = @(@{ Label = '扫描时剩余空间'; Value = $result.Available })
    }
    for ($i = 0; $i -lt $metrics.Count; $i++) {
        $metric = $metrics[$i]
        $tile = Add-Control $dialog Panel '' (24 + 236 * $i) 92 228 68
        $tile.BackColor = $color.White
        $label = Add-Control $tile Label $metric.Label 11 6 206 22
        $label.ForeColor = $color.Muted
        $value = Add-Control $tile Label $metric.Value 11 28 206 34
        $value.Font = $font.Metric
        $value.AutoEllipsis = $true
    }

    $hint = '实际占用变化来自磁盘可用空间。差额较大时，先看原始报告里的跳过项。'
    if ($result.Baseline) { $hint = '下方按当前文件大小排序，供首次排查；大小本身不能判断是否可删。' }
    $help = Add-Control $dialog Label $hint 24 169 700 24
    $help.ForeColor = $color.Muted
    $category = Add-Control $dialog ComboBox '' 24 201 255 30
    $category.DropDownStyle = 'DropDownList'
    $choices = @($result.Groups.Keys)
    if ($result.Baseline) { $choices = @('当前最大文件') } else { $choices = @($choices | Where-Object { $_ -ne '当前最大文件' }) }
    foreach ($key in $choices) {
        $null = $category.Items.Add("$key（$($result.Groups[$key].Count)）")
    }

    $grid = Add-Control $dialog DataGridView '' 24 239 700 194
    $grid.BackgroundColor = $color.White
    $grid.BorderStyle = 'None'
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $false
    $grid.RowTemplate.Height = 27
    $grid.AlternatingRowsDefaultCellStyle.BackColor = $color.Canvas
    $null = $grid.Columns.Add('Amount', '大小或变化')
    $null = $grid.Columns.Add('Change', '类型')
    $null = $grid.Columns.Add('Advice', '处理建议')
    $null = $grid.Columns.Add('Path', '路径')
    $grid.Columns[0].Width = 120
    $grid.Columns[1].Width = 78
    $grid.Columns[2].Width = 137
    $grid.Columns[3].AutoSizeMode = 'Fill'
    foreach ($column in $grid.Columns) { $column.SortMode = 'NotSortable' }

    $tip = Add-Control $dialog Label '' 24 441 700 48
    $tip.Font = $font.Small
    $tip.ForeColor = $color.Muted
    $rawButton = Add-Button $dialog '打开原始报告' 24 504 130 30
    $rawButton.Tag = $Path
    $rawButton.add_Click({ param($sender, $eventArgs) Open-Path ([string]$sender.Tag) })
    $closeButton = Add-Button $dialog '关闭' 620 504 104 30
    $closeButton.DialogResult = 'Cancel'
    $dialog.CancelButton = $closeButton

    $adviceRule = ${function:Get-PathAdvice}
    $grid.add_SelectionChanged({
        if ($grid.SelectedRows.Count -gt 0) {
            $tip.Text = [string]$grid.SelectedRows[0].Tag
        }
    }.GetNewClosure())
    $category.add_SelectedIndexChanged({
        if ($category.SelectedIndex -lt 0) { return }
        $grid.Rows.Clear()
        $tip.Text = '该分组没有可显示的项目。'
        foreach ($entry in $result.Groups[$choices[$category.SelectedIndex]]) {
            $advice = & $adviceRule $entry.Path $entry.Change
            $kind = $entry.Change
            if (-not $kind) { $kind = '当前大小' }
            $index = $grid.Rows.Add([object[]]@($entry.Size, $kind, $advice[0], $entry.Path))
            $row = $grid.Rows[$index]
            $row.Tag = $advice[1]
            $row.Cells[3].ToolTipText = $entry.Path
            if ($advice[0] -eq '勿手动删除') {
                $row.Cells[2].Style.ForeColor = $color.Low
            } elseif ($advice[0] -eq '可通过系统清理') {
                $row.Cells[2].Style.ForeColor = $color.Good
            }
        }
        if ($grid.Rows.Count -gt 0) {
            $grid.Rows[0].Selected = $true
            $tip.Text = [string]$grid.Rows[0].Tag
        }
    }.GetNewClosure())
    $category.SelectedIndex = 0
    try {
        $null = $dialog.ShowDialog($form)
    } finally {
        $dialog.Dispose()
    }
}

function Format-Capacity {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} TiB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N1} GiB' -f ($Bytes / 1GB)) }
    return ('{0:N0} MiB' -f ($Bytes / 1MB))
}

$header = Add-Control $form Panel '' 0 0 748 96
$header.BackColor = $color.Header
$title = Add-Control $header Label '磁盘空间诊断' 23 13 690 43
$title.Font = $font.Title
$title.ForeColor = $color.White
$subhead = Add-Control $header Label '对比两次扫描，找出占用空间增长最多的文件和目录。' 25 60 690 24
$subhead.ForeColor = $color.HeaderText

$section = Add-Control $form Label '扫描范围' 24 115 125 28
$section.Font = $font.Strong
$selection = Add-Control $form Label '' 160 118 350 22
$selection.ForeColor = $color.Muted
$refreshButton = Add-Button $form '刷新磁盘' 621 110 103 31

$cards = [ordered]@{}
foreach ($letter in @('C', 'D', 'E')) {
    $panel = Add-Control $form Panel '' (24 + $cards.Count * 236) 153 228 222
    $panel.BackColor = $color.White

    $check = Add-Control $panel CheckBox "$letter 盘" 15 12 100 30
    $check.Font = $font.Strong
    $check.AccessibleName = "扫描 $letter 盘"
    $check.Checked = $letter -eq 'C'

    $tag = Add-Control $panel Label '' 116 17 96 22
    $tag.Font = $font.Small
    $tag.TextAlign = 'TopRight'
    $metric = Add-Control $panel Label '' 15 49 198 35
    $metric.Font = $font.Metric

    $capacity = Add-Control $panel Label '' 15 86 198 20
    $capacity.Font = $font.Small
    $capacity.ForeColor = $color.Muted
    $bar = Add-Control $panel ProgressBar '' 15 110 198 9
    $bar.AccessibleName = "$letter 盘已用空间比例"

    $last = Add-Control $panel Label '' 15 128 198 20
    $last.Font = $font.Small
    $last.ForeColor = $color.Muted
    $change = Add-Control $panel Label '' 15 151 198 21
    $change.Font = $font.Small
    $change.AutoEllipsis = $true
    $open = Add-Button $panel '查看诊断结果' 15 181 128 29
    $open.AccessibleName = "查看 $letter 盘的最新报告"
    $open.add_Click({
        param($sender, $eventArgs)
        if ($sender.Tag) { Show-ScanResult ([string]$sender.Tag) }
    })

    $cards[$letter] = @{
        Check = $check; Tag = $tag; Metric = $metric; Capacity = $capacity
        Bar = $bar; Last = $last; Change = $change; Open = $open; Ready = $false
    }
}

$footer = Add-Control $form Panel '' 0 390 748 99
$footer.BackColor = $color.White
$status = Add-Control $footer Label '选择盘符后开始扫描。' 24 10 550 24
$status.AutoEllipsis = $true
$status.AccessibleName = '扫描状态'
$detailButton = Add-Button $footer '查看错误' 621 8 103 27
$detailButton.Visible = $false
$activity = Add-Control $footer ProgressBar '' 24 39 700 5
$activity.Style = 'Marquee'
$activity.Visible = $false
$scanButton = Add-Button $footer '开始扫描' 24 54 144 33 -Primary
$outputButton = Add-Button $footer '打开历史报告文件夹' 180 54 176 33

$form.AcceptButton = $scanButton
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 350
$state = @{ Worker = $null; Job = $null; Errors = @() }
$workerCommand = {
    param($ScanScript, $OutputDir, $Selected)
    try {
        & $ScanScript -OutputDir $OutputDir -Drive $Selected -PassThru
    } catch {
        Write-Error -ErrorRecord $_ -ErrorAction Continue
    }
}

function Update-Selection {
    $count = @($cards.Values | Where-Object { $_.Ready -and $_.Check.Checked }).Count
    $selection.Text = "已选择 $count 个磁盘"
    $scanButton.Enabled = $count -gt 0 -and -not $state.Worker
}

function Update-Overview {
    foreach ($letter in $cards.Keys) {
        $card = $cards[$letter]
        $card.Ready = $false
        $card.Metric.Text = '—'
        $card.Capacity.Text = '磁盘未连接或不可访问'
        $card.Tag.Text = '不可用'
        $card.Tag.ForeColor = $color.Muted
        $card.Bar.Visible = $false
        try {
            $volume = [System.IO.DriveInfo]::new("${letter}:\")
            if ($volume.IsReady -and $volume.TotalSize -gt 0) {
                $total = $volume.TotalSize
                $free = $volume.TotalFreeSpace
                $percent = [int][Math]::Min(100, [Math]::Max(0, [Math]::Round(100.0 * ($total - $free) / $total)))
                $card.Ready = $true
                $card.Metric.Text = Format-Capacity $free
                $card.Capacity.Text = "剩余 / 共 $(Format-Capacity $total)"
                $card.Bar.Value = $percent
                $card.Bar.Visible = $true
                $card.Tag.Text = "已用 $percent%"
                $card.Tag.ForeColor = $color.Muted
                if ($free -le 5GB) {
                    $card.Tag.Text = '空间紧张'
                    $card.Tag.ForeColor = $color.Low
                }
            }
        } catch {
            $card.Capacity.Text = '无法读取磁盘容量'
        }

        $card.Check.Enabled = $card.Ready
        $card.Open.Tag = $null
        $card.Open.Enabled = $false
        $card.Last.Text = '尚无扫描记录'
        $card.Change.Text = '首次扫描将建立基线'
        $card.Change.ForeColor = $color.Muted
        $folder = $OutputDir
        if ($letter -ne 'C') { $folder = Join-Path $OutputDir $letter }
        try {
            if ([System.IO.Directory]::Exists($folder)) {
                $latest = Get-ChildItem -LiteralPath $folder -Filter 'Report-*.txt' -File |
                    Sort-Object Name -Descending | Select-Object -First 1
                if ($latest) {
                    $card.Open.Tag = $latest.FullName
                    $card.Open.Enabled = $true
                    $card.Last.Text = '上次扫描 ' + $latest.LastWriteTime.ToString('MM-dd HH:mm')
                    $card.Change.Text = '暂无两次扫描的对比'
                    $report = Read-ScanReport $latest.FullName
                    if ($report.Baseline) {
                        $card.Change.Text = '已建立基线，等待下次扫描'
                    } elseif ($report.Actual) {
                        $card.Change.Text = '占用变化 ' + $report.Actual
                        if ($report.Actual.StartsWith('+')) { $card.Change.ForeColor = $color.Low }
                        if ($report.Actual.StartsWith('-')) { $card.Change.ForeColor = $color.Good }
                    }
                }
            }
        } catch {
            $card.Change.Text = '无法读取最近一次报告摘要'
        }
    }
    $outputButton.Enabled = [System.IO.Directory]::Exists($OutputDir)
    Update-Selection
}

foreach ($card in $cards.Values) { $card.Check.add_CheckedChanged({ Update-Selection }) }
$refreshButton.add_Click({ Update-Overview })
$outputButton.add_Click({ Open-Path $OutputDir })
$detailButton.add_Click({
    $null = [System.Windows.Forms.MessageBox]::Show($form, ($state.Errors -join [Environment]::NewLine), '扫描错误', 'OK', 'Warning')
})

$scanButton.add_Click({
    $selected = @($cards.Keys | Where-Object { $cards[$_].Ready -and $cards[$_].Check.Checked })
    if ($selected.Count -eq 0) { return }
    $state.Errors = @()
    $detailButton.Visible = $false
    try {
        $state.Worker = [System.Management.Automation.PowerShell]::Create()
        $null = $state.Worker.AddScript($workerCommand.ToString()).AddArgument($ScanScript).AddArgument($OutputDir).AddArgument($selected)
        $state.Job = $state.Worker.BeginInvoke()
        $scanButton.Enabled = $false
        $refreshButton.Enabled = $false
        foreach ($card in $cards.Values) { $card.Check.Enabled = $false }
        $status.Text = '正在依次扫描 ' + ($selected -join '、') + ' 盘。'
        $activity.Visible = $true
        $timer.Start()
    } catch {
        if ($state.Worker) { $state.Worker.Dispose() }
        $state.Worker = $null
        $state.Errors = @($_.Exception.Message)
        $status.Text = '无法启动扫描。'
        $detailButton.Visible = $true
        $refreshButton.Enabled = $true
        Update-Overview
    }
})

$timer.add_Tick({
    if (-not $state.Job.IsCompleted) { return }
    $timer.Stop()
    $completed = @()
    try {
        $completed = @($state.Worker.EndInvoke($state.Job))
        $state.Errors = @($state.Worker.Streams.Warning | ForEach-Object Message) +
                        @($state.Worker.Streams.Error | ForEach-Object { $_.Exception.Message })
    } catch {
        $state.Errors = @($_.Exception.Message)
    } finally {
        $state.Worker.Dispose()
        $state.Worker = $null
        $state.Job = $null
    }
    $activity.Visible = $false
    $refreshButton.Enabled = $true
    $detailButton.Visible = $state.Errors.Count -gt 0
    Update-Overview
    if ($completed.Count -gt 0) {
        $names = ($completed | ForEach-Object Drive) -join '、'
        if ($detailButton.Visible) {
            $status.Text = "$names 盘已生成报告，部分磁盘扫描失败。"
        } else {
            $status.Text = "$names 盘扫描完成，可在对应卡片查看报告。"
        }
    } else {
        $status.Text = '本次未生成报告，可查看错误详情。'
    }
})

$form.add_FormClosing({
    param($sender, $eventArgs)
    if ($state.Worker) {
        $eventArgs.Cancel = $true
        $status.Text = '扫描仍在进行，请等待本次扫描完成。'
    }
})
try {
    Update-Overview
    $null = $form.ShowDialog()
} finally {
    $timer.Dispose()
    $form.Dispose()
    foreach ($item in $font.Values) { $item.Dispose() }
}
