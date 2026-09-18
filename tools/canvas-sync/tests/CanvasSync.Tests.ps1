$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'CanvasSync.psm1'
Import-Module $modulePath -Force

Describe 'CanvasSync path handling' {
    It 'removes the Canvas root folder name' {
        Get-CanvasRelativeFolder 'course files/slides/week 1' | Should Be ([IO.Path]::Combine('slides', 'week 1'))
    }

    It 'sanitizes Windows-invalid characters' {
        ConvertTo-SafePathSegment 'week:1?.pdf' | Should Be 'week_1_.pdf'
    }

    It 'protects Windows reserved names' {
        ConvertTo-SafePathSegment 'CON.txt' | Should Be '_CON.txt'
    }

    It 'creates a stable conflict filename' {
        $root = Join-Path $TestDrive 'materials'
        New-Item -ItemType Directory -Path $root | Out-Null
        Get-ConflictPath (Join-Path $root '2-EDA.pdf') '42' | Should Be (Join-Path $root '2-EDA.canvas-conflict-42.pdf')
    }
}

Describe 'CanvasSync course matching and pagination' {
    It 'matches a course code embedded in DSC5002' {
        $courses = @(
            [pscustomobject]@{ id = 10; course_code = 'DSC5002'; name = 'Exploratory Data Analysis'; original_name = $null; sis_course_id = $null },
            [pscustomobject]@{ id = 11; course_code = 'DSC5003'; name = 'Data Storage'; original_name = $null; sis_course_id = $null }
        )
        @(Find-CanvasCourseCandidates -Courses $courses -Code '5002').Count | Should Be 1
        @(Find-CanvasCourseCandidates -Courses $courses -Code '5002')[0].id | Should Be 10
    }

    It 'handles Canvas course objects with optional properties omitted' {
        $courses = @(
            [pscustomobject]@{ id = 20; course_code = 'DSC5002'; name = 'Exploratory Data Analysis' }
        )
        @(Find-CanvasCourseCandidates -Courses $courses -Code '5002').Count | Should Be 1
    }

    It 'extracts the next pagination link' {
        $link = '<https://canvas.cityu.edu.hk/api/v1/courses?page=2>; rel="next", <https://canvas.cityu.edu.hk/api/v1/courses?page=3>; rel="last"'
        Get-NextLink $link | Should Be 'https://canvas.cityu.edu.hk/api/v1/courses?page=2'
    }
}

Describe 'CanvasSync download safety' {
    InModuleScope CanvasSync {
        It 'keeps an unmanaged local file and writes a conflict copy' {
            $target = Join-Path $TestDrive 'materials\slides\lesson.pdf'
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            [IO.File]::WriteAllText($target, 'local-copy')
            $file = [pscustomobject]@{ id = 42; url = 'https://example.invalid/file'; size = 11 }

            Mock Invoke-WebRequest {
                param($Method, $Uri, $Headers, $OutFile)
                [IO.File]::WriteAllText($OutFile, 'canvas-copy')
            }

            $result = Receive-CanvasFile -File $file -TargetPath $target -Headers @{} -Mode ExistingUnmanaged
            $result.Outcome | Should Be 'Conflict'
            [IO.File]::ReadAllText($target) | Should Be 'local-copy'
            [IO.File]::ReadAllText($result.Path) | Should Be 'canvas-copy'
        }

        It 'replaces a file already managed by the synchronizer' {
            $target = Join-Path $TestDrive 'managed\lesson.pdf'
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            [IO.File]::WriteAllText($target, 'old-version')
            $file = [pscustomobject]@{ id = 43; url = 'https://example.invalid/file'; size = 11 }

            Mock Invoke-WebRequest {
                param($Method, $Uri, $Headers, $OutFile)
                [IO.File]::WriteAllText($OutFile, 'new-version')
            }

            $result = Receive-CanvasFile -File $file -TargetPath $target -Headers @{} -Mode Updated
            $result.Outcome | Should Be 'Updated'
            [IO.File]::ReadAllText($target) | Should Be 'new-version'
        }
    }
}
