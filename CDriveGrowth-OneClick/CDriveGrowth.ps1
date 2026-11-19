# Windows PowerShell 5.1, Windows 10 x86/x64. Run once per day.
[CmdletBinding()]
param(
    [string]$OutputDir,
    [string[]]$Drive = @('C'),
    [switch]$SelectDrives,
    [switch]$OpenReport,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $scriptFolder = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptFolder) -and $MyInvocation.MyCommand.Path) {
        $scriptFolder = [IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
    }
    if ([string]::IsNullOrWhiteSpace($scriptFolder)) {
        throw 'Unable to locate the script folder. Run the extracted Scan-C-Drive.cmd.'
    }
    $OutputDir = [IO.Path]::Combine($scriptFolder, 'CDriveGrowth-Data')
}
if ($SelectDrives) {
    $Drive = @(Read-Host 'Enter drives to scan (C, D, E, or CDE). Press Enter for C')
    if ([string]::IsNullOrWhiteSpace($Drive[0])) { $Drive = @('C') }
}
$selection = ($Drive -join ',') -replace '[,\s]', ''
if ($selection -notmatch '^[CDE]+$') {
    throw 'Enter one or more drive letters from C, D and E, for example CDE or C,D.'
}
$selectedDrives = $selection.ToUpperInvariant().ToCharArray() | Select-Object -Unique
$outputBase = [IO.Path]::GetFullPath($OutputDir).TrimEnd('\')
if ($outputBase -eq [IO.Path]::GetPathRoot($outputBase + '\').TrimEnd('\')) {
    throw 'Choose a dedicated output subfolder, such as D:\CDriveGrowth.'
}

if (-not ('CDriveGrowth' -as [type])) {
    Add-Type -ReferencedAssemblies 'System.dll' -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;
using System.Collections.Generic;
using System.Text;

public static class CDriveGrowth
{
    private static readonly StringComparer Paths = StringComparer.OrdinalIgnoreCase;
    private const int Top = 30;

    private sealed class Snapshot : IDisposable
    {
        public readonly BinaryReader Reader;
        public readonly DateTime Time;
        public readonly long Free;
        public string Path;
        public long Size;

        public Snapshot(string file)
        {
            Reader = new BinaryReader(new GZipStream(File.OpenRead(file), CompressionMode.Decompress));
            try {
                if (Reader.ReadString() != "CDriveGrowth-v1") throw new InvalidDataException(file);
                Time = DateTime.FromBinary(Reader.ReadInt64());
                Free = Reader.ReadInt64();
                Advance();
            } catch { Reader.Dispose(); throw; }
        }
        public void Advance()
        {
            Path = Reader.ReadString();
            if (Path.Length == 0) { Path = null; return; }
            Size = Reader.ReadInt64();
        }
        public void Dispose() { Reader.Dispose(); }
    }

    private sealed class Entry
    {
        public string Path;
        public string Label;
        public long Delta;
    }

    private static bool IsReadError(Exception error)
    {
        return error is IOException || error is UnauthorizedAccessException ||
               error is System.Security.SecurityException || error is ArgumentException ||
               error is NotSupportedException;
    }

    private static void ListFiles(DirectoryInfo folder, string excluded, BinaryWriter writer,
                                  SortedDictionary<string, string> skipped)
    {
        FileSystemInfo[] items;
        try { items = folder.GetFileSystemInfos(); }
        catch (Exception error) {
            if (!IsReadError(error) || folder.Parent == null) throw;
            skipped[folder.FullName] = error.Message;
            return;
        }
        // A directory sorts as its path plus the separator, the shared prefix of all its files.
        Array.Sort(items, delegate(FileSystemInfo a, FileSystemInfo b) {
            return Paths.Compare(a.Name + (a is DirectoryInfo ? "\\" : ""),
                                 b.Name + (b is DirectoryInfo ? "\\" : ""));
        });
        foreach (FileSystemInfo item in items) {
            if (Paths.Equals(item.FullName, excluded)) {
                skipped[item.FullName] = "脚本自己的输出目录";
                continue;
            }
            long size = 0;
            try {
                if ((item.Attributes & FileAttributes.ReparsePoint) != 0) {
                    skipped[item.FullName] = "重解析点，包括联接、符号链接和部分云占位文件";
                    continue;
                }
                FileInfo file = item as FileInfo;
                if (file != null) size = file.Length;
            } catch (Exception error) {
                if (!IsReadError(error)) throw;
                skipped[item.FullName] = error.Message;
                continue;
            }
            DirectoryInfo subfolder = item as DirectoryInfo;
            if (subfolder != null) ListFiles(subfolder, excluded, writer, skipped);
            else {
                writer.Write(item.FullName);
                writer.Write(size);
            }
        }
    }

    private static void WriteSnapshot(string root, string excluded, string file)
    {
        var skipped = new SortedDictionary<string, string>(Paths);
        using (var writer = new BinaryWriter(new GZipStream(File.Create(file), CompressionMode.Compress))) {
            writer.Write("CDriveGrowth-v1");
            writer.Write(DateTime.Now.ToBinary());
            writer.Write(new DriveInfo(root).TotalFreeSpace);
            ListFiles(new DirectoryInfo(root), excluded, writer, skipped);
            writer.Write("");
            writer.Write(skipped.Count);
            foreach (var skip in skipped) {
                writer.Write(skip.Key);
                writer.Write(skip.Value);
            }
        }
    }

    private static Dictionary<string, string> ReadSkipped(Snapshot snapshot, List<Entry> largest)
    {
        while (snapshot.Path != null) {
            if (largest != null && snapshot.Size > 0)
                Track(largest, snapshot.Path, "", snapshot.Size);
            snapshot.Advance();
        }
        var skipped = new Dictionary<string, string>(Paths);
        int count = snapshot.Reader.ReadInt32();
        for (int i = 0; i < count; i++) {
            string path = snapshot.Reader.ReadString();
            skipped.Add(path, snapshot.Reader.ReadString());
        }
        return skipped;
    }

    private static bool WasSkipped(Dictionary<string, string> skipped, string path)
    {
        for (int end = path.Length; end >= 3; end = path.LastIndexOf('\\', end - 1)) {
            if (skipped.ContainsKey(path.Substring(0, end))) return true;
        }
        return false;
    }

    private static void Track(List<Entry> entries, string path, string label, long delta)
    {
        if (entries.Count == Top && entries[Top - 1].Delta >= delta) return;
        int index = entries.FindIndex(delegate(Entry entry) { return entry.Delta < delta; });
        var candidate = new Entry { Path = path, Label = label, Delta = delta };
        if (index < 0) entries.Add(candidate);
        else entries.Insert(index, candidate);
        if (entries.Count > Top) entries.RemoveAt(Top);
    }

    private static string Size(long bytes)
    {
        return String.Format("{0:+0.00;-0.00;0.00} MiB ({1:+#,0;-#,0;0} 字节)", bytes / 1048576.0, bytes);
    }

    private static void PrintTop(TextWriter report, string title, List<Entry> entries, int sign)
    {
        report.WriteLine();
        report.WriteLine(title);
        if (entries.Count == 0) report.WriteLine("  无");
        foreach (Entry entry in entries)
            report.WriteLine("  {0}  {1}  {2}", Size(sign * entry.Delta), entry.Label, entry.Path);
    }

    private static void Compare(string root, TextWriter report, Snapshot oldScan, Snapshot newScan,
                                Dictionary<string, string> oldSkipped, Dictionary<string, string> newSkipped)
    {
        var added = new List<Entry>();
        var reduced = new List<Entry>();
        var folders = new Dictionary<string, long>(Paths);
        long net = 0, unknown = 0, newFiles = 0, grown = 0, gone = 0, shrunk = 0;
        while (oldScan.Path != null || newScan.Path != null) {
            int order = oldScan.Path == null ? 1 : newScan.Path == null ? -1 :
                        Paths.Compare(oldScan.Path, newScan.Path);
            string path = order < 0 ? oldScan.Path : newScan.Path;
            long delta;
            string label;
            if (order < 0) {
                delta = -oldScan.Size;
                oldScan.Advance();
                if (WasSkipped(newSkipped, path)) { unknown++; continue; }
                label = "消失";
                gone++;
            } else if (order > 0) {
                delta = newScan.Size;
                newScan.Advance();
                if (WasSkipped(oldSkipped, path)) { unknown++; continue; }
                label = "新增";
                newFiles++;
            } else {
                delta = newScan.Size - oldScan.Size;
                oldScan.Advance();
                newScan.Advance();
                if (delta == 0) continue;
                label = delta > 0 ? "变大" : "缩小";
                if (delta > 0) grown++;
                else shrunk++;
            }
            if (delta == 0) continue;
            net += delta;
            int first = path.IndexOf('\\', 3);
            int second = first < 0 ? -1 : path.IndexOf('\\', first + 1);
            string folder = second >= 0 ? path.Substring(0, second) :
                            first >= 0 ? path.Substring(0, first) : root;
            long current;
            folders.TryGetValue(folder, out current);
            folders[folder] = current + delta;
            if (delta > 0) Track(added, path, label, delta);
            else Track(reduced, path, label, -delta);
        }

        long used = oldScan.Free - newScan.Free;
        report.WriteLine("比较区间  {0:yyyy-MM-dd HH:mm:ss} 至 {1:yyyy-MM-dd HH:mm:ss}", oldScan.Time, newScan.Time);
        report.WriteLine("{0} 盘实际占用变化  {1}", root[0], Size(used));
        report.WriteLine("可比较文件的逻辑大小净变化  {0}", Size(net));
        report.WriteLine("实际占用变化减去文件逻辑净变化  {0}", Size(used - net));
        report.WriteLine("新增 {0:N0}  变大 {1:N0}  消失 {2:N0}  缩小 {3:N0}", newFiles, grown, gone, shrunk);
        report.WriteLine("因至少一次扫描无法读取而无法判定的路径  {0:N0}", unknown);
        var topFolders = new List<Entry>();
        foreach (var folder in folders)
            if (folder.Value > 0) Track(topFolders, folder.Key, "净增长", folder.Value);
        PrintTop(report, "目录净增长前 30 项（汇总至所选盘下最多两层）", topFolders, 1);
        PrintTop(report, "新增或变大前 30 项", added, 1);
        PrintTop(report, "消失或缩小前 30 项", reduced, -1);
        report.WriteLine();
        report.WriteLine("文件按路径比较，移动或改名可能表现为一增一减。");
        report.WriteLine("差额较大时，结合跳过清单检查系统保护目录、卷影副本、NTFS 元数据、压缩、稀疏文件和硬链接。");
        report.WriteLine("可在管理员命令提示符运行 vssadmin list shadowstorage 查看卷影副本占用。");
    }

    public static string Run(string root, string output, string excluded)
    {
        string baseline = Path.Combine(output, "baseline.bin.gz");
        string temporary = Path.Combine(output, "baseline.pending");
        string timestamp = DateTime.Now.ToString("yyyyMMdd-HHmmss-fff");
        string reportPath = Path.Combine(output, "Report-" + timestamp + ".txt");
        string pendingReport = reportPath + ".tmp";
        try {
            WriteSnapshot(root, excluded, temporary);
            Dictionary<string, string> newSkipped;
            Dictionary<string, string> oldSkipped = null;
            if (File.Exists(baseline)) {
                using (var scan = new Snapshot(baseline)) oldSkipped = ReadSkipped(scan, null);
            }
            var largest = oldSkipped == null ? new List<Entry>() : null;
            using (var scan = new Snapshot(temporary)) newSkipped = ReadSkipped(scan, largest);
            using (var report = new StreamWriter(pendingReport, false, new UTF8Encoding(true))) {
                report.WriteLine("{0} 盘空间变化报告", root[0]);
                using (var newScan = new Snapshot(temporary)) {
                    report.WriteLine("本次扫描开始时的 {0} 盘剩余空间  {1:N2} GiB", root[0], newScan.Free / 1073741824.0);
                    if (oldSkipped == null) {
                        report.WriteLine("首次扫描，已生成对比基线。下次运行将列出变化。");
                        PrintTop(report, "当前可读取文件中最大的 30 项（逻辑大小）", largest, 1);
                    } else {
                        using (var oldScan = new Snapshot(baseline))
                            Compare(root, report, oldScan, newScan, oldSkipped, newSkipped);
                    }
                }
                report.WriteLine();
                report.WriteLine("本次跳过的文件或目录（{0:N0} 项）", newSkipped.Count);
                foreach (var skip in new SortedDictionary<string, string>(newSkipped, Paths))
                    report.WriteLine("  {0}  {1}", skip.Key, skip.Value);
            }
            File.Move(pendingReport, reportPath);
            if (File.Exists(baseline)) File.Replace(temporary, baseline, null);
            else File.Move(temporary, baseline);
            return reportPath;
        } finally {
            if (File.Exists(temporary)) File.Delete(temporary);
            if (File.Exists(pendingReport)) File.Delete(pendingReport);
        }
    }
}
'@
}

$reports = @()
$failedDrives = @()
foreach ($letter in $selectedDrives) {
    try {
        $driveRoot = "${letter}:\"
        $volume = [IO.DriveInfo]::new($driveRoot)
        if (-not $volume.IsReady) {
            throw "Drive $driveRoot is unavailable. Check that it is connected and unlocked."
        }
        $driveOutput = $outputBase
        if ($letter -ne 'C') {
            $driveOutput = Join-Path $outputBase ([string]$letter)
        }
        [IO.Directory]::CreateDirectory($driveOutput) | Out-Null
        $lock = [IO.File]::Open((Join-Path $driveOutput 'scan.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            Write-Host "Scanning $driveRoot (read-only). This may take several minutes."
            $report = [CDriveGrowth]::Run($driveRoot, $driveOutput, $outputBase)
            $reports += $report
            Write-Host "Report: $report"
            if ($PassThru) {
                [pscustomobject]@{ Drive = [string]$letter; Path = $report }
            }
        } finally {
            $lock.Dispose()
        }
    } catch {
        $failedDrives += $letter
        Write-Warning ("Drive {0}: {1}" -f $letter, $_.Exception.Message)
    }
}
if ($OpenReport) {
    foreach ($report in $reports) {
        Invoke-Item -LiteralPath $report -ErrorAction Continue
    }
}
if ($failedDrives.Count -gt 0) {
    throw ('Scan failed for: ' + ($failedDrives -join ', '))
}
