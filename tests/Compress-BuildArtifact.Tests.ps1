#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for Compress-BuildArtifact and the New-ZipArchiveFromFile streaming-zip helper.
    The zip path uses System.IO.Compression.ZipFile instead of Compress-Archive because
    Compress-Archive throws "Stream was too long." on inputs larger than ~2 GB.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'src/WindowsIsoMaker') -Force
}

Describe 'New-ZipArchiveFromFile' {
    BeforeEach {
        $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-zip-" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null
    }
    AfterEach {
        if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
            Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'creates a zip that round-trips the source file content' {
        $src = Join-Path $script:WorkDir 'fake.iso'
        $content = 'hello-iso-' + ('x' * 5000)
        Set-Content -LiteralPath $src -Value $content -NoNewline -Encoding utf8
        $zip = Join-Path $script:WorkDir 'out.zip'

        InModuleScope WindowsIsoMaker -Parameters @{ Src = $src; Zip = $zip } {
            param($Src, $Zip)
            New-ZipArchiveFromFile -SourceFile $Src -DestinationArchive $Zip
        }

        Test-Path -LiteralPath $zip | Should -BeTrue

        $extractDir = Join-Path $script:WorkDir 'extract'
        Expand-Archive -LiteralPath $zip -DestinationPath $extractDir -Force
        $extracted = Join-Path $extractDir 'fake.iso'
        Test-Path -LiteralPath $extracted | Should -BeTrue
        (Get-Content -LiteralPath $extracted -Raw) | Should -Be $content
    }

    It 'uses the provided EntryName for the archive entry' {
        $src = Join-Path $script:WorkDir 'source.bin'
        Set-Content -LiteralPath $src -Value 'data' -NoNewline
        $zip = Join-Path $script:WorkDir 'named.zip'

        InModuleScope WindowsIsoMaker -Parameters @{ Src = $src; Zip = $zip } {
            param($Src, $Zip)
            New-ZipArchiveFromFile -SourceFile $Src -DestinationArchive $Zip -EntryName 'Windows11.iso'
        }

        try { Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction Stop } catch { Write-Verbose "System.IO.Compression.FileSystem already loaded: $_" }
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
        try {
            $names = @($archive.Entries | ForEach-Object { $_.FullName })
        }
        finally {
            $archive.Dispose()
        }
        $names | Should -Contain 'Windows11.iso'
    }

    It 'resolves a relative destination against PowerShell $PWD, not the .NET current directory' {
        # Regression: [ZipFile]::Open resolves relative paths against [Environment]::CurrentDirectory
        # (the process start dir), which differs from $PWD, so './out/x.zip' landed in the wrong place.
        $src = Join-Path $script:WorkDir 'fake.iso'
        Set-Content -LiteralPath $src -Value 'iso' -NoNewline
        $outDir = Join-Path $script:WorkDir 'out'
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null

        # Point the .NET current directory somewhere else entirely to prove it is not used.
        $savedNetCwd = [System.Environment]::CurrentDirectory
        [System.Environment]::CurrentDirectory = [System.IO.Path]::GetTempPath()
        Push-Location -LiteralPath $script:WorkDir
        try {
            InModuleScope WindowsIsoMaker -Parameters @{ Src = $src } {
                param($Src)
                New-ZipArchiveFromFile -SourceFile $Src -DestinationArchive './out/relative.zip'
            }
            (Join-Path $outDir 'relative.zip') | Should -Exist
        }
        finally {
            Pop-Location
            [System.Environment]::CurrentDirectory = $savedNetCwd
        }
    }
}

Describe 'Compress-BuildArtifact (zip format)' {
    BeforeEach {
        $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wim-cba-" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null
    }
    AfterEach {
        if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
            Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'produces a zip artifact with a checksum without invoking Compress-Archive' {
        $iso = Join-Path $script:WorkDir 'Windows11-Pro-amd64-latest.iso'
        Set-Content -LiteralPath $iso -Value ('iso-bytes-' + ('y' * 2000)) -NoNewline

        $result = Compress-BuildArtifact -IsoPath $iso -OutputDirectory $script:WorkDir -Format zip -Edition Pro -Architecture amd64 -Release latest

        $result.ArchivePath | Should -Exist
        $result.ArchivePath | Should -BeLike '*Windows11-Pro-amd64-latest.zip'
        $result.Sha256 | Should -Not -BeNullOrEmpty
        $result.SizeBytes | Should -BeGreaterThan 0
    }

    It 'returns an absolute ArchivePath anchored next to $PWD for a relative OutputDirectory' {
        # Regression: a relative OutputDirectory (e.g. './out') must resolve next to where the
        # build runs, not the process/home directory. New-Item -Force's .FullName is authoritative,
        # so the archive lands beside $PWD and the returned ArchivePath is absolute.
        $iso = Join-Path $script:WorkDir 'Windows11-Pro-amd64-latest.iso'
        Set-Content -LiteralPath $iso -Value ('iso-bytes-' + ('z' * 2000)) -NoNewline

        Push-Location -LiteralPath $script:WorkDir
        try {
            $result = Compress-BuildArtifact -IsoPath $iso -OutputDirectory './out' -Format zip -Edition Pro -Architecture amd64 -Release latest
        }
        finally {
            Pop-Location
        }

        [System.IO.Path]::IsPathRooted($result.ArchivePath) | Should -BeTrue
        $result.ArchivePath | Should -Exist
        $expected = Join-Path (Join-Path $script:WorkDir 'out') 'Windows11-Pro-amd64-latest.zip'
        # Compare canonical paths (handles any 8.3/short-name or casing differences).
        (Convert-Path -LiteralPath $result.ArchivePath) | Should -Be (Convert-Path -LiteralPath $expected)
    }
}
