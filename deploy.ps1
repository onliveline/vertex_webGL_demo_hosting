# deploy.ps1
# Copies build outputs from the Unity project into this GitHub Pages repo
# and (optionally) commits + pushes so GitHub Pages serves the update.
#
# Workflow:
#   1. In Unity:  OnVR > Bootstrap > 1 - Build Addressables + WebGL + Deploy
#   2. Then run:  .\deploy.ps1 -SkipUnityBuild -Push
#
# Or headless (close Unity Editor first!):
#   .\deploy.ps1 -Push        <- runs Unity headless + copies + pushes
#
# Flags:
#   -SkipUnityBuild     Skip Unity build (use outputs already on disk)
#   -AddressablesOnly   Copy bundles only, skip WebGL player copy
#   -DryRun             Preview without copying / committing
#   -Push               After copying, git add + commit + push to origin/main
#   -CommitMessage      Custom commit message (default: timestamped)

param(
    [switch]$SkipUnityBuild,
    [switch]$AddressablesOnly,
    [switch]$DryRun,
    [switch]$Push,
    [string]$CommitMessage
)

$unityProject = "D:\vertex_web_gl_demo_unity"
$repoRoot     = $PSScriptRoot
$logFile      = Join-Path $unityProject "unity_build.log"
$liveUrl      = "https://onliveline.github.io/vertex_webGL_demo_hosting/"

function Step($msg) { Write-Host "`n>>> $msg" -ForegroundColor Cyan }

# -- 1. Unity headless build (only when NOT skipping) -------------------------
if (-not $SkipUnityBuild) {
    $unityExe = Get-ChildItem "C:\Program Files\Unity\Hub\Editor" -Directory |
                Sort-Object Name -Descending | Select-Object -First 1 |
                ForEach-Object { Join-Path $_.FullName "Editor\Unity.exe" }

    if (-not (Test-Path $unityExe)) { Write-Error "Unity.exe not found. Close Unity and retry, or use -SkipUnityBuild."; exit 1 }

    $unityRunning = Get-Process -Name "Unity" -ErrorAction SilentlyContinue
    if ($unityRunning) {
        Write-Host ""
        Write-Host "  WARNING: Unity Editor is open. Headless build will likely fail." -ForegroundColor Yellow
        Write-Host "  Close Unity first, or use:  .\deploy.ps1 -SkipUnityBuild" -ForegroundColor Yellow
        Write-Host ""
        $confirm = Read-Host "  Continue anyway? (y/N)"
        if ($confirm -ne "y") { Write-Host "Cancelled. Close Unity and re-run, or use -SkipUnityBuild."; exit 0 }
    }

    $method = if ($AddressablesOnly) { "BuildPipeline_WebGL.BuildAddressablesOnly" } else { "BuildPipeline_WebGL.BuildAll" }
    Step "Running Unity headless: $method"
    Write-Host "  Log -> $logFile" -ForegroundColor DarkGray

    if (-not $DryRun) {
        $proc = Start-Process -FilePath $unityExe -ArgumentList @(
            "-batchmode", "-quit",
            "-projectPath", $unityProject,
            "-executeMethod", $method,
            "-logFile", $logFile
        ) -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            Write-Error "Unity build failed (exit $($proc.ExitCode)). Log: $logFile"
            if (Test-Path $logFile) { Get-Content $logFile -Tail 40 }
            exit 1
        }
        Write-Host "  Build succeeded." -ForegroundColor Green
    } else { Write-Host "  [DRY RUN] Would run Unity -executeMethod $method" -ForegroundColor Yellow }
}

# -- 2. Copy WebGL player -----------------------------------------------------
if (-not $AddressablesOnly) {
    Step "Copying WebGL player..."
    $buildSrc  = Join-Path $unityProject "vertex_webgl_demo_build\Build"
    $tplSrc    = Join-Path $unityProject "vertex_webgl_demo_build\TemplateData"
    $idxSrc    = Join-Path $unityProject "vertex_webgl_demo_build\index.html"
    $strmSrc   = Join-Path $unityProject "vertex_webgl_demo_build\StreamingAssets"
    if (-not (Test-Path $buildSrc)) { Write-Error "WebGL build not found at $buildSrc. Build in Unity first (OnVR > Bootstrap > Build)."; exit 1 }
    if (-not $DryRun) {
        if (Test-Path "$repoRoot\Build")           { Remove-Item "$repoRoot\Build" -Recurse -Force }
        if (Test-Path "$repoRoot\TemplateData")    { Remove-Item "$repoRoot\TemplateData" -Recurse -Force }
        if (Test-Path "$repoRoot\StreamingAssets") { Remove-Item "$repoRoot\StreamingAssets" -Recurse -Force }
        Copy-Item $buildSrc "$repoRoot\Build"        -Recurse -Force
        Copy-Item $tplSrc   "$repoRoot\TemplateData" -Recurse -Force
        if (Test-Path $idxSrc)  { Copy-Item $idxSrc  "$repoRoot\index.html" -Force }
        if (Test-Path $strmSrc) { Copy-Item $strmSrc "$repoRoot\StreamingAssets" -Recurse -Force }
        $mb = [math]::Round((Get-ChildItem "$repoRoot\Build" -File | Measure-Object Length -Sum).Sum/1MB,1)
        Write-Host "  Copied Build/ ($mb MB)" -ForegroundColor Green
        if (Test-Path $strmSrc) { Write-Host "  Copied StreamingAssets/ (Addressables catalog)" -ForegroundColor Green }
    } else { Write-Host "  [DRY RUN] Would copy WebGL build + StreamingAssets" -ForegroundColor Yellow }
}

# -- 3. Copy Addressables bundles ---------------------------------------------
Step "Copying Addressables bundles..."
$bundleSrc = Join-Path $unityProject "ServerData\WebGL"
$bundleDst = Join-Path $repoRoot "WebGL"
if (-not (Test-Path $bundleSrc)) { Write-Error "Bundles not found at $bundleSrc. Run Addressables build first."; exit 1 }
if (-not $DryRun) {
    if (Test-Path $bundleDst) { Remove-Item $bundleDst -Recurse -Force }
    Copy-Item $bundleSrc $bundleDst -Recurse -Force
    Write-Host "  Copied $((Get-ChildItem $bundleDst -File).Count) bundle files." -ForegroundColor Green
} else { Write-Host "  [DRY RUN] Would copy $((Get-ChildItem $bundleSrc -File).Count) bundle files." -ForegroundColor Yellow }

# -- 4. Warn about files exceeding GitHub's 100 MB hard limit -----------------
$oversize = Get-ChildItem $repoRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 100MB -and $_.FullName -notmatch '\\\.git\\' }
if ($oversize) {
    Write-Host ""
    Write-Host "  WARNING: these files exceed GitHub's 100 MB per-file limit and will be rejected:" -ForegroundColor Yellow
    $oversize | ForEach-Object {
        Write-Host ("    {0,8:N1} MB  {1}" -f ($_.Length/1MB), $_.FullName.Substring($repoRoot.Length+1)) -ForegroundColor Yellow
    }
    Write-Host "  Consider enabling Git LFS or reducing asset size." -ForegroundColor Yellow
}

# -- 5. Git commit + push -----------------------------------------------------
Step "Git status..."
Set-Location $repoRoot

if ($DryRun) {
    git status --short
    Write-Host "  [DRY RUN] Skipping commit/push." -ForegroundColor Yellow
    exit 0
}

# Stage Build/, TemplateData/, WebGL/, index.html (explicit paths - no `git add .`)
$paths = @()
if (-not $AddressablesOnly) { $paths += "Build", "TemplateData", "index.html", "StreamingAssets" }
$paths += "WebGL"

git add -- $paths
$pending = git status --porcelain
if (-not $pending) {
    Write-Host "  No changes to commit." -ForegroundColor DarkGray
    exit 0
}

if (-not $CommitMessage) {
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm"
    $CommitMessage = "Deploy WebGL build ($stamp)"
}

Step "Committing: $CommitMessage"
git commit -m $CommitMessage
if ($LASTEXITCODE -ne 0) { Write-Error "git commit failed."; exit 1 }

if ($Push) {
    Step "Pushing to origin/main..."
    git push origin main
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`nPushed. GitHub Pages should refresh within ~1 minute." -ForegroundColor Green
        Write-Host "Live at: $liveUrl" -ForegroundColor Green
    } else {
        Write-Error "git push failed (exit $LASTEXITCODE). Commit is local; push manually when ready."
        exit 1
    }
} else {
    Write-Host "`nCommit created locally. Run 'git push origin main' when ready, or re-run with -Push." -ForegroundColor Yellow
}
