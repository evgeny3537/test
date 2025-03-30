<#
.SYNOPSIS
  Скрипт для автоматической склейки изображений с использованием ICE (StitchEngine.DLL).
  Входные файлы проверяются каждые 10 секунд в папке, заданной в $config.InputFolder.
  Если файлы обнаружены – после 10-секундного ожидания запускается процесс склейки.
  Результат сохраняется в $config.OutputFolder с уникальным именем.
  Временные (уменьшённые) файлы сохраняются в $config.TempFolder.
  После экспорта выполняется заливка чёрных углов белым.
  Дополнительно проверяется папка $config.ImprovementFolder – если там есть файлы,
  вызывается функция «магия», которая выводит сообщение «Привет».
  Пул потоков настраивается: минимальное число потоков = (число логических ядер) * 16.
#>

# --- Общие настройки ---
$ErrorActionPreference = "Stop"
Set-ExecutionPolicy Bypass -Scope Process -Force

$config = @{
    BaseFolder           = "C:\Users\evgeny\Pictures\program"
    TempFolder           = "C:\Users\evgeny\Pictures\Temp"
    IceDllPath           = "C:\Users\evgeny\Pictures\program\StitchEngine.DLL"
    InputFolder          = "C:\Users\evgeny\Pictures\до обработки\склейка"
    ImprovementFolder    = "C:\Users\evgeny\Pictures\до обработки\улучшение"
    OutputFolder         = "C:\Users\evgeny\Pictures\после обработки"
    JpegQuality          = 70
    TimeoutSec           = 6000000    # Большой таймаут для каждого этапа
    UseLowRes            = $true      # Использовать уменьшённые копии для ускорения Projecting
    MaxWidth             = 3840       # Максимальная ширина при масштабировании
    MaxHeight            = 3840       # Максимальная высота при масштабировании
}

# --- Функции управления ресурсами ---

function Set-ProcessAffinityAll {
    try {
        $proc = [System.Diagnostics.Process]::GetCurrentProcess()
        $cores = (Get-WmiObject Win32_ComputerSystem).NumberOfLogicalProcessors
        $mask = [math]::Pow(2, $cores) - 1
        $proc.ProcessorAffinity = [IntPtr]::new([int]$mask)
        Write-Host "Установлена привязка к CPU: использовано $cores логических ядер." -ForegroundColor Green
    }
    catch {
        Write-Host "Ошибка установки привязки CPU: $_" -ForegroundColor Red
    }
}

function Set-ThreadPoolMin {
    try {
        $worker = 0; $io = 0
        [System.Threading.ThreadPool]::GetMinThreads([ref]$worker, [ref]$io)
        $cores = (Get-WmiObject Win32_ComputerSystem).NumberOfLogicalProcessors
        $newMin = $cores * 16
        [System.Threading.ThreadPool]::SetMinThreads($newMin, $newMin) | Out-Null
        Write-Host "Минимальное число потоков в ThreadPool установлено в $newMin (было: $worker)." -ForegroundColor Green
    }
    catch {
        Write-Host "Ошибка настройки пула потоков: $_" -ForegroundColor Red
    }
}

# --- Функция загрузки зависимостей ---
function Load-Dependencies {
    Write-Host "Загрузка зависимостей..."
    $deps = @(
        "Microsoft.ApplicationInsights.DLL",
        "Microsoft.ApplicationInsights.Extensibility.RuntimeTelemetry.DLL",
        "Microsoft.Diagnostics.Instrumentation.Extensions.Intercept.DLL",
        "Microsoft.Diagnostics.Tracing.EventSource.DLL",
        "Microsoft.Research.VisionTools.Toolkit.Desktop.DLL",
        "Microsoft.Research.VisionTools.Toolkit.DLL",
        "Microsoft.Threading.Tasks.DLL",
        "Microsoft.Threading.Tasks.Extensions.DLL",
        "Microsoft.WindowsAPICodePack.DLL",
        "Microsoft.WindowsAPICodePack.Shell.DLL",
        "Newtonsoft.Json.DLL"
    )
    foreach ($dep in $deps) {
        $depPath = Join-Path $config.BaseFolder $dep
        if (Test-Path $depPath) {
            Write-Host "Загрузка $dep..."
            Add-Type -Path $depPath -ErrorAction Stop
        }
        else {
            Write-Host "Предупреждение: Не найден файл ${depPath}" -ForegroundColor Yellow
        }
    }
}

# --- Функция инициализации окружения ---
function Initialize-Environment {
    Write-Host "[1/4] Проверка DLL StitchEngine..." -ForegroundColor Cyan
    if (-not (Test-Path $config.IceDllPath)) {
        throw "Файл StitchEngine.DLL не найден по пути: ${config.IceDllPath}"
    }
    Write-Host "[2/4] Проверка изображений в '${config.InputFolder}'..." -ForegroundColor Cyan
    $global:Images = @(Get-ChildItem -Path $config.InputFolder -Filter *.jpg)
    if ($global:Images.Count -lt 2) {
        throw "Требуется минимум 2 изображения. Найдено: ${($global:Images.Count)}"
    }
    Write-Host "[3/4] Загрузка сборок зависимостей..." -ForegroundColor Cyan
    Load-Dependencies
    Write-Host "[4/4] Загрузка сборки StitchEngine.DLL..." -ForegroundColor Cyan
    Add-Type -Path $config.IceDllPath -ErrorAction Stop
}

# --- Функция подготовки изображений (масштабирование) ---
function Prepare-ImageForStitching {
    param(
        [string]$path,
        [int]$maxWidth = $config.MaxWidth,
        [int]$maxHeight = $config.MaxHeight
    )
    Add-Type -AssemblyName System.Drawing
    try {
        $img = [System.Drawing.Image]::FromFile($path)
    }
    catch {
        throw "Ошибка загрузки изображения ${path}: $($_.Exception.Message)"
    }
    if ($img.Width -le $maxWidth -and $img.Height -le $maxHeight) {
        $img.Dispose()
        return $path
    }
    $ratio = [Math]::Min($maxWidth / $img.Width, $maxHeight / $img.Height)
    $newWidth = [int]($img.Width * $ratio)
    $newHeight = [int]($img.Height * $ratio)
    $bitmap = New-Object System.Drawing.Bitmap $newWidth, $newHeight
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.DrawImage($img, 0, 0, $newWidth, $newHeight)
    $tempFile = Join-Path $config.TempFolder ("{0}_resized.jpg" -f ([System.IO.Path]::GetFileNameWithoutExtension($path)))
    $bitmap.Save($tempFile, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $graphics.Dispose()
    $bitmap.Dispose()
    $img.Dispose()
    Write-Host "Изображение ${path} уменьшено до ${newWidth} x ${newHeight} и сохранено как ${tempFile}" -ForegroundColor Cyan
    return $tempFile
}

# --- Функция автоматической обрезки (auto crop) ---
function Set-AutoCropRect {
    param(
        [object]$stitch
    )
    if ($stitch.CompositeWidth -and $stitch.CompositeHeight -and ($stitch.CompositeWidth -gt 0) -and ($stitch.CompositeHeight -gt 0)) {
        $cropX = [int]($stitch.CompositeWidth * 0.05)
        $cropY = [int]($stitch.CompositeHeight * 0.05)
        $cropWidth = $stitch.CompositeWidth - 2 * $cropX
        $cropHeight = $stitch.CompositeHeight - 2 * $cropY
        Write-Host "Авто crop:" 
        Write-Host "  X = ${cropX}"
        Write-Host "  Y = ${cropY}"
        Write-Host "  Width = ${cropWidth}"
        Write-Host "  Height = ${cropHeight}" -ForegroundColor Cyan
        return New-Object System.Windows.Int32Rect($cropX, $cropY, $cropWidth, $cropHeight)
    }
    else {
        Write-Host "Параметры композитного изображения недоступны. Обрезка не выполняется." -ForegroundColor Yellow
        return $stitch.ResetCropRect
    }
}

# --- Функция заливки чёрных углов белым (auto completion) ---
function FillBlackCornersWithWhite {
    param(
        [string]$filePath
    )
    Add-Type -AssemblyName System.Drawing
    try {
        $bmp = New-Object System.Drawing.Bitmap($filePath)
    }
    catch {
        throw "Ошибка загрузки изображения для заливки углов: $($_.Exception.Message)"
    }
    $threshold = 64
    $maxPasses = 3
    function FloodFillArea($startX, $startY, $endX, $endY) {
        $stack = New-Object System.Collections.Stack
        for ($x = $startX; $x -le $endX; $x++) {
            for ($y = $startY; $y -le $endY; $y++) {
                $stack.Push([Tuple]::Create($x, $y))
            }
        }
        while ($stack.Count -gt 0) {
            $coord = $stack.Pop()
            $cx = $coord.Item1; $cy = $coord.Item2
            if ($cx -lt 0 -or $cy -lt 0 -or $cx -ge $bmp.Width -or $cy -ge $bmp.Height) { continue }
            $pixel = $bmp.GetPixel($cx, $cy)
            if (($pixel.R -le $threshold) -and ($pixel.G -le $threshold) -and ($pixel.B -le $threshold)) {
                $bmp.SetPixel($cx, $cy, [System.Drawing.Color]::White)
                $stack.Push([Tuple]::Create($cx+1, $cy))
                $stack.Push([Tuple]::Create($cx-1, $cy))
                $stack.Push([Tuple]::Create($cx, $cy+1))
                $stack.Push([Tuple]::Create($cx, $cy-1))
            }
        }
    }
    for ($pass = 1; $pass -le $maxPasses; $pass++) {
        $cornerSize = 50
        FloodFillArea 0 0 ($cornerSize - 1) ($cornerSize - 1)
        FloodFillArea ($bmp.Width - $cornerSize) 0 ($bmp.Width - 1) ($cornerSize - 1)
        FloodFillArea 0 ($bmp.Height - $cornerSize) ($cornerSize - 1) ($bmp.Height - 1)
        FloodFillArea ($bmp.Width - $cornerSize) ($bmp.Height - $cornerSize) ($bmp.Width - 1) ($bmp.Height - 1)
    }
    $newFilePath = [System.IO.Path]::Combine(
        [System.IO.Path]::GetDirectoryName($filePath),
        ([System.IO.Path]::GetFileNameWithoutExtension($filePath) + "_whitecorners.jpg")
    )
    $bmp.Save($newFilePath, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $bmp.Dispose()
  #  Write-Host "Изображение `${filePath}`: чёрные углы залиты белым. Результат: ${newFilePath}" -ForegroundColor Cyan
    return $newFilePath
}

# --- Функция ожидания завершения этапа ---
$global:TaskCompletedFlag = $false
function Wait-ForTaskCompletionWithDiagnostic {
    param(
        [int]$TimeoutSec,
        [object]$stitch
    )
    $elapsed = 0
    while (-not $global:TaskCompletedFlag -and $elapsed -lt $TimeoutSec) {
        Start-Sleep -Seconds 1
        $elapsed++
    }
    if (-not $global:TaskCompletedFlag) {
        throw "Таймаут ожидания завершения задачи (больше ${TimeoutSec} сек). Последняя ошибка: '$($stitch.LastErrorMessage)'"
    }
    $global:TaskCompletedFlag = $false
}

# --- Основной процесс склейки ---
function Invoke-StitchingProcess {
    Write-Host "[Инициализация StitchEngine...]" -ForegroundColor Green
    $stitch = New-Object Microsoft.Research.ICE.Stitching.StitchEngineWrapper
    if (-not $stitch) { throw "Не удалось создать экземпляр StitchEngineWrapper." }
    Unregister-Event -SourceIdentifier "StitchTaskCompleted" -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier "StitchProgressChanged" -ErrorAction SilentlyContinue

    $null = Register-ObjectEvent -InputObject $stitch -EventName TaskCompleted -SourceIdentifier "StitchTaskCompleted" -Action {
        $global:TaskCompletedFlag = $true
    }
    $null = Register-ObjectEvent -InputObject $stitch -EventName ProgressChanged -SourceIdentifier "StitchProgressChanged" -Action {
       # Write-Host -NoNewline "."
    }

    $project = New-Object Microsoft.Research.ICE.Stitching.StitchProjectInfo
    foreach ($file in $global:Images) {
        $pathToUse = $file.FullName
        if ($config.UseLowRes) {
            $resized = Prepare-ImageForStitching -path $file.FullName
            if ($resized -ne $file.FullName) {
                $global:TempFiles += $resized
                $pathToUse = $resized
            }
        }
        try {
            $imgInfo = New-Object Microsoft.Research.ICE.Stitching.ImageInfo($pathToUse, $null)
            $project.SourceImages.Add($imgInfo) | Out-Null
            Write-Host "Добавлено изображение: $($file.Name)" -ForegroundColor DarkGray
        }
        catch {
            throw "Ошибка добавления изображения ${file.FullName}: $($_.Exception.Message)"
        }
    }

    if (-not $stitch.InitializeFromProjectInfo($project)) {
        throw "Ошибка инициализации: $($stitch.LastErrorMessage)"
    }
    Write-Host "Инициализация прошла успешно." -ForegroundColor Green

    $steps = @("Aligning", "Compositing", "Projecting")
    foreach ($step in $steps) {
        Write-Host ""
        Write-Host "=== Этап ${step} ===" -ForegroundColor Magenta
        $method = "Start$step"
        $stitch.$method() | Out-Null
        Wait-ForTaskCompletionWithDiagnostic -TimeoutSec $config.TimeoutSec -stitch $stitch
        if ($stitch.HasLastError) {
            throw "Ошибка на этапе ${step}: $($stitch.LastErrorMessage)"
        }
        Write-Host "Этап ${step} завершен успешно." -ForegroundColor Green
        Start-Sleep -Seconds 1
    }

    $cropRect = $stitch.ResetCropRect

    Write-Host ""
    Write-Host "=== Экспорт результата ===" -ForegroundColor Magenta
    if (-not (Test-Path $config.OutputFolder)) {
        New-Item -Path $config.OutputFolder -ItemType Directory -Force | Out-Null
    }
    $outputPath = Join-Path $config.OutputFolder ("stitched_" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".jpg")
    #Write-Host "Целевой файл: $outputPath" -ForegroundColor Cyan

    $exportFormat  = [Microsoft.Research.ICE.Stitching.ExportFormat]::JPEG
    $exportOptions = New-Object Microsoft.Research.ICE.Stitching.OutputOptions($exportFormat, $config.JpegQuality, $true, $false, $false)

    $stitch.StartExporting($outputPath, $cropRect, 1, $exportOptions, $false) | Out-Null
    Wait-ForTaskCompletionWithDiagnostic -TimeoutSec $config.TimeoutSec -stitch $stitch
    if ($stitch.HasLastError) {
        throw "Ошибка экспорта: $($stitch.LastErrorMessage)"
    }
   # Write-Host "Экспорт завершен успешно: $outputPath" -ForegroundColor Green

    Unregister-Event -SourceIdentifier "StitchTaskCompleted" -Force
    Unregister-Event -SourceIdentifier "StitchProgressChanged" -Force
    $stitch.Dispose()

    try {
        $filled = FillBlackCornersWithWhite -filePath $outputPath
        if ($filled -ne $outputPath) {
            Remove-Item $outputPath -Force
            Rename-Item $filled $outputPath -Force
            Write-Host "Итоговое изображение сохранено как $outputPath" -ForegroundColor Green
        }
    }
    catch {
        Write-Host "Ошибка при заливке чёрных углов: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    foreach ($tmp in $global:TempFiles) {
        if (Test-Path $tmp) { Remove-Item $tmp -Force }
    }
    $global:TempFiles = @()
}

# --- Функция "магия" ---
function магия {
    Write-Host ""
    Write-Host "Привет" -ForegroundColor Magenta
}

# --- Основной цикл ---
while ($true) {
    $files = Get-ChildItem -Path $config.InputFolder -Filter *.jpg
    if ($files.Count -gt 0) {
        Write-Host "Обнаружены файлы для склейки. Ждём 10 секунд для стабилизации..."
        Start-Sleep -Seconds 10
        $files = Get-ChildItem -Path $config.InputFolder -Filter *.jpg
        if ($files.Count -gt 0) {
            Write-Host "Запуск задачи склейки..."
            Initialize-Environment
            Set-ProcessAffinityAll
            Set-ThreadPoolMin
            Invoke-StitchingProcess
            Write-Host "Склейка завершена. Удаляю исходные файлы..."
            Get-ChildItem -Path $config.InputFolder -Filter *.jpg | Remove-Item -Force
        }
    }
    $improveFiles = Get-ChildItem -Path $config.ImprovementFolder -Filter *.jpg
    if ($improveFiles.Count -gt 0) {
        Write-Host "Обнаружены файлы для улучшения. Ждём 10 секунд..."
        Start-Sleep -Seconds 10
        $improveFiles = Get-ChildItem -Path $config.ImprovementFolder -Filter *.jpg
        if ($improveFiles.Count -gt 0) {
            Write-Host "Запуск магии..."
            магия
        }
    }
    Start-Sleep -Seconds 10
}
