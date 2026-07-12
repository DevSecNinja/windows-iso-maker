function New-ZipArchiveFromFile {
    <#
    .SYNOPSIS
        Create a .zip archive containing a single file, streaming to disk.
    .DESCRIPTION
        Uses the .NET System.IO.Compression.ZipFile API (native to the runtime, no extra
        dependency) instead of Compress-Archive. Compress-Archive buffers the entry in a
        MemoryStream and throws "Stream was too long." for inputs larger than ~2 GB, which
        is fatal for multi-gigabyte Windows ISOs. ZipArchive streams the entry and emits
        Zip64 headers automatically when the file exceeds 4 GB.
    .PARAMETER SourceFile
        Path to the file to place inside the archive.
    .PARAMETER DestinationArchive
        Path of the .zip archive to create. Any existing file is overwritten by the caller.
    .PARAMETER EntryName
        Name of the entry inside the archive. Defaults to the source file name.
    .PARAMETER CompressionLevel
        System.IO.Compression.CompressionLevel name (Optimal, Fastest, NoCompression).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $SourceFile,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $DestinationArchive,

        [Parameter()]
        [string] $EntryName,

        [Parameter()]
        [ValidateSet('Optimal', 'Fastest', 'NoCompression')]
        [string] $CompressionLevel = 'Optimal'
    )

    # ZipFile lives in System.IO.Compression.FileSystem on Windows PowerShell 5.1; it is part
    # of the shared framework on PowerShell 7 (Add-Type there throws, which we ignore).
    try { Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction Stop } catch { $null = $_ }

    if (-not $EntryName) {
        $EntryName = [System.IO.Path]::GetFileName($SourceFile)
    }
    $level = [System.IO.Compression.CompressionLevel]::$CompressionLevel

    $zip = [System.IO.Compression.ZipFile]::Open($DestinationArchive, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $SourceFile, $EntryName, $level) | Out-Null
    }
    finally {
        $zip.Dispose()
    }
}
